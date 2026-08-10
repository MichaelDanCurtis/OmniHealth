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

import 'package:wger/features/ai/agent/acp/acp_agent_backend.dart';

/// How the fake agent should behave.
enum FakeAgentMode {
  /// A well-behaved session.
  normal,

  /// Exits abruptly while answering a prompt.
  crashMidTurn,

  /// Replies with something that is not JSON-RPC at all.
  protocolViolation,

  /// Accepts the prompt and never answers.
  hang,
}

/// A stand-in ACP agent, in-process.
///
/// Real agents are large and non-deterministic, and driving one through an
/// actual subprocess made these tests minutes long and dependent on how the
/// test runner resolves a Dart executable. This speaks the same protocol over
/// the same interface, and can be told to misbehave in the specific ways the
/// backend has to survive.
class FakeAcpAgent implements AgentProcess {
  final FakeAgentMode mode;

  final _stdout = StreamController<List<int>>();
  final _stderr = StreamController<List<int>>();
  final _inputBuffer = StringBuffer();

  /// What the client advertised, so tests can assert on it directly.
  Map<String, dynamic>? clientCapabilities;
  List<dynamic>? mcpServers;

  bool killed = false;

  FakeAcpAgent(this.mode);

  @override
  Stream<List<int>> get stdout => _stdout.stream;

  @override
  Stream<List<int>> get stderr => _stderr.stream;

  @override
  void kill() {
    killed = true;
    _close();
  }

  void _close() {
    if (!_stdout.isClosed) {
      _stdout.close();
    }
    if (!_stderr.isClosed) {
      _stderr.close();
    }
  }

  void _write(Map<String, dynamic> message) {
    if (_stdout.isClosed) {
      return;
    }
    _stdout.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  @override
  void writeStdin(List<int> bytes) {
    _inputBuffer.write(utf8.decode(bytes));
    final content = _inputBuffer.toString();
    if (!content.contains('\n')) {
      return;
    }

    final lines = content.split('\n');
    _inputBuffer
      ..clear()
      ..write(lines.removeLast());

    for (final line in lines) {
      if (line.trim().isNotEmpty) {
        _handle(line);
      }
    }
  }

  void _handle(String line) {
    if (mode == FakeAgentMode.protocolViolation) {
      if (!_stdout.isClosed) {
        _stdout.add(utf8.encode('this is not json-rpc at all\n'));
        // A well-behaved client should give up rather than retry into a loop.
        _close();
      }
      return;
    }

    final message = jsonDecode(line) as Map<String, dynamic>;
    final id = message['id'];
    final params = (message['params'] as Map?)?.cast<String, dynamic>() ?? const {};

    switch (message['method'] as String?) {
      case 'initialize':
        clientCapabilities =
            (params['clientCapabilities'] as Map?)?.cast<String, dynamic>();
        _write({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'protocolVersion': params['protocolVersion']},
        });

      case 'session/new':
        mcpServers = params['mcpServers'] as List?;
        _write({'jsonrpc': '2.0', 'id': id, 'result': {'sessionId': 'fake-session'}});

      case 'session/prompt':
        if (mode == FakeAgentMode.hang) {
          return;
        }
        if (mode == FakeAgentMode.crashMidTurn) {
          _write({
            'jsonrpc': '2.0',
            'method': 'session/update',
            'params': {
              'sessionId': 'fake-session',
              'update': {
                'sessionUpdate': 'agent_message_chunk',
                'content': {'text': 'Starting'},
              },
            },
          });
          _close();
          return;
        }

        _write({
          'jsonrpc': '2.0',
          'method': 'session/update',
          'params': {
            'sessionId': 'fake-session',
            'update': {
              'sessionUpdate': 'agent_message_chunk',
              'content': {'text': 'Hello from the agent.'},
            },
          },
        });
        _write({'jsonrpc': '2.0', 'id': id, 'result': {'stopReason': 'end_turn'}});

      case 'session/cancel':
        // A notification; nothing to answer.
        break;

      default:
        _write({
          'jsonrpc': '2.0',
          'id': id,
          'error': {'code': -32601, 'message': 'Method not found'},
        });
    }
  }
}
