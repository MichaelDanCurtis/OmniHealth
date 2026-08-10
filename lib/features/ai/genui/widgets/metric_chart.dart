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

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

/// One point in a metric series.
class MetricPoint {
  final DateTime date;
  final double value;

  const MetricPoint({required this.date, required this.value});
}

/// A trend line over a metric series.
///
/// The one component A2UI's Basic Catalog genuinely lacks, and the highest
/// value read in a health app. Read-only: it is not in
/// `OmniCatalog.writeComponents`, mints no token, and has no control that
/// could commit anything.
class MetricChart extends StatelessWidget {
  /// Padding applied when a series has no spread on an axis, so `fl_chart` is
  /// never handed a zero interval.
  static const _flatSeriesPadding = 1.0;

  final List<MetricPoint> series;
  final String unit;
  final String? label;

  const MetricChart({super.key, required this.series, required this.unit, this.label});

  /// Exposed so ordering is testable without reaching into the chart.
  List<MetricPoint> get sortedSeries =>
      [...series]..sort((a, b) => a.date.compareTo(b.date));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    if (series.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No data yet', style: theme.textTheme.bodyMedium),
        ),
      );
    }

    final points = sortedSeries;
    final values = points.map((p) => p.value).toList();

    var minY = values.reduce((a, b) => a < b ? a : b);
    var maxY = values.reduce((a, b) => a > b ? a : b);
    // A single point, or a perfectly flat series, gives zero range on an axis —
    // a classic divide-by-zero inside charting libraries. Pad instead.
    if (minY == maxY) {
      minY -= _flatSeriesPadding;
      maxY += _flatSeriesPadding;
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${label ?? 'Trend'} ($unit)',
              style: theme.textTheme.titleSmall,
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 180,
              child: LineChart(
                LineChartData(
                  minY: minY,
                  maxY: maxY,
                  gridData: const FlGridData(show: false),
                  titlesData: const FlTitlesData(show: false),
                  borderData: FlBorderData(show: false),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        for (var i = 0; i < points.length; i++)
                          FlSpot(i.toDouble(), points[i].value),
                      ],
                      isCurved: true,
                      barWidth: 2,
                      color: theme.colorScheme.primary,
                      dotData: FlDotData(show: points.length <= 20),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
