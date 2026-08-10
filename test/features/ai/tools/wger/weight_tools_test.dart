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
import 'package:wger/features/ai/tools/wger/weight_tools.dart';
import 'package:wger/features/weight/models/weight_entry.dart';

/// Records what the tool asked the app to do, without a database.
class FakeWeightSink {
  final List<WeightEntry> added = [];
  List<WeightEntry> history = [];

  Future<void> add(WeightEntry entry) async => added.add(entry);

  Stream<List<WeightEntry>> watch() => Stream.value(history);
}

void main() {
  late FakeWeightSink sink;

  setUp(() => sink = FakeWeightSink());

  group('GetWeightHistoryTool', () {
    test('is a read tool', () {
      expect(GetWeightHistoryTool(watch: sink.watch).isWrite, isFalse);
    });

    test('returns entries as a list of maps', () async {
      sink.history = [
        WeightEntry(date: DateTime(2026, 8, 6), weight: 82.4),
        WeightEntry(date: DateTime(2026, 8, 7), weight: 82.1),
      ];
      final result = await GetWeightHistoryTool(watch: sink.watch).call({});
      expect(result.isError, isFalse);
      expect(result.data! as List, hasLength(2));
      expect(((result.data! as List).first as Map)['weight'], 82.4);
      expect(((result.data! as List).first as Map)['date'], '2026-08-06');
    });

    test('respects the limit argument', () async {
      sink.history = List.generate(
        10,
        (i) => WeightEntry(date: DateTime(2026, 8, i + 1), weight: 80.0 + i),
      );
      final result = await GetWeightHistoryTool(watch: sink.watch).call({'limit': 3});
      expect(result.data! as List, hasLength(3));
    });

    test('an empty history is a success, not an error', () async {
      final result = await GetWeightHistoryTool(watch: sink.watch).call({});
      expect(result.isError, isFalse);
      expect(result.data! as List, isEmpty);
    });

    test('emits no URLs — nothing the agent could echo into a render request', () async {
      sink.history = [WeightEntry(date: DateTime(2026, 8, 6), weight: 82.4)];
      final result = await GetWeightHistoryTool(watch: sink.watch).call({});
      expect(result.data.toString(), isNot(contains('http')));
    });
  });

  group('LogWeightTool', () {
    test('is a write tool — the registry will demand confirmation', () {
      expect(LogWeightTool(add: sink.add).isWrite, isTrue);
    });

    test('declares confirmationToken in its schema', () {
      final schema = LogWeightTool(add: sink.add).inputSchema;
      expect((schema['properties'] as Map).containsKey('confirmationToken'), isTrue);
      expect(schema['required'] as List, contains('confirmationToken'));
    });

    test("writes the entry through the app's own sink", () async {
      final result = await LogWeightTool(add: sink.add).call({
        'value': 82.4,
        'date': '2026-08-07',
      });
      expect(result.isError, isFalse);
      expect(sink.added, hasLength(1));
      expect(sink.added.single.weight, 82.4);
      expect(sink.added.single.date, DateTime(2026, 8, 7));
    });

    test('an integer weight is stored as a double', () async {
      // WeightEntry.toCompanion() does `weight as double`, which throws on an
      // int. JSON gives us `82` for a whole number, so coerce or it blows up
      // at persist time rather than here.
      await LogWeightTool(add: sink.add).call({'value': 82, 'date': '2026-08-07'});
      expect(sink.added.single.weight, isA<double>());
      expect(sink.added.single.weight, 82.0);
    });

    test('rejects an unparseable date rather than writing a wrong one', () async {
      final result = await LogWeightTool(
        add: sink.add,
      ).call({'value': 82.4, 'date': 'yesterday-ish'});
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });

    test('rejects a weight below the app’s own minimum', () async {
      final result = await LogWeightTool(
        add: sink.add,
      ).call({'value': WeightEntry.minValue - 1.0, 'date': '2026-08-07'});
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });

    test('rejects a weight above the app’s own maximum', () async {
      final result = await LogWeightTool(
        add: sink.add,
      ).call({'value': WeightEntry.maxValue + 1.0, 'date': '2026-08-07'});
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });

    test('accepts weights exactly at the boundaries', () async {
      await LogWeightTool(
        add: sink.add,
      ).call({'value': WeightEntry.minValue, 'date': '2026-08-07'});
      await LogWeightTool(
        add: sink.add,
      ).call({'value': WeightEntry.maxValue, 'date': '2026-08-07'});
      expect(sink.added, hasLength(2));
    });

    test('the error message names the bounds so the agent can self-correct', () async {
      final result = await LogWeightTool(add: sink.add).call({'value': 5.0, 'date': '2026-08-07'});
      expect(result.message, contains('${WeightEntry.minValue}'));
      expect(result.message, contains('${WeightEntry.maxValue}'));
    });
  });
}
