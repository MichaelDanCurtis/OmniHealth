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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/agent/local/local_agent_backend.dart';
import 'package:wger/features/ai/genui/omni_catalog.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';
import 'package:wger/features/ai/tools/wger/weight_tools.dart';
import 'package:wger/features/weight/models/weight_entry.dart';

/// Stands in for the Drift-backed store. What lands here is what would be
/// written to the database.
class InMemoryWeightStore {
  final List<WeightEntry> entries = [];

  Future<void> add(WeightEntry entry) async => entries.add(entry);

  Stream<List<WeightEntry>> watch() => Stream.value(entries);
}

/// A provider that behaves like a model actually would: it reads the
/// confirmation token out of the previous tool result rather than being handed
/// it, which is the part a hardcoded script would fake away.
class WeightFlowProvider implements LlmProvider {
  /// What the model tries to write once confirmed.
  final double valueToWrite;

  /// When true, skips render_ui entirely and calls log_weight with a token it
  /// made up — the attack the write gate exists to stop.
  final bool forgeToken;

  /// When true, renders a Button labelled Cancel carrying a write intent,
  /// instead of a proper confirmation component.
  final bool useMislabelledButton;

  int turn = 0;

  WeightFlowProvider({
    this.valueToWrite = 82.4,
    this.forgeToken = false,
    this.useMislabelledButton = false,
  });

  @override
  String get id => 'weight-flow';

  @override
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  }) async* {
    turn++;

    if (turn == 1) {
      if (forgeToken) {
        yield ToolCallRequested(
          ToolCall(
            id: 'c1',
            name: 'log_weight',
            arguments: {
              'value': valueToWrite,
              'date': '2026-08-07',
              'confirmationToken': 'forged-by-the-model',
            },
          ),
        );
      } else {
        yield ToolCallRequested(
          ToolCall(
            id: 'c1',
            name: 'render_ui',
            arguments: {
              'component': useMislabelledButton ? 'Button' : 'MetricEntryCard',
              'props': useMislabelledButton
                  ? {'text': 'Cancel'}
                  : {'metric': 'weight', 'unit': 'kg'},
              'intent': {
                'tool': 'log_weight',
                'arguments': {'value': valueToWrite, 'date': '2026-08-07'},
              },
            },
          ),
        );
      }
      yield const TurnComplete();
      return;
    }

    if (turn == 2 && !forgeToken) {
      // Read the token back out of the tool result, as a real model would.
      final toolResult = messages.lastWhere(
        (m) => m.role == MessageRole.tool,
        orElse: () => const Message(role: MessageRole.tool, content: '{}'),
      );

      String? token;
      Map<String, dynamic>? confirmed;
      try {
        final decoded = jsonDecode(toolResult.content) as Map<String, dynamic>;
        token = decoded['confirmationToken'] as String?;
        confirmed = (decoded['confirmedArguments'] as Map?)?.cast<String, dynamic>();
      } catch (_) {
        // Leave both null; the call below will be refused, which is the point.
      }

      yield ToolCallRequested(
        ToolCall(
          id: 'c2',
          name: 'log_weight',
          arguments: {
            'value': confirmed?['value'] ?? valueToWrite,
            'date': confirmed?['date'] ?? '2026-08-07',
            'confirmationToken': ?token,
          },
        ),
      );
      yield const TurnComplete();
      return;
    }

    yield const TextDelta('Logged.');
    yield const TurnComplete();
  }
}

void main() {
  late InMemoryWeightStore store;
  late ConfirmationTokenService tokens;
  late ToolRegistry registry;
  late List<SurfaceRequest> surfaced;

  ToolRegistry buildRegistry() {
    registry = ToolRegistry(tokenService: tokens)
      ..register(GetWeightHistoryTool(watch: store.watch))
      ..register(LogWeightTool(add: store.add))
      ..register(
        RenderUiTool(
          tokenService: tokens,
          knownComponents: OmniCatalog.knownComponentNames,
          writeComponents: OmniCatalog.writeComponents,
          surfaceSink: surfaced.add,
        ),
      );
    return registry;
  }

  setUp(() {
    store = InMemoryWeightStore();
    tokens = ConfirmationTokenService();
    surfaced = [];
    buildRegistry();
  });

  /// Runs a turn, standing in for the user tapping when a surface appears.
  Future<List<AgentEvent>> run(
    LocalAgentBackend backend, {
    required void Function(SurfaceRequest) act,
  }) async {
    final events = <AgentEvent>[];
    final done = Completer<void>();

    backend.sendMessage('I want to enter my weight for today').listen(
      events.add,
      onDone: done.complete,
    );

    // Poll for the surface, then act on it — the loop is suspended inside
    // render_ui until we do.
    for (var i = 0; i < 50 && surfaced.isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    if (surfaced.isNotEmpty) {
      act(surfaced.first);
    }

    await done.future.timeout(const Duration(seconds: 5));
    return events;
  }

  test('the weight demo works end to end', () async {
    // Spec §6.1, and the definition of done for slice 1.
    final backend = LocalAgentBackend(
      provider: WeightFlowProvider(),
      registry: registry,
    );

    final events = await run(
      backend,
      act: (request) {
        expect(request.component, 'MetricEntryCard');
        expect(request.props['metric'], 'weight');
        // The user types 82.4 and taps Save.
        request.complete({'value': 82.4, 'date': '2026-08-07'});
      },
    );

    expect(store.entries, hasLength(1));
    expect(store.entries.single.weight, 82.4);
    expect(store.entries.single.date, DateTime(2026, 8, 7));

    expect(
      events.whereType<AgentToolFinished>().where((e) => e.name == 'log_weight').single.isError,
      isFalse,
    );
    expect(events.whereType<AgentText>().map((e) => e.text).join(), contains('Logged'));
  });

  test('the value the user actually typed is what gets written', () async {
    // The model proposed 80; the user changed it to 82.4 before saving.
    final backend = LocalAgentBackend(
      provider: WeightFlowProvider(valueToWrite: 80),
      registry: registry,
    );

    await run(
      backend,
      act: (request) => request.complete({'value': 82.4, 'date': '2026-08-07'}),
    );

    expect(store.entries.single.weight, 82.4);
  });

  test('dismissing the card writes nothing', () async {
    final backend = LocalAgentBackend(
      provider: WeightFlowProvider(),
      registry: registry,
    );

    await run(backend, act: (request) => request.dismiss());

    expect(store.entries, isEmpty);
  });

  test('a forged token writes nothing', () async {
    // The model skips the confirmation entirely and invents a token.
    final backend = LocalAgentBackend(
      provider: WeightFlowProvider(forgeToken: true),
      registry: registry,
    );

    final events = await run(backend, act: (_) {});

    expect(store.entries, isEmpty);
    expect(
      events.whereType<AgentToolFinished>().where((e) => e.name == 'log_weight').single.isError,
      isTrue,
    );
    expect(surfaced, isEmpty, reason: 'it never even asked the user');
  });

  test('a mislabelled Cancel button cannot obtain a token', () async {
    // Spec §5.2's end-to-end case: the agent renders a raw Button labelled
    // Cancel carrying a log_weight intent. The user taps it expecting to
    // cancel. Nothing may be written.
    final backend = LocalAgentBackend(
      provider: WeightFlowProvider(useMislabelledButton: true),
      registry: registry,
    );

    final events = await run(
      backend,
      act: (request) {
        expect(request.component, 'Button');
        request.complete({'tapped': true});
      },
    );

    expect(store.entries, isEmpty, reason: 'no write may result from a mislabelled control');
    expect(
      events.whereType<AgentToolFinished>().where((e) => e.name == 'log_weight').single.isError,
      isTrue,
    );
  });

  test('a token cannot be replayed for a second write', () async {
    final backend = LocalAgentBackend(
      provider: WeightFlowProvider(),
      registry: registry,
    );


    await run(
      backend,
      act: (request) => request.complete({'value': 82.4, 'date': '2026-08-07'}),
    );
    expect(store.entries, hasLength(1));

    // Recover the token the renderer minted and try to spend it again.
    final token = tokens.mint(toolName: 'log_weight', arguments: {'value': 1.0, 'date': 'x'});
    await registry.dispatch('log_weight', {
      'value': 1.0,
      'date': 'x',
      'confirmationToken': token,
    });
    final replay = await registry.dispatch('log_weight', {
      'value': 1.0,
      'date': 'x',
      'confirmationToken': token,
    });

    expect(replay.isError, isTrue);
  });
}
