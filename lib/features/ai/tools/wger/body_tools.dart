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
import 'package:wger/features/measurements/models/measurement_entry.dart';

String _isoDate(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-'
    '${d.month.toString().padLeft(2, '0')}-'
    '${d.day.toString().padLeft(2, '0')}';

/// One training log row, flattened to what the agent needs.
///
/// Declared here rather than reusing wger's `Log` so the tool layer does not
/// re-export a model whose shape is an upstream concern.
class WorkoutLogEntry {
  final DateTime date;
  final num weight;
  final num repetitions;

  const WorkoutLogEntry({
    required this.date,
    required this.weight,
    required this.repetitions,
  });
}

/// Reads training history for one exercise.
///
/// Deviation from spec 4.3, which named this `get_workout_log` with no
/// arguments: wger's repository exposes only `watchLogsByExerciseDrift`, a
/// per-exercise query. Adding a cross-exercise query would mean editing wger's
/// own repository and breaking the isolated-module boundary, so the tool takes
/// the exercise id the underlying store actually requires.
class GetWorkoutLogTool implements Tool {
  final Stream<List<WorkoutLogEntry>> Function(int exerciseId) watchByExercise;

  GetWorkoutLogTool({required this.watchByExercise});

  @override
  String get name => 'get_workout_log';

  @override
  String get description =>
      'Returns logged sets for one exercise, most recent first. '
      'Get the exerciseId from search_exercises.';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'exerciseId': {
        'type': 'integer',
        'description': 'Exercise id, as returned by search_exercises.',
      },
      'limit': {'type': 'integer', 'description': 'Maximum sets. Defaults to 50.', 'minimum': 1},
    },
    'required': ['exerciseId'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final limit = (args['limit'] as int?) ?? 50;
    final logs = await watchByExercise(args['exerciseId'] as int).first;
    return ToolResult.ok(
      logs
          .take(limit)
          .map(
            (l) => {
              'date': _isoDate(l.date),
              'weight': l.weight,
              'repetitions': l.repetitions,
            },
          )
          .toList(),
    );
  }
}

/// Reads body measurements for one category (waist, biceps, and so on).
class GetBodyMeasurementsTool implements Tool {
  /// Category name keyed by id, so results are legible without a second call.
  final Future<Map<String, String>> Function() categories;
  final Stream<List<MeasurementEntry>> Function(String categoryId) watchEntries;

  GetBodyMeasurementsTool({required this.categories, required this.watchEntries});

  @override
  String get name => 'get_body_measurements';

  @override
  String get description =>
      'Returns body measurement entries. Omit categoryId to list the available '
      'measurement categories instead.';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'categoryId': {
        'type': 'string',
        'description': 'Category to read. Omit to list categories.',
      },
      'limit': {
        'type': 'integer',
        'description': 'Maximum entries. Defaults to 50.',
        'minimum': 1,
      },
    },
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final known = await categories();
    final categoryId = args['categoryId'] as String?;

    // Listing categories is the useful default: the agent cannot guess an id,
    // and an empty result here would read as "no data" rather than "ask first".
    if (categoryId == null) {
      return ToolResult.ok({
        'categories': known.entries.map((e) => {'id': e.key, 'name': e.value}).toList(),
      });
    }

    if (!known.containsKey(categoryId)) {
      return ToolResult.error(
        'No measurement category "$categoryId". Call this tool without '
        'categoryId to list the available ones.',
      );
    }

    final limit = (args['limit'] as int?) ?? 50;
    final entries = await watchEntries(categoryId).first;
    return ToolResult.ok({
      'category': known[categoryId],
      'entries': entries
          .take(limit)
          .map((e) => {'date': _isoDate(e.date), 'value': e.value})
          .toList(),
    });
  }
}
