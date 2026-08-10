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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/chat/providers/chat_notifier.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';

/// Emits a scripted event sequence, so the notifier can be driven through
/// states a real model would produce only rarely.
class FakeBackend implements AgentBackend {
  final List<AgentEvent> events;
  final Duration gap;

  bool cancelled = false;
  bool disposed = false;

  FakeBackend(this.events, {this.gap = Duration.zero});

  @override
  Stream<AgentEvent> sendMessage(String text) async* {
    for (final event in events) {
      if (cancelled) {
        return;
      }
      if (gap > Duration.zero) {
        await Future<void>.delayed(gap);
      }
      yield event;
    }
  }

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async => disposed = true;
}

void main() {
  late ProviderContainer container;

  ChatNotifier notifier() => container.read(chatProvider.notifier);
  ChatState chatState() => container.read(chatProvider);

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  void attach(List<AgentEvent> events) {
    notifier().attachBackend(FakeBackend(events));
  }

  test('a sent message appears in the transcript', () async {
    attach([const AgentText('hi there'), const AgentTurnComplete()]);
    await notifier().send('hello');

    expect(chatState().entries.first, isA<UserEntry>());
    expect((chatState().entries.first as UserEntry).text, 'hello');
  });

  test('assistant text deltas coalesce into one entry', () async {
    attach([
      const AgentText('Hello'),
      const AgentText(' there'),
      const AgentTurnComplete(),
    ]);
    await notifier().send('hi');

    final assistant = chatState().entries.whereType<AssistantEntry>().toList();
    expect(assistant, hasLength(1));
    expect(assistant.single.text, 'Hello there');
  });

  test('an empty message is ignored', () async {
    attach([const AgentTurnComplete()]);
    await notifier().send('   ');

    expect(chatState().entries, isEmpty);
  });

  test('sending with no backend attached does nothing', () async {
    await notifier().send('hello');
    expect(chatState().entries, isEmpty);
  });

  test('a tool shows as running then finished', () async {
    attach([
      const AgentToolStarted('log_weight'),
      const AgentToolFinished('log_weight', isError: false),
      const AgentTurnComplete(),
    ]);
    await notifier().send('log it');

    final tool = chatState().entries.whereType<ToolEntry>().single;
    expect(tool.name, 'log_weight');
    expect(tool.running, isFalse);
    expect(tool.isError, isFalse);
  });

  test('a failed tool is marked as an error, not hidden', () async {
    attach([
      const AgentToolStarted('log_weight'),
      const AgentToolFinished('log_weight', isError: true),
      const AgentTurnComplete(),
    ]);
    await notifier().send('log it');

    expect(chatState().entries.whereType<ToolEntry>().single.isError, isTrue);
  });

  test('render_ui gets no tool chip — its surface is the visible thing', () async {
    attach([
      const AgentToolStarted('render_ui'),
      const AgentToolFinished('render_ui', isError: false),
      const AgentTurnComplete(),
    ]);
    await notifier().send('log my weight');

    expect(chatState().entries.whereType<ToolEntry>(), isEmpty);
  });

  test('a provider failure becomes a visible, retriable entry', () async {
    attach([const AgentFailure('rate limited', retriable: true)]);
    await notifier().send('hi');

    final failure = chatState().entries.whereType<FailureEntry>().single;
    expect(failure.message, contains('rate limited'));
    expect(failure.retriable, isTrue);
  });

  test('a surface request appears inline in the transcript', () async {
    attach([const AgentTurnComplete()]);
    notifier().onSurfaceRequested(
      SurfaceRequest(component: 'MetricEntryCard', props: const {'metric': 'weight'}),
    );

    final surface = chatState().entries.whereType<SurfaceEntry>().single;
    expect(surface.request.component, 'MetricEntryCard');
    expect(surface.resolved, isFalse);
  });

  test('resolving a surface marks it so the UI can collapse it', () async {
    attach([const AgentTurnComplete()]);
    final request = SurfaceRequest(component: 'ConfirmationCard', props: const {});
    notifier().onSurfaceRequested(request);

    final entry = chatState().entries.whereType<SurfaceEntry>().single;
    notifier().markSurfaceResolved(entry);

    expect(chatState().entries.whereType<SurfaceEntry>().single.resolved, isTrue);
  });

  test('busy clears when the turn ends', () async {
    attach([const AgentText('done'), const AgentTurnComplete()]);
    await notifier().send('hi');

    expect(chatState().busy, isFalse);
  });

  test('cancel dismisses any surface still waiting', () async {
    // Otherwise the render_ui call never returns and the turn hangs forever.
    attach([const AgentTurnComplete()]);
    final request = SurfaceRequest(component: 'MetricEntryCard', props: const {});
    notifier().onSurfaceRequested(request);

    var settled = false;
    unawaited(request.outcome.then((_) => settled = true));

    await notifier().cancel();
    await Future<void>.delayed(Duration.zero);

    expect(settled, isTrue);
    expect(chatState().entries.whereType<SurfaceEntry>().single.resolved, isTrue);
  });

  test('cancel stops the backend and clears busy', () async {
    final backend = FakeBackend(
      List.generate(100, (_) => const AgentText('x')),
      gap: const Duration(milliseconds: 5),
    );
    notifier().attachBackend(backend);

    unawaited(notifier().send('go'));
    await Future<void>.delayed(const Duration(milliseconds: 15));
    await notifier().cancel();

    expect(backend.cancelled, isTrue);
    expect(chatState().busy, isFalse);
  });

  test('a second turn starts a new assistant entry', () async {
    attach([const AgentText('first'), const AgentTurnComplete()]);
    await notifier().send('one');

    notifier().attachBackend(
      FakeBackend([const AgentText('second'), const AgentTurnComplete()]),
    );
    await notifier().send('two');

    final assistants = chatState().entries.whereType<AssistantEntry>().toList();
    expect(assistants.map((a) => a.text), ['first', 'second']);
  });
}
