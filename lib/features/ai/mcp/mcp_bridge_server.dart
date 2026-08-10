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
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

/// Where an external agent should connect, and the secret it must present.
class McpBridgeHandle {
  final int port;
  final String bearerToken;

  const McpBridgeHandle({required this.port, required this.bearerToken});

  Uri get uri => Uri.parse('http://127.0.0.1:$port');

  /// Never prints the token — this ends up in logs and error messages.
  @override
  String toString() => 'McpBridgeHandle(port: $port)';
}

/// Exposes the [ToolRegistry] to an external ACP agent as an MCP server.
///
/// Desktop only. Its whole reason to exist is that ACP tools and local tools
/// should be literally the same objects: an external agent gets the same
/// registry the in-process loop uses, so the confirmation-token gate applies
/// identically no matter which backend is driving.
///
/// Two deliberate restrictions, because this opens a port on a machine holding
/// someone's health data:
///
/// - Bound to loopback only. Never `0.0.0.0`.
/// - Every request must present a per-session bearer token, generated at start
///   and passed to the agent we spawn. Loopback alone is not access control —
///   any other local process could otherwise drive the user's health data.
class McpBridgeServer {
  static const _protocolVersion = '2024-11-05';

  final ToolRegistry registry;
  final _logger = Logger('McpBridgeServer');

  HttpServer? _server;
  String? _bearerToken;

  McpBridgeServer({required this.registry});

  bool get isRunning => _server != null;

  Future<McpBridgeHandle> start() async {
    if (_server != null) {
      throw StateError('Bridge is already running');
    }

    final random = Random.secure();
    final token = base64Url.encode(List<int>.generate(32, (_) => random.nextInt(256)));

    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server = server;
    _bearerToken = token;

    unawaited(_serve(server));

    _logger.info('MCP bridge listening on 127.0.0.1:${server.port}');
    return McpBridgeHandle(port: server.port, bearerToken: token);
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _bearerToken = null;
  }

  Future<void> _serve(HttpServer server) async {
    await for (final request in server) {
      try {
        await _handle(request);
      } catch (e, st) {
        _logger.warning('Bridge request failed', e, st);
        try {
          request.response.statusCode = HttpStatus.internalServerError;
          await request.response.close();
        } catch (_) {
          // The client may already be gone; nothing useful to do.
        }
      }
    }
  }

  Future<void> _handle(HttpRequest request) async {
    // Authenticate before reading or parsing anything.
    final auth = request.headers.value(HttpHeaders.authorizationHeader);
    if (auth != 'Bearer $_bearerToken') {
      request.response.statusCode = HttpStatus.unauthorized;
      await request.response.close();
      return;
    }

    if (request.method != 'POST') {
      request.response.statusCode = HttpStatus.methodNotAllowed;
      await request.response.close();
      return;
    }

    final body = await utf8.decoder.bind(request).join();
    Map<String, dynamic> rpc;
    try {
      rpc = jsonDecode(body) as Map<String, dynamic>;
    } catch (_) {
      await _writeJson(request, {
        'jsonrpc': '2.0',
        'id': null,
        'error': {'code': -32700, 'message': 'Parse error'},
      });
      return;
    }

    final id = rpc['id'];
    final method = rpc['method'] as String?;
    final params = (rpc['params'] as Map?)?.cast<String, dynamic>() ?? const {};

    switch (method) {
      case 'initialize':
        await _writeJson(request, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'protocolVersion': _protocolVersion,
            'capabilities': {
              'tools': <String, dynamic>{},
            },
            'serverInfo': {'name': 'omnihealth', 'version': '1'},
          },
        });

      case 'tools/list':
        await _writeJson(request, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'tools': registry
                .specs()
                .map(
                  (s) => {
                    'name': s.name,
                    'description': s.description,
                    'inputSchema': s.inputSchema,
                  },
                )
                .toList(),
          },
        });

      case 'tools/call':
        final toolName = params['name'] as String?;
        if (toolName == null) {
          await _writeJson(request, {
            'jsonrpc': '2.0',
            'id': id,
            'error': {'code': -32602, 'message': 'Missing tool name'},
          });
          return;
        }

        final arguments = (params['arguments'] as Map?)?.cast<String, dynamic>() ?? const {};
        final result = await registry.dispatch(toolName, arguments);

        // MCP reports tool failures as results with isError, not as JSON-RPC
        // errors — the agent is meant to read and recover from them, which is
        // the same contract the local loop uses.
        await _writeJson(request, {
          'jsonrpc': '2.0',
          'id': id,
          'result': {
            'isError': result.isError,
            'content': [
              {
                'type': 'text',
                'text': result.isError ? result.message : jsonEncode(result.data),
              },
            ],
          },
        });

      default:
        await _writeJson(request, {
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found: $method'},
        });
    }
  }

  Future<void> _writeJson(HttpRequest request, Map<String, dynamic> payload) async {
    request.response
      ..statusCode = HttpStatus.ok
      ..headers.contentType = ContentType.json
      ..write(jsonEncode(payload));
    await request.response.close();
  }
}
