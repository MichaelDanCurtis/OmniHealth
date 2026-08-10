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
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

/// Runs the agent loop in-process: prompt the provider, execute any tool calls
/// against the registry, feed the results back, repeat until the model stops
/// asking for tools.
///
/// Knows nothing about HTTP — that is the provider's job — and nothing about
/// widgets. Generative UI reaches it as an ordinary tool call (`render_ui`),
/// which is what lets the same loop serve both backends.
class LocalAgentBackend implements AgentBackend {
  final LlmProvider provider;
  final ToolRegistry registry;

  /// Hard stop so a model that keeps requesting tools cannot spin forever,
  /// burning the user's tokens on their own API key.
  final int maxIterations;

  final List<Message> _history = [];
  final _logger = Logger('LocalAgentBackend');
  bool _cancelled = false;

  LocalAgentBackend({
    required this.provider,
    required this.registry,
    this.maxIterations = 12,
  });

  /// The conversation so far, for the UI to restore or inspect.
  List<Message> get history => List.unmodifiable(_history);

  @override
  Stream<AgentEvent> sendMessage(String text) {
    // Reset eagerly rather than inside the generator: an `async*` body does not
    // run until the stream is listened to, so resetting there would silently
    // drop a cancel() arriving between send and first listen.
    _cancelled = false;
    _history.add(Message(role: MessageRole.user, content: text));
    return _run();
  }

  Stream<AgentEvent> _run() async* {
    for (var iteration = 0; iteration < maxIterations; iteration++) {
      if (_cancelled) {
        return;
      }

      final toolCalls = <ToolCall>[];
      final assistantText = StringBuffer();
      var failed = false;

      await for (final event in provider.stream(
        messages: List.unmodifiable(_history),
        tools: registry.specs(),
      )) {
        if (_cancelled) {
          return;
        }

        switch (event) {
          case TextDelta(:final text):
            assistantText.write(text);
            yield AgentText(text);
          case ToolCallRequested(:final call):
            toolCalls.add(call);
          case ProviderError(:final message, :final retriable):
            failed = true;
            yield AgentFailure(message, retriable: retriable);
          case TurnComplete():
            break;
        }
      }

      if (failed) {
        return;
      }

      _history.add(
        Message(
          role: MessageRole.assistant,
          content: assistantText.toString(),
          toolCalls: toolCalls,
        ),
      );

      // No tools requested means the model has finished talking.
      if (toolCalls.isEmpty) {
        yield const AgentTurnComplete();
        return;
      }

      for (final call in toolCalls) {
        if (_cancelled) {
          return;
        }
        yield AgentToolStarted(call.name);

        final result = await registry.dispatch(call.name, call.arguments);
        yield AgentToolFinished(call.name, isError: result.isError);

        // Errors go back as ordinary tool results so the model can explain or
        // recover, rather than aborting the turn on the user.
        _history.add(
          Message(
            role: MessageRole.tool,
            toolCallId: call.id,
            content: result.isError ? 'ERROR: ${result.message}' : jsonEncode(result.data),
          ),
        );
      }
    }

    _logger.warning('Hit iteration cap of $maxIterations');
    yield AgentFailure(
      'Stopped after too many steps ($maxIterations). Try rephrasing your request.',
    );
  }

  @override
  Future<void> cancel() async => _cancelled = true;

  @override
  Future<void> dispose() async {
    _cancelled = true;
    _history.clear();
  }
}
