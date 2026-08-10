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

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/mcp/mcp_bridge_server.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

class CountingWriteTool implements Tool {
  int calls = 0;

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
    return ToolResult.ok({'written': args['value']});
  }
}

void main() {
  late ConfirmationTokenService tokens;
  late CountingWriteTool writeTool;
  late ToolRegistry registry;
  late McpBridgeServer bridge;
  late McpBridgeHandle handle;
  late HttpClient client;

  setUp(() async {
    tokens = ConfirmationTokenService();
    writeTool = CountingWriteTool();
    registry = ToolRegistry(tokenService: tokens)..register(writeTool);
    bridge = McpBridgeServer(registry: registry);
    handle = await bridge.start();
    client = HttpClient();
  });

  tearDown(() async {
    client.close(force: true);
    await bridge.stop();
  });

  Future<HttpClientResponse> post(
    Map<String, dynamic> body, {
    String? token,
    Uri? to,
  }) async {
    final request = await client.postUrl(to ?? handle.uri);
    if (token != null) {
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
    }
    request.headers.contentType = ContentType.json;
    request.write(jsonEncode(body));
    return request.close();
  }

  Future<Map<String, dynamic>> jsonOf(HttpClientResponse response) async =>
      jsonDecode(await response.transform(utf8.decoder).join()) as Map<String, dynamic>;

  group('binding', () {
    test('binds loopback, not a routable address', () {
      expect(handle.uri.host, '127.0.0.1');
    });

    test('the handle never prints its bearer token', () {
      // This ends up in logs and error messages.
      expect(handle.toString(), isNot(contains(handle.bearerToken)));
    });

    test('stop releases the port', () async {
      await bridge.stop();
      expect(bridge.isRunning, isFalse);

      await expectLater(
        post({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'}, token: handle.bearerToken),
        throwsA(isA<SocketException>()),
      );
    });
  });

  group('authentication', () {
    test('a request with no token is refused', () async {
      final response = await post({'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'});
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('a request with the wrong token is refused', () async {
      final response = await post(
        {'jsonrpc': '2.0', 'id': 1, 'method': 'tools/list'},
        token: 'not-the-token',
      );
      expect(response.statusCode, HttpStatus.unauthorized);
    });

    test('an unauthenticated tools/call never reaches the registry', () async {
      // Loopback alone is not access control: any other local process could
      // otherwise drive the user's health data.
      final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
      await post({
        'jsonrpc': '2.0',
        'id': 1,
        'method': 'tools/call',
        'params': {
          'name': 'write_thing',
          'arguments': {'value': 1.0, 'confirmationToken': token},
        },
      });

      expect(writeTool.calls, 0);
    });
  });

  group('protocol', () {
    test('initialize reports tool capability', () async {
      final response = await post(
        {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize'},
        token: handle.bearerToken,
      );
      final body = await jsonOf(response);

      expect(body['id'], 1);
      expect((body['result'] as Map)['capabilities'], contains('tools'));
    });

    test('tools/list returns exactly the registry’s specs', () async {
      final response = await post(
        {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
        token: handle.bearerToken,
      );
      final body = await jsonOf(response);

      final names = ((body['result'] as Map)['tools'] as List)
          .map((t) => (t as Map)['name'])
          .toSet();
      expect(names, registry.specs().map((s) => s.name).toSet());
    });

    test('an unknown method returns a JSON-RPC error', () async {
      final response = await post(
        {'jsonrpc': '2.0', 'id': 3, 'method': 'nonsense'},
        token: handle.bearerToken,
      );
      final body = await jsonOf(response);

      expect((body['error'] as Map)['code'], -32601);
    });

    test('malformed JSON returns a parse error rather than closing the socket', () async {
      final request = await client.postUrl(handle.uri);
      request.headers.set(HttpHeaders.authorizationHeader, 'Bearer ${handle.bearerToken}');
      request.write('{not json');
      final body = await jsonOf(await request.close());

      expect((body['error'] as Map)['code'], -32700);
    });
  });

  group('the write gate applies through the bridge', () {
    test('a valid token executes the tool exactly once', () async {
      final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
      final response = await post({
        'jsonrpc': '2.0',
        'id': 4,
        'method': 'tools/call',
        'params': {
          'name': 'write_thing',
          'arguments': {'value': 1.0, 'confirmationToken': token},
        },
      }, token: handle.bearerToken);

      final result = (await jsonOf(response))['result'] as Map;
      expect(result['isError'], isFalse);
      expect(writeTool.calls, 1);
    });

    test('an external agent cannot skip the confirmation gate', () async {
      // The whole point of sharing one registry: the ACP path gets the same
      // guarantee as the local loop, not a parallel one that might drift.
      final response = await post({
        'jsonrpc': '2.0',
        'id': 5,
        'method': 'tools/call',
        'params': {
          'name': 'write_thing',
          'arguments': {'value': 999.0},
        },
      }, token: handle.bearerToken);

      final result = (await jsonOf(response))['result'] as Map;
      expect(result['isError'], isTrue);
      expect(writeTool.calls, 0);
    });

    test('tool failures come back as results, not JSON-RPC errors', () async {
      final response = await post({
        'jsonrpc': '2.0',
        'id': 6,
        'method': 'tools/call',
        'params': {'name': 'no_such_tool', 'arguments': <String, dynamic>{}},
      }, token: handle.bearerToken);

      final body = await jsonOf(response);
      expect(body.containsKey('error'), isFalse);
      expect((body['result'] as Map)['isError'], isTrue);
    });
  });
}
