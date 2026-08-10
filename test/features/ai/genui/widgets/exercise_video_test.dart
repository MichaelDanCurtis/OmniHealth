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

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/genui/widgets/exercise_video.dart';
import 'package:wger/features/exercises/models/video.dart';

Video _video({String? author = 'Jane Doe'}) => Video(
  id: 412,
  uuid: 'v-412',
  exerciseId: 1,
  isMain: true,
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
  licenseAuthor: author,
  licenseAuthorUrl: 'https://example.com/jane',
  licenseDerivativeSourceUrl: 'https://example.com/source',
);

Widget _host(Widget child, {Video? video}) => ProviderScope(
  overrides: [
    exerciseVideoLookupProvider.overrideWithValue((_) async => video),
  ],
  child: MaterialApp(home: Scaffold(body: child)),
);

void main() {
  testWidgets('takes a video id — there is no URL parameter to pass', (tester) async {
    // Spec 5.5: if this component ever grows a url/src/host parameter, an agent
    // can exfiltrate health data in a query string with no user interaction.
    // This is the tripwire for that regression.
    const widget = ExerciseVideo(videoId: 412);
    expect(widget.videoId, 412);

    final description = widget.toStringDeep().toLowerCase();
    expect(description, isNot(contains('http')));
    expect(description, isNot(contains('src:')));
    expect(description, isNot(contains('url:')));
  });

  testWidgets('an unknown video id renders a not-found state, not an exception', (tester) async {
    await tester.pumpWidget(_host(const ExerciseVideo(videoId: 999999)));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('not available'), findsOneWidget);
  });

  testWidgets('renders licence attribution whenever a video resolves', (tester) async {
    // Spec 5.6: wger's exercise media is CC BY-SA. Attribution is a licence
    // obligation and must not depend on the agent remembering to mention it.
    await tester.pumpWidget(
      _host(const ExerciseVideo(videoId: 412), video: _video()),
    );
    await tester.pump();

    expect(find.textContaining('CC BY-SA 4.0'), findsOneWidget);
    expect(find.textContaining('Jane Doe'), findsOneWidget);
  });

  testWidgets('attribution still renders when the author is null', (tester) async {
    // Video.licenseAuthor is nullable on the server.
    await tester.pumpWidget(
      _host(const ExerciseVideo(videoId: 412), video: _video(author: null)),
    );
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('CC BY-SA 4.0'), findsOneWidget);
  });

  testWidgets('the attribution never renders a licence URL', (tester) async {
    // The model carries licenseObjectUrl and licenseAuthorUrl; neither should
    // reach the screen as a fetchable destination.
    await tester.pumpWidget(
      _host(const ExerciseVideo(videoId: 412), video: _video()),
    );
    await tester.pump();

    expect(find.textContaining('http'), findsNothing);
  });
}
