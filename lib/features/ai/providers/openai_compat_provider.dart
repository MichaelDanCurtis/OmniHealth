/*
 * This file is part of OmniHealth <https://github.com/wger-project>.
 * Copyright (c) 2026, OmniHealth contributors
 *
 * OmniHealth is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program.  If not, see <http://www.gnu.org/licenses/>.
 */

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

/// Speaks the OpenAI `/chat/completions` streaming dialect, which OpenAI, Grok,
/// Kimi and GLM all accept.
class OpenAiCompatProvider implements LlmProvider {
  final ProviderConfig config;
  final String apiKey;
  final http.Client httpClient;

  final _logger = Logger('OpenAiCompatProvider');

  OpenAiCompatProvider({
    required this.config,
    required this.apiKey,
    required this.httpClient,
  });

  @override
  String get id => config.id;

  @override
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  }) async* {
    final request = http.Request('POST', Uri.parse('${config.baseUrl}/chat/completions'))
      ..headers.addAll({
        'content-type': 'application/json',
        'authorization': 'Bearer $apiKey',
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': config.modelId,
        'stream': true,
        'messages': messages.map(_encodeMessage).toList(),
        if (tools.isNotEmpty) 'tools': tools.map(_encodeTool).toList(),
      });

    final http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } catch (e) {
      yield ProviderError('Network error: $e', retriable: true);
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      // 408/429 and 5xx are transient. Everything else needs the user to act,
      // so offering a retry button would just waste their time.
      final retriable =
          response.statusCode == 408 ||
          response.statusCode == 429 ||
          response.statusCode >= 500;
      yield ProviderError(
        'HTTP ${response.statusCode}: ${body.trim()}',
        retriable: retriable,
      );
      return;
    }

    // Tool calls arrive as fragments keyed by index — the name in one frame,
    // the arguments split across any number of later ones. Accumulate, then
    // emit each call once, whole.
    final pending = <int, _PartialToolCall>{};

    await for (final line
        in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      if (!line.startsWith('data:')) {
        continue;
      }
      final payload = line.substring(5).trim();
      if (payload.isEmpty) {
        continue;
      }
      if (payload == '[DONE]') {
        break;
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        // One bad frame should not lose the rest of the response.
        _logger.warning('Skipping unparseable SSE frame');
        continue;
      }

      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) {
        continue;
      }
      final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
      if (delta == null) {
        continue;
      }

      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        yield TextDelta(content);
      }

      final toolCalls = delta['tool_calls'] as List<dynamic>?;
      if (toolCalls == null) {
        continue;
      }
      for (final raw in toolCalls.cast<Map<String, dynamic>>()) {
        final index = raw['index'] as int? ?? 0;
        final partial = pending.putIfAbsent(index, _PartialToolCall.new);
        partial.id = (raw['id'] as String?) ?? partial.id;

        final fn = raw['function'] as Map<String, dynamic>?;
        if (fn == null) {
          continue;
        }
        partial.name = (fn['name'] as String?) ?? partial.name;
        partial.arguments.write((fn['arguments'] as String?) ?? '');
      }
    }

    for (final partial in pending.values) {
      final raw = partial.arguments.toString();
      final Map<String, dynamic> parsed;
      try {
        parsed = raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        // Emitting a half-parsed call would hand the registry garbage; tell the
        // agent instead so it can try again.
        yield ProviderError('Model emitted malformed tool arguments for ${partial.name}');
        continue;
      }
      yield ToolCallRequested(
        ToolCall(id: partial.id, name: partial.name, arguments: parsed),
      );
    }

    yield const TurnComplete();
  }

  Map<String, dynamic> _encodeTool(ToolSpec spec) => {
    'type': 'function',
    'function': {
      'name': spec.name,
      'description': spec.description,
      'parameters': spec.inputSchema,
    },
  };

  Map<String, dynamic> _encodeMessage(Message m) => {
    'role': m.role.wireName,
    'content': m.content,
    if (m.toolCallId != null) 'tool_call_id': m.toolCallId,
    if (m.toolCalls.isNotEmpty)
      'tool_calls': m.toolCalls
          .map(
            (c) => {
              'id': c.id,
              'type': 'function',
              'function': {'name': c.name, 'arguments': jsonEncode(c.arguments)},
            },
          )
          .toList(),
  };
}

class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
