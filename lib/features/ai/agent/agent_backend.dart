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

sealed class AgentEvent {
  const AgentEvent();
}

class AgentText extends AgentEvent {
  final String text;
  const AgentText(this.text);
}

class AgentToolStarted extends AgentEvent {
  final String name;
  const AgentToolStarted(this.name);
}

class AgentToolFinished extends AgentEvent {
  final String name;
  final bool isError;
  const AgentToolFinished(this.name, {required this.isError});
}

class AgentTurnComplete extends AgentEvent {
  const AgentTurnComplete();
}

class AgentFailure extends AgentEvent {
  final String message;
  final bool retriable;
  const AgentFailure(this.message, {this.retriable = false});
}

/// A complete conversational agent.
///
/// The abstraction sits here rather than at the provider level because an ACP
/// agent runs its own tool loop: it is an agent, not a model endpoint. Forcing
/// both behind one interface would leak the difference immediately.
///
/// Two implementations: `LocalAgentBackend`, which owns the loop and drives an
/// `LlmProvider`, and (desktop only) an ACP client that delegates the loop to
/// an external process.
abstract interface class AgentBackend {
  Stream<AgentEvent> sendMessage(String text);

  Future<void> cancel();

  Future<void> dispose();
}
