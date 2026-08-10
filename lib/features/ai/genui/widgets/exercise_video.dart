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
import 'package:wger/features/exercises/models/video.dart';
import 'package:wger/features/exercises/widgets/videos.dart';

/// Resolves an exercise video by id.
///
/// A seam, overridden with the real Drift-backed lookup when the module is
/// registered, and with a stub in tests. Defaults to "not found" so a missing
/// wiring degrades to a visible message rather than an exception.
final exerciseVideoLookupProvider = Provider<Future<Video?> Function(int)>(
  (ref) => (_) async => null,
);

/// Plays an exercise form video, by **id**.
///
/// Spec §5.5: there is deliberately no url, src, or host parameter. The agent
/// names a video the app already holds; resolution to an absolute URL happens
/// inside wger's `ExerciseVideoWidget` via `mediaUrlBuilderProvider`, which can
/// only ever address the user's own server. Adding a URL parameter here would
/// reopen the silent egress channel the spec closes.
///
/// Wraps wger's existing player rather than reimplementing it, which brings
/// scrubbing and 0.25x/0.5x playback along for free — the slow-motion being the
/// point when the question is "am I doing this lift right".
///
/// Spec §5.6: wger's exercise media is CC BY-SA, so attribution is rendered
/// unconditionally rather than left to the agent to remember.
class ExerciseVideo extends ConsumerWidget {
  final int videoId;

  const ExerciseVideo({super.key, required this.videoId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final lookup = ref.watch(exerciseVideoLookupProvider);

    return FutureBuilder<Video?>(
      future: lookup(videoId),
      builder: (context, snapshot) {
        if (snapshot.connectionState != ConnectionState.done) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: Center(child: CircularProgressIndicator()),
            ),
          );
        }

        final video = snapshot.data;
        if (video == null) {
          return const Card(
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Text('That video is not available.'),
            ),
          );
        }

        return Card(
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ExerciseVideoWidget(video: video),
              Padding(
                padding: const EdgeInsets.all(12),
                child: _Attribution(video: video),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Creative Commons attribution for the video.
///
/// Rendered whenever a video resolves. The author is nullable on the server, so
/// the licence alone must still produce a valid credit.
class _Attribution extends StatelessWidget {
  final Video video;

  const _Attribution({required this.video});

  @override
  Widget build(BuildContext context) {
    final style = Theme.of(context).textTheme.bodySmall;
    final author = video.licenseAuthor;

    return Text(
      author == null || author.isEmpty
          ? video.licenseTitle
          : '${video.licenseTitle} — $author',
      style: style,
    );
  }
}
