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

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wger/core/network/network_provider.dart';
import 'package:wger/features/ai/ai_module.dart';
import 'package:wger/features/ai/tools/wger/body_tools.dart';
import 'package:wger/features/exercises/models/exercise.dart';
import 'package:wger/features/exercises/models/video.dart';
import 'package:wger/features/exercises/providers/exercise_repository.dart';
import 'package:wger/features/measurements/models/measurement_entry.dart';
import 'package:wger/features/measurements/providers/measurement_repository.dart';
import 'package:wger/features/nutrition/models/log.dart';
import 'package:wger/features/nutrition/providers/ingredient_repository.dart';
import 'package:wger/features/nutrition/providers/nutrition_repository.dart';
import 'package:wger/features/routines/providers/workout_logs_repository.dart';
import 'package:wger/features/weight/models/weight_entry.dart';
import 'package:wger/features/weight/providers/body_weight_notifier.dart';
import 'package:wger/features/weight/providers/body_weight_repository.dart';

/// Binds the AI tools to wger's own repositories.
///
/// This is the single place the module reaches into the rest of the app, which
/// is what makes the dependency reviewable — and removable, if the layer is
/// ever offered upstream as an optional feature.
///
/// Everything here goes through Drift/PowerSync rather than REST, so the tools
/// work offline and a write shows up live on the corresponding screen.
AiToolBindings buildAiToolBindings(Ref ref) {
  return AiToolBindings(
    // ---- weight ----
    watchWeight: () => ref.read(bodyWeightRepositoryProvider).watchAllDrift(),
    addWeight: (WeightEntry entry) =>
        ref.read(weightEntryProvider.notifier).addEntry(entry),

    // ---- nutrition ----
    watchNutritionLog: () => ref.read(nutritionRepositoryProvider).watchAllLogsHydrated(),
    addNutritionLog: (LogItem item) =>
        ref.read(nutritionRepositoryProvider).addLogLocalDrift(item),
    searchIngredient: (String term) async {
      // The repository takes an explicit online flag rather than probing, so
      // pass the app's current view of connectivity. Offline still returns
      // locally-synced ingredients.
      final online = ref.read(networkStatusProvider);
      return ref.read(ingredientRepositoryProvider).search(term, isOnline: online);
    },
    currentPlanId: () async {
      // A free-form diary entry still needs a plan to hang off. Use the most
      // recent one; if the user has none, the tool says so rather than failing.
      final plans = await ref.read(nutritionRepositoryProvider).watchAllDrift().first;
      return plans.isEmpty ? null : plans.first.id;
    },

    // ---- training ----
    watchWorkoutLog: (int exerciseId) => ref
        .read(workoutLogRepositoryProvider)
        .watchLogsByExerciseDrift(exerciseId: exerciseId)
        .map(
          (logs) => logs
              .map(
                (l) => WorkoutLogEntry(
                  date: l.date,
                  weight: l.weight ?? 0,
                  repetitions: l.repetitions ?? 0,
                ),
              )
              .toList(),
        ),

    // ---- measurements ----
    // watchAll() returns categories with their entries already attached, so
    // both bindings come from the same stream.
    measurementCategories: () async {
      final categories = await ref.read(measurementRepositoryProvider).watchAll().first;
      return {
        for (final c in categories)
          if (c.id != null) c.id!: '${c.name} (${c.unit})',
      };
    },
    watchMeasurements: (String categoryId) =>
        ref.read(measurementRepositoryProvider).watchAll().map((categories) {
          for (final c in categories) {
            if (c.id == categoryId) {
              return c.entries;
            }
          }
          return <MeasurementEntry>[];
        }),

    // ---- exercises ----
    searchExercises: (String term) async {
      final all = await _allExercises(ref);
      final needle = term.toLowerCase();
      return all
          .where(
            (e) => e.translations.any((t) => t.name.toLowerCase().contains(needle)),
          )
          .toList();
    },
    loadExercise: (int id) async {
      final all = await _allExercises(ref);
      for (final e in all) {
        if (e.id == id) {
          return e;
        }
      }
      return null;
    },
  );
}

/// Searches the locally-synced exercise database.
///
/// Deliberately local rather than `searchExerciseServer`: that returns bare ids
/// needing a second round trip, and a local search keeps the tools working
/// offline like every other one.
Future<List<Exercise>> _allExercises(Ref ref) async {
  final state = await ref.read(exerciseRepositoryProvider).watchAllDrift().first;
  return state.exercises;
}

/// Resolves an exercise video by id, for the `ExerciseVideo` component.
///
/// Spec §5.5: the component takes an id, and resolution to a URL happens here
/// and in wger's player — never from anything the agent supplied.
Future<Video?> lookupExerciseVideo(Ref ref, int videoId) async {
  final exercises = await _allExercises(ref);
  for (final exercise in exercises) {
    for (final video in exercise.videos) {
      if (video.id == videoId) {
        return video;
      }
    }
  }
  return null;
}

/// Resolver for the `ExerciseVideo` component's lookup seam.
///
/// Both this and [buildAiToolBindings] are applied as overrides at the app's
/// `ProviderScope` (see `main.dart`). Without them the assistant runs but finds
/// no data, which is the deliberate graceful default rather than a crash.
Future<Video?> Function(int) buildExerciseVideoLookup(Ref ref) =>
    (int videoId) => lookupExerciseVideo(ref, videoId);
