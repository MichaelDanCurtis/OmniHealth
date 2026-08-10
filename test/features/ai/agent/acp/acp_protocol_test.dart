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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/acp/acp_protocol.dart';

void main() {
  late StreamController<List<int>> incoming;
  late List<String> written;
  late AcpConnection connection;

  setUp(() {
    incoming = StreamController<List<int>>();
    written = [];
    connection = AcpConnection(
      incoming: incoming.stream,
      write: (bytes) => written.add(utf8.decode(bytes)),
    );
  });

  tearDown(() async {
    await connection.close();
    if (!incoming.isClosed) {
      await incoming.close();
    }
  });

  void send(Map<String, dynamic> message) {
    incoming.add(utf8.encode('${jsonEncode(message)}\n'));
  }

  Map<String, dynamic> lastWritten() =>
      jsonDecode(written.last.trim()) as Map<String, dynamic>;

  test('a request is framed as newline-delimited JSON-RPC 2.0', () async {
    // Never answered; tearDown closes the connection, which fails it. Swallow
    // that here so it does not surface as an unhandled async error.
    unawaited(
      connection
          .request('initialize', {'x': 1})
          .catchError((_) => <String, dynamic>{}),
    );
    await Future<void>.delayed(Duration.zero);

    expect(written.single, endsWith('\n'));
    final message = lastWritten();
    expect(message['jsonrpc'], '2.0');
    expect(message['method'], 'initialize');
    expect(message['id'], isA<int>());
    expect((message['params'] as Map)['x'], 1);
  });

  test('a response resolves its request', () async {
    final future = connection.request('initialize');
    await Future<void>.delayed(Duration.zero);

    send({'jsonrpc': '2.0', 'id': lastWritten()['id'], 'result': {'ok': true}});

    expect((await future)['ok'], isTrue);
  });

  test('out-of-order responses resolve the right futures', () async {
    final first = connection.request('a');
    await Future<void>.delayed(Duration.zero);
    final firstId = lastWritten()['id'];

    final second = connection.request('b');
    await Future<void>.delayed(Duration.zero);
    final secondId = lastWritten()['id'];

    // Answer the second request first.
    send({'jsonrpc': '2.0', 'id': secondId, 'result': {'which': 'b'}});
    send({'jsonrpc': '2.0', 'id': firstId, 'result': {'which': 'a'}});

    expect((await first)['which'], 'a');
    expect((await second)['which'], 'b');
  });

  test('a notification reaches the stream and resolves nothing', () async {
    final seen = <Map<String, dynamic>>[];
    connection.notifications.listen(seen.add);

    final pending = connection.request('prompt');
    await Future<void>.delayed(Duration.zero);

    send({'jsonrpc': '2.0', 'method': 'session/update', 'params': {'kind': 'text'}});
    await Future<void>.delayed(Duration.zero);

    expect(seen.single['method'], 'session/update');

    var resolved = false;
    unawaited(pending.then((_) => resolved = true, onError: (_) {}));
    await Future<void>.delayed(Duration.zero);
    expect(resolved, isFalse);
  });

  test('an error response completes the future with an error', () async {
    final future = connection.request('bad');
    await Future<void>.delayed(Duration.zero);

    send({
      'jsonrpc': '2.0',
      'id': lastWritten()['id'],
      'error': {'code': -32601, 'message': 'Method not found'},
    });

    await expectLater(
      future,
      throwsA(isA<AcpError>().having((e) => e.code, 'code', -32601)),
    );
  });

  test('an unparseable line is skipped without killing the connection', () async {
    // Agents sometimes emit stray output on stdout; one bad line must not tear
    // down a working session.
    final future = connection.request('initialize');
    await Future<void>.delayed(Duration.zero);

    incoming.add(utf8.encode('this is not json\n'));
    send({'jsonrpc': '2.0', 'id': lastWritten()['id'], 'result': {'ok': true}});

    expect((await future)['ok'], isTrue);
  });

  test('a response to an unknown id is ignored, not fatal', () async {
    final future = connection.request('initialize');
    await Future<void>.delayed(Duration.zero);
    final realId = lastWritten()['id'] as int;

    send({'jsonrpc': '2.0', 'id': realId + 999, 'result': {'stray': true}});
    send({'jsonrpc': '2.0', 'id': realId, 'result': {'ok': true}});

    expect((await future)['ok'], isTrue);
  });

  test('the agent exiting fails everything still in flight', () async {
    // Otherwise the UI spins forever waiting on a process that is gone.
    final future = connection.request('prompt');
    await Future<void>.delayed(Duration.zero);

    await incoming.close();

    await expectLater(future, throwsA(isA<AcpProtocolViolation>()));
  });

  test('requests after close fail rather than hanging', () async {
    await connection.close();
    await expectLater(
      connection.request('initialize'),
      throwsA(isA<AcpProtocolViolation>()),
    );
  });

  test('a notification we send carries no id', () async {
    connection.notify('session/cancel', {'sessionId': 's1'});
    await Future<void>.delayed(Duration.zero);

    final message = lastWritten();
    expect(message.containsKey('id'), isFalse);
    expect(message['method'], 'session/cancel');
  });
}
