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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

class FakeReadTool implements Tool {
  int calls = 0;

  @override
  String get name => 'get_thing';

  @override
  String get description => 'Reads a thing';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'id': {'type': 'integer'},
    },
    'required': ['id'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    calls++;
    return ToolResult.ok({'id': args['id']});
  }
}

class FakeWriteTool implements Tool {
  int calls = 0;
  Map<String, dynamic>? lastArgs;

  @override
  String get name => 'write_thing';

  @override
  String get description => 'Writes a thing';

  @override
  bool get isWrite => true;

  @override
  Map<String, dynamic> get inputSchema => {
    'type': 'object',
    'properties': {
      'value': {'type': 'number'},
      'confirmationToken': {'type': 'string'},
    },
    'required': ['value', 'confirmationToken'],
  };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    calls++;
    lastArgs = args;
    return ToolResult.ok({'written': args['value']});
  }
}

class ThrowingTool implements Tool {
  @override
  String get name => 'explode';

  @override
  String get description => 'Always throws';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': <String, dynamic>{}};

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => throw StateError('boom');
}

void main() {
  late ConfirmationTokenService tokens;
  late ToolRegistry registry;
  late FakeWriteTool writeTool;
  late FakeReadTool readTool;

  setUp(() {
    tokens = ConfirmationTokenService();
    registry = ToolRegistry(tokenService: tokens);
    writeTool = FakeWriteTool();
    readTool = FakeReadTool();
    registry.register(readTool);
    registry.register(writeTool);
  });

  group('dispatch and schema validation', () {
    test('specs() exposes every registered tool', () {
      expect(
        registry.specs().map((s) => s.name),
        containsAll(['get_thing', 'write_thing']),
      );
    });

    test('dispatches a read tool with valid arguments', () async {
      final result = await registry.dispatch('get_thing', {'id': 7});
      expect(result.isError, isFalse);
      expect((result.data! as Map)['id'], 7);
    });

    test('unknown tool returns an error rather than throwing', () async {
      final result = await registry.dispatch('nonexistent', {});
      expect(result.isError, isTrue);
      expect(result.message, contains('nonexistent'));
    });

    test('missing required argument returns a schema error', () async {
      final result = await registry.dispatch('get_thing', {});
      expect(result.isError, isTrue);
      expect(result.message, contains('id'));
      expect(readTool.calls, 0);
    });

    test('wrong argument type returns a schema error', () async {
      final result = await registry.dispatch('get_thing', {'id': 'seven'});
      expect(result.isError, isTrue);
      expect(readTool.calls, 0);
    });

    test('a tool that throws is converted to an error result', () async {
      registry.register(ThrowingTool());
      final result = await registry.dispatch('explode', {});
      expect(result.isError, isTrue);
      expect(result.message, contains('boom'));
    });
  });

  group('write gating — the security boundary', () {
    test('a write without a confirmation token is refused and never executes', () async {
      final result = await registry.dispatch('write_thing', {'value': 1.0});
      expect(result.isError, isTrue);
      expect(result.message.toLowerCase(), contains('confirm'));
      expect(writeTool.calls, 0);
    });

    test('a write with a fabricated token is refused and never executes', () async {
      final result = await registry.dispatch('write_thing', {
        'value': 1.0,
        'confirmationToken': 'fabricated',
      });
      expect(result.isError, isTrue);
      expect(writeTool.calls, 0);
    });

    test('a write with a valid token executes exactly once', () async {
      final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
      final result = await registry.dispatch('write_thing', {
        'value': 1.0,
        'confirmationToken': token,
      });
      expect(result.isError, isFalse);
      expect(writeTool.calls, 1);
    });

    test('replaying a consumed token is refused', () async {
      final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
      await registry.dispatch('write_thing', {'value': 1.0, 'confirmationToken': token});
      final replay = await registry.dispatch('write_thing', {
        'value': 1.0,
        'confirmationToken': token,
      });
      expect(replay.isError, isTrue);
      expect(writeTool.calls, 1);
    });

    test('a token minted for other values will not write these ones', () async {
      // The honesty guarantee: the user confirmed 1.0, so 999 must not go through.
      final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
      final result = await registry.dispatch('write_thing', {
        'value': 999.0,
        'confirmationToken': token,
      });
      expect(result.isError, isTrue);
      expect(writeTool.calls, 0);
    });

    test('a token minted for a different tool will not write this one', () async {
      final token = tokens.mint(toolName: 'some_other_tool', arguments: {'value': 1.0});
      final result = await registry.dispatch('write_thing', {
        'value': 1.0,
        'confirmationToken': token,
      });
      expect(result.isError, isTrue);
      expect(writeTool.calls, 0);
    });

    test('the token is stripped before the tool sees its arguments', () async {
      // Tools implement domain logic; the token is a transport concern and
      // would otherwise leak into anything they persist or echo.
      final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
      await registry.dispatch('write_thing', {'value': 1.0, 'confirmationToken': token});
      expect(writeTool.lastArgs, isNotNull);
      expect(writeTool.lastArgs!.containsKey('confirmationToken'), isFalse);
      expect(writeTool.lastArgs!['value'], 1.0);
    });

    test('read tools need no token', () async {
      final result = await registry.dispatch('get_thing', {'id': 1});
      expect(result.isError, isFalse);
      expect(readTool.calls, 1);
    });
  });
}
