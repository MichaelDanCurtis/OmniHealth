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
import 'package:wger/features/ai/genui/widgets/metric_chart.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders a label and unit', (tester) async {
    await tester.pumpWidget(
      _host(
        MetricChart(
          label: 'Weight',
          unit: 'kg',
          series: [
            MetricPoint(date: DateTime(2026, 8, 1), value: 83),
            MetricPoint(date: DateTime(2026, 8, 7), value: 82.4),
          ],
        ),
      ),
    );

    expect(find.textContaining('Weight'), findsOneWidget);
    expect(find.textContaining('kg'), findsOneWidget);
  });

  testWidgets('an empty series renders an empty state, not an exception', (tester) async {
    await tester.pumpWidget(_host(const MetricChart(series: [], unit: 'kg')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('No data'), findsOneWidget);
  });

  testWidgets('a single point renders without throwing', (tester) async {
    // One point means zero range on both axes — a classic divide-by-zero in
    // charting libraries.
    await tester.pumpWidget(
      _host(
        MetricChart(
          unit: 'kg',
          series: [MetricPoint(date: DateTime(2026, 8, 7), value: 82.4)],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a flat series renders without throwing', (tester) async {
    // Identical values means zero y-range; same failure mode.
    await tester.pumpWidget(
      _host(
        MetricChart(
          unit: 'kg',
          series: [
            MetricPoint(date: DateTime(2026, 8, 1), value: 82),
            MetricPoint(date: DateTime(2026, 8, 7), value: 82),
          ],
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('points are ordered by date regardless of input order', (tester) async {
    final chart = MetricChart(
      unit: 'kg',
      series: [
        MetricPoint(date: DateTime(2026, 8, 7), value: 82.4),
        MetricPoint(date: DateTime(2026, 8, 1), value: 83),
      ],
    );
    await tester.pumpWidget(_host(chart));
    await tester.pump();

    expect(chart.sortedSeries.first.date, DateTime(2026, 8, 1));
    expect(chart.sortedSeries.last.date, DateTime(2026, 8, 7));
    expect(tester.takeException(), isNull);
  });

  testWidgets('sorting does not mutate the caller’s list', (tester) async {
    final original = [
      MetricPoint(date: DateTime(2026, 8, 7), value: 82.4),
      MetricPoint(date: DateTime(2026, 8, 1), value: 83),
    ];
    MetricChart(unit: 'kg', series: original).sortedSeries;

    expect(original.first.date, DateTime(2026, 8, 7));
  });

  testWidgets('a long series still renders', (tester) async {
    await tester.pumpWidget(
      _host(
        MetricChart(
          unit: 'kg',
          series: List.generate(
            200,
            (i) => MetricPoint(date: DateTime(2026, 1, 1).add(Duration(days: i)), value: 80 + i % 5),
          ),
        ),
      ),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
  });
}
