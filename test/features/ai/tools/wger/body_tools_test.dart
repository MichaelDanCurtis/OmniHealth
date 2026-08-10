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
import 'package:wger/features/ai/tools/wger/body_tools.dart';
import 'package:wger/features/measurements/models/measurement_entry.dart';

class FakeBodySource {
  Map<String, String> cats = {'c1': 'Waist'};
  List<MeasurementEntry> entries = [];
  List<WorkoutLogEntry> logs = [];

  Future<Map<String, String>> categories() async => cats;

  Stream<List<MeasurementEntry>> watchEntries(String id) => Stream.value(entries);

  Stream<List<WorkoutLogEntry>> watchLogs(int exerciseId) => Stream.value(logs);
}

void main() {
  late FakeBodySource source;

  setUp(() => source = FakeBodySource());

  group('GetWorkoutLogTool', () {
    GetWorkoutLogTool tool() => GetWorkoutLogTool(watchByExercise: source.watchLogs);

    test('is a read tool requiring an exerciseId', () {
      expect(tool().isWrite, isFalse);
      expect(tool().inputSchema['required'] as List, contains('exerciseId'));
    });

    test('returns sets with date, weight and reps', () async {
      source.logs = [
        WorkoutLogEntry(date: DateTime(2026, 8, 7), weight: 100, repetitions: 5),
      ];
      final result = await tool().call({'exerciseId': 1});

      final first = (result.data! as List).first as Map<String, dynamic>;
      expect(first['date'], '2026-08-07');
      expect(first['weight'], 100);
      expect(first['repetitions'], 5);
    });

    test('an exercise with no logged sets is a success', () async {
      final result = await tool().call({'exerciseId': 1});
      expect(result.isError, isFalse);
      expect(result.data! as List, isEmpty);
    });
  });

  group('GetBodyMeasurementsTool', () {
    GetBodyMeasurementsTool tool() => GetBodyMeasurementsTool(
      categories: source.categories,
      watchEntries: source.watchEntries,
    );

    test('lists categories when none is named', () async {
      // The agent cannot guess a category id, so listing is the useful default.
      final result = await tool().call({});
      expect(result.isError, isFalse);

      final cats = (result.data! as Map<String, dynamic>)['categories'] as List;
      expect((cats.first as Map)['name'], 'Waist');
    });

    test('returns entries for a known category', () async {
      source.entries = [
        MeasurementEntry(
          categoryId: 'c1',
          date: DateTime(2026, 8, 7),
          value: 82,
          notes: '',
        ),
      ];
      final result = await tool().call({'categoryId': 'c1'});

      final data = result.data! as Map<String, dynamic>;
      expect(data['category'], 'Waist');
      expect(((data['entries'] as List).first as Map)['value'], 82);
    });

    test('an unknown category is an error that says how to recover', () async {
      final result = await tool().call({'categoryId': 'nope'});
      expect(result.isError, isTrue);
      expect(result.message, contains('nope'));
      expect(result.message.toLowerCase(), contains('list'));
    });

    test('a known category with no entries is a success', () async {
      final result = await tool().call({'categoryId': 'c1'});
      expect(result.isError, isFalse);
      expect((result.data! as Map<String, dynamic>)['entries'] as List, isEmpty);
    });
  });
}
