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

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Fails if any real provider credential is visible to the test process.
///
/// Provider adapters are tested against recorded fixtures, never live
/// endpoints. A key leaking into the test environment would mean CI could bill
/// a real account or send data to a third party, so this guard fails loudly
/// rather than letting it pass unnoticed.
void main() {
  test('no real provider API keys are visible to tests', () {
    const forbidden = [
      'OPENAI_API_KEY',
      'ANTHROPIC_API_KEY',
      'XAI_API_KEY',
      'GROK_API_KEY',
      'MOONSHOT_API_KEY',
      'ZHIPU_API_KEY',
      'GLM_API_KEY',
    ];

    final present = forbidden
        .where((k) => (Platform.environment[k] ?? '').isNotEmpty)
        .toList();

    expect(
      present,
      isEmpty,
      reason: 'Tests must never see real credentials. Unset: ${present.join(', ')}',
    );
  });
}
