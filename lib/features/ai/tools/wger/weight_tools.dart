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

import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/weight/models/weight_entry.dart';

/// `YYYY-MM-DD`, the only date format these tools accept.
String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// Reads body-weight history from the local Drift store.
///
/// Takes the repository method as a callback rather than the repository itself,
/// so the tool is testable without a database.
class GetWeightHistoryTool implements Tool {
  final Stream<List<WeightEntry>> Function() watch;

  GetWeightHistoryTool({required this.watch});

  @override
  String get name => 'get_weight_history';

  @override
  String get description =>
      "Returns the user's recorded body weight entries, most recent first.";

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'limit': {
        'type': 'integer',
        'description': 'Maximum entries to return. Defaults to 30.',
        'minimum': 1,
      },
    },
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final limit = (args['limit'] as int?) ?? 30;
    final entries = await watch().first;
    return ToolResult.ok(
      entries.take(limit).map((e) => {'date': _isoDate(e.date), 'weight': e.weight}).toList(),
    );
  }
}

/// Records a body-weight entry.
///
/// Write tool: the registry refuses to run this without a confirmation token
/// minted by a real user tap.
class LogWeightTool implements Tool {
  final Future<void> Function(WeightEntry) add;

  LogWeightTool({required this.add});

  @override
  String get name => 'log_weight';

  @override
  String get description =>
      'Records a body weight entry for a given date. Requires user confirmation.';

  @override
  bool get isWrite => true;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'value': {
        'type': 'number',
        'description':
            "Body weight in the user's configured unit, between "
            '${WeightEntry.minValue} and ${WeightEntry.maxValue}.',
      },
      'date': {'type': 'string', 'description': 'Date in YYYY-MM-DD format.'},
      'confirmationToken': {
        'type': 'string',
        'description':
            'Token returned by render_ui when the user tapped save. Never invent this.',
      },
    },
    'required': ['value', 'date', 'confirmationToken'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    // JSON gives `82` for a whole number, and WeightEntry.toCompanion() does
    // `weight as double` — which throws on an int at persist time, far from
    // here. Coerce at the boundary.
    final value = (args['value'] as num).toDouble();

    // The app's own bounds. Naming them in the message lets the agent correct
    // itself instead of guessing.
    if (value < WeightEntry.minValue || value > WeightEntry.maxValue) {
      return ToolResult.error(
        'Weight must be between ${WeightEntry.minValue} and ${WeightEntry.maxValue}, '
        'got $value.',
      );
    }

    final rawDate = args['date'] as String;
    final date = DateTime.tryParse(rawDate);
    if (date == null) {
      return ToolResult.error('Could not parse date "$rawDate". Use YYYY-MM-DD.');
    }

    await add(WeightEntry(date: date, weight: value));
    return ToolResult.ok({
      'logged': {'date': _isoDate(date), 'weight': value},
    });
  }
}
