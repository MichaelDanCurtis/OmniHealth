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

/// Wire contract shared by every LLM provider adapter.
///
/// Providers own HTTP and wire-format concerns and nothing else: they do not
/// execute tools, and they know nothing about widgets. The agent loop consumes
/// this contract; see `agent/local/local_agent_backend.dart`.
library;

enum MessageRole {
  system('system'),
  user('user'),
  assistant('assistant'),
  tool('tool');

  const MessageRole(this.wireName);

  /// The string this role is called on the wire. Kept explicit rather than
  /// derived from [name] so a Dart rename can never change the protocol.
  final String wireName;
}

/// One turn in the conversation sent to a provider.
class Message {
  final MessageRole role;
  final String content;

  /// Set on [MessageRole.tool] messages to link a result to its request.
  final String? toolCallId;

  /// Set on assistant messages that requested tools.
  final List<ToolCall> toolCalls;

  const Message({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolCalls = const [],
  });
}

/// A model's request to invoke one tool.
class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({
    required this.id,
    required this.name,
    required this.arguments,
  });
}

/// A tool advertised to the model. Mirrors MCP's shape so the bridge in `mcp/`
/// stays a thin adapter.
class ToolSpec {
  final String name;
  final String description;

  /// JSON Schema describing the arguments.
  final Map<String, dynamic> inputSchema;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

/// Streamed output from a provider.
sealed class LlmEvent {
  const LlmEvent();
}

/// An incremental chunk of assistant text.
class TextDelta extends LlmEvent {
  final String text;
  const TextDelta(this.text);
}

/// The model asked to invoke a tool. Emitted once per call, fully assembled —
/// adapters are responsible for reassembling fragmented arguments first.
class ToolCallRequested extends LlmEvent {
  final ToolCall call;
  const ToolCallRequested(this.call);
}

/// The provider finished this turn cleanly.
class TurnComplete extends LlmEvent {
  const TurnComplete();
}

/// The provider failed.
///
/// [retriable] distinguishes transient conditions (rate limits, timeouts,
/// 5xx) from ones the user must act on (an invalid key), so the UI can offer
/// retry only where retrying could actually help.
class ProviderError extends LlmEvent {
  final String message;
  final bool retriable;
  const ProviderError(this.message, {this.retriable = false});
}

/// A streaming connection to one LLM endpoint.
abstract interface class LlmProvider {
  /// Identifies the configured endpoint this provider serves.
  String get id;

  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  });
}
