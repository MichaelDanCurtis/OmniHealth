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

/// Outcome of a tool invocation.
///
/// Errors are values, not exceptions. A failed tool result is fed back to the
/// model so it can explain the failure or try something else, rather than
/// aborting the turn and leaving the user staring at a dead conversation.
class ToolResult {
  final Object? data;
  final String message;
  final bool isError;

  const ToolResult._({this.data, this.message = '', required this.isError});

  factory ToolResult.ok(Object? data) => ToolResult._(data: data, isError: false);

  factory ToolResult.error(String message) => ToolResult._(message: message, isError: true);
}

/// One capability the agent may invoke.
///
/// Shaped after MCP — name, description, JSON Schema, call — so the loopback
/// MCP bridge and any future remote plugin are thin adapters rather than a
/// second tool system.
abstract interface class Tool {
  String get name;

  /// Written for a model to read. This is prompt surface, not documentation.
  String get description;

  /// JSON Schema for the arguments. The registry validates against this before
  /// [call] runs, so implementations may assume well-formed input.
  Map<String, dynamic> get inputSchema;

  /// Whether invoking this mutates the user's data.
  ///
  /// Write tools additionally require a valid `confirmationToken`, enforced by
  /// the registry — never by the tool itself, and never by the prompt.
  bool get isWrite;

  Future<ToolResult> call(Map<String, dynamic> args);
}
