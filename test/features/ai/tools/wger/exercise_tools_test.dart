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
import 'package:wger/core/language.dart';
import 'package:wger/features/ai/tools/wger/exercise_tools.dart';
import 'package:wger/features/exercises/models/category.dart';
import 'package:wger/features/exercises/models/exercise.dart';
import 'package:wger/features/exercises/models/translation.dart';
import 'package:wger/features/exercises/models/video.dart';

const _language = Language(id: 2, shortName: 'en', fullName: 'English');

Video _video({int id = 412}) => Video(
  id: id,
  uuid: 'v-$id',
  exerciseId: 1,
  isMain: true,
  // A server-relative media path. It must never reach the agent.
  video: 'exercise-video/1/deadlift.mp4',
  size: 1024,
  duration: 12,
  width: 1920,
  height: 1080,
  codec: 'h264',
  codecLong: 'H.264',
  created: DateTime(2026),
  lastUpdate: DateTime(2026),
  licenseId: 1,
  licenseTitle: 'CC BY-SA 4.0',
  licenseObjectUrl: 'https://creativecommons.example/by-sa',
  licenseAuthor: 'Jane Doe',
  licenseAuthorUrl: 'https://example.com/jane',
  licenseDerivativeSourceUrl: 'https://example.com/source',
);

Exercise _exercise({int id = 1, bool withVideo = true}) => Exercise(
  id: id,
  uuid: 'e-$id',
  category: const ExerciseCategory(id: 1, name: 'Legs'),
  translations: const [
    Translation(
      name: 'Romanian Deadlift',
      // wger stores descriptions as HTML, and user-contributed content can
      // contain anchors.
      description: '<p>Hinge at the hips. See <a href="https://spam.example">here</a>.</p>',
      language: _language,
    ),
  ],
  videos: withVideo ? [_video()] : const [],
  authors: const ['Jane Doe'],
);

class FakeExerciseSource {
  List<Exercise> results = [];
  Exercise? detail;

  Future<List<Exercise>> search(String term) async => results;

  Future<Exercise?> load(int id) async => detail;
}

void main() {
  late FakeExerciseSource source;

  setUp(() => source = FakeExerciseSource());

  group('SearchExercisesTool', () {
    test('is a read tool', () {
      expect(SearchExercisesTool(search: source.search).isWrite, isFalse);
    });

    test('returns id, name and a hasVideo flag rather than a link', () async {
      source.results = [_exercise()];
      final result = await SearchExercisesTool(search: source.search).call({'query': 'deadlift'});

      final first = (result.data! as List).first as Map<String, dynamic>;
      expect(first['id'], 1);
      expect(first['name'], 'Romanian Deadlift');
      expect(first['hasVideo'], isTrue);
    });

    test('hasVideo is false when the exercise has none', () async {
      source.results = [_exercise(withVideo: false)];
      final result = await SearchExercisesTool(search: source.search).call({'query': 'x'});
      expect(((result.data! as List).first as Map)['hasVideo'], isFalse);
    });

    test('emits no URLs and no media paths', () async {
      source.results = [_exercise()];
      final result = await SearchExercisesTool(search: source.search).call({'query': 'deadlift'});

      final encoded = jsonEncode(result.data);
      expect(encoded, isNot(contains('http')));
      expect(encoded, isNot(contains('.mp4')));
      expect(encoded, isNot(contains('exercise-video')));
    });

    test('a blank query is an error', () async {
      final result = await SearchExercisesTool(search: source.search).call({'query': '  '});
      expect(result.isError, isTrue);
    });

    test('no results is a success', () async {
      final result = await SearchExercisesTool(search: source.search).call({'query': 'nope'});
      expect(result.isError, isFalse);
      expect(result.data! as List, isEmpty);
    });
  });

  group('GetExerciseDetailTool', () {
    test('returns video ids, never paths or URLs', () async {
      // Spec 5.5: the id is what ExerciseVideo takes. Resolution to a URL
      // happens client-side via mediaUrlBuilderProvider, which can only address
      // the user's own server.
      source.detail = _exercise();
      final result = await GetExerciseDetailTool(load: source.load).call({'id': 1});

      final data = result.data! as Map<String, dynamic>;
      final videos = data['videos'] as List;
      expect(videos, hasLength(1));
      expect((videos.first as Map)['id'], 412);

      final encoded = jsonEncode(data);
      expect(encoded, isNot(contains('http')));
      expect(encoded, isNot(contains('.mp4')));
      expect(encoded, isNot(contains('creativecommons')));
    });

    test('strips HTML and embedded links from the description', () async {
      source.detail = _exercise();
      final result = await GetExerciseDetailTool(load: source.load).call({'id': 1});

      final description = (result.data! as Map<String, dynamic>)['description'] as String;
      expect(description, contains('Hinge at the hips'));
      expect(description, isNot(contains('<p>')));
      expect(description, isNot(contains('<a')));
      expect(description, isNot(contains('spam.example')));
    });

    test('includes muscles and equipment', () async {
      source.detail = _exercise();
      final result = await GetExerciseDetailTool(load: source.load).call({'id': 1});
      final data = result.data! as Map<String, dynamic>;
      expect(data.containsKey('muscles'), isTrue);
      expect(data['category'], 'Legs');
    });

    test('an unknown id is an error, not an empty object', () async {
      final result = await GetExerciseDetailTool(load: source.load).call({'id': 999});
      expect(result.isError, isTrue);
      expect(result.message, contains('999'));
    });
  });
}
