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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wger/features/ai/providers/anthropic_provider.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

const _config = ProviderConfig(
  id: 'claude',
  displayName: 'Claude',
  kind: ProviderKind.anthropic,
  baseUrl: 'https://api.anthropic.invalid/v1',
  modelId: 'claude-test',
);

MockClient _clientReturning(String body, {int status = 200, List<http.BaseRequest>? capture}) {
  return MockClient((request) async {
    capture?.add(request);
    return http.Response(body, status, request: request);
  });
}

AnthropicProvider _provider(http.Client client) =>
    AnthropicProvider(config: _config, apiKey: 'secret', httpClient: client);

Future<List<LlmEvent>> _run(
  AnthropicProvider provider, {
  List<Message>? messages,
  List<ToolSpec> tools = const [],
}) {
  return provider
      .stream(
        messages: messages ?? [const Message(role: MessageRole.user, content: 'log my weight')],
        tools: tools,
      )
      .toList();
}

void main() {
  test('parses text then a tool_use whose input spans two frames', () async {
    final body = File(
      'test/features/ai/providers/fixtures/anthropic_stream_tool_use.txt',
    ).readAsStringSync();

    final events = await _run(_provider(_clientReturning(body)));

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Sure, one moment.');

    final call = events.whereType<ToolCallRequested>().single.call;
    expect(call.id, 'toolu_1');
    expect(call.name, 'log_weight');
    expect(call.arguments['value'], 82.4);
    expect(events.last, isA<TurnComplete>());
  });

  test('authenticates with x-api-key and a version header, never a bearer token', () async {
    final capture = <http.BaseRequest>[];
    await _run(_provider(_clientReturning('', capture: capture)));

    final headers = capture.single.headers;
    expect(headers['x-api-key'], 'secret');
    expect(headers.containsKey('anthropic-version'), isTrue);
    expect(headers.containsKey('authorization'), isFalse);
  });

  test('hoists system messages into the top-level system field', () async {
    final capture = <http.BaseRequest>[];
    await _run(
      _provider(_clientReturning('', capture: capture)),
      messages: const [
        Message(role: MessageRole.system, content: 'You are helpful.'),
        Message(role: MessageRole.user, content: 'hi'),
      ],
    );

    final body = jsonDecode((capture.single as http.Request).body) as Map<String, dynamic>;
    expect(body['system'], 'You are helpful.');
    // The system turn must not also appear in messages — Anthropic rejects it.
    expect(body['messages'] as List, hasLength(1));
    expect(((body['messages'] as List).single as Map)['role'], 'user');
  });

  test('omits the system field entirely when there is no system message', () async {
    final capture = <http.BaseRequest>[];
    await _run(_provider(_clientReturning('', capture: capture)));

    final body = jsonDecode((capture.single as http.Request).body) as Map<String, dynamic>;
    expect(body.containsKey('system'), isFalse);
  });

  test('encodes tools with input_schema, not OpenAI parameters', () async {
    final capture = <http.BaseRequest>[];
    await _run(
      _provider(_clientReturning('', capture: capture)),
      tools: const [
        ToolSpec(
          name: 'log_weight',
          description: 'Records a weight',
          inputSchema: {'type': 'object', 'properties': {}},
        ),
      ],
    );

    final body = jsonDecode((capture.single as http.Request).body) as Map<String, dynamic>;
    final tool = (body['tools'] as List).single as Map<String, dynamic>;
    expect(tool['name'], 'log_weight');
    expect(tool.containsKey('input_schema'), isTrue);
    expect(tool.containsKey('parameters'), isFalse);
  });

  test('maps HTTP 401 to a non-retriable ProviderError', () async {
    final events = await _run(_provider(_clientReturning('bad key', status: 401)));
    final err = events.whereType<ProviderError>().single;
    expect(err.retriable, isFalse);
    expect(err.message, contains('401'));
  });

  test('maps HTTP 429 and 529 to retriable ProviderErrors', () async {
    for (final status in [429, 529]) {
      final events = await _run(_provider(_clientReturning('busy', status: status)));
      expect(
        events.whereType<ProviderError>().single.retriable,
        isTrue,
        reason: 'HTTP $status should be retriable',
      );
    }
  });

  test('a network failure is retriable, not a crash', () async {
    final client = MockClient((request) async => throw const SocketException('offline'));
    final events = await _run(_provider(client));

    final err = events.whereType<ProviderError>().single;
    expect(err.retriable, isTrue);
    expect(err.message.toLowerCase(), contains('network'));
  });

  test('malformed tool input produces an error, not a bad tool call', () async {
    const body =
        'data: {"type":"content_block_start","index":0,"content_block":'
        '{"type":"tool_use","id":"toolu_1","name":"log_weight","input":{}}}\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":'
        '{"type":"input_json_delta","partial_json":"{not json"}}\n\n'
        'data: {"type":"message_stop"}\n\n';

    final events = await _run(_provider(_clientReturning(body)));

    expect(events.whereType<ToolCallRequested>(), isEmpty);
    expect(events.whereType<ProviderError>().single.message, contains('log_weight'));
  });

  test('an unparseable frame is skipped without killing the stream', () async {
    const body =
        'data: {broken\n\n'
        'data: {"type":"content_block_delta","index":0,"delta":'
        '{"type":"text_delta","text":"still here"}}\n\n'
        'data: {"type":"message_stop"}\n\n';

    final events = await _run(_provider(_clientReturning(body)));

    expect(events.whereType<TextDelta>().single.text, 'still here');
    expect(events.last, isA<TurnComplete>());
  });
}
