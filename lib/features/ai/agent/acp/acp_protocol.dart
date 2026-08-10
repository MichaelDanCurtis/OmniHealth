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

/// A JSON-RPC error returned by the agent.
class AcpError implements Exception {
  final int code;
  final String message;

  const AcpError(this.code, this.message);

  @override
  String toString() => 'AcpError($code): $message';
}

/// The agent violated the protocol badly enough that the session cannot be
/// trusted to continue.
class AcpProtocolViolation implements Exception {
  final String detail;

  const AcpProtocolViolation(this.detail);

  @override
  String toString() => 'AcpProtocolViolation: $detail';
}

/// JSON-RPC 2.0 over a pair of byte streams — newline-delimited, as ACP
/// specifies for stdio transport.
///
/// Deliberately knows nothing about ACP's methods. It matches responses to
/// requests by id and forwards everything without one to [notifications], which
/// is all the framing layer should decide.
class AcpConnection {
  final void Function(List<int>) _write;
  final _logger = Logger('AcpConnection');

  final Map<int, Completer<Map<String, dynamic>>> _pending = {};
  final StreamController<Map<String, dynamic>> _notifications =
      StreamController<Map<String, dynamic>>.broadcast();

  StreamSubscription<String>? _subscription;
  int _nextId = 1;
  bool _closed = false;

  AcpConnection({
    required Stream<List<int>> incoming,
    required void Function(List<int>) write,
  }) : _write = write {
    _subscription = incoming
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen(_onLine, onDone: _onDone);
  }

  /// Messages with no id: `session/update` and friends.
  Stream<Map<String, dynamic>> get notifications => _notifications.stream;

  Future<Map<String, dynamic>> request(
    String method, [
    Map<String, dynamic> params = const {},
  ]) {
    if (_closed) {
      return Future.error(const AcpProtocolViolation('connection is closed'));
    }

    final id = _nextId++;
    final completer = Completer<Map<String, dynamic>>();
    _pending[id] = completer;

    _write(
      utf8.encode(
        '${jsonEncode({'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params})}\n',
      ),
    );

    return completer.future;
  }

  void notify(String method, [Map<String, dynamic> params = const {}]) {
    if (_closed) {
      return;
    }
    _write(
      utf8.encode('${jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params})}\n'),
    );
  }

  void _onLine(String line) {
    if (line.trim().isEmpty) {
      return;
    }

    final Map<String, dynamic> message;
    try {
      message = jsonDecode(line) as Map<String, dynamic>;
    } catch (_) {
      // One unparseable line should not tear down a working session; agents
      // sometimes emit stray output on stdout.
      _logger.warning('Skipping unparseable ACP line');
      return;
    }

    final id = message['id'];
    if (id == null) {
      _notifications.add(message);
      return;
    }

    final completer = _pending.remove(id as int);
    if (completer == null) {
      // A response to a request we never made means the agent is confused
      // about session state; that is not recoverable.
      _logger.warning('Response for unknown id $id');
      return;
    }

    if (message.containsKey('error')) {
      final error = message['error'] as Map<String, dynamic>;
      completer.completeError(
        AcpError(error['code'] as int? ?? -1, error['message'] as String? ?? 'unknown'),
      );
      return;
    }

    completer.complete((message['result'] as Map?)?.cast<String, dynamic>() ?? const {});
  }

  void _onDone() {
    // The process exited. Anything still waiting will never be answered, so
    // fail it now rather than leaving the UI spinning forever.
    _closed = true;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(
          const AcpProtocolViolation('agent exited before responding'),
        );
      }
    }
    _pending.clear();
    _notifications.close();
  }

  Future<void> close() async {
    _closed = true;
    await _subscription?.cancel();
    _subscription = null;
    for (final completer in _pending.values) {
      if (!completer.isCompleted) {
        completer.completeError(const AcpProtocolViolation('connection closed'));
      }
    }
    _pending.clear();
    if (!_notifications.isClosed) {
      await _notifications.close();
    }
  }
}
