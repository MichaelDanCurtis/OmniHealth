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
import 'package:wger/features/ai/chat/providers/chat_notifier.dart';
import 'package:wger/features/ai/genui/omni_catalog.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';
import 'package:wger/features/ai/tools/wger/body_tools.dart';
import 'package:wger/features/ai/tools/wger/exercise_tools.dart';
import 'package:wger/features/ai/tools/wger/nutrition_tools.dart';
import 'package:wger/features/ai/tools/wger/weight_tools.dart';
import 'package:wger/features/exercises/models/exercise.dart';
import 'package:wger/features/measurements/models/measurement_entry.dart';
import 'package:wger/features/nutrition/models/ingredient.dart';
import 'package:wger/features/nutrition/models/log.dart';
import 'package:wger/features/weight/models/weight_entry.dart';

/// Everything the built-in tools need from the rest of the app.
///
/// Declared as one seam so the module's dependency on wger is a single,
/// reviewable surface rather than a scatter of imports through the tool files —
/// which is what keeps the AI layer offerable upstream.
class AiToolBindings {
  final Stream<List<WeightEntry>> Function() watchWeight;
  final Future<void> Function(WeightEntry) addWeight;

  final Stream<List<LogItem>> Function() watchNutritionLog;
  final Future<void> Function(LogItem) addNutritionLog;
  final Future<List<Ingredient>> Function(String) searchIngredient;
  final Future<String?> Function() currentPlanId;

  final Stream<List<WorkoutLogEntry>> Function(int) watchWorkoutLog;
  final Future<Map<String, String>> Function() measurementCategories;
  final Stream<List<MeasurementEntry>> Function(String) watchMeasurements;

  final Future<List<Exercise>> Function(String) searchExercises;
  final Future<Exercise?> Function(int) loadExercise;

  const AiToolBindings({
    required this.watchWeight,
    required this.addWeight,
    required this.watchNutritionLog,
    required this.addNutritionLog,
    required this.searchIngredient,
    required this.currentPlanId,
    required this.watchWorkoutLog,
    required this.measurementCategories,
    required this.watchMeasurements,
    required this.searchExercises,
    required this.loadExercise,
  });
}

/// Registers every built-in tool against [registry].
///
/// Kept separate from provider wiring so the full tool surface can be asserted
/// in a test without a database, a network, or a running app.
void registerAiTools({
  required ToolRegistry registry,
  required AiToolBindings bindings,
  required void Function(SurfaceRequest) surfaceSink,
  required ConfirmationTokenService tokenService,
}) {
  final tools = <Tool>[
    GetWeightHistoryTool(watch: bindings.watchWeight),
    LogWeightTool(add: bindings.addWeight),
    GetNutritionLogTool(watch: bindings.watchNutritionLog),
    SearchIngredientTool(search: bindings.searchIngredient),
    LogNutritionEntryTool(
      addLog: bindings.addNutritionLog,
      currentPlanId: bindings.currentPlanId,
    ),
    GetWorkoutLogTool(watchByExercise: bindings.watchWorkoutLog),
    GetBodyMeasurementsTool(
      categories: bindings.measurementCategories,
      watchEntries: bindings.watchMeasurements,
    ),
    SearchExercisesTool(search: bindings.searchExercises),
    GetExerciseDetailTool(load: bindings.loadExercise),
    RenderUiTool(
      tokenService: tokenService,
      knownComponents: OmniCatalog.knownComponentNames,
      writeComponents: OmniCatalog.writeComponents,
      surfaceSink: surfaceSink,
    ),
  ];

  tools.forEach(registry.register);
}

/// Bindings that do nothing, for tests that only care about the tool surface.
AiToolBindings stubBindings() => AiToolBindings(
  watchWeight: () => Stream.value(const []),
  addWeight: (_) async {},
  watchNutritionLog: () => Stream.value(const []),
  addNutritionLog: (_) async {},
  searchIngredient: (_) async => const [],
  currentPlanId: () async => null,
  watchWorkoutLog: (_) => Stream.value(const []),
  measurementCategories: () async => const {},
  watchMeasurements: (_) => Stream.value(const []),
  searchExercises: (_) async => const [],
  loadExercise: (_) async => null,
);

/// The registry the agent is given, wired to the running app.
final aiToolRegistryProvider = Provider<ToolRegistry>((ref) {
  final registry = ToolRegistry(tokenService: ref.read(confirmationTokenServiceProvider));

  registerAiTools(
    registry: registry,
    bindings: ref.read(aiToolBindingsProvider),
    tokenService: ref.read(confirmationTokenServiceProvider),
    surfaceSink: ref.read(chatProvider.notifier).onSurfaceRequested,
  );

  return registry;
});

/// Overridden at app start with bindings onto wger's repositories.
///
/// Defaults to stubs so a partially-wired build degrades to an assistant that
/// can talk but finds no data, rather than throwing on first use.
final aiToolBindingsProvider = Provider<AiToolBindings>((ref) => stubBindings());
