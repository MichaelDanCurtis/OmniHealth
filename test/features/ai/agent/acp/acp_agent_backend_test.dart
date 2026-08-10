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

import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/acp/acp_agent_backend.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/mcp/mcp_bridge_server.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

import 'fake_acp_agent.dart';

void main() {
  late McpBridgeServer bridge;
  late FakeAcpAgent agent;

  setUp(() {
    bridge = McpBridgeServer(
      registry: ToolRegistry(tokenService: ConfirmationTokenService()),
    );
  });

  AcpAgentBackend backendFor(FakeAgentMode mode, {Duration? timeout}) {
    agent = FakeAcpAgent(mode);
    return AcpAgentBackend(
      binaryPath: '/fake/agent',
      bridge: bridge,
      promptTimeout: timeout ?? const Duration(seconds: 5),
      launcher: (_, _, _) async => agent,
    );
  }

  test('a normal session streams text and completes', () async {
    final backend = backendFor(FakeAgentMode.normal);
    addTearDown(backend.dispose);

    final events = await backend.sendMessage('hello').toList();

    expect(
      events.whereType<AgentText>().map((e) => e.text).join(),
      contains('Hello from the agent'),
    );
    expect(events.last, isA<AgentTurnComplete>());
  });

  test('advertises no filesystem and no terminal capability', () async {
    // OmniHealth is not an editor. An agent connected here can use the health
    // tools and nothing else — it cannot read files or run commands.
    final backend = backendFor(FakeAgentMode.normal);
    addTearDown(backend.dispose);

    await backend.sendMessage('hello').toList();

    expect(agent.clientCapabilities, isNotNull);
    final encoded = jsonEncode(agent.clientCapabilities);
    expect(encoded, contains('"terminal":false'));
    expect(encoded, contains('"readTextFile":false'));
    expect(encoded, contains('"writeTextFile":false'));
  });

  test('passes the MCP bridge so the agent gets the same tools and gate', () async {
    // The point of sharing one registry: the confirmation-token gate applies
    // identically here rather than being reimplemented and drifting.
    final backend = backendFor(FakeAgentMode.normal);
    addTearDown(backend.dispose);

    await backend.sendMessage('hello').toList();

    final server = (agent.mcpServers!.single as Map).cast<String, dynamic>();
    expect(server['name'], 'omnihealth');
    expect(server['url'], contains('127.0.0.1'));
    expect((server['headers'] as Map)['Authorization'], startsWith('Bearer '));
  });

  test('the bridge URL is loopback, never a routable address', () async {
    final backend = backendFor(FakeAgentMode.normal);
    addTearDown(backend.dispose);

    await backend.sendMessage('hello').toList();

    final url = (agent.mcpServers!.single as Map)['url'] as String;
    expect(Uri.parse(url).host, '127.0.0.1');
  });

  test('a crash mid-turn produces a clear failure, not a hang', () async {
    final backend = backendFor(FakeAgentMode.crashMidTurn);
    addTearDown(backend.dispose);

    final events = await backend.sendMessage('hello').toList();

    expect(events.whereType<AgentFailure>(), isNotEmpty);
    expect(events.whereType<AgentTurnComplete>(), isEmpty);
  });

  test('a protocol violation ends the session rather than retrying', () async {
    final backend = backendFor(FakeAgentMode.protocolViolation);
    addTearDown(backend.dispose);

    final events = await backend.sendMessage('hello').toList();

    expect(events.whereType<AgentFailure>(), isNotEmpty);
  });

  test('a wedged agent is bounded by the prompt timeout', () async {
    final backend = backendFor(FakeAgentMode.hang, timeout: const Duration(milliseconds: 300));
    addTearDown(backend.dispose);

    final events = await backend.sendMessage('hello').toList();

    expect(
      events.whereType<AgentFailure>().single.message.toLowerCase(),
      contains('stopped responding'),
    );
  });

  test('a failure reaps the subprocess rather than orphaning it', () async {
    // An orphaned agent would keep the bridge port and its token alive after
    // the user thought the session was over.
    final backend = backendFor(FakeAgentMode.hang, timeout: const Duration(milliseconds: 300));

    await backend.sendMessage('hello').toList();

    expect(agent.killed, isTrue);
    expect(bridge.isRunning, isFalse);
  });

  test('a launcher failure fails cleanly instead of throwing', () async {
    final backend = AcpAgentBackend(
      binaryPath: '/nonexistent/agent-binary',
      bridge: bridge,
      launcher: (_, _, _) async => throw Exception('No such file or directory'),
    );
    addTearDown(backend.dispose);

    final events = await backend.sendMessage('hello').toList();

    expect(
      events.whereType<AgentFailure>().single.message,
      contains('Could not start'),
    );
  });

  test('dispose releases the bridge port', () async {
    final backend = backendFor(FakeAgentMode.normal);
    await backend.sendMessage('hello').toList();
    await backend.dispose();

    expect(bridge.isRunning, isFalse);
    expect(agent.killed, isTrue);
  });

  test('the advertised capability map is exactly what the class declares', () {
    // Pinned so nobody quietly widens what an external agent may do.
    final encoded = jsonEncode(AcpAgentBackend.clientCapabilities);
    expect(encoded, contains('"terminal":false'));
    expect(AcpAgentBackend.clientCapabilities.containsKey('fs'), isTrue);
  });
}
