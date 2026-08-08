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

import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';

void main() {
  late ConfirmationTokenService service;

  setUp(() => service = ConfirmationTokenService());

  test('a freshly minted token validates for its exact tool and arguments', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
      TokenCheck.valid,
    );
  });

  test('a token is single-use', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
      TokenCheck.alreadyUsed,
    );
  });

  test('a token bound to one tool is rejected for another', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(
        token: token,
        toolName: 'log_nutrition_entry',
        arguments: {'value': 82.4},
      ),
      TokenCheck.unknown,
    );
  });

  test('altered arguments are rejected — the model cannot swap the payload', () {
    // The honesty guarantee in spec 5.2: the user confirmed 82.4, so 999 must
    // not be writable with the token they granted.
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'value': 999.0}),
      TokenCheck.argumentMismatch,
    );
  });

  test('altering a nested argument value is also rejected', () {
    final token = service.mint(
      toolName: 'log_nutrition_entry',
      arguments: {
        'item': {'id': 1, 'grams': 100},
      },
    );
    expect(
      service.consume(
        token: token,
        toolName: 'log_nutrition_entry',
        arguments: {
          'item': {'id': 1, 'grams': 900},
        },
      ),
      TokenCheck.argumentMismatch,
    );
  });

  test('adding an extra argument is rejected', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(
        token: token,
        toolName: 'log_weight',
        arguments: {'value': 82.4, 'userId': 7},
      ),
      TokenCheck.argumentMismatch,
    );
  });

  test('a token expires after five minutes', () {
    final start = DateTime(2026, 8, 7, 12);
    late String token;
    withClock(Clock.fixed(start), () {
      token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    });
    withClock(Clock.fixed(start.add(const Duration(minutes: 5, seconds: 1))), () {
      expect(
        service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
        TokenCheck.expired,
      );
    });
  });

  test('a token just inside the window is still valid', () {
    final start = DateTime(2026, 8, 7, 12);
    late String token;
    withClock(Clock.fixed(start), () {
      token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    });
    withClock(Clock.fixed(start.add(const Duration(minutes: 4, seconds: 59))), () {
      expect(
        service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
        TokenCheck.valid,
      );
    });
  });

  test('an invented token is unknown', () {
    expect(
      service.consume(token: 'made-up', toolName: 'log_weight', arguments: {}),
      TokenCheck.unknown,
    );
  });

  test('argument key order does not affect validation', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'a': 1, 'b': 2});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'b': 2, 'a': 1}),
      TokenCheck.valid,
    );
  });

  test('tokens are unpredictable and distinct', () {
    // A guessable token would let the agent mint its own confirmations.
    final tokens = List.generate(
      100,
      (_) => service.mint(toolName: 'log_weight', arguments: {'value': 1.0}),
    );
    expect(tokens.toSet(), hasLength(100));
    expect(tokens.every((t) => t.length >= 32), isTrue);
  });
}
