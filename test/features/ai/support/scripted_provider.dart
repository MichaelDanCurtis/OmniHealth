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

import 'package:wger/features/ai/providers/llm_provider.dart';

/// Replays scripted event sequences, one list per turn.
///
/// Lets the agent loop and the acceptance tests be driven deterministically —
/// including sequences a real model would rarely produce, like a malformed
/// response or an endless run of tool calls — without ever touching a network.
class ScriptedProvider implements LlmProvider {
  /// One list of events per turn, consumed in order. Turns beyond the end of
  /// the script complete immediately.
  final List<List<LlmEvent>> turns;

  /// The messages passed on each call, so tests can assert what the loop sent
  /// back to the model.
  final List<List<Message>> received = [];

  /// The tool specs offered on each call.
  final List<List<ToolSpec>> offeredTools = [];

  int turnIndex = 0;

  ScriptedProvider(this.turns);

  @override
  String get id => 'scripted';

  @override
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  }) async* {
    received.add(List.of(messages));
    offeredTools.add(List.of(tools));

    final events = turnIndex < turns.length ? turns[turnIndex] : const [TurnComplete()];
    turnIndex++;

    for (final event in events) {
      yield event;
    }
  }
}
