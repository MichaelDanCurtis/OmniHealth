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
import 'package:wger/features/ai/tools/wger/nutrition_tools.dart';
import 'package:wger/features/nutrition/models/ingredient.dart';
import 'package:wger/features/nutrition/models/log.dart';

Ingredient _ingredient({int id = 1, String name = 'Egg'}) => Ingredient(
  remoteId: null,
  sourceName: 'Open Food Facts',
  // The fields spec 5.5 cares about: these must never reach the agent.
  sourceUrl: 'https://openfoodfacts.example/product/1',
  licenseObjectURl: 'https://creativecommons.example/by-sa',
  id: id,
  code: null,
  name: name,
  brand: 'Farm',
  created: DateTime(2026),
  energy: 140,
  carbohydrates: 1.1,
  protein: 12.6,
  fat: 9.5,
);

class FakeNutritionSink {
  final List<LogItem> added = [];
  List<LogItem> logs = [];
  List<Ingredient> searchResults = [];
  String? planId = 'plan-1';

  Future<void> addLog(LogItem item) async => added.add(item);

  Stream<List<LogItem>> watchLogs() => Stream.value(logs);

  Future<List<Ingredient>> search(String term) async => searchResults;

  Future<String?> currentPlanId() async => planId;
}

void main() {
  late FakeNutritionSink sink;

  setUp(() => sink = FakeNutritionSink());

  group('SearchIngredientTool', () {
    test('is a read tool', () {
      expect(SearchIngredientTool(search: sink.search).isWrite, isFalse);
    });

    test('returns id, name and macros', () async {
      sink.searchResults = [_ingredient()];
      final result = await SearchIngredientTool(search: sink.search).call({'query': 'egg'});

      final first = (result.data! as List).first as Map<String, dynamic>;
      expect(first['id'], 1);
      expect(first['name'], 'Egg');
      expect(first['energy'], 140);
    });

    test('strips every URL the Ingredient model carries', () async {
      // Spec 5.5: Ingredient has sourceUrl and licenseObjectURl. Anything the
      // agent can see, it can echo into a render request.
      sink.searchResults = [_ingredient()];
      final result = await SearchIngredientTool(search: sink.search).call({'query': 'egg'});

      final encoded = jsonEncode(result.data);
      expect(encoded, isNot(contains('http')));
      expect(encoded, isNot(contains('openfoodfacts')));
      expect(encoded, isNot(contains('creativecommons')));
    });

    test('an empty result set is a success, not an error', () async {
      final result = await SearchIngredientTool(search: sink.search).call({'query': 'nothing'});
      expect(result.isError, isFalse);
      expect(result.data! as List, isEmpty);
    });

    test('a blank query is an error rather than an unbounded scan', () async {
      final result = await SearchIngredientTool(search: sink.search).call({'query': '   '});
      expect(result.isError, isTrue);
    });
  });

  group('GetNutritionLogTool', () {
    test('is a read tool and an empty log is a success', () async {
      final tool = GetNutritionLogTool(watch: sink.watchLogs);
      expect(tool.isWrite, isFalse);

      final result = await tool.call({});
      expect(result.isError, isFalse);
      expect(result.data! as List, isEmpty);
    });

    test('returns entries with date and amount', () async {
      sink.logs = [
        LogItem(
          ingredientId: 1,
          amount: 100,
          planId: 'plan-1',
          datetime: DateTime(2026, 8, 7, 9, 30),
        ),
      ];
      final result = await GetNutritionLogTool(watch: sink.watchLogs).call({});

      final first = (result.data! as List).first as Map<String, dynamic>;
      expect(first['date'], '2026-08-07');
      expect(first['amount'], 100);
      expect(first['ingredientId'], 1);
    });

    test('emits no URLs even when a log has a hydrated ingredient', () async {
      final log = LogItem(
        ingredientId: 1,
        amount: 100,
        planId: 'plan-1',
        datetime: DateTime(2026, 8, 7),
      )..ingredient = _ingredient();
      sink.logs = [log];

      final result = await GetNutritionLogTool(watch: sink.watchLogs).call({});
      expect(jsonEncode(result.data), isNot(contains('http')));
    });
  });

  group('LogNutritionEntryTool', () {
    LogNutritionEntryTool tool() =>
        LogNutritionEntryTool(addLog: sink.addLog, currentPlanId: sink.currentPlanId);

    test('is a write tool declaring confirmationToken', () {
      expect(tool().isWrite, isTrue);
      expect(tool().inputSchema['required'] as List, contains('confirmationToken'));
    });

    test('writes through the app’s own sink', () async {
      final result = await tool().call({
        'ingredientId': 1,
        'amount': 100.0,
        'date': '2026-08-07',
      });
      expect(result.isError, isFalse);
      expect(sink.added, hasLength(1));
      expect(sink.added.single.ingredientId, 1);
      expect(sink.added.single.amount, 100.0);
      expect(sink.added.single.planId, 'plan-1');
    });

    test('rejects a non-positive amount', () async {
      final result = await tool().call({
        'ingredientId': 1,
        'amount': 0.0,
        'date': '2026-08-07',
      });
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });

    test('rejects an unparseable date', () async {
      final result = await tool().call({
        'ingredientId': 1,
        'amount': 100.0,
        'date': 'whenever',
      });
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });

    test('explains itself when the user has no nutrition plan', () async {
      // LogItem requires a planId. Without one there is nothing to write to,
      // and the agent needs to be told why rather than silently failing.
      sink.planId = null;
      final result = await tool().call({
        'ingredientId': 1,
        'amount': 100.0,
        'date': '2026-08-07',
      });
      expect(result.isError, isTrue);
      expect(result.message.toLowerCase(), contains('plan'));
      expect(sink.added, isEmpty);
    });
  });
}
