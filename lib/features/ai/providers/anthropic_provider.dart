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

/// Speaks Anthropic's Messages API.
///
/// This is the Console API-key path, and deliberately the only one. OmniHealth
/// does not support Claude subscription OAuth: Anthropic restricts those
/// credentials to first-party products and enforces it server-side, so routing
/// a user's subscription through a third-party app risks their account.
///
/// Three things differ from the OpenAI dialect and are the reason this is a
/// separate adapter rather than a config entry: auth uses `x-api-key` plus a
/// version header; the system prompt is a top-level field rather than a
/// message; and tool arguments stream as `input_json_delta` fragments inside
/// named content blocks.
class AnthropicProvider implements LlmProvider {
  static const _apiVersion = '2023-06-01';
  static const _maxTokens = 4096;

  final ProviderConfig config;
  final String apiKey;
  final http.Client httpClient;

  final _logger = Logger('AnthropicProvider');

  AnthropicProvider({
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
    // Anthropic takes the system prompt as a top-level field and rejects a
    // system-role turn in `messages`, so split them apart.
    final systemPrompt = messages
        .where((m) => m.role == MessageRole.system)
        .map((m) => m.content)
        .join('\n');
    final conversation = messages.where((m) => m.role != MessageRole.system).toList();

    final request = http.Request('POST', Uri.parse('${config.baseUrl}/messages'))
      ..headers.addAll({
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': config.modelId,
        'max_tokens': _maxTokens,
        'stream': true,
        if (systemPrompt.isNotEmpty) 'system': systemPrompt,
        'messages': conversation
            .map((m) => {'role': m.role.wireName, 'content': m.content})
            .toList(),
        if (tools.isNotEmpty)
          'tools': tools
              .map(
                (t) => {
                  'name': t.name,
                  'description': t.description,
                  'input_schema': t.inputSchema,
                },
              )
              .toList(),
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
      // 529 is Anthropic's "overloaded"; it lands in the >=500 bucket.
      final retriable = response.statusCode == 429 || response.statusCode >= 500;
      yield ProviderError(
        'HTTP ${response.statusCode}: ${body.trim()}',
        retriable: retriable,
      );
      return;
    }

    final pending = <int, _PartialToolUse>{};

    await for (final line
        in response.stream.transform(utf8.decoder).transform(const LineSplitter())) {
      // `event:` lines carry no information the payload lacks — the JSON
      // repeats the type — so only `data:` is read.
      if (!line.startsWith('data:')) {
        continue;
      }
      final payload = line.substring(5).trim();
      if (payload.isEmpty) {
        continue;
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        _logger.warning('Skipping unparseable event payload');
        continue;
      }

      switch (json['type'] as String?) {
        case 'content_block_start':
          final block = json['content_block'] as Map<String, dynamic>?;
          if (block != null && block['type'] == 'tool_use') {
            pending[json['index'] as int] = _PartialToolUse(
              id: block['id'] as String,
              name: block['name'] as String,
            );
          }
        case 'content_block_delta':
          final delta = json['delta'] as Map<String, dynamic>?;
          if (delta == null) {
            break;
          }
          switch (delta['type'] as String?) {
            case 'text_delta':
              yield TextDelta(delta['text'] as String? ?? '');
            case 'input_json_delta':
              pending[json['index'] as int]?.input.write(
                delta['partial_json'] as String? ?? '',
              );
          }
        case 'message_stop':
          break;
      }
    }

    for (final p in pending.values) {
      final raw = p.input.toString();
      final Map<String, dynamic> parsed;
      try {
        parsed = raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        yield ProviderError('Model emitted malformed tool arguments for ${p.name}');
        continue;
      }
      yield ToolCallRequested(ToolCall(id: p.id, name: p.name, arguments: parsed));
    }

    yield const TurnComplete();
  }
}

class _PartialToolUse {
  final String id;
  final String name;
  final StringBuffer input = StringBuffer();

  _PartialToolUse({required this.id, required this.name});
}
