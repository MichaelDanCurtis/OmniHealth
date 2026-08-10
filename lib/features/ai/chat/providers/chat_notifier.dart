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

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';

/// One item in the visible conversation.
sealed class ChatEntry {
  const ChatEntry();
}

class UserEntry extends ChatEntry {
  final String text;
  const UserEntry(this.text);
}

/// Assistant prose. Mutable because text streams in delta by delta.
class AssistantEntry extends ChatEntry {
  final StringBuffer _buffer;

  AssistantEntry([String initial = '']) : _buffer = StringBuffer(initial);

  void append(String delta) => _buffer.write(delta);

  String get text => _buffer.toString();
  bool get isEmpty => _buffer.isEmpty;
}

/// A tool running, or having run.
class ToolEntry extends ChatEntry {
  final String name;
  bool running;
  bool isError;

  ToolEntry(this.name, {this.running = true, this.isError = false});
}

/// A rendered component awaiting the user.
class SurfaceEntry extends ChatEntry {
  final SurfaceRequest request;

  /// Set once the user acts, so the UI can collapse it to a receipt rather than
  /// leaving a live form in the scrollback.
  bool resolved;

  SurfaceEntry(this.request, {this.resolved = false});
}

/// Something went wrong, stated plainly rather than swallowed.
class FailureEntry extends ChatEntry {
  final String message;
  final bool retriable;
  const FailureEntry(this.message, {required this.retriable});
}

class ChatState {
  final List<ChatEntry> entries;
  final bool busy;

  const ChatState({this.entries = const [], this.busy = false});

  ChatState copyWith({List<ChatEntry>? entries, bool? busy}) =>
      ChatState(entries: entries ?? this.entries, busy: busy ?? this.busy);
}

/// Drives one conversation.
///
/// Owns the transcript and translates [AgentEvent]s into visible entries. Knows
/// nothing about providers or HTTP; the backend abstraction means the same
/// notifier serves the local loop and an ACP agent unchanged.
class ChatNotifier extends Notifier<ChatState> {
  StreamSubscription<AgentEvent>? _subscription;
  AgentBackend? _backend;

  @override
  ChatState build() {
    ref.onDispose(() {
      _subscription?.cancel();
      _backend?.dispose();
    });
    return const ChatState();
  }

  /// Injected rather than read from a provider so tests can supply a fake.
  void attachBackend(AgentBackend backend) => _backend = backend;

  /// Called by `render_ui` when the agent asks to draw something.
  void onSurfaceRequested(SurfaceRequest request) {
    _append(SurfaceEntry(request));
  }

  /// Marks a surface resolved so the UI stops offering its controls.
  void markSurfaceResolved(SurfaceEntry entry) {
    entry.resolved = true;
    state = state.copyWith(entries: [...state.entries]);
  }

  Future<void> send(String text) async {
    final backend = _backend;
    if (backend == null || text.trim().isEmpty) {
      return;
    }

    _append(UserEntry(text.trim()));
    state = state.copyWith(busy: true);

    // A fresh assistant entry per turn, appended to as deltas arrive.
    AssistantEntry? current;

    final completer = Completer<void>();
    _subscription = backend.sendMessage(text.trim()).listen(
      (event) {
        switch (event) {
          case AgentText(:final text):
            if (current == null) {
              current = AssistantEntry(text);
              _append(current!);
            } else {
              current!.append(text);
              state = state.copyWith(entries: [...state.entries]);
            }

          case AgentToolStarted(:final name):
            // render_ui is represented by the surface it produces; showing a
            // "running render_ui" chip alongside the card is just noise.
            if (name != 'render_ui') {
              _append(ToolEntry(name));
            }

          case AgentToolFinished(:final name, :final isError):
            final match = state.entries.whereType<ToolEntry>().where(
              (t) => t.name == name && t.running,
            );
            if (match.isNotEmpty) {
              match.last
                ..running = false
                ..isError = isError;
              state = state.copyWith(entries: [...state.entries]);
            }
            // A new turn follows a tool call, so start a fresh prose entry.
            current = null;

          case AgentFailure(:final message, :final retriable):
            _append(FailureEntry(message, retriable: retriable));

          case AgentTurnComplete():
            break;
        }
      },
      onError: (Object e) {
        _append(FailureEntry('Something went wrong: $e', retriable: true));
      },
      onDone: () {
        state = state.copyWith(busy: false);
        if (!completer.isCompleted) {
          completer.complete();
        }
      },
      cancelOnError: false,
    );

    await completer.future;
  }

  Future<void> cancel() async {
    await _backend?.cancel();
    await _subscription?.cancel();
    _subscription = null;

    // Any surface still waiting would otherwise hang the turn forever.
    for (final entry in state.entries.whereType<SurfaceEntry>()) {
      if (!entry.resolved) {
        entry.request.dismiss();
        entry.resolved = true;
      }
    }

    state = state.copyWith(busy: false, entries: [...state.entries]);
  }

  void _append(ChatEntry entry) {
    state = state.copyWith(entries: [...state.entries, entry]);
  }
}

final chatProvider = NotifierProvider<ChatNotifier, ChatState>(ChatNotifier.new);
