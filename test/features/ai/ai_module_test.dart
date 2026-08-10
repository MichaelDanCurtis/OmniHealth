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

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/ai_module.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

ToolRegistry _wired() {
  final tokens = ConfirmationTokenService();
  final registry = ToolRegistry(tokenService: tokens);
  registerAiTools(
    registry: registry,
    bindings: stubBindings(),
    tokenService: tokens,
    surfaceSink: (_) {},
  );
  return registry;
}

void main() {
  test('registers exactly the expected built-in tools', () {
    expect(_wired().specs().map((s) => s.name).toSet(), {
      'get_weight_history',
      'log_weight',
      'get_nutrition_log',
      'search_ingredient',
      'log_nutrition_entry',
      'get_workout_log',
      'get_body_measurements',
      'search_exercises',
      'get_exercise_detail',
      'render_ui',
    });
  });

  test('every tool declares a non-empty description and an object schema', () {
    for (final spec in _wired().specs()) {
      expect(spec.description, isNotEmpty, reason: '${spec.name} needs a description');
      expect(
        spec.inputSchema['type'],
        'object',
        reason: '${spec.name} schema must be an object',
      );
    }
  });

  test('no tool description or schema leaks a URL', () {
    // Spec §5.5: anything the agent can see, it can echo into a render request.
    for (final spec in _wired().specs()) {
      final encoded = jsonEncode({'d': spec.description, 's': spec.inputSchema});
      expect(encoded, isNot(contains('http')), reason: '${spec.name} mentions a URL');
    }
  });

  test('every write tool requires a confirmation token in its schema', () {
    // The registry enforces this at dispatch; declaring it in the schema is how
    // the model learns to ask for one rather than guessing.
    for (final spec in _wired().specs().where((s) => s.name.startsWith('log_'))) {
      expect(
        spec.inputSchema['required'] as List,
        contains('confirmationToken'),
        reason: '${spec.name} is a write and must declare confirmationToken',
      );
    }
  });

  test('a write refuses to run through the wired registry without a token', () async {
    final result = await _wired().dispatch('log_weight', {
      'value': 82.4,
      'date': '2026-08-07',
    });

    expect(result.isError, isTrue);
    expect(result.message.toLowerCase(), contains('confirm'));
  });

  test('read tools work through the wired registry', () async {
    final result = await _wired().dispatch('get_weight_history', {});
    expect(result.isError, isFalse);
  });
}
