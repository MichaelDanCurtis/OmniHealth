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

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/genui/widgets/confirmation_card.dart';
import 'package:wger/features/ai/genui/widgets/metric_entry_card.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('MetricEntryCard', () {
    MetricEntryCard build({
      void Function(double, DateTime)? onSubmit,
      VoidCallback? onDismiss,
    }) => MetricEntryCard(
      metric: 'weight',
      unit: 'kg',
      initialDate: DateTime(2026, 8, 7),
      onSubmit: onSubmit ?? (_, _) {},
      onDismiss: onDismiss ?? () {},
    );

    testWidgets('shows the metric label and unit', (tester) async {
      await tester.pumpWidget(_host(build()));
      expect(find.textContaining('weight'), findsWidgets);
      expect(find.textContaining('kg'), findsWidgets);
    });

    testWidgets('submitting reports the typed value and date', (tester) async {
      double? value;
      DateTime? date;
      await tester.pumpWidget(
        _host(
          build(
            onSubmit: (v, d) {
              value = v;
              date = d;
            },
          ),
        ),
      );

      await tester.enterText(find.byKey(MetricEntryCard.fieldKey), '82.4');
      await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
      await tester.pump();

      expect(value, 82.4);
      expect(date, DateTime(2026, 8, 7));
    });

    testWidgets('does not submit a non-numeric value', (tester) async {
      var submitted = false;
      await tester.pumpWidget(_host(build(onSubmit: (_, _) => submitted = true)));

      await tester.enterText(find.byKey(MetricEntryCard.fieldKey), 'heavy');
      await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
      await tester.pump();

      expect(submitted, isFalse);
      expect(find.textContaining('number'), findsOneWidget);
    });

    testWidgets('does not submit an empty value', (tester) async {
      var submitted = false;
      await tester.pumpWidget(_host(build(onSubmit: (_, _) => submitted = true)));

      await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
      await tester.pump();

      expect(submitted, isFalse);
    });

    testWidgets('dismissing reports dismissal and never submits', (tester) async {
      var submitted = false;
      var dismissed = false;
      await tester.pumpWidget(
        _host(
          build(
            onSubmit: (_, _) => submitted = true,
            onDismiss: () => dismissed = true,
          ),
        ),
      );

      await tester.enterText(find.byKey(MetricEntryCard.fieldKey), '82.4');
      await tester.tap(find.byKey(MetricEntryCard.cancelButtonKey));
      await tester.pump();

      expect(dismissed, isTrue);
      expect(submitted, isFalse);
    });

    testWidgets('rendering alone never submits — only a tap does', (tester) async {
      // The core invariant at the widget level: no lifecycle path reaches
      // onSubmit without user input.
      var submitted = false;
      await tester.pumpWidget(_host(build(onSubmit: (_, _) => submitted = true)));
      await tester.pumpAndSettle();

      expect(submitted, isFalse);
    });
  });

  group('ConfirmationCard', () {
    ConfirmationCard build({
      Map<String, Object?>? values,
      VoidCallback? onAccept,
      VoidCallback? onReject,
    }) => ConfirmationCard(
      summary: 'Log 2 eggs, 140 kcal?',
      values: values ?? const {'ingredient': 'Egg', 'amount': '100 g'},
      onAccept: onAccept ?? () {},
      onReject: onReject ?? () {},
    );

    testWidgets('renders the summary', (tester) async {
      await tester.pumpWidget(_host(build()));
      expect(find.textContaining('Log 2 eggs'), findsOneWidget);
    });

    testWidgets('renders every resolved value it is about to write', (tester) async {
      // Spec 5.2's honesty guarantee: the payload is the label. If a value the
      // token covers is not on screen, the user cannot have consented to it.
      await tester.pumpWidget(
        _host(build(values: const {'weight': '82.4 kg', 'date': '2026-08-07'})),
      );

      expect(find.text('weight'), findsOneWidget);
      expect(find.text('82.4 kg'), findsOneWidget);
      expect(find.text('date'), findsOneWidget);
      expect(find.text('2026-08-07'), findsOneWidget);
    });

    testWidgets('button labels are fixed, not agent-supplied', (tester) async {
      // The mislabelled-Cancel attack is prevented structurally: this widget
      // owns its labels and the agent supplies only content.
      await tester.pumpWidget(_host(build()));
      expect(find.text('Confirm'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('accept fires once and reject never', (tester) async {
      var accepted = 0;
      var rejected = 0;
      await tester.pumpWidget(
        _host(build(onAccept: () => accepted++, onReject: () => rejected++)),
      );

      await tester.tap(find.byKey(ConfirmationCard.acceptButtonKey));
      await tester.pump();

      expect(accepted, 1);
      expect(rejected, 0);
    });

    testWidgets('reject fires and accept never', (tester) async {
      var accepted = 0;
      var rejected = 0;
      await tester.pumpWidget(
        _host(build(onAccept: () => accepted++, onReject: () => rejected++)),
      );

      await tester.tap(find.byKey(ConfirmationCard.rejectButtonKey));
      await tester.pump();

      expect(rejected, 1);
      expect(accepted, 0);
    });

    testWidgets('an empty value map still renders and stays usable', (tester) async {
      await tester.pumpWidget(_host(build(values: const {})));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(find.byKey(ConfirmationCard.acceptButtonKey), findsOneWidget);
    });

    testWidgets('rendering alone never accepts', (tester) async {
      var accepted = false;
      await tester.pumpWidget(_host(build(onAccept: () => accepted = true)));
      await tester.pumpAndSettle();

      expect(accepted, isFalse);
    });
  });
}
