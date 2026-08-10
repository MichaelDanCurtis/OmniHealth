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
import 'package:wger/features/exercises/models/exercise.dart';

/// Projects an [Exercise] to the fields the agent may see.
///
/// Spec 5.5, and this model is the sharpest case of it: `images` and `videos`
/// both carry server paths, and `Ingredient`-style source URLs live on the
/// translations. Videos are surfaced as **ids only** — the `ExerciseVideo`
/// component resolves an id to a URL client-side, through
/// `mediaUrlBuilderProvider`, which can only ever address the user's own
/// server. An allowlist, so an upstream field addition cannot leak by default.
/// wger stores exercise descriptions as HTML, which may contain anchors.
///
/// Strip the markup — the model wants prose, not tags — and drop any URL that
/// survives, so a link embedded in user-contributed content cannot become a
/// destination the agent repeats back (spec 5.5).
String _plainText(String html) => html
    .replaceAll(RegExp(r'<[^>]*>'), ' ')
    .replaceAll(RegExp(r'https?://\S+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

Map<String, dynamic> _publicExercise(Exercise e, {required bool detail}) {
  // No convenience accessor exists on Exercise; names and descriptions live on
  // translations, one per language.
  final translation = e.translations.firstOrNull;

  return {
    'id': e.id,
    'name': translation?.name ?? 'Exercise ${e.id}',
    'category': e.category.name,
    'equipment': e.equipment.map((x) => x.name).toList(),
    'hasVideo': e.videos.isNotEmpty,
    if (detail) ...{
      'muscles': e.muscles.map((m) => m.name).toList(),
      'secondaryMuscles': e.musclesSecondary.map((m) => m.name).toList(),
      if (translation != null) 'description': _plainText(translation.description),
      // Ids, never paths. This is the whole point of the component taking an id.
      'videos': e.videos.map((v) => {'id': v.id, 'durationSeconds': v.duration}).toList(),
      'authors': e.authors,
    },
  };
}

/// Searches the exercise database.
class SearchExercisesTool implements Tool {
  final Future<List<Exercise>> Function(String term) search;

  SearchExercisesTool({required this.search});

  @override
  String get name => 'search_exercises';

  @override
  String get description =>
      'Searches exercises by name. Returns ids, equipment, and whether a form '
      'video exists. Use the id with get_exercise_detail or get_workout_log.';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'query': {'type': 'string', 'description': 'Exercise name to search for.'},
      'limit': {'type': 'integer', 'description': 'Maximum results. Defaults to 20.', 'minimum': 1},
    },
    'required': ['query'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final query = (args['query'] as String).trim();
    if (query.isEmpty) {
      return ToolResult.error('Provide a non-empty search term.');
    }
    final limit = (args['limit'] as int?) ?? 20;
    final results = await search(query);
    return ToolResult.ok(
      results.take(limit).map((e) => _publicExercise(e, detail: false)).toList(),
    );
  }
}

/// Reads one exercise in full, including the ids of any form videos.
class GetExerciseDetailTool implements Tool {
  final Future<Exercise?> Function(int id) load;

  GetExerciseDetailTool({required this.load});

  @override
  String get name => 'get_exercise_detail';

  @override
  String get description =>
      'Returns full detail for one exercise: description, muscles worked, '
      'equipment, and the ids of any form videos. To show a video, render the '
      'ExerciseVideo component with one of the returned video ids.';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'id': {'type': 'integer', 'description': 'Exercise id, from search_exercises.'},
    },
    'required': ['id'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final id = args['id'] as int;
    final exercise = await load(id);
    if (exercise == null) {
      return ToolResult.error('No exercise with id $id. Use search_exercises to find one.');
    }
    return ToolResult.ok(_publicExercise(exercise, detail: true));
  }
}
