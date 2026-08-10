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

import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:logging/logging.dart';
import 'package:wger/features/ai/providers/llm_provider.dart' show ToolSpec;
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';

/// The only surface an agent may invoke.
///
/// This is the security boundary for writes. Whatever the agent renders, and
/// whatever a component claims, a write-capable tool does not run here without
/// a valid confirmation token. The catalog's write components exist to keep
/// that confirmation *honest*; this class is what makes it *binding*.
///
/// Order of operations: resolve the name, validate arguments against the
/// declared schema, enforce the token for writes, then execute.
class ToolRegistry {
  static const confirmationTokenArg = 'confirmationToken';

  final ConfirmationTokenService tokenService;
  final Map<String, Tool> _tools = {};
  final _logger = Logger('ToolRegistry');

  ToolRegistry({required this.tokenService});

  void register(Tool tool) => _tools[tool.name] = tool;

  List<ToolSpec> specs() => _tools.values
      .map(
        (t) => ToolSpec(
          name: t.name,
          description: t.description,
          inputSchema: t.inputSchema,
        ),
      )
      .toList();

  Future<ToolResult> dispatch(String name, Map<String, dynamic> args) async {
    final tool = _tools[name];
    if (tool == null) {
      return ToolResult.error('No tool named "$name" is available.');
    }

    // The token is transport, not domain. Strip it once here so neither schema
    // validation nor the tool itself ever sees it.
    final domainArgs = Map<String, dynamic>.from(args)..remove(confirmationTokenArg);

    final schemaError = await _validate(tool, domainArgs);
    if (schemaError != null) {
      return ToolResult.error('Invalid arguments for "$name": $schemaError');
    }

    if (tool.isWrite) {
      final refusal = _checkConfirmation(
        tool,
        token: args[confirmationTokenArg] as String?,
        domainArgs: domainArgs,
      );
      if (refusal != null) {
        return refusal;
      }
    }

    try {
      return await tool.call(domainArgs);
    } catch (e, st) {
      _logger.warning('Tool "$name" threw', e, st);
      return ToolResult.error('Tool "$name" failed: $e');
    }
  }

  Future<String?> _validate(Tool tool, Map<String, dynamic> domainArgs) async {
    // `confirmationToken` is declared in write tools' schemas so the model
    // knows to pass it, but it has already been stripped from the arguments —
    // so drop it from `required` too, or every write would fail validation.
    final schema = Map<String, Object?>.from(tool.inputSchema);
    final required = (schema['required'] as List?)
        ?.where((k) => k != confirmationTokenArg)
        .toList();
    if (required != null) {
      schema['required'] = required;
    }

    final errors = await Schema.fromMap(schema).validate(domainArgs);
    if (errors.isEmpty) {
      return null;
    }
    return errors.map((e) => e.toErrorString()).join('; ');
  }

  ToolResult? _checkConfirmation(
    Tool tool, {
    required String? token,
    required Map<String, dynamic> domainArgs,
  }) {
    if (token == null || token.isEmpty) {
      return ToolResult.error(
        'Tool "${tool.name}" changes the user\'s data and requires confirmation. '
        'Render a confirmation UI first and pass the resulting $confirmationTokenArg.',
      );
    }

    final check = tokenService.consume(
      token: token,
      toolName: tool.name,
      arguments: domainArgs,
    );

    return switch (check) {
      TokenCheck.valid => null,
      TokenCheck.unknown => ToolResult.error(
        'That confirmation is not valid for "${tool.name}". Ask the user again.',
      ),
      TokenCheck.expired => ToolResult.error(
        'That confirmation expired. Ask the user to confirm again.',
      ),
      TokenCheck.alreadyUsed => ToolResult.error(
        'That confirmation was already used. Ask the user to confirm again.',
      ),
      TokenCheck.argumentMismatch => ToolResult.error(
        'The values changed after the user confirmed. Ask the user to confirm again.',
      ),
    };
  }
}

final toolRegistryProvider = Provider<ToolRegistry>(
  (ref) => ToolRegistry(tokenService: ref.read(confirmationTokenServiceProvider)),
);
