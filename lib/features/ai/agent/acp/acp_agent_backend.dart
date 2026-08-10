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
import 'dart:io';

import 'package:logging/logging.dart';
import 'package:wger/features/ai/agent/acp/acp_protocol.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/mcp/mcp_bridge_server.dart';

/// Whether this platform can host an ACP agent at all.
///
/// ACP spawns the agent as a local subprocess, which iOS and Android do not
/// permit. This is why ACP is a second backend rather than the primary
/// transport.
bool get acpIsSupported => Platform.isMacOS || Platform.isWindows || Platform.isLinux;

/// The slice of a spawned process the backend actually uses.
///
/// Injected rather than calling `Process.start` directly so the session logic —
/// handshake, streaming, crash and timeout handling — is testable in-memory.
/// Driving those paths through a real subprocess made the suite minutes long
/// and depended on how the test runner resolves a Dart executable.
abstract interface class AgentProcess {
  Stream<List<int>> get stdout;
  Stream<List<int>> get stderr;

  void writeStdin(List<int> bytes);
  void kill();
}

typedef AgentProcessLauncher =
    Future<AgentProcess> Function(String binaryPath, List<String> args, String cwd);

class _RealAgentProcess implements AgentProcess {
  final Process _process;

  _RealAgentProcess(this._process);

  @override
  Stream<List<int>> get stdout => _process.stdout;

  @override
  Stream<List<int>> get stderr => _process.stderr;

  @override
  void writeStdin(List<int> bytes) => _process.stdin.add(bytes);

  @override
  void kill() => _process.kill();
}

/// Spawns a real subprocess. The default launcher.
Future<AgentProcess> launchRealAgentProcess(
  String binaryPath,
  List<String> args,
  String cwd,
) async {
  final process = await Process.start(binaryPath, args, workingDirectory: cwd);
  return _RealAgentProcess(process);
}

/// Delegates the whole agent loop to an external ACP agent process.
///
/// OmniHealth is the ACP **client**: it spawns a user-configured binary and
/// speaks JSON-RPC 2.0 over its stdio.
///
/// Two deliberate restrictions:
///
/// - **No filesystem or terminal capability is advertised.** OmniHealth is not
///   an editor. An agent connected here can use the health tools and nothing
///   else — it cannot read files or run commands on the user's machine.
/// - **Tools arrive only through the MCP bridge**, which serves the same
///   `ToolRegistry` the local loop uses. The confirmation-token gate therefore
///   applies identically, rather than being reimplemented and drifting.
class AcpAgentBackend implements AgentBackend {
  static const _protocolVersion = 1;

  final String binaryPath;
  final List<String> args;
  final McpBridgeServer bridge;
  final String workingDirectory;

  /// How long to wait for a prompt before giving up on a wedged agent.
  final Duration promptTimeout;

  /// How the subprocess is created. Swapped in tests.
  final AgentProcessLauncher launcher;

  final _logger = Logger('AcpAgentBackend');

  AgentProcess? _process;
  AcpConnection? _connection;
  McpBridgeHandle? _bridgeHandle;
  String? _sessionId;
  StreamSubscription<Map<String, dynamic>>? _updates;

  AcpAgentBackend({
    required this.binaryPath,
    required this.bridge,
    this.args = const [],
    this.workingDirectory = '.',
    this.promptTimeout = const Duration(minutes: 2),
    this.launcher = launchRealAgentProcess,
  });

  /// The capabilities advertised to the agent. Exposed so the "we grant no
  /// filesystem or terminal access" claim is directly testable.
  static const clientCapabilities = <String, dynamic>{
    'fs': {'readTextFile': false, 'writeTextFile': false},
    'terminal': false,
  };

  @override
  Stream<AgentEvent> sendMessage(String text) async* {
    if (!acpIsSupported) {
      yield const AgentFailure(
        'Local agents are only available on desktop.',
      );
      return;
    }

    try {
      await _ensureSession();
    } on Object catch (e) {
      yield AgentFailure('Could not start the local agent: $e');
      await dispose();
      return;
    }

    final events = StreamController<AgentEvent>();

    _updates = _connection!.notifications.listen((message) {
      if (message['method'] != 'session/update') {
        return;
      }
      final update =
          ((message['params'] as Map?)?['update'] as Map?)?.cast<String, dynamic>();
      if (update == null) {
        return;
      }

      switch (update['sessionUpdate'] as String?) {
        case 'agent_message_chunk':
          final text = ((update['content'] as Map?)?['text'] as String?) ?? '';
          if (text.isNotEmpty) {
            events.add(AgentText(text));
          }
        case 'tool_call':
          events.add(AgentToolStarted('${update['title'] ?? 'tool'}'));
        case 'tool_call_update':
          final status = update['status'] as String?;
          if (status == 'completed' || status == 'failed') {
            events.add(
              AgentToolFinished('${update['title'] ?? 'tool'}', isError: status == 'failed'),
            );
          }
      }
    });

    unawaited(
      _connection!
          .request('session/prompt', {
            'sessionId': _sessionId,
            'prompt': [
              {'type': 'text', 'text': text},
            ],
          })
          .timeout(promptTimeout)
          .then(
            (_) {
              events
                ..add(const AgentTurnComplete())
                ..close();
            },
            onError: (Object e) async {
              // A crash, a protocol violation, or a wedged agent all land here.
              // Each ends the session rather than being retried blindly.
              events.add(AgentFailure(_describe(e)));

              // Tear down *before* closing the stream, so that by the time a
              // caller observes the turn ending, the subprocess is reaped and
              // the bridge port is released. Firing this off unawaited left a
              // window where the session looked over but the port was still
              // open with a live token.
              await dispose();
              await events.close();
            },
          ),
    );

    yield* events.stream;
  }

  String _describe(Object error) => switch (error) {
    TimeoutException() => 'The local agent stopped responding.',
    AcpProtocolViolation(:final detail) => 'The local agent misbehaved: $detail.',
    AcpError(:final message) => 'The local agent reported an error: $message',
    _ => 'The local agent failed: $error',
  };

  Future<void> _ensureSession() async {
    if (_sessionId != null) {
      return;
    }

    _bridgeHandle = await bridge.start();

    final process = await launcher(binaryPath, args, workingDirectory);
    _process = process;

    // The agent's stderr is diagnostic only; never surfaced to the user, but
    // worth logging when one refuses to start.
    unawaited(
      process.stderr
          .transform(const SystemEncoding().decoder)
          .forEach((line) => _logger.fine('agent stderr: $line'))
          .catchError((Object _) {}),
    );

    final connection = AcpConnection(
      incoming: process.stdout,
      write: process.writeStdin,
    );
    _connection = connection;

    await connection.request('initialize', {
      'protocolVersion': _protocolVersion,
      'clientCapabilities': clientCapabilities,
    });

    final session = await connection.request('session/new', {
      'cwd': workingDirectory,
      // The only capability we do hand over: our own health tools, behind the
      // same registry and the same write gate the local loop uses.
      'mcpServers': [
        {
          'name': 'omnihealth',
          'type': 'http',
          'url': _bridgeHandle!.uri.toString(),
          'headers': {'Authorization': 'Bearer ${_bridgeHandle!.bearerToken}'},
        },
      ],
    });

    _sessionId = session['sessionId'] as String?;
    if (_sessionId == null) {
      throw const AcpProtocolViolation('session/new returned no sessionId');
    }
  }

  @override
  Future<void> cancel() async {
    if (_sessionId != null) {
      _connection?.notify('session/cancel', {'sessionId': _sessionId});
    }
  }

  @override
  Future<void> dispose() async {
    await _updates?.cancel();
    _updates = null;

    await _connection?.close();
    _connection = null;

    // Always reap the subprocess; an orphaned agent would keep a port and a
    // token alive after the user thought they had closed the session.
    _process?.kill();
    _process = null;

    await bridge.stop();
    _bridgeHandle = null;
    _sessionId = null;
  }
}
