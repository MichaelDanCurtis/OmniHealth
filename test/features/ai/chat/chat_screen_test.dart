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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/chat/providers/chat_notifier.dart';
import 'package:wger/features/ai/chat/screens/chat_screen.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';
import 'package:wger/features/ai/genui/widgets/confirmation_card.dart';
import 'package:wger/features/ai/genui/widgets/metric_chart.dart';
import 'package:wger/features/ai/genui/widgets/metric_entry_card.dart';

class FakeBackend implements AgentBackend {
  final List<AgentEvent> events;
  bool cancelled = false;

  FakeBackend(this.events);

  @override
  Stream<AgentEvent> sendMessage(String text) => Stream.fromIterable(events);

  @override
  Future<void> cancel() async => cancelled = true;

  @override
  Future<void> dispose() async {}
}

void main() {
  late ProviderContainer container;

  setUp(() => container = ProviderContainer());
  tearDown(() => container.dispose());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: ChatScreen()),
      ),
    );
    await tester.pump();
  }

  void surface(String component, Map<String, dynamic> props) {
    container
        .read(chatProvider.notifier)
        .onSurfaceRequested(SurfaceRequest(component: component, props: props));
  }

  testWidgets('typing and sending appends the message', (tester) async {
    container.read(chatProvider.notifier).attachBackend(
      FakeBackend([const AgentText('hi'), const AgentTurnComplete()]),
    );
    await pump(tester);

    await tester.enterText(find.byKey(ChatScreen.inputKey), 'hello');
    await tester.tap(find.byKey(ChatScreen.sendKey));
    await tester.pumpAndSettle();

    expect(find.text('hello'), findsOneWidget);
    expect(find.text('hi'), findsOneWidget);
  });

  testWidgets('a failure is shown, not swallowed', (tester) async {
    container.read(chatProvider.notifier).attachBackend(
      FakeBackend([const AgentFailure('bad key')]),
    );
    await pump(tester);

    await tester.enterText(find.byKey(ChatScreen.inputKey), 'hi');
    await tester.tap(find.byKey(ChatScreen.sendKey));
    await tester.pumpAndSettle();

    expect(find.textContaining('bad key'), findsOneWidget);
  });

  testWidgets('a retriable failure says so', (tester) async {
    container.read(chatProvider.notifier).attachBackend(
      FakeBackend([const AgentFailure('rate limited', retriable: true)]),
    );
    await pump(tester);

    await tester.enterText(find.byKey(ChatScreen.inputKey), 'hi');
    await tester.tap(find.byKey(ChatScreen.sendKey));
    await tester.pumpAndSettle();

    expect(find.textContaining('try again'), findsOneWidget);
  });

  group('inline surfaces', () {
    testWidgets('a MetricEntryCard renders inline', (tester) async {
      await pump(tester);
      surface('MetricEntryCard', {'metric': 'weight', 'unit': 'kg'});
      await tester.pump();

      expect(find.byType(MetricEntryCard), findsOneWidget);
    });

    testWidgets('submitting completes the suspended tool call', (tester) async {
      await pump(tester);

      final request = SurfaceRequest(
        component: 'MetricEntryCard',
        props: const {'metric': 'weight', 'unit': 'kg'},
      );
      container.read(chatProvider.notifier).onSurfaceRequested(request);
      await tester.pump();

      Map<String, dynamic>? submitted;
      unawaited(
        request.outcome.then((o) => submitted = o.values),
      );

      await tester.enterText(find.byKey(MetricEntryCard.fieldKey), '82.4');
      await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
      await tester.pumpAndSettle();

      expect(submitted, isNotNull);
      expect(submitted!['value'], 82.4);
    });

    testWidgets('a resolved surface collapses to a receipt', (tester) async {
      await pump(tester);
      surface('MetricEntryCard', {'metric': 'weight', 'unit': 'kg'});
      await tester.pump();

      await tester.enterText(find.byKey(MetricEntryCard.fieldKey), '82.4');
      await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
      await tester.pumpAndSettle();

      expect(find.byType(MetricEntryCard), findsNothing);
      expect(find.text('Submitted.'), findsOneWidget);
    });

    testWidgets('a ConfirmationCard renders its resolved values', (tester) async {
      await pump(tester);
      surface('ConfirmationCard', {
        'summary': 'Log 2 eggs?',
        'values': {'amount': '100 g'},
      });
      await tester.pump();

      expect(find.byType(ConfirmationCard), findsOneWidget);
      expect(find.text('100 g'), findsOneWidget);
    });

    testWidgets('a MetricChart renders read-only', (tester) async {
      await pump(tester);
      surface('MetricChart', {
        'unit': 'kg',
        'series': [
          {'date': '2026-08-01', 'value': 83.0},
          {'date': '2026-08-07', 'value': 82.4},
        ],
      });
      await tester.pump();

      expect(find.byType(MetricChart), findsOneWidget);
    });

    testWidgets('a malformed chart point is skipped, not fatal', (tester) async {
      await pump(tester);
      surface('MetricChart', {
        'unit': 'kg',
        'series': [
          {'date': 'not-a-date', 'value': 1.0},
          {'date': '2026-08-07', 'value': 82.4},
        ],
      });
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byType(MetricChart), findsOneWidget);
    });

    testWidgets('an unknown component degrades to a visible card', (tester) async {
      // Spec §7: the chat never crashes on something the model asked for.
      await pump(tester);
      surface('ArbitraryHtml', const {});
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining("Couldn't display this"), findsOneWidget);
    });

    testWidgets('an ExerciseVideo missing its id degrades rather than throwing', (tester) async {
      await pump(tester);
      surface('ExerciseVideo', const {});
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.textContaining("Couldn't display this"), findsOneWidget);
    });
  });
}
