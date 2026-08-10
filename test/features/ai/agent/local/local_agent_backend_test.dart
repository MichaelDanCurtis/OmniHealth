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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/agent/local/local_agent_backend.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';
import '../../support/scripted_provider.dart';

class EchoTool implements Tool {
  int calls = 0;

  @override
  String get name => 'echo';

  @override
  String get description => 'Echoes';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': <String, dynamic>{}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    calls++;
    return ToolResult.ok({'echoed': true});
  }
}

ToolRegistry _registryWith(Tool tool) =>
    ToolRegistry(tokenService: ConfirmationTokenService())..register(tool);

List<LlmEvent> _toolTurn(String name) => [
  ToolCallRequested(ToolCall(id: 'c1', name: name, arguments: const {})),
  const TurnComplete(),
];

void main() {
  test('streams plain text and completes', () async {
    final provider = ScriptedProvider([
      [const TextDelta('Hello'), const TextDelta(' there'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    final events = await backend.sendMessage('hi').toList();

    expect(events.whereType<AgentText>().map((e) => e.text).join(), 'Hello there');
    expect(events.last, isA<AgentTurnComplete>());
  });

  test('executes a tool call and feeds the result back for a second turn', () async {
    final tool = EchoTool();
    final provider = ScriptedProvider([
      _toolTurn('echo'),
      [const TextDelta('done'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(tool));

    final events = await backend.sendMessage('go').toList();

    expect(tool.calls, 1);
    expect(events.whereType<AgentToolStarted>().single.name, 'echo');
    expect(events.whereType<AgentToolFinished>().single.isError, isFalse);
    expect(events.whereType<AgentText>().map((e) => e.text).join(), 'done');

    // The second request must carry the tool result back, or the model is
    // answering blind.
    expect(provider.received, hasLength(2));
    expect(provider.received[1].any((m) => m.role == MessageRole.tool), isTrue);
    expect(
      provider.received[1].firstWhere((m) => m.role == MessageRole.tool).toolCallId,
      'c1',
    );
  });

  test('a failing tool is reported to the model, not thrown', () async {
    final provider = ScriptedProvider([
      _toolTurn('missing'),
      [const TextDelta('sorry'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    final events = await backend.sendMessage('go').toList();

    expect(events.whereType<AgentToolFinished>().single.isError, isTrue);
    expect(events.last, isA<AgentTurnComplete>());

    final toolMessage = provider.received[1].firstWhere((m) => m.role == MessageRole.tool);
    expect(toolMessage.content, startsWith('ERROR:'));
  });

  test('a provider error surfaces as AgentFailure and ends the turn', () async {
    final provider = ScriptedProvider([
      [const ProviderError('bad key')],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    final events = await backend.sendMessage('hi').toList();

    final failure = events.whereType<AgentFailure>().single;
    expect(failure.message, contains('bad key'));
    expect(failure.retriable, isFalse);
    expect(events.whereType<AgentTurnComplete>(), isEmpty);
  });

  test('a retriable provider error is marked retriable', () async {
    final provider = ScriptedProvider([
      [const ProviderError('rate limited', retriable: true)],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    final events = await backend.sendMessage('hi').toList();
    expect(events.whereType<AgentFailure>().single.retriable, isTrue);
  });

  test('stops at the iteration cap instead of looping forever', () async {
    // Every turn asks for another tool call; without a cap this never ends and
    // spends the user's own API credit doing it.
    final provider = ScriptedProvider(List.generate(50, (_) => _toolTurn('echo')));
    final tool = EchoTool();
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(tool),
      maxIterations: 3,
    );

    final events = await backend.sendMessage('go').toList();

    expect(tool.calls, 3);
    expect(
      events.whereType<AgentFailure>().single.message.toLowerCase(),
      contains('too many'),
    );
  });

  test('cancel mid-turn stops the loop well short of the cap', () async {
    final provider = ScriptedProvider(List.generate(50, (_) => _toolTurn('echo')));
    final tool = EchoTool();
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(tool),
      maxIterations: 50,
    );

    final events = <AgentEvent>[];
    late final StreamSubscription<AgentEvent> sub;
    final done = Completer<void>();

    sub = backend.sendMessage('go').listen(
      (e) async {
        events.add(e);
        // Cancel as soon as the first tool starts, the way a user tapping stop
        // would.
        if (e is AgentToolStarted && events.length == 1) {
          await backend.cancel();
        }
      },
      onDone: done.complete,
    );

    await done.future;
    await sub.cancel();

    expect(tool.calls, lessThan(50));
    expect(events.length, lessThan(50));
    expect(events.whereType<AgentFailure>(), isEmpty, reason: 'cancel is not a failure');
  });

  test('a cancel before the next message does not suppress that message', () async {
    // cancel() ends the current turn; it must not poison the next one.
    final provider = ScriptedProvider([
      [const TextDelta('first'), const TurnComplete()],
      [const TextDelta('second'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    await backend.sendMessage('one').toList();
    await backend.cancel();

    final events = await backend.sendMessage('two').toList();
    expect(events.whereType<AgentText>().map((e) => e.text).join(), 'second');
  });

  test('history accumulates user and assistant turns', () async {
    final provider = ScriptedProvider([
      [const TextDelta('hi back'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    await backend.sendMessage('hello').toList();

    expect(backend.history.first.role, MessageRole.user);
    expect(backend.history.first.content, 'hello');
    expect(backend.history.last.role, MessageRole.assistant);
    expect(backend.history.last.content, 'hi back');
  });

  test('dispose clears the conversation', () async {
    final provider = ScriptedProvider([
      [const TextDelta('x'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(EchoTool()));

    await backend.sendMessage('hello').toList();
    await backend.dispose();

    expect(backend.history, isEmpty);
  });
}
