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
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/openai_compat_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

const _config = ProviderConfig(
  id: 'test',
  displayName: 'Test',
  kind: ProviderKind.openaiCompat,
  baseUrl: 'https://example.invalid/v1',
  modelId: 'test-model',
);

/// Responds with [body] as a single chunk, capturing the outgoing request.
MockClient _clientReturning(String body, {int status = 200, List<http.BaseRequest>? capture}) {
  return MockClient((request) async {
    capture?.add(request);
    return http.Response(body, status, request: request);
  });
}

OpenAiCompatProvider _provider(http.Client client) =>
    OpenAiCompatProvider(config: _config, apiKey: 'fake-key', httpClient: client);

Future<List<LlmEvent>> _run(OpenAiCompatProvider provider, {List<ToolSpec> tools = const []}) {
  return provider
      .stream(
        messages: [const Message(role: MessageRole.user, content: 'log my weight')],
        tools: tools,
      )
      .toList();
}

void main() {
  test('parses text deltas then a tool call whose arguments span two frames', () async {
    final body = File(
      'test/features/ai/providers/fixtures/openai_stream_tool_call.txt',
    ).readAsStringSync();

    final events = await _run(_provider(_clientReturning(body)));

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Sure, one moment.');

    final calls = events.whereType<ToolCallRequested>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.call.id, 'call_1');
    expect(calls.single.call.name, 'log_weight');
    // The fixture splits `{"value":` and `82.4}` across frames; if reassembly
    // is wrong this is where it shows.
    expect(calls.single.call.arguments['value'], 82.4);

    expect(events.last, isA<TurnComplete>());
  });

  test('maps HTTP 401 to a non-retriable ProviderError', () async {
    final events = await _run(
      _provider(_clientReturning('{"error":"bad key"}', status: 401)),
    );

    final err = events.whereType<ProviderError>().single;
    expect(err.retriable, isFalse);
    expect(err.message, contains('401'));
    expect(events.whereType<TurnComplete>(), isEmpty);
  });

  test('maps HTTP 429 to a retriable ProviderError', () async {
    final events = await _run(_provider(_clientReturning('slow down', status: 429)));
    expect(events.whereType<ProviderError>().single.retriable, isTrue);
  });

  test('maps HTTP 500 to a retriable ProviderError', () async {
    final events = await _run(_provider(_clientReturning('boom', status: 500)));
    expect(events.whereType<ProviderError>().single.retriable, isTrue);
  });

  test('a network failure is retriable, not a crash', () async {
    final client = MockClient((request) async => throw const SocketException('offline'));
    final events = await _run(_provider(client));

    final err = events.whereType<ProviderError>().single;
    expect(err.retriable, isTrue);
    expect(err.message.toLowerCase(), contains('network'));
  });

  test('sends a bearer token and the configured model', () async {
    final capture = <http.BaseRequest>[];
    await _run(_provider(_clientReturning('data: [DONE]\n\n', capture: capture)));

    final request = capture.single as http.Request;
    expect(request.headers['authorization'], 'Bearer fake-key');
    expect(request.url.toString(), 'https://example.invalid/v1/chat/completions');

    final body = jsonDecode(request.body) as Map<String, dynamic>;
    expect(body['model'], 'test-model');
    expect(body['stream'], isTrue);
  });

  test('omits the tools field entirely when no tools are offered', () async {
    final capture = <http.BaseRequest>[];
    await _run(_provider(_clientReturning('data: [DONE]\n\n', capture: capture)));

    final body = jsonDecode((capture.single as http.Request).body) as Map<String, dynamic>;
    expect(body.containsKey('tools'), isFalse);
  });

  test('encodes tool specs as OpenAI function definitions', () async {
    final capture = <http.BaseRequest>[];
    await _run(
      _provider(_clientReturning('data: [DONE]\n\n', capture: capture)),
      tools: const [
        ToolSpec(
          name: 'log_weight',
          description: 'Records a weight',
          inputSchema: {
            'type': 'object',
            'properties': {
              'value': {'type': 'number'},
            },
          },
        ),
      ],
    );

    final body = jsonDecode((capture.single as http.Request).body) as Map<String, dynamic>;
    final tool = (body['tools'] as List).single as Map<String, dynamic>;
    expect(tool['type'], 'function');
    expect((tool['function'] as Map)['name'], 'log_weight');
    expect(((tool['function'] as Map)['parameters'] as Map)['type'], 'object');
  });

  test('malformed tool arguments produce an error, not a bad tool call', () async {
    const body = 'data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1",'
        '"function":{"name":"log_weight","arguments":"{not json"}}]},"index":0}]}\n\n'
        'data: [DONE]\n\n';

    final events = await _run(_provider(_clientReturning(body)));

    expect(events.whereType<ToolCallRequested>(), isEmpty);
    expect(events.whereType<ProviderError>().single.message, contains('log_weight'));
  });

  test('an unparseable SSE frame is skipped without killing the stream', () async {
    const body = 'data: {this is not json}\n\n'
        'data: {"choices":[{"delta":{"content":"still here"},"index":0}]}\n\n'
        'data: [DONE]\n\n';

    final events = await _run(_provider(_clientReturning(body)));

    expect(events.whereType<TextDelta>().single.text, 'still here');
    expect(events.last, isA<TurnComplete>());
  });
}
