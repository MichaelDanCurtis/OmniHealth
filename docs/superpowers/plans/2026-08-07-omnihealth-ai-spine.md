# OmniHealth AI Spine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an on-device, bring-your-own-key AI agent to a fork of wger's Flutter app that can read and write the user's health data through generative UI, where the model proposes UI but only a human tap causes a write.

**Architecture:** A single feature module at `lib/features/ai/` containing two agent backends behind one interface — a local Dart agent loop driving a pluggable `LlmProvider`, and (desktop only) an ACP client that delegates the loop to an external agent process. Both consume one MCP-shaped `ToolRegistry` whose tools call wger's existing PowerSync/Drift repositories, and both render generative UI through one A2UI catalog via `flutter/genui`.

**Tech Stack:** Flutter 3.44.7 / Dart 3.12.2 · Riverpod 3.3 with codegen · Drift + PowerSync · `genui` (+ `a2ui_core`, `json_schema_builder`) · `flutter_secure_storage` 10.3 · `http` 1.6

**Spec:** [2026-08-07-omnihealth-ai-spine-design.md](../specs/2026-08-07-omnihealth-ai-spine-design.md)
**Spike findings:** [2026-08-07-slice-0-findings.md](../specs/2026-08-07-slice-0-findings.md)

## Progress

| Task | Status |
|---|---|
| 0 — Establish the fork | **Done** — `8732988`. Analyze clean, macOS + iOS build. |
| 1 — Provider contract + guard test | **Done** — 6 tests |
| 2 — OpenAI-compatible provider | **Done** — 10 tests |
| 3 — Anthropic provider | **Done** — 10 tests |
| 4 — API key storage | **Done** — 6 tests |
| 5 — Confirmation tokens | **Done** — 11 tests |
| 6 — Tool registry | **Done** — 14 tests |
| 7 — Weight tools | **Done** — 14 tests |
| 8 — Nutrition, body, exercise tools | **Done** — 36 tests |
| 9 — Local agent backend | **Done** — 10 tests |
| 10 — A2UI catalog | **Done** — 24 tests |
| 11 — MetricChart + ExerciseVideo | **Done** — 12 tests |
| 12 — render_ui tool | **Done** — 15 tests |
| 13 — Settings screen | **Done** — 23 tests |
| 14 — Chat screen | **Done** — 25 tests |
| 15 — Wire module into app | **Done** — 6 tests |
| 16 — Acceptance tests | **Done** — 6 tests |
| 17 — MCP bridge | **Done** — 13 tests |
| 18 — ACP backend | **Done** — 21 tests |

## Slice 1 complete

**258 tests passing, `flutter analyze` clean, macOS and iOS both build.**
Packages added: `crypto`, `json_schema_builder`, `genui`.

The module boundary held: the entire slice touches **6 lines outside
`lib/features/ai/`** — two imports and two route entries in `main.dart`.

### Deviations from this plan, and why

- **Task 16** was specced against a Dockerised wger. The tools take callbacks,
  so the acceptance tests run against an in-memory store instead — no external
  dependency, no flake, runs in CI.
- **Task 18** was specced to spawn a real subprocess. `Platform.resolvedExecutable`
  under `flutter test` is not the `dart` binary, and the suite took minutes. The
  process is injected behind an `AgentProcess` interface; behaviour is tested
  in-memory in milliseconds.
- **Tasks 13–14** use plain Riverpod notifiers rather than `@riverpod` codegen.
  `build_runner` would regenerate `.g.dart` across all 379 of wger's files.
- **`get_workout_log`** requires an `exerciseId`; wger's repository has no
  cross-exercise query and adding one would breach the module boundary.

### Carried forward

1. **Composition (slice 1b).** `render_ui` takes one component plus props, which
   cannot express a `Column` with children. The "primitives gather, our
   components commit" design in spec §5.1 assumes A2UI's adjacency list. Today
   the chat renders our four components directly and shows a visible fallback
   for anything else, so the weight demo works but a composed form does not.
   Closing this means `render_ui` accepting a full A2UI document and handing it
   to genui's `SurfaceController`.
2. **`aiToolBindingsProvider` and `exerciseVideoLookupProvider` still default to
   stubs.** Both need overriding with Drift-backed lookups before the assistant
   sees real data in a running app. Deliberately graceful: an unwired build
   talks but finds nothing, rather than throwing.
3. **Android and Windows unverified** — no Android SDK on this host, and Windows
   cannot build from macOS.

### Carried into Task 15

`exerciseVideoLookupProvider` (in `genui/widgets/exercise_video.dart`) is a seam
that currently defaults to returning null, so an unwired build shows "not
available" rather than throwing. Task 15 must override it with the real
Drift-backed lookup, and add a test that a known video id resolves through the
wired provider. Until then `ExerciseVideo` renders its not-found state in the
running app even for valid ids.

## Global Constraints

- **Every new file begins with the AGPL header block** copied verbatim from any existing wger source file (see `lib/core/network/secure_token_storage.dart` lines 1–17), with the copyright line reading `Copyright (c) 2026, OmniHealth contributors`.
- **All new code lives under `lib/features/ai/`.** The only permitted changes outside it are one navigation entry and one Riverpod registration, both in Task 15.
- **Tests mirror source paths** under `test/features/ai/`.
- **No test may make a live LLM API call or read a real API key from the environment.** Task 1 adds the guard test that enforces this.
- **Interfaces use `abstract interface class`**, with the concrete implementation as a separate class and a Riverpod `Provider` binding them — mirroring `lib/core/network/secure_token_storage.dart`.
- **Notifiers use** `@riverpod final class X extends _$X` with a `part 'x.g.dart';` directive. Run `dart run build_runner build --delete-conflicting-outputs` after adding or changing any annotated class.
- **Dart SDK constraint** stays `>=3.10.0 <4.0.0`. Do not raise it.
- **Run `flutter analyze` before every commit.** The baseline is zero issues; keep it there. If you pipe it (`flutter analyze | tail -2 && git commit ...`) the pipeline's exit code is `tail`'s, so a failing analyze still commits. Use `set -o pipefail`, or don't pipe. This has already caused one bad commit on this repo.
- Commit after every task. Use Conventional Commits (`feat:`, `test:`, `fix:`, `chore:`).

---

## File Structure

```
lib/features/ai/
├── credentials/
│   └── ai_key_storage.dart          interface + FlutterSecureStorage impl + provider
├── providers/
│   ├── llm_provider.dart            LlmProvider, LlmEvent, Message, ToolSpec, ToolCall
│   ├── provider_config.dart         persisted {displayName, kind, baseUrl, modelId, keyRef}
│   ├── openai_compat_provider.dart  OpenAI, Grok, Kimi, GLM
│   └── anthropic_provider.dart      Anthropic Messages API
├── tools/
│   ├── tool.dart                    Tool interface, ToolResult
│   ├── confirmation_token.dart      ConfirmationTokenService
│   ├── tool_registry.dart           registration, schema validation, token enforcement
│   └── wger/
│       ├── weight_tools.dart        get_weight_history, log_weight
│       ├── nutrition_tools.dart     get_nutrition_log, search_ingredient, log_nutrition_entry
│       └── body_tools.dart          get_workout_log, get_body_measurements
├── agent/
│   ├── agent_backend.dart           AgentBackend interface, AgentEvent
│   ├── local/local_agent_backend.dart
│   └── acp/
│       ├── acp_protocol.dart        JSON-RPC 2.0 framing
│       └── acp_agent_backend.dart   desktop-only
├── genui/
│   ├── omni_catalog.dart            the five approved components
│   ├── render_ui_tool.dart          render_ui — suspends until user acts
│   └── widgets/
│       ├── metric_entry_card.dart
│       ├── confirmation_card.dart
│       ├── metric_chart.dart
│       ├── choice_list.dart
│       └── summary_card.dart
├── mcp/
│   └── mcp_bridge_server.dart       loopback MCP server, per-session bearer token
├── chat/
│   ├── providers/chat_notifier.dart
│   └── screens/chat_screen.dart
└── settings/
    └── screens/ai_settings_screen.dart
```

**Boundaries.** `providers/` knows HTTP but not tools or widgets. `tools/` knows repositories but not providers or widgets. `agent/` knows providers and tools but not widgets. `genui/` knows widgets and the token service but not providers. This keeps each unit testable with a fake for everything it depends on.

---

## Task 0: Establish the fork

Every later task assumes wger's source tree is present in this repository. Nothing has put it there
yet. This task does, in a way that keeps pulling upstream cheap.

**Files:**
- Create: the whole `wger-project/flutter` tree at the repository root
- Create: `README.md` — what OmniHealth is and what it forked
- Modify: `.gitignore` — add Flutter's ignores

**Interfaces:**
- Consumes: nothing
- Produces: a buildable Flutter app at the repository root, with `upstream` configured

- [ ] **Step 1: Add upstream as a remote and fetch it**

```bash
git remote add upstream https://github.com/wger-project/flutter.git
git fetch upstream --depth 50
```

Using a remote rather than copying files is what makes `git merge upstream/master` work later. This
is the whole reason the module boundary exists — do not skip it in favour of copying the tree.

- [ ] **Step 2: Merge upstream's tree into this repository**

```bash
git merge --allow-unrelated-histories --no-edit upstream/master
```

Expected: the merge succeeds. The only file that can conflict is `.gitignore`; if it does, keep
both sets of rules.

- [ ] **Step 3: Verify the tree arrived intact**

```bash
ls lib/features/          # account auth exercises gallery measurements nutrition routines trophies weight
flutter pub get
flutter analyze
```
Expected: `pub get` clean, `flutter analyze` reports **No issues found**. That zero-issue result is
the baseline every later task must preserve.

- [ ] **Step 4: Confirm it builds**

```bash
flutter build macos --debug
```
Expected: `✓ Built build/macos/Build/Products/Debug/wger.app`

- [ ] **Step 5: Write the README**

State plainly: OmniHealth is an AGPL-3.0+ fork of wger-project/flutter; the AI layer lives entirely
in `lib/features/ai/`; upstream is tracked as the `upstream` remote. Include the §6.4 policy — that
OmniHealth supports provider API keys only, and does not support subscription credentials from any
vendor.

- [ ] **Step 6: Commit**

```bash
git add README.md .gitignore
git commit -m "chore: fork wger-project/flutter as the OmniHealth base"
```

---

## Task 1: Provider contract and the no-live-calls guard

**Files:**
- Create: `lib/features/ai/providers/llm_provider.dart`
- Test: `test/features/ai/providers/llm_provider_test.dart`
- Test: `test/features/ai/no_live_calls_guard_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces: `LlmProvider` (abstract interface, method `Stream<LlmEvent> stream({required List<Message> messages, required List<ToolSpec> tools})`), `LlmEvent` sealed class with variants `TextDelta(String text)`, `ToolCallRequested(ToolCall call)`, `TurnComplete()`, `ProviderError(String message, {bool retriable})`; `Message(role, content, {toolCallId, toolCalls})` with `MessageRole` enum `{system, user, assistant, tool}`; `ToolSpec(name, description, inputSchema)`; `ToolCall(id, name, arguments)`.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/providers/llm_provider_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';

void main() {
  test('LlmEvent variants carry their payloads', () {
    const delta = TextDelta('hi');
    expect(delta.text, 'hi');

    const call = ToolCall(id: 'c1', name: 'log_weight', arguments: {'value': 82.4});
    expect(ToolCallRequested(call).call.name, 'log_weight');

    const err = ProviderError('rate limited', retriable: true);
    expect(err.retriable, isTrue);
  });

  test('ProviderError defaults to non-retriable', () {
    expect(const ProviderError('bad key').retriable, isFalse);
  });

  test('Message serialises role as a wire string', () {
    const m = Message(role: MessageRole.assistant, content: 'ok');
    expect(m.role.wireName, 'assistant');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/providers/llm_provider_test.dart`
Expected: FAIL — `Target of URI doesn't exist: 'package:wger/features/ai/providers/llm_provider.dart'`

- [ ] **Step 3: Write minimal implementation**

```dart
// lib/features/ai/providers/llm_provider.dart
// <AGPL header block — see Global Constraints>

enum MessageRole {
  system('system'),
  user('user'),
  assistant('assistant'),
  tool('tool');

  const MessageRole(this.wireName);
  final String wireName;
}

class Message {
  final MessageRole role;
  final String content;
  final String? toolCallId;
  final List<ToolCall> toolCalls;

  const Message({
    required this.role,
    required this.content,
    this.toolCallId,
    this.toolCalls = const [],
  });
}

class ToolCall {
  final String id;
  final String name;
  final Map<String, dynamic> arguments;

  const ToolCall({required this.id, required this.name, required this.arguments});
}

class ToolSpec {
  final String name;
  final String description;
  final Map<String, dynamic> inputSchema;

  const ToolSpec({
    required this.name,
    required this.description,
    required this.inputSchema,
  });
}

sealed class LlmEvent {
  const LlmEvent();
}

class TextDelta extends LlmEvent {
  final String text;
  const TextDelta(this.text);
}

class ToolCallRequested extends LlmEvent {
  final ToolCall call;
  const ToolCallRequested(this.call);
}

class TurnComplete extends LlmEvent {
  const TurnComplete();
}

class ProviderError extends LlmEvent {
  final String message;
  final bool retriable;
  const ProviderError(this.message, {this.retriable = false});
}

/// A streaming connection to one LLM endpoint.
///
/// Implementations own HTTP and wire-format concerns and nothing else: they do
/// not execute tools, and they know nothing about widgets.
abstract interface class LlmProvider {
  String get id;

  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  });
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/features/ai/providers/llm_provider_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 5: Add the no-live-calls guard test**

```dart
// test/features/ai/no_live_calls_guard_test.dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

/// Fails if any real provider credential is visible to the test process.
/// A leaked key here means CI could bill a real account or exfiltrate data.
void main() {
  test('no real API keys are visible to tests', () {
    const forbidden = [
      'OPENAI_API_KEY',
      'ANTHROPIC_API_KEY',
      'XAI_API_KEY',
      'GROK_API_KEY',
      'MOONSHOT_API_KEY',
      'ZHIPU_API_KEY',
      'GLM_API_KEY',
    ];
    final present = forbidden.where((k) {
      final v = Platform.environment[k];
      return v != null && v.isNotEmpty;
    }).toList();

    expect(
      present,
      isEmpty,
      reason: 'Tests must never see real credentials. Unset: ${present.join(', ')}',
    );
  });
}
```

- [ ] **Step 6: Run the guard test**

Run: `flutter test test/features/ai/no_live_calls_guard_test.dart`
Expected: PASS (assuming no provider keys are exported in your shell)

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/providers/llm_provider.dart test/features/ai/
git commit -m "feat(ai): add LlmProvider contract and no-live-calls test guard"
```

---

## Task 2: OpenAI-compatible provider

Covers OpenAI, Grok, Kimi, and GLM — they differ only by base URL and model id.

**Files:**
- Create: `lib/features/ai/providers/provider_config.dart`
- Create: `lib/features/ai/providers/openai_compat_provider.dart`
- Test: `test/features/ai/providers/openai_compat_provider_test.dart`
- Test fixture: `test/features/ai/providers/fixtures/openai_stream_tool_call.txt`

**Interfaces:**
- Consumes: `LlmProvider`, `LlmEvent`, `Message`, `ToolSpec`, `ToolCall` from Task 1
- Produces: `ProviderKind` enum `{openaiCompat, anthropic}`; `ProviderConfig(id, displayName, kind, baseUrl, modelId)`; `OpenAiCompatProvider(config, httpClient)` implementing `LlmProvider`

- [ ] **Step 1: Write the fixture**

Create `test/features/ai/providers/fixtures/openai_stream_tool_call.txt` with a recorded SSE body:

```
data: {"choices":[{"delta":{"content":"Sure"},"index":0}]}

data: {"choices":[{"delta":{"content":", one moment."},"index":0}]}

data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"call_1","function":{"name":"log_weight","arguments":"{\"value\":82.4}"}}]},"index":0}]}

data: {"choices":[{"delta":{},"finish_reason":"tool_calls","index":0}]}

data: [DONE]

```

- [ ] **Step 2: Write the failing test**

```dart
// test/features/ai/providers/openai_compat_provider_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/openai_compat_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

const _config = ProviderConfig(
  id: 'test',
  displayName: 'Test',
  kind: ProviderKind.openaiCompat,
  baseUrl: 'https://example.invalid/v1',
  modelId: 'test-model',
);

void main() {
  test('parses text deltas then a tool call from an SSE stream', () async {
    final body = File(
      'test/features/ai/providers/fixtures/openai_stream_tool_call.txt',
    ).readAsStringSync();

    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(
        Stream.value(utf8.encode(body)),
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });

    final provider = OpenAiCompatProvider(
      config: _config,
      apiKey: 'fake-key',
      httpClient: client,
    );

    final events = await provider.stream(
      messages: [const Message(role: MessageRole.user, content: 'log my weight')],
      tools: const [],
    ).toList();

    final text = events.whereType<TextDelta>().map((e) => e.text).join();
    expect(text, 'Sure, one moment.');

    final calls = events.whereType<ToolCallRequested>().toList();
    expect(calls, hasLength(1));
    expect(calls.single.call.name, 'log_weight');
    expect(calls.single.call.arguments['value'], 82.4);

    expect(events.last, isA<TurnComplete>());
  });

  test('maps HTTP 401 to a non-retriable ProviderError', () async {
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode('{"error":"bad key"}')), 401);
    });

    final provider = OpenAiCompatProvider(
      config: _config,
      apiKey: 'fake-key',
      httpClient: client,
    );

    final events = await provider.stream(
      messages: [const Message(role: MessageRole.user, content: 'hi')],
      tools: const [],
    ).toList();

    final err = events.whereType<ProviderError>().single;
    expect(err.retriable, isFalse);
    expect(err.message, contains('401'));
  });

  test('maps HTTP 429 to a retriable ProviderError', () async {
    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode('slow down')), 429);
    });

    final provider = OpenAiCompatProvider(
      config: _config,
      apiKey: 'fake-key',
      httpClient: client,
    );

    final events = await provider.stream(
      messages: [const Message(role: MessageRole.user, content: 'hi')],
      tools: const [],
    ).toList();

    expect(events.whereType<ProviderError>().single.retriable, isTrue);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ai/providers/openai_compat_provider_test.dart`
Expected: FAIL — `openai_compat_provider.dart` does not exist

- [ ] **Step 4: Write ProviderConfig**

```dart
// lib/features/ai/providers/provider_config.dart
// <AGPL header block>

enum ProviderKind { openaiCompat, anthropic }

/// Persisted description of one configured endpoint.
///
/// Deliberately contains no secret: the API key lives in secure storage and is
/// looked up by [id]. See `credentials/ai_key_storage.dart`.
class ProviderConfig {
  final String id;
  final String displayName;
  final ProviderKind kind;
  final String baseUrl;
  final String modelId;

  const ProviderConfig({
    required this.id,
    required this.displayName,
    required this.kind,
    required this.baseUrl,
    required this.modelId,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'displayName': displayName,
        'kind': kind.name,
        'baseUrl': baseUrl,
        'modelId': modelId,
      };

  factory ProviderConfig.fromJson(Map<String, dynamic> json) => ProviderConfig(
        id: json['id'] as String,
        displayName: json['displayName'] as String,
        kind: ProviderKind.values.byName(json['kind'] as String),
        baseUrl: json['baseUrl'] as String,
        modelId: json['modelId'] as String,
      );

  /// Never include the key. Guards against accidental logging.
  @override
  String toString() => 'ProviderConfig($id, $displayName, ${kind.name}, $modelId)';
}
```

- [ ] **Step 5: Write the provider**

```dart
// lib/features/ai/providers/openai_compat_provider.dart
// <AGPL header block>

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

/// Speaks the OpenAI `/chat/completions` streaming dialect, which OpenAI, Grok,
/// Kimi and GLM all accept. Differences between them are entirely in
/// [ProviderConfig.baseUrl] and [ProviderConfig.modelId].
class OpenAiCompatProvider implements LlmProvider {
  final ProviderConfig config;
  final String apiKey;
  final http.Client httpClient;
  final _logger = Logger('OpenAiCompatProvider');

  OpenAiCompatProvider({
    required this.config,
    required this.apiKey,
    required this.httpClient,
  });

  @override
  String get id => config.id;

  @override
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  }) async* {
    final request = http.Request('POST', Uri.parse('${config.baseUrl}/chat/completions'))
      ..headers.addAll({
        'content-type': 'application/json',
        'authorization': 'Bearer $apiKey',
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': config.modelId,
        'stream': true,
        'messages': messages.map(_encodeMessage).toList(),
        if (tools.isNotEmpty)
          'tools': tools
              .map((t) => {
                    'type': 'function',
                    'function': {
                      'name': t.name,
                      'description': t.description,
                      'parameters': t.inputSchema,
                    },
                  })
              .toList(),
      });

    late http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } catch (e) {
      yield ProviderError('Network error: $e', retriable: true);
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      // 408/429 and 5xx are transient; everything else is the caller's problem.
      final retriable = response.statusCode == 408 ||
          response.statusCode == 429 ||
          response.statusCode >= 500;
      yield ProviderError(
        'HTTP ${response.statusCode}: ${body.trim()}',
        retriable: retriable,
      );
      return;
    }

    // Tool calls stream in fragments keyed by index; accumulate then emit once.
    final pendingCalls = <int, _PartialToolCall>{};

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;
      if (payload == '[DONE]') break;

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        _logger.warning('Skipping unparseable SSE payload');
        continue;
      }

      final choices = json['choices'] as List<dynamic>?;
      if (choices == null || choices.isEmpty) continue;
      final delta = (choices.first as Map<String, dynamic>)['delta'] as Map<String, dynamic>?;
      if (delta == null) continue;

      final content = delta['content'] as String?;
      if (content != null && content.isNotEmpty) {
        yield TextDelta(content);
      }

      final toolCalls = delta['tool_calls'] as List<dynamic>?;
      if (toolCalls != null) {
        for (final raw in toolCalls.cast<Map<String, dynamic>>()) {
          final index = raw['index'] as int? ?? 0;
          final partial = pendingCalls.putIfAbsent(index, _PartialToolCall.new);
          partial.id = (raw['id'] as String?) ?? partial.id;
          final fn = raw['function'] as Map<String, dynamic>?;
          if (fn != null) {
            partial.name = (fn['name'] as String?) ?? partial.name;
            partial.arguments.write((fn['arguments'] as String?) ?? '');
          }
        }
      }
    }

    for (final partial in pendingCalls.values) {
      final args = partial.arguments.toString();
      Map<String, dynamic> parsed;
      try {
        parsed = args.isEmpty ? {} : jsonDecode(args) as Map<String, dynamic>;
      } catch (_) {
        yield ProviderError('Model emitted malformed tool arguments for ${partial.name}');
        continue;
      }
      yield ToolCallRequested(
        ToolCall(id: partial.id, name: partial.name, arguments: parsed),
      );
    }

    yield const TurnComplete();
  }

  Map<String, dynamic> _encodeMessage(Message m) => {
        'role': m.role.wireName,
        'content': m.content,
        if (m.toolCallId != null) 'tool_call_id': m.toolCallId,
        if (m.toolCalls.isNotEmpty)
          'tool_calls': m.toolCalls
              .map((c) => {
                    'id': c.id,
                    'type': 'function',
                    'function': {
                      'name': c.name,
                      'arguments': jsonEncode(c.arguments),
                    },
                  })
              .toList(),
      };
}

class _PartialToolCall {
  String id = '';
  String name = '';
  final StringBuffer arguments = StringBuffer();
}
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `flutter test test/features/ai/providers/openai_compat_provider_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 7: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/providers/ test/features/ai/providers/
git commit -m "feat(ai): add OpenAI-compatible streaming provider"
```

---

## Task 3: Anthropic provider

**Files:**
- Create: `lib/features/ai/providers/anthropic_provider.dart`
- Test: `test/features/ai/providers/anthropic_provider_test.dart`
- Test fixture: `test/features/ai/providers/fixtures/anthropic_stream_tool_use.txt`

**Interfaces:**
- Consumes: `LlmProvider`, `LlmEvent`, `Message`, `ToolSpec`, `ToolCall` (Task 1); `ProviderConfig`, `ProviderKind` (Task 2)
- Produces: `AnthropicProvider(config, apiKey, httpClient)` implementing `LlmProvider`

Anthropic's Messages API differs from OpenAI's in three ways that matter: auth uses `x-api-key` plus an `anthropic-version` header rather than a bearer token; the system prompt is a top-level `system` field rather than a message with `role: system`; and streaming emits named events (`content_block_start`, `content_block_delta`, `content_block_stop`, `message_stop`) where tool arguments arrive as `input_json_delta` fragments.

- [ ] **Step 1: Write the fixture**

Create `test/features/ai/providers/fixtures/anthropic_stream_tool_use.txt`:

```
event: content_block_start
data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

event: content_block_delta
data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"Sure, one moment."}}

event: content_block_stop
data: {"type":"content_block_stop","index":0}

event: content_block_start
data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"toolu_1","name":"log_weight","input":{}}}

event: content_block_delta
data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"value\":82.4}"}}

event: content_block_stop
data: {"type":"content_block_stop","index":1}

event: message_stop
data: {"type":"message_stop"}

```

- [ ] **Step 2: Write the failing test**

```dart
// test/features/ai/providers/anthropic_provider_test.dart
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:wger/features/ai/providers/anthropic_provider.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

const _config = ProviderConfig(
  id: 'claude',
  displayName: 'Claude',
  kind: ProviderKind.anthropic,
  baseUrl: 'https://api.anthropic.invalid/v1',
  modelId: 'claude-test',
);

void main() {
  test('parses text then tool_use from the Anthropic event stream', () async {
    final body = File(
      'test/features/ai/providers/fixtures/anthropic_stream_tool_use.txt',
    ).readAsStringSync();

    final client = MockClient.streaming((request, bodyStream) async {
      return http.StreamedResponse(Stream.value(utf8.encode(body)), 200);
    });

    final provider = AnthropicProvider(
      config: _config,
      apiKey: 'fake-key',
      httpClient: client,
    );

    final events = await provider.stream(
      messages: [const Message(role: MessageRole.user, content: 'log my weight')],
      tools: const [],
    ).toList();

    expect(events.whereType<TextDelta>().map((e) => e.text).join(), 'Sure, one moment.');

    final call = events.whereType<ToolCallRequested>().single.call;
    expect(call.name, 'log_weight');
    expect(call.id, 'toolu_1');
    expect(call.arguments['value'], 82.4);
    expect(events.last, isA<TurnComplete>());
  });

  test('sends x-api-key and anthropic-version headers, not a bearer token', () async {
    late http.BaseRequest captured;
    final client = MockClient.streaming((request, bodyStream) async {
      captured = request;
      return http.StreamedResponse(Stream.value(utf8.encode('')), 200);
    });

    await AnthropicProvider(config: _config, apiKey: 'secret', httpClient: client)
        .stream(
          messages: [const Message(role: MessageRole.user, content: 'hi')],
          tools: const [],
        )
        .toList();

    expect(captured.headers['x-api-key'], 'secret');
    expect(captured.headers.containsKey('anthropic-version'), isTrue);
    expect(captured.headers.containsKey('authorization'), isFalse);
  });

  test('hoists a system message into the top-level system field', () async {
    late String capturedBody;
    final client = MockClient.streaming((request, bodyStream) async {
      capturedBody = (request as http.Request).body;
      return http.StreamedResponse(Stream.value(utf8.encode('')), 200);
    });

    await AnthropicProvider(config: _config, apiKey: 'k', httpClient: client)
        .stream(
          messages: [
            const Message(role: MessageRole.system, content: 'You are helpful.'),
            const Message(role: MessageRole.user, content: 'hi'),
          ],
          tools: const [],
        )
        .toList();

    final json = jsonDecode(capturedBody) as Map<String, dynamic>;
    expect(json['system'], 'You are helpful.');
    expect((json['messages'] as List).length, 1);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ai/providers/anthropic_provider_test.dart`
Expected: FAIL — `anthropic_provider.dart` does not exist

- [ ] **Step 4: Write the provider**

```dart
// lib/features/ai/providers/anthropic_provider.dart
// <AGPL header block>

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/providers/provider_config.dart';

/// Speaks Anthropic's Messages API.
///
/// Note this is the Console API-key path. OmniHealth deliberately does not
/// support Claude subscription OAuth: Anthropic restricts those credentials to
/// first-party products and enforces it server-side, so routing a user's
/// subscription through this app would put their account at risk.
class AnthropicProvider implements LlmProvider {
  static const _apiVersion = '2023-06-01';
  static const _maxTokens = 4096;

  final ProviderConfig config;
  final String apiKey;
  final http.Client httpClient;
  final _logger = Logger('AnthropicProvider');

  AnthropicProvider({
    required this.config,
    required this.apiKey,
    required this.httpClient,
  });

  @override
  String get id => config.id;

  @override
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  }) async* {
    // Anthropic takes the system prompt as a top-level field, not a message.
    final systemPrompt =
        messages.where((m) => m.role == MessageRole.system).map((m) => m.content).join('\n');
    final conversation = messages.where((m) => m.role != MessageRole.system).toList();

    final request = http.Request('POST', Uri.parse('${config.baseUrl}/messages'))
      ..headers.addAll({
        'content-type': 'application/json',
        'x-api-key': apiKey,
        'anthropic-version': _apiVersion,
        'accept': 'text/event-stream',
      })
      ..body = jsonEncode({
        'model': config.modelId,
        'max_tokens': _maxTokens,
        'stream': true,
        if (systemPrompt.isNotEmpty) 'system': systemPrompt,
        'messages': conversation
            .map((m) => {'role': m.role.wireName, 'content': m.content})
            .toList(),
        if (tools.isNotEmpty)
          'tools': tools
              .map((t) => {
                    'name': t.name,
                    'description': t.description,
                    'input_schema': t.inputSchema,
                  })
              .toList(),
      });

    late http.StreamedResponse response;
    try {
      response = await httpClient.send(request);
    } catch (e) {
      yield ProviderError('Network error: $e', retriable: true);
      return;
    }

    if (response.statusCode != 200) {
      final body = await response.stream.bytesToString();
      final retriable = response.statusCode == 429 || response.statusCode >= 500;
      yield ProviderError('HTTP ${response.statusCode}: ${body.trim()}', retriable: retriable);
      return;
    }

    final pending = <int, _PartialToolUse>{};

    await for (final line in response.stream
        .transform(utf8.decoder)
        .transform(const LineSplitter())) {
      if (!line.startsWith('data:')) continue;
      final payload = line.substring(5).trim();
      if (payload.isEmpty) continue;

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(payload) as Map<String, dynamic>;
      } catch (_) {
        _logger.warning('Skipping unparseable event payload');
        continue;
      }

      switch (json['type'] as String?) {
        case 'content_block_start':
          final block = json['content_block'] as Map<String, dynamic>?;
          if (block?['type'] == 'tool_use') {
            pending[json['index'] as int] = _PartialToolUse(
              id: block!['id'] as String,
              name: block['name'] as String,
            );
          }
        case 'content_block_delta':
          final delta = json['delta'] as Map<String, dynamic>?;
          if (delta == null) break;
          if (delta['type'] == 'text_delta') {
            yield TextDelta(delta['text'] as String);
          } else if (delta['type'] == 'input_json_delta') {
            pending[json['index'] as int]?.input.write(delta['partial_json'] as String? ?? '');
          }
        case 'message_stop':
          break;
      }
    }

    for (final p in pending.values) {
      final raw = p.input.toString();
      Map<String, dynamic> parsed;
      try {
        parsed = raw.isEmpty ? {} : jsonDecode(raw) as Map<String, dynamic>;
      } catch (_) {
        yield ProviderError('Model emitted malformed tool arguments for ${p.name}');
        continue;
      }
      yield ToolCallRequested(ToolCall(id: p.id, name: p.name, arguments: parsed));
    }

    yield const TurnComplete();
  }
}

class _PartialToolUse {
  final String id;
  final String name;
  final StringBuffer input = StringBuffer();
  _PartialToolUse({required this.id, required this.name});
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/providers/anthropic_provider_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/providers/anthropic_provider.dart test/features/ai/providers/
git commit -m "feat(ai): add Anthropic Messages API provider"
```

---

## Task 4: API key storage

**Files:**
- Create: `lib/features/ai/credentials/ai_key_storage.dart`
- Test: `test/features/ai/credentials/ai_key_storage_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces: `AiKeyStorage` (abstract interface with `Future<void> writeKey(String providerId, String key)`, `Future<String?> readKey(String providerId)`, `Future<void> deleteKey(String providerId)`, `Future<bool> hasKey(String providerId)`); `FlutterAiKeyStorage`; `aiKeyStorageProvider`

Mirrors `lib/core/network/secure_token_storage.dart` exactly — interface, platform implementation, Riverpod provider.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/credentials/ai_key_storage_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/credentials/ai_key_storage.dart';

/// In-memory double so tests never touch platform channels.
class InMemoryAiKeyStorage implements AiKeyStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> writeKey(String providerId, String key) async => _store[providerId] = key;

  @override
  Future<String?> readKey(String providerId) async => _store[providerId];

  @override
  Future<void> deleteKey(String providerId) async => _store.remove(providerId);

  @override
  Future<bool> hasKey(String providerId) async => _store.containsKey(providerId);
}

void main() {
  late InMemoryAiKeyStorage storage;

  setUp(() => storage = InMemoryAiKeyStorage());

  test('round-trips a key by provider id', () async {
    await storage.writeKey('openai', 'sk-test');
    expect(await storage.readKey('openai'), 'sk-test');
    expect(await storage.hasKey('openai'), isTrue);
  });

  test('keys are namespaced per provider', () async {
    await storage.writeKey('openai', 'sk-a');
    await storage.writeKey('grok', 'sk-b');
    expect(await storage.readKey('openai'), 'sk-a');
    expect(await storage.readKey('grok'), 'sk-b');
  });

  test('delete removes only the named key', () async {
    await storage.writeKey('openai', 'sk-a');
    await storage.writeKey('grok', 'sk-b');
    await storage.deleteKey('openai');
    expect(await storage.readKey('openai'), isNull);
    expect(await storage.readKey('grok'), 'sk-b');
  });

  test('reading an unknown provider returns null rather than throwing', () async {
    expect(await storage.readKey('never-configured'), isNull);
    expect(await storage.hasKey('never-configured'), isFalse);
  });

  test('storage key names are namespaced to avoid colliding with wger auth', () {
    expect(FlutterAiKeyStorage.storageKeyFor('openai'), 'omnihealth_ai_key_openai');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/credentials/ai_key_storage_test.dart`
Expected: FAIL — `ai_key_storage.dart` does not exist

- [ ] **Step 3: Write the implementation**

```dart
// lib/features/ai/credentials/ai_key_storage.dart
// <AGPL header block>

import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Stores per-provider LLM API keys in platform secure storage (Keychain on
/// iOS/macOS, EncryptedSharedPreferences on Android, DPAPI on Windows).
///
/// Keys are never logged, never serialised into chat history, and never
/// included in any object's `toString()`. They leave the device only in the
/// Authorization header of a request to the provider the user configured.
///
/// Wrapped behind an interface so tests substitute an in-memory double without
/// touching platform channels.
abstract interface class AiKeyStorage {
  Future<void> writeKey(String providerId, String key);
  Future<String?> readKey(String providerId);
  Future<void> deleteKey(String providerId);
  Future<bool> hasKey(String providerId);
}

class FlutterAiKeyStorage implements AiKeyStorage {
  /// Namespaced so AI keys can never collide with wger's own auth tokens.
  static String storageKeyFor(String providerId) => 'omnihealth_ai_key_$providerId';

  final FlutterSecureStorage _storage;

  const FlutterAiKeyStorage([this._storage = const FlutterSecureStorage()]);

  @override
  Future<void> writeKey(String providerId, String key) =>
      _storage.write(key: storageKeyFor(providerId), value: key);

  @override
  Future<String?> readKey(String providerId) => _storage.read(key: storageKeyFor(providerId));

  @override
  Future<void> deleteKey(String providerId) => _storage.delete(key: storageKeyFor(providerId));

  @override
  Future<bool> hasKey(String providerId) async =>
      await _storage.read(key: storageKeyFor(providerId)) != null;
}

final aiKeyStorageProvider = Provider<AiKeyStorage>((ref) => const FlutterAiKeyStorage());
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/ai/credentials/ai_key_storage_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/credentials/ test/features/ai/credentials/
git commit -m "feat(ai): add namespaced secure storage for provider API keys"
```

---

## Task 5: Confirmation tokens

The mechanism that enforces "the model proposes, only a tap writes". Built before the registry because the registry depends on it.

**Files:**
- Create: `lib/features/ai/tools/confirmation_token.dart`
- Test: `test/features/ai/tools/confirmation_token_test.dart`

**Interfaces:**
- Consumes: nothing
- Produces: `ConfirmationTokenService(clock)` with `String mint({required String toolName, required Map<String, dynamic> arguments})`, `TokenCheck consume({required String token, required String toolName, required Map<String, dynamic> arguments})`; `TokenCheck` enum `{valid, unknown, expired, alreadyUsed, argumentMismatch}`; `confirmationTokenServiceProvider`

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/tools/confirmation_token_test.dart
import 'package:clock/clock.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';

void main() {
  late ConfirmationTokenService service;

  setUp(() => service = ConfirmationTokenService());

  test('a freshly minted token validates for its exact tool and arguments', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
      TokenCheck.valid,
    );
  });

  test('a token is single-use', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
      TokenCheck.alreadyUsed,
    );
  });

  test('a token bound to one tool is rejected for another', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_nutrition_entry', arguments: {'value': 82.4}),
      TokenCheck.unknown,
    );
  });

  test('altered arguments are rejected — the model cannot swap the payload', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'value': 999.0}),
      TokenCheck.argumentMismatch,
    );
  });

  test('a token expires after five minutes', () {
    final start = DateTime(2026, 8, 7, 12);
    late String token;
    withClock(Clock.fixed(start), () {
      token = service.mint(toolName: 'log_weight', arguments: {'value': 82.4});
    });
    withClock(Clock.fixed(start.add(const Duration(minutes: 5, seconds: 1))), () {
      expect(
        service.consume(token: token, toolName: 'log_weight', arguments: {'value': 82.4}),
        TokenCheck.expired,
      );
    });
  });

  test('an invented token is unknown', () {
    expect(
      service.consume(token: 'made-up', toolName: 'log_weight', arguments: {}),
      TokenCheck.unknown,
    );
  });

  test('argument key order does not affect validation', () {
    final token = service.mint(toolName: 'log_weight', arguments: {'a': 1, 'b': 2});
    expect(
      service.consume(token: token, toolName: 'log_weight', arguments: {'b': 2, 'a': 1}),
      TokenCheck.valid,
    );
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/tools/confirmation_token_test.dart`
Expected: FAIL — `confirmation_token.dart` does not exist

- [ ] **Step 3: Write the implementation**

```dart
// lib/features/ai/tools/confirmation_token.dart
// <AGPL header block>

import 'dart:convert';
import 'dart:math';

import 'package:clock/clock.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;

enum TokenCheck { valid, unknown, expired, alreadyUsed, argumentMismatch }

/// Enforces the core safety invariant: a write tool runs only when the user
/// physically tapped a control in the rendered UI.
///
/// Tokens are minted **only** by the A2UI renderer, in direct response to a
/// tap. They are single-use, bound to one tool name and one exact argument set,
/// and expire after [_ttl]. Prompt instructions are not a security boundary;
/// this is.
class ConfirmationTokenService {
  static const _ttl = Duration(minutes: 5);

  final _random = Random.secure();
  final Map<String, _Grant> _grants = {};

  /// Called by the renderer when the user taps a submit/confirm control.
  String mint({required String toolName, required Map<String, dynamic> arguments}) {
    final bytes = List<int>.generate(32, (_) => _random.nextInt(256));
    final token = base64Url.encode(bytes);
    _grants[token] = _Grant(
      toolName: toolName,
      argumentsDigest: _digest(arguments),
      issuedAt: clock.now(),
    );
    _evictExpired();
    return token;
  }

  /// Called by the registry before executing a write tool.
  TokenCheck consume({
    required String token,
    required String toolName,
    required Map<String, dynamic> arguments,
  }) {
    final grant = _grants[token];
    if (grant == null) return TokenCheck.unknown;
    // Binding to the tool name is part of identity: a token for one tool must
    // read as unknown for another, not merely invalid.
    if (grant.toolName != toolName) return TokenCheck.unknown;
    if (grant.consumed) return TokenCheck.alreadyUsed;
    if (clock.now().difference(grant.issuedAt) > _ttl) return TokenCheck.expired;
    if (grant.argumentsDigest != _digest(arguments)) return TokenCheck.argumentMismatch;

    grant.consumed = true;
    return TokenCheck.valid;
  }

  /// Order-independent digest, so re-serialising arguments cannot break a token.
  String _digest(Map<String, dynamic> arguments) {
    final sortedKeys = arguments.keys.toList()..sort();
    final canonical = {for (final k in sortedKeys) k: arguments[k]};
    return sha256.convert(utf8.encode(jsonEncode(canonical))).toString();
  }

  void _evictExpired() {
    final now = clock.now();
    _grants.removeWhere((_, g) => now.difference(g.issuedAt) > _ttl);
  }
}

class _Grant {
  final String toolName;
  final String argumentsDigest;
  final DateTime issuedAt;
  bool consumed = false;

  _Grant({
    required this.toolName,
    required this.argumentsDigest,
    required this.issuedAt,
  });
}

final confirmationTokenServiceProvider =
    Provider<ConfirmationTokenService>((ref) => ConfirmationTokenService());
```

- [ ] **Step 4: Add the `crypto` dependency**

```bash
flutter pub add crypto
```

`clock` is already a wger dependency; do not re-add it.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/tools/confirmation_token_test.dart`
Expected: PASS (7 tests)

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/tools/ test/features/ai/tools/ pubspec.yaml pubspec.lock
git commit -m "feat(ai): add single-use confirmation tokens gating all writes"
```

---

## Task 6: Tool contract and registry

**Files:**
- Create: `lib/features/ai/tools/tool.dart`
- Create: `lib/features/ai/tools/tool_registry.dart`
- Test: `test/features/ai/tools/tool_registry_test.dart`

**Interfaces:**
- Consumes: `ToolSpec` (Task 1); `ConfirmationTokenService`, `TokenCheck` (Task 5)
- Produces: `Tool` (abstract interface: `String get name`, `String get description`, `Map<String, dynamic> get inputSchema`, `bool get isWrite`, `Future<ToolResult> call(Map<String, dynamic> args)`); `ToolResult.ok(Object? data)` / `ToolResult.error(String message)` with `bool get isError`; `ToolRegistry(tokenService)` with `register(Tool)`, `List<ToolSpec> specs()`, `Future<ToolResult> dispatch(String name, Map<String, dynamic> args)`

The registry is the only surface an agent can invoke. It validates arguments against the declared schema and enforces the confirmation token on any tool where `isWrite` is true.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/tools/tool_registry_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

class FakeReadTool implements Tool {
  @override
  String get name => 'get_thing';
  @override
  String get description => 'Reads a thing';
  @override
  bool get isWrite => false;
  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {'id': {'type': 'integer'}},
        'required': ['id'],
      };
  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => ToolResult.ok({'id': args['id']});
}

class FakeWriteTool implements Tool {
  int callCount = 0;
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
    callCount++;
    return ToolResult.ok({'written': args['value']});
  }
}

void main() {
  late ConfirmationTokenService tokens;
  late ToolRegistry registry;
  late FakeWriteTool writeTool;

  setUp(() {
    tokens = ConfirmationTokenService();
    registry = ToolRegistry(tokenService: tokens);
    writeTool = FakeWriteTool();
    registry.register(FakeReadTool());
    registry.register(writeTool);
  });

  test('specs() exposes every registered tool', () {
    expect(registry.specs().map((s) => s.name), containsAll(['get_thing', 'write_thing']));
  });

  test('dispatches a read tool with valid arguments', () async {
    final result = await registry.dispatch('get_thing', {'id': 7});
    expect(result.isError, isFalse);
    expect((result.data as Map)['id'], 7);
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
  });

  test('wrong argument type returns a schema error', () async {
    final result = await registry.dispatch('get_thing', {'id': 'seven'});
    expect(result.isError, isTrue);
  });

  test('a write without a confirmation token is refused and never executes', () async {
    final result = await registry.dispatch('write_thing', {'value': 1.0});
    expect(result.isError, isTrue);
    expect(result.message.toLowerCase(), contains('confirm'));
    expect(writeTool.callCount, 0);
  });

  test('a write with a fabricated token is refused and never executes', () async {
    final result = await registry.dispatch(
      'write_thing',
      {'value': 1.0, 'confirmationToken': 'fabricated'},
    );
    expect(result.isError, isTrue);
    expect(writeTool.callCount, 0);
  });

  test('a write with a valid token executes exactly once', () async {
    final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
    final result = await registry.dispatch(
      'write_thing',
      {'value': 1.0, 'confirmationToken': token},
    );
    expect(result.isError, isFalse);
    expect(writeTool.callCount, 1);
  });

  test('replaying a consumed token is refused', () async {
    final token = tokens.mint(toolName: 'write_thing', arguments: {'value': 1.0});
    await registry.dispatch('write_thing', {'value': 1.0, 'confirmationToken': token});
    final replay = await registry.dispatch(
      'write_thing',
      {'value': 1.0, 'confirmationToken': token},
    );
    expect(replay.isError, isTrue);
    expect(writeTool.callCount, 1);
  });

  test('a tool that throws is converted to an error result', () async {
    registry.register(_ThrowingTool());
    final result = await registry.dispatch('explode', {});
    expect(result.isError, isTrue);
    expect(result.message, contains('boom'));
  });
}

class _ThrowingTool implements Tool {
  @override
  String get name => 'explode';
  @override
  String get description => 'Always throws';
  @override
  bool get isWrite => false;
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};
  @override
  Future<ToolResult> call(Map<String, dynamic> args) async => throw StateError('boom');
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/tools/tool_registry_test.dart`
Expected: FAIL — `tool.dart` and `tool_registry.dart` do not exist

- [ ] **Step 3: Write the Tool contract**

```dart
// lib/features/ai/tools/tool.dart
// <AGPL header block>

/// Outcome of a tool invocation.
///
/// Errors are values, not exceptions: a failed tool result is fed back to the
/// model so it can explain the failure or retry, rather than aborting the turn.
class ToolResult {
  final Object? data;
  final String message;
  final bool isError;

  const ToolResult._({this.data, this.message = '', required this.isError});

  factory ToolResult.ok(Object? data) => ToolResult._(data: data, isError: false);
  factory ToolResult.error(String message) => ToolResult._(message: message, isError: true);
}

/// One capability the agent may invoke. Shaped after MCP (name, description,
/// JSON Schema, call) so the MCP bridge in `mcp/` and future remote plugins are
/// thin adapters rather than rewrites.
abstract interface class Tool {
  String get name;
  String get description;

  /// JSON Schema for the arguments. Validated by the registry before [call].
  Map<String, dynamic> get inputSchema;

  /// Whether invoking this tool mutates user data. Write tools additionally
  /// require a valid `confirmationToken` argument, enforced by the registry.
  bool get isWrite;

  Future<ToolResult> call(Map<String, dynamic> args);
}
```

- [ ] **Step 4: Write the registry**

```dart
// lib/features/ai/tools/tool_registry.dart
// <AGPL header block>

import 'package:flutter_riverpod/flutter_riverpod.dart' show Provider;
import 'package:json_schema_builder/json_schema_builder.dart';
import 'package:logging/logging.dart';
import 'package:wger/features/ai/providers/llm_provider.dart' show ToolSpec;
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';

/// The only surface an agent may invoke.
///
/// Responsibilities, in order: resolve the name, validate arguments against the
/// declared schema, enforce the confirmation token for writes, then execute.
class ToolRegistry {
  static const confirmationTokenArg = 'confirmationToken';

  final ConfirmationTokenService tokenService;
  final Map<String, Tool> _tools = {};
  final _logger = Logger('ToolRegistry');

  ToolRegistry({required this.tokenService});

  void register(Tool tool) => _tools[tool.name] = tool;

  List<ToolSpec> specs() => _tools.values
      .map((t) => ToolSpec(
            name: t.name,
            description: t.description,
            inputSchema: t.inputSchema,
          ))
      .toList();

  Future<ToolResult> dispatch(String name, Map<String, dynamic> args) async {
    final tool = _tools[name];
    if (tool == null) {
      return ToolResult.error('No tool named "$name" is available.');
    }

    final schemaError = _validate(tool, args);
    if (schemaError != null) {
      return ToolResult.error('Invalid arguments for "$name": $schemaError');
    }

    if (tool.isWrite) {
      final gate = _checkConfirmation(tool, args);
      if (gate != null) return gate;
    }

    try {
      return await tool.call(args);
    } catch (e, st) {
      _logger.warning('Tool "$name" threw', e, st);
      return ToolResult.error('Tool "$name" failed: $e');
    }
  }

  String? _validate(Tool tool, Map<String, dynamic> args) {
    // The confirmation token is a transport concern, not part of the tool's
    // domain arguments — strip it before schema validation.
    final domainArgs = Map<String, dynamic>.from(args)..remove(confirmationTokenArg);
    final schema = Map<String, dynamic>.from(tool.inputSchema);
    final required = (schema['required'] as List?)
        ?.where((k) => k != confirmationTokenArg)
        .toList();
    if (required != null) schema['required'] = required;

    final validation = JsonSchema.fromMap(schema).validate(domainArgs);
    if (validation.isValid) return null;
    return validation.errors.map((e) => e.toString()).join('; ');
  }

  ToolResult? _checkConfirmation(Tool tool, Map<String, dynamic> args) {
    final token = args[confirmationTokenArg] as String?;
    if (token == null || token.isEmpty) {
      return ToolResult.error(
        'Tool "${tool.name}" changes the user\'s data and requires confirmation. '
        'Render a confirmation UI first and pass the resulting $confirmationTokenArg.',
      );
    }

    final domainArgs = Map<String, dynamic>.from(args)..remove(confirmationTokenArg);
    final check = tokenService.consume(
      token: token,
      toolName: tool.name,
      arguments: domainArgs,
    );

    return switch (check) {
      TokenCheck.valid => null,
      TokenCheck.unknown => ToolResult.error(
          'That confirmation is not valid for "${tool.name}". Ask the user again.'),
      TokenCheck.expired => ToolResult.error(
          'That confirmation expired. Ask the user to confirm again.'),
      TokenCheck.alreadyUsed => ToolResult.error(
          'That confirmation was already used. Ask the user to confirm again.'),
      TokenCheck.argumentMismatch => ToolResult.error(
          'The values changed after the user confirmed. Ask the user to confirm again.'),
    };
  }
}

final toolRegistryProvider = Provider<ToolRegistry>((ref) {
  return ToolRegistry(tokenService: ref.read(confirmationTokenServiceProvider));
});
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/tools/tool_registry_test.dart`
Expected: PASS (10 tests)

If `json_schema_builder`'s API differs from `JsonSchema.fromMap(...).validate(...)`, read the installed package under `~/.pub-cache/hosted/pub.dev/json_schema_builder-*/lib/` and adapt `_validate` only. Do not change the tests — they assert behavior, not the library's API.

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/tools/ test/features/ai/tools/
git commit -m "feat(ai): add MCP-shaped tool registry with schema and write gating"
```

---

## Task 7: Weight tools over the wger repositories

**Files:**
- Create: `lib/features/ai/tools/wger/weight_tools.dart`
- Test: `test/features/ai/tools/wger/weight_tools_test.dart`

**Interfaces:**
- Consumes: `Tool`, `ToolResult` (Task 6)
- Produces: `GetWeightHistoryTool(repository)`, `LogWeightTool(notifier)`

These call wger's existing `BodyWeightRepository` / `WeightEntryNotifier` — not HTTP. Writes land in local Drift and PowerSync replicates them, so the tools work offline and the weight screen updates live.

- [ ] **Step 1: Read the existing types**

Read these before writing anything, and match their exact signatures:
- `lib/features/weight/models/weight_entry.dart` — the `WeightEntry` fields and constructor
- `lib/features/weight/providers/body_weight_repository.dart` — `watchAllDrift()`, `addLocalDrift(WeightEntry)`
- `lib/features/weight/providers/body_weight_notifier.dart` — `addEntry(WeightEntry)`

- [ ] **Step 2: Write the failing test**

```dart
// test/features/ai/tools/wger/weight_tools_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/tools/wger/weight_tools.dart';
import 'package:wger/features/weight/models/weight_entry.dart';

/// Records what the tool asked the app to do, without a database.
class FakeWeightSink {
  final List<WeightEntry> added = [];
  List<WeightEntry> history = [];

  Future<void> add(WeightEntry entry) async => added.add(entry);
  Stream<List<WeightEntry>> watch() => Stream.value(history);
}

void main() {
  late FakeWeightSink sink;

  setUp(() => sink = FakeWeightSink());

  group('GetWeightHistoryTool', () {
    test('is a read tool', () {
      expect(GetWeightHistoryTool(watch: sink.watch).isWrite, isFalse);
    });

    test('returns entries as a list of maps', () async {
      sink.history = [
        WeightEntry(date: DateTime(2026, 8, 6), weight: 82.4),
        WeightEntry(date: DateTime(2026, 8, 7), weight: 82.1),
      ];
      final result = await GetWeightHistoryTool(watch: sink.watch).call({});
      expect(result.isError, isFalse);
      expect((result.data as List), hasLength(2));
    });

    test('respects the limit argument', () async {
      sink.history = List.generate(
        10,
        (i) => WeightEntry(date: DateTime(2026, 8, i + 1), weight: 80.0 + i),
      );
      final result = await GetWeightHistoryTool(watch: sink.watch).call({'limit': 3});
      expect((result.data as List), hasLength(3));
    });

    test('an empty history is a success, not an error', () async {
      final result = await GetWeightHistoryTool(watch: sink.watch).call({});
      expect(result.isError, isFalse);
      expect((result.data as List), isEmpty);
    });
  });

  group('LogWeightTool', () {
    test('is a write tool — the registry will demand confirmation', () {
      expect(LogWeightTool(add: sink.add).isWrite, isTrue);
    });

    test('declares confirmationToken in its schema', () {
      final schema = LogWeightTool(add: sink.add).inputSchema;
      expect((schema['properties'] as Map).containsKey('confirmationToken'), isTrue);
    });

    test('writes the entry through the app\'s own sink', () async {
      final result = await LogWeightTool(add: sink.add).call({
        'value': 82.4,
        'date': '2026-08-07',
        'confirmationToken': 'checked-by-registry',
      });
      expect(result.isError, isFalse);
      expect(sink.added, hasLength(1));
      expect(sink.added.single.weight, 82.4);
      expect(sink.added.single.date, DateTime(2026, 8, 7));
    });

    test('rejects an unparseable date rather than writing a wrong one', () async {
      final result = await LogWeightTool(add: sink.add).call({
        'value': 82.4,
        'date': 'yesterday-ish',
        'confirmationToken': 't',
      });
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });

    test('rejects a non-positive weight', () async {
      final result = await LogWeightTool(add: sink.add).call({
        'value': 0.0,
        'date': '2026-08-07',
        'confirmationToken': 't',
      });
      expect(result.isError, isTrue);
      expect(sink.added, isEmpty);
    });
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ai/tools/wger/weight_tools_test.dart`
Expected: FAIL — `weight_tools.dart` does not exist

- [ ] **Step 4: Write the tools**

Taking the repository methods as injected callbacks keeps these tools testable without a Drift database. Adjust `WeightEntry`'s construction to match what Step 1 found.

```dart
// lib/features/ai/tools/wger/weight_tools.dart
// <AGPL header block>

import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/weight/models/weight_entry.dart';

/// Reads body-weight history from the local Drift store.
class GetWeightHistoryTool implements Tool {
  final Stream<List<WeightEntry>> Function() watch;

  GetWeightHistoryTool({required this.watch});

  @override
  String get name => 'get_weight_history';

  @override
  String get description =>
      'Returns the user\'s recorded body weight entries, most recent first.';

  @override
  bool get isWrite => false;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'limit': {
            'type': 'integer',
            'description': 'Maximum entries to return. Defaults to 30.',
            'minimum': 1,
          },
        },
      };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final limit = (args['limit'] as int?) ?? 30;
    final entries = await watch().first;
    return ToolResult.ok(
      entries
          .take(limit)
          .map((e) => {
                'date': e.date.toIso8601String().split('T').first,
                'weight': e.weight,
              })
          .toList(),
    );
  }
}

/// Records a body-weight entry. Write tool: the registry refuses to run this
/// without a confirmation token minted by a user tap.
class LogWeightTool implements Tool {
  final Future<void> Function(WeightEntry) add;

  LogWeightTool({required this.add});

  @override
  String get name => 'log_weight';

  @override
  String get description =>
      'Records a body weight entry for a given date. Requires user confirmation.';

  @override
  bool get isWrite => true;

  @override
  Map<String, dynamic> get inputSchema => {
        'type': 'object',
        'properties': {
          'value': {
            'type': 'number',
            'description': 'Body weight in the user\'s configured unit.',
            'exclusiveMinimum': 0,
          },
          'date': {
            'type': 'string',
            'description': 'Date in YYYY-MM-DD format.',
          },
          'confirmationToken': {
            'type': 'string',
            'description':
                'Token returned by render_ui when the user tapped save. Never invent this.',
          },
        },
        'required': ['value', 'date', 'confirmationToken'],
      };

  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    final value = (args['value'] as num).toDouble();
    if (value <= 0) {
      return ToolResult.error('Weight must be greater than zero, got $value.');
    }

    final rawDate = args['date'] as String;
    final date = DateTime.tryParse(rawDate);
    if (date == null) {
      return ToolResult.error('Could not parse date "$rawDate". Use YYYY-MM-DD.');
    }

    await add(WeightEntry(date: date, weight: value));
    return ToolResult.ok({
      'logged': {'date': rawDate, 'weight': value},
    });
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/tools/wger/weight_tools_test.dart`
Expected: PASS (9 tests)

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/tools/wger/ test/features/ai/tools/wger/
git commit -m "feat(ai): add weight read/write tools over wger repositories"
```

---

## Task 8: Nutrition, workout, measurement, and exercise tools

**Files:**
- Create: `lib/features/ai/tools/wger/nutrition_tools.dart`
- Create: `lib/features/ai/tools/wger/body_tools.dart`
- Create: `lib/features/ai/tools/wger/exercise_tools.dart`
- Test: `test/features/ai/tools/wger/nutrition_tools_test.dart`
- Test: `test/features/ai/tools/wger/body_tools_test.dart`
- Test: `test/features/ai/tools/wger/exercise_tools_test.dart`

**Interfaces:**
- Consumes: `Tool`, `ToolResult` (Task 6)
- Produces: `GetNutritionLogTool`, `SearchIngredientTool`, `LogNutritionEntryTool`, `GetWorkoutLogTool`, `GetBodyMeasurementsTool`, `SearchExercisesTool`, `GetExerciseDetailTool`

The two exercise tools are what make the `ExerciseVideo` component (Task 11) reachable: the agent searches for a lift, gets back video **ids**, and renders one. Per spec §5.5 these tools return ids and never URLs — no tool result may contain a media URL, because anything the agent sees it can put in its next render request.

- [ ] **Step 1: Read the existing repositories**

- `lib/features/nutrition/providers/nutrition_repository.dart` — `watchAllLogsHydrated()`, `addLogLocalDrift(LogItem)`
- `lib/features/nutrition/providers/ingredient_repository.dart` — `search(...)`, which already picks server or local transport
- `lib/features/routines/providers/workout_logs_repository.dart`
- `lib/features/measurements/providers/measurement_repository.dart`
- The corresponding models under each feature's `models/`

- [ ] **Step 2: Write the nutrition tests**

Follow the exact structure of Task 7's tests: a fake sink per repository method, one test asserting `isWrite`, one asserting schema shape for write tools, one happy path, one rejection path, and one empty-result path. Specifically assert:

- `GetNutritionLogTool` — `isWrite` false; returns a list; honors `date` filter; empty log is success
- `SearchIngredientTool` — `isWrite` false; passes the query through; empty results is success, not error; a blank query returns an error rather than searching
- `LogNutritionEntryTool` — `isWrite` true; schema contains `confirmationToken`; writes through the sink; rejects a non-existent ingredient id; rejects a non-positive amount

- [ ] **Step 3: Run tests to verify they fail**

Run: `flutter test test/features/ai/tools/wger/nutrition_tools_test.dart`
Expected: FAIL — `nutrition_tools.dart` does not exist

- [ ] **Step 4: Write the nutrition tools**

Mirror Task 7's structure exactly: injected callbacks rather than repositories, JSON Schema with descriptions written for a model to read, validation before any write, `ToolResult.error` rather than exceptions. `SearchIngredientTool.isWrite` is false; `LogNutritionEntryTool.isWrite` is true and declares `confirmationToken` in both `properties` and `required`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/tools/wger/nutrition_tools_test.dart`
Expected: PASS

- [ ] **Step 6: Repeat Steps 2–5 for `body_tools.dart`**

`GetWorkoutLogTool` and `GetBodyMeasurementsTool` are both reads, so neither declares a confirmation token. Both accept an optional `limit` and an optional `since` date string, and both return an empty list as a success.

- [ ] **Step 7: Repeat Steps 2–5 for `exercise_tools.dart`**

Read `lib/features/exercises/providers/exercise_repository.dart` first — it exposes `searchExerciseServer(...)` and `watchAllDrift()` returning an `ExerciseState`. The `Exercise` model already carries `List<Video> videos`.

- `SearchExercisesTool` — `{query, limit?}` → `[{id, name, category, equipment, hasVideo}]`. Empty results is a success. A blank query is an error rather than an unbounded scan.
- `GetExerciseDetailTool` — `{id}` → `{name, description, muscles, equipment, videos: [{id, durationSeconds}], license: {title, author}}`. An unknown id is an error, not an empty object.

**Two assertions this task exists to pin**, both from spec §5.5:

```dart
test('exercise results expose video ids, never media URLs', () async {
  final result = await GetExerciseDetailTool(load: fake.load).call({'id': 1});
  final encoded = jsonEncode(result.data);
  expect(encoded, contains('"id"'));
  // Anything URL-shaped in a tool result is a URL the agent can echo into a
  // render request. Media resolution belongs client-side, in the component.
  expect(encoded, isNot(contains('http')));
  expect(encoded, isNot(contains('/media/')));
});

test('search results expose hasVideo as a flag, not a link', () async {
  final result = await SearchExercisesTool(search: fake.search).call({'query': 'deadlift'});
  expect(jsonEncode(result.data), isNot(contains('http')));
});
```

- [ ] **Step 8: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/tools/wger/ test/features/ai/tools/wger/
git commit -m "feat(ai): add nutrition, workout, measurement and exercise tools"
```

---

## Task 9: Local agent backend

**Files:**
- Create: `lib/features/ai/agent/agent_backend.dart`
- Create: `lib/features/ai/agent/local/local_agent_backend.dart`
- Test: `test/features/ai/agent/local/local_agent_backend_test.dart`

**Interfaces:**
- Consumes: `LlmProvider`, `LlmEvent`, `Message`, `ToolCall` (Task 1); `ToolRegistry`, `ToolResult` (Task 6)
- Produces: `AgentBackend` (abstract interface: `Stream<AgentEvent> sendMessage(String text)`, `Future<void> cancel()`, `Future<void> dispose()`); `AgentEvent` sealed class with `AgentText(String)`, `AgentToolStarted(String name)`, `AgentToolFinished(String name, bool isError)`, `AgentTurnComplete()`, `AgentFailure(String message, {bool retriable})`; `LocalAgentBackend(provider, registry, {maxIterations = 12})`

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/agent/local/local_agent_backend_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/agent/local/local_agent_backend.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

/// Replays scripted event sequences, one list per turn.
class ScriptedProvider implements LlmProvider {
  final List<List<LlmEvent>> turns;
  int turnIndex = 0;
  final List<List<Message>> received = [];

  ScriptedProvider(this.turns);

  @override
  String get id => 'scripted';

  @override
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
  }) async* {
    received.add(List.of(messages));
    final events = turnIndex < turns.length ? turns[turnIndex] : [const TurnComplete()];
    turnIndex++;
    for (final e in events) {
      yield e;
    }
  }
}

class EchoTool implements Tool {
  int calls = 0;
  @override
  String get name => 'echo';
  @override
  String get description => 'Echoes';
  @override
  bool get isWrite => false;
  @override
  Map<String, dynamic> get inputSchema => {'type': 'object', 'properties': {}};
  @override
  Future<ToolResult> call(Map<String, dynamic> args) async {
    calls++;
    return ToolResult.ok({'echoed': true});
  }
}

ToolRegistry _registryWith(Tool tool) {
  final r = ToolRegistry(tokenService: ConfirmationTokenService());
  r.register(tool);
  return r;
}

void main() {
  test('streams plain text and completes', () async {
    final provider = ScriptedProvider([
      [const TextDelta('Hello'), const TextDelta(' there'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(EchoTool()),
    );

    final events = await backend.sendMessage('hi').toList();
    expect(
      events.whereType<AgentText>().map((e) => e.text).join(),
      'Hello there',
    );
    expect(events.last, isA<AgentTurnComplete>());
  });

  test('executes a tool call and feeds the result back for a second turn', () async {
    final tool = EchoTool();
    final provider = ScriptedProvider([
      [
        const ToolCallRequested(ToolCall(id: 'c1', name: 'echo', arguments: {})),
        const TurnComplete(),
      ],
      [const TextDelta('done'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(provider: provider, registry: _registryWith(tool));

    final events = await backend.sendMessage('go').toList();

    expect(tool.calls, 1);
    expect(events.whereType<AgentToolStarted>().single.name, 'echo');
    expect(events.whereType<AgentToolFinished>().single.isError, isFalse);
    expect(events.whereType<AgentText>().map((e) => e.text).join(), 'done');
    // The second request must carry the tool result back to the model.
    expect(provider.received.length, 2);
    expect(provider.received[1].any((m) => m.role == MessageRole.tool), isTrue);
  });

  test('a failing tool is reported to the model, not thrown', () async {
    final provider = ScriptedProvider([
      [
        const ToolCallRequested(ToolCall(id: 'c1', name: 'missing', arguments: {})),
        const TurnComplete(),
      ],
      [const TextDelta('sorry'), const TurnComplete()],
    ]);
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(EchoTool()),
    );

    final events = await backend.sendMessage('go').toList();
    expect(events.whereType<AgentToolFinished>().single.isError, isTrue);
    expect(events.last, isA<AgentTurnComplete>());
  });

  test('a provider error surfaces as AgentFailure and ends the turn', () async {
    final provider = ScriptedProvider([
      [const ProviderError('bad key')],
    ]);
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(EchoTool()),
    );

    final events = await backend.sendMessage('hi').toList();
    final failure = events.whereType<AgentFailure>().single;
    expect(failure.message, contains('bad key'));
    expect(failure.retriable, isFalse);
  });

  test('stops at the iteration cap instead of looping forever', () async {
    // Every turn asks for another tool call — without a cap this never ends.
    final provider = ScriptedProvider(
      List.generate(
        50,
        (_) => [
          const ToolCallRequested(ToolCall(id: 'c', name: 'echo', arguments: {})),
          const TurnComplete(),
        ],
      ),
    );
    final tool = EchoTool();
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(tool),
      maxIterations: 3,
    );

    final events = await backend.sendMessage('go').toList();
    expect(tool.calls, 3);
    expect(events.whereType<AgentFailure>().single.message.toLowerCase(), contains('too many'));
  });

  test('cancel stops the turn', () async {
    final provider = ScriptedProvider(
      List.generate(
        50,
        (_) => [
          const ToolCallRequested(ToolCall(id: 'c', name: 'echo', arguments: {})),
          const TurnComplete(),
        ],
      ),
    );
    final backend = LocalAgentBackend(
      provider: provider,
      registry: _registryWith(EchoTool()),
      maxIterations: 100,
    );

    final events = <AgentEvent>[];
    final sub = backend.sendMessage('go').listen(events.add);
    await Future<void>.delayed(Duration.zero);
    await backend.cancel();
    await sub.cancel();

    expect(events.length, lessThan(100));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/agent/local/local_agent_backend_test.dart`
Expected: FAIL — `agent_backend.dart` does not exist

- [ ] **Step 3: Write the AgentBackend contract**

```dart
// lib/features/ai/agent/agent_backend.dart
// <AGPL header block>

sealed class AgentEvent {
  const AgentEvent();
}

class AgentText extends AgentEvent {
  final String text;
  const AgentText(this.text);
}

class AgentToolStarted extends AgentEvent {
  final String name;
  const AgentToolStarted(this.name);
}

class AgentToolFinished extends AgentEvent {
  final String name;
  final bool isError;
  const AgentToolFinished(this.name, {required this.isError});
}

class AgentTurnComplete extends AgentEvent {
  const AgentTurnComplete();
}

class AgentFailure extends AgentEvent {
  final String message;
  final bool retriable;
  const AgentFailure(this.message, {this.retriable = false});
}

/// A complete conversational agent.
///
/// Two implementations exist and they sit at this level, not at the provider
/// level, because an ACP agent runs its own tool loop: it is an agent, not a
/// model endpoint. Conflating the two produces a leaky interface.
abstract interface class AgentBackend {
  Stream<AgentEvent> sendMessage(String text);
  Future<void> cancel();
  Future<void> dispose();
}
```

- [ ] **Step 4: Write the local backend**

```dart
// lib/features/ai/agent/local/local_agent_backend.dart
// <AGPL header block>

import 'dart:async';
import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:wger/features/ai/agent/agent_backend.dart';
import 'package:wger/features/ai/providers/llm_provider.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

/// Runs the agent loop in-process: prompt the provider, execute any tool calls
/// against the registry, feed results back, repeat until the model stops asking
/// for tools.
///
/// Knows nothing about HTTP (that is the provider's job) or widgets.
class LocalAgentBackend implements AgentBackend {
  final LlmProvider provider;
  final ToolRegistry registry;

  /// Hard stop so a model that keeps requesting tools cannot spin forever.
  final int maxIterations;

  final List<Message> _history = [];
  final _logger = Logger('LocalAgentBackend');
  bool _cancelled = false;

  LocalAgentBackend({
    required this.provider,
    required this.registry,
    this.maxIterations = 12,
  });

  @override
  Stream<AgentEvent> sendMessage(String text) async* {
    _cancelled = false;
    _history.add(Message(role: MessageRole.user, content: text));

    for (var iteration = 0; iteration < maxIterations; iteration++) {
      if (_cancelled) return;

      final toolCalls = <ToolCall>[];
      final assistantText = StringBuffer();
      var failed = false;

      await for (final event in provider.stream(
        messages: List.unmodifiable(_history),
        tools: registry.specs(),
      )) {
        if (_cancelled) return;

        switch (event) {
          case TextDelta(:final text):
            assistantText.write(text);
            yield AgentText(text);
          case ToolCallRequested(:final call):
            toolCalls.add(call);
          case ProviderError(:final message, :final retriable):
            failed = true;
            yield AgentFailure(message, retriable: retriable);
          case TurnComplete():
            break;
        }
      }

      if (failed) return;

      _history.add(Message(
        role: MessageRole.assistant,
        content: assistantText.toString(),
        toolCalls: toolCalls,
      ));

      // No tools requested means the model is done talking.
      if (toolCalls.isEmpty) {
        yield const AgentTurnComplete();
        return;
      }

      for (final call in toolCalls) {
        if (_cancelled) return;
        yield AgentToolStarted(call.name);

        final result = await registry.dispatch(call.name, call.arguments);
        yield AgentToolFinished(call.name, isError: result.isError);

        // Errors go back to the model as ordinary results so it can recover.
        _history.add(Message(
          role: MessageRole.tool,
          toolCallId: call.id,
          content: result.isError ? 'ERROR: ${result.message}' : jsonEncode(result.data),
        ));
      }
    }

    _logger.warning('Hit iteration cap of $maxIterations');
    yield AgentFailure(
      'Stopped after too many steps ($maxIterations). Try rephrasing your request.',
    );
  }

  @override
  Future<void> cancel() async => _cancelled = true;

  @override
  Future<void> dispose() async {
    _cancelled = true;
    _history.clear();
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/agent/local/local_agent_backend_test.dart`
Expected: PASS (6 tests)

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/agent/ test/features/ai/agent/
git commit -m "feat(ai): add local agent backend with tool loop and iteration cap"
```

---

## Task 10: A2UI catalog — entry and confirmation components

**Files:**
- Create: `lib/features/ai/genui/widgets/metric_entry_card.dart`
- Create: `lib/features/ai/genui/widgets/confirmation_card.dart`
- Create: `lib/features/ai/genui/omni_catalog.dart`
- Test: `test/features/ai/genui/widgets/metric_entry_card_test.dart`
- Test: `test/features/ai/genui/widgets/confirmation_card_test.dart`

**Interfaces:**
- Consumes: `ConfirmationTokenService` (Task 5)
- Produces: `MetricEntryCard({metric, unit, initialDate, onSubmit, onDismiss})`, `ConfirmationCard({summary, onAccept, onReject})`, `OmniCatalog.build(...)` returning a genui `Catalog`

- [ ] **Step 1: Add genui and read its catalog API**

```bash
flutter pub add genui
```

Then read the installed package to learn the exact `Catalog` / `CatalogItem` construction signature:

```bash
ls ~/.pub-cache/hosted/pub.dev/genui-*/lib/
```

Write down the real signature before Step 5. Do not guess it — the widget tests in Steps 2–4 do not depend on it, so build them first and wire the catalog after.

- [ ] **Step 2: Write the failing widget test**

```dart
// test/features/ai/genui/widgets/metric_entry_card_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/genui/widgets/metric_entry_card.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('shows the metric label and unit', (tester) async {
    await tester.pumpWidget(_host(MetricEntryCard(
      metric: 'weight',
      unit: 'kg',
      initialDate: DateTime(2026, 8, 7),
      onSubmit: (_, __) {},
      onDismiss: () {},
    )));

    expect(find.textContaining('weight'), findsWidgets);
    expect(find.textContaining('kg'), findsWidgets);
  });

  testWidgets('submitting reports the typed value and date', (tester) async {
    double? value;
    DateTime? date;

    await tester.pumpWidget(_host(MetricEntryCard(
      metric: 'weight',
      unit: 'kg',
      initialDate: DateTime(2026, 8, 7),
      onSubmit: (v, d) {
        value = v;
        date = d;
      },
      onDismiss: () {},
    )));

    await tester.enterText(find.byType(TextField), '82.4');
    await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
    await tester.pump();

    expect(value, 82.4);
    expect(date, DateTime(2026, 8, 7));
  });

  testWidgets('does not submit a non-numeric value', (tester) async {
    var submitted = false;
    await tester.pumpWidget(_host(MetricEntryCard(
      metric: 'weight',
      unit: 'kg',
      initialDate: DateTime(2026, 8, 7),
      onSubmit: (_, __) => submitted = true,
      onDismiss: () {},
    )));

    await tester.enterText(find.byType(TextField), 'heavy');
    await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
    await tester.pump();

    expect(submitted, isFalse);
    expect(find.textContaining('number'), findsOneWidget);
  });

  testWidgets('does not submit an empty value', (tester) async {
    var submitted = false;
    await tester.pumpWidget(_host(MetricEntryCard(
      metric: 'weight',
      unit: 'kg',
      initialDate: DateTime(2026, 8, 7),
      onSubmit: (_, __) => submitted = true,
      onDismiss: () {},
    )));

    await tester.tap(find.byKey(MetricEntryCard.saveButtonKey));
    await tester.pump();
    expect(submitted, isFalse);
  });

  testWidgets('dismissing reports dismissal and never submits', (tester) async {
    var submitted = false;
    var dismissed = false;

    await tester.pumpWidget(_host(MetricEntryCard(
      metric: 'weight',
      unit: 'kg',
      initialDate: DateTime(2026, 8, 7),
      onSubmit: (_, __) => submitted = true,
      onDismiss: () => dismissed = true,
    )));

    await tester.enterText(find.byType(TextField), '82.4');
    await tester.tap(find.byKey(MetricEntryCard.cancelButtonKey));
    await tester.pump();

    expect(dismissed, isTrue);
    expect(submitted, isFalse);
  });
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `flutter test test/features/ai/genui/widgets/metric_entry_card_test.dart`
Expected: FAIL — `metric_entry_card.dart` does not exist

- [ ] **Step 4: Write the widget**

```dart
// lib/features/ai/genui/widgets/metric_entry_card.dart
// <AGPL header block>

import 'package:flutter/material.dart';

/// Collects a single numeric health metric.
///
/// The agent may request this card, but it cannot submit it — [onSubmit] fires
/// only from a real tap, and only then is a confirmation token minted.
class MetricEntryCard extends StatefulWidget {
  static const saveButtonKey = Key('metric_entry_save');
  static const cancelButtonKey = Key('metric_entry_cancel');

  final String metric;
  final String unit;
  final DateTime initialDate;
  final void Function(double value, DateTime date) onSubmit;
  final VoidCallback onDismiss;

  const MetricEntryCard({
    super.key,
    required this.metric,
    required this.unit,
    required this.initialDate,
    required this.onSubmit,
    required this.onDismiss,
  });

  @override
  State<MetricEntryCard> createState() => _MetricEntryCardState();
}

class _MetricEntryCardState extends State<MetricEntryCard> {
  final _controller = TextEditingController();
  late DateTime _date = widget.initialDate;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final parsed = double.tryParse(_controller.text.trim());
    if (parsed == null) {
      setState(() => _error = 'Enter a number');
      return;
    }
    setState(() => _error = null);
    widget.onSubmit(parsed, _date);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Log ${widget.metric}', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: widget.metric,
                suffixText: widget.unit,
                errorText: _error,
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Text(
                  '${_date.year}-${_date.month.toString().padLeft(2, '0')}-'
                  '${_date.day.toString().padLeft(2, '0')}',
                  style: theme.textTheme.bodyMedium,
                ),
                const Spacer(),
                TextButton(
                  key: MetricEntryCard.cancelButtonKey,
                  onPressed: widget.onDismiss,
                  child: const Text('Cancel'),
                ),
                const SizedBox(width: 8),
                FilledButton(
                  key: MetricEntryCard.saveButtonKey,
                  onPressed: _submit,
                  child: const Text('Save'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/features/ai/genui/widgets/metric_entry_card_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 6: Repeat Steps 2–5 for `ConfirmationCard`**

Same shape. Tests assert: the summary text renders; tapping accept fires `onAccept` exactly once; tapping reject fires `onReject` and never `onAccept`; the accept and reject buttons carry stable `Key`s.

- [ ] **Step 7: Wire the catalog using the real genui API from Step 1**

Create `omni_catalog.dart` composing **A2UI's Basic Catalog minus its media items, plus OmniHealth's own**.

genui 0.10.1 already provides exactly this. `BasicCatalogItems.asNoAssetCatalog()` returns the Basic Catalog with `[audioPlayer, image, video]` removed — the same three spec §5.5 excludes, arrived at independently (genui's stated reason is that they "require additional data"; ours is silent egress). Use it rather than hand-listing items:

```dart
final base = BasicCatalogItems.asNoAssetCatalog(
  systemPromptFragments: [omniCatalogRules],
);
// then add MetricChart, ExerciseVideo, MetricEntryCard, ConfirmationCard
```

Two things worth knowing about the real API:
- `Catalog(items, {functions, catalogId, systemPromptFragments})` — `systemPromptFragments` lets the catalog contribute its own prompt rules. Use it to state the render-then-confirm flow, so the rule travels with the catalog instead of living in a system prompt someone edits later.
- `Catalog.copyWithout(itemsToRemove: [...])` exists, which is how `asNoAssetCatalog` is built. A test should assert `image`, `video`, and `audioPlayer` are absent from our final catalog — relying on `asNoAssetCatalog`'s current behaviour without pinning it would let an upstream change silently re-add them.

Add `OmniCatalog.writeComponents`, a constant set naming only the components permitted to mint confirmation tokens. After this task it contains `MetricEntryCard` and `ConfirmationCard`.

Catalog tests must assert:
- The Basic Catalog components resolve
- `MetricEntryCard` and `ConfirmationCard` resolve
- A name in neither set does **not** resolve
- `writeComponents` contains exactly `{MetricEntryCard, ConfirmationCard}` — this set is what Task 12 keys token minting off, so it gets its own explicit test

- [ ] **Step 8: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/genui/ test/features/ai/genui/ pubspec.yaml pubspec.lock
git commit -m "feat(ai): add A2UI catalog with metric entry and confirmation cards"
```

---

## Task 11: MetricChart and ExerciseVideo

The two read components the adopted Basic Catalog cannot supply — one because it has no chart primitive, one because its `Video` takes a URL and §5.5 forbids that. `ChoiceList` and `SummaryCard` were dropped from an earlier draft — `List` + `ChoicePicker` and `Card` + `Column` + `Text` already express them (spec §5.1).

**Files:**
- Create: `lib/features/ai/genui/widgets/metric_chart.dart`
- Create: `lib/features/ai/genui/widgets/exercise_video.dart`
- Test: `test/features/ai/genui/widgets/metric_chart_test.dart`
- Test: `test/features/ai/genui/widgets/exercise_video_test.dart`
- Modify: `lib/features/ai/genui/omni_catalog.dart` — register both as **read** components

**Interfaces:**
- Consumes: `fl_chart` and wger's existing `ExerciseVideoWidget` + `mediaUrlBuilderProvider` (all already present — add no packages)
- Produces: `MetricChart({required List<MetricPoint> series, required String unit, String? label})`; `MetricPoint({required DateTime date, required double value})`; `ExerciseVideo({required int videoId})`

Read-only. Not in `writeComponents`; mints no token; has no interactive control that could commit anything.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/genui/widgets/metric_chart_test.dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/genui/widgets/metric_chart.dart';

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  testWidgets('renders a label and unit', (tester) async {
    await tester.pumpWidget(_host(MetricChart(
      label: 'Weight',
      unit: 'kg',
      series: [
        MetricPoint(date: DateTime(2026, 8, 1), value: 83.0),
        MetricPoint(date: DateTime(2026, 8, 7), value: 82.4),
      ],
    )));

    expect(find.textContaining('Weight'), findsWidgets);
    expect(find.textContaining('kg'), findsWidgets);
  });

  testWidgets('an empty series renders an empty state, not an exception', (tester) async {
    await tester.pumpWidget(_host(const MetricChart(series: [], unit: 'kg')));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('No data'), findsOneWidget);
  });

  testWidgets('a single point renders without throwing', (tester) async {
    // A one-point series has zero range on both axes — a classic divide-by-zero
    // in chart libraries.
    await tester.pumpWidget(_host(MetricChart(
      unit: 'kg',
      series: [MetricPoint(date: DateTime(2026, 8, 7), value: 82.4)],
    )));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('a flat series renders without throwing', (tester) async {
    // Identical values means zero y-range; same failure mode as above.
    await tester.pumpWidget(_host(MetricChart(
      unit: 'kg',
      series: [
        MetricPoint(date: DateTime(2026, 8, 1), value: 82.0),
        MetricPoint(date: DateTime(2026, 8, 7), value: 82.0),
      ],
    )));
    await tester.pump();

    expect(tester.takeException(), isNull);
  });

  testWidgets('points are plotted in date order regardless of input order', (tester) async {
    final chart = MetricChart(
      unit: 'kg',
      series: [
        MetricPoint(date: DateTime(2026, 8, 7), value: 82.4),
        MetricPoint(date: DateTime(2026, 8, 1), value: 83.0),
      ],
    );
    await tester.pumpWidget(_host(chart));
    await tester.pump();

    expect(chart.sortedSeries.first.date, DateTime(2026, 8, 1));
    expect(tester.takeException(), isNull);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/genui/widgets/metric_chart_test.dart`
Expected: FAIL — `metric_chart.dart` does not exist

- [ ] **Step 3: Implement**

Use `fl_chart`'s `LineChart`. Expose `sortedSeries` as a getter so ordering is testable without reaching into the chart's internals. Guard the zero-range cases explicitly: when `series` is empty render an empty state; when min and max coincide on either axis, pad the range rather than passing a zero interval to `fl_chart`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/ai/genui/widgets/metric_chart_test.dart`
Expected: PASS (5 tests)

- [ ] **Step 5: Register MetricChart in the catalog**

Assert it resolves, and assert `writeComponents` still contains exactly `{MetricEntryCard, ConfirmationCard}` — adding a read component must not widen the write surface.

- [ ] **Step 6: Read wger's existing video widget**

Read `lib/features/exercises/widgets/videos.dart` and `lib/features/exercises/models/video.dart`. `ExerciseVideoWidget` already handles controller lifecycle, scrubbing, playback speed (0.25x / 0.5x / 1.0x), and the error state, and resolves media through `ref.read(mediaUrlBuilderProvider)`. **Wrap it; do not reimplement it.**

- [ ] **Step 7: Write the failing ExerciseVideo test**

The interface is the point of this component, so the tests assert the interface, not the pixels:

```dart
testWidgets('takes a video id — there is no URL parameter to pass', (tester) async {
  // Spec 5.5: if this component ever grows a url/src/host parameter, an agent
  // can exfiltrate health data in a query string with no user interaction.
  // This test is the tripwire for that regression.
  const widget = ExerciseVideo(videoId: 412);
  expect(widget.videoId, 412);
  expect(
    widget.toStringDeep(),
    isNot(anyOf(contains('http'), contains('url'), contains('src'))),
  );
});

testWidgets('an unknown video id renders a not-found state, not an exception', (tester) async {
  await tester.pumpWidget(_host(const ExerciseVideo(videoId: 999999)));
  await tester.pump();
  expect(tester.takeException(), isNull);
  expect(find.textContaining('not available'), findsOneWidget);
});

testWidgets('renders licence attribution whenever a video resolves', (tester) async {
  // Spec 5.6: wger's exercise media is CC BY-SA. Attribution is a licence
  // obligation and must not depend on the agent remembering to mention it.
  await tester.pumpWidget(_host(_withFakeVideo(
    const ExerciseVideo(videoId: 412),
    licenseTitle: 'CC BY-SA 4.0',
    licenseAuthor: 'Jane Doe',
  )));
  await tester.pump();

  expect(find.textContaining('CC BY-SA 4.0'), findsOneWidget);
  expect(find.textContaining('Jane Doe'), findsOneWidget);
});

testWidgets('attribution still renders when the author is null', (tester) async {
  // Video.licenseAuthor is nullable on the server.
  await tester.pumpWidget(_host(_withFakeVideo(
    const ExerciseVideo(videoId: 412),
    licenseTitle: 'CC BY-SA 4.0',
    licenseAuthor: null,
  )));
  await tester.pump();

  expect(tester.takeException(), isNull);
  expect(find.textContaining('CC BY-SA 4.0'), findsOneWidget);
});
```

Provide `_withFakeVideo` as a Riverpod `ProviderScope` override supplying a stub video lookup, so no network or database is touched.

- [ ] **Step 8: Implement ExerciseVideo and register it**

Look the video up by id, render `ExerciseVideoWidget` for the hit, and render attribution beneath it unconditionally. Register as a **read** component. Re-assert `writeComponents` is unchanged.

- [ ] **Step 9: Run all catalog tests, analyze, and commit**

Run: `flutter test test/features/ai/genui/`
Expected: PASS

```bash
flutter analyze
git add lib/features/ai/genui/ test/features/ai/genui/
git commit -m "feat(ai): add MetricChart and id-keyed ExerciseVideo components"
```

---

## Task 12: The render_ui tool

The bridge between the agent and the catalog, and the only place confirmation tokens are minted.

**Files:**
- Create: `lib/features/ai/genui/render_ui_tool.dart`
- Test: `test/features/ai/genui/render_ui_tool_test.dart`

**Interfaces:**
- Consumes: `Tool`, `ToolResult` (Task 6); `ConfirmationTokenService` (Task 5); `OmniCatalog` including `writeComponents` (Tasks 10–11)
- Produces: `RenderUiTool(tokenService, catalog, surfaceSink)`; `SurfaceRequest(component, props, completer)`

`render_ui` suspends until the user acts. Three rules, in order:

1. The root component must resolve in the catalog (Basic Catalog or OmniHealth's own), else error.
2. A token is minted **only** when the component is in `OmniCatalog.writeComponents` **and** an `intent` naming a tool and arguments was declared.
3. Dismissal mints nothing, ever.

Rule 2 is the executable form of spec §5.2: a `Button` from the Basic Catalog can declare whatever intent it likes and still gets no token, so the registry rejects the write. The security boundary is the registry; this rule is what keeps the honesty guarantee intact alongside it.

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/genui/render_ui_tool_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/genui/render_ui_tool.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';

void main() {
  late ConfirmationTokenService tokens;
  late List<SurfaceRequest> surfaced;
  late RenderUiTool tool;

  setUp(() {
    tokens = ConfirmationTokenService();
    surfaced = [];
    tool = RenderUiTool(
      tokenService: tokens,
      // Basic Catalog names plus OmniHealth's own.
      knownComponents: const {
        'Column', 'Row', 'Card', 'Text', 'Button', 'TextField', 'Slider',
        'MetricChart', 'ExerciseVideo', 'MetricEntryCard', 'ConfirmationCard',
      },
      writeComponents: const {'MetricEntryCard', 'ConfirmationCard'},
      surfaceSink: surfaced.add,
    );
  });

  test('is not a write tool — it only renders', () {
    expect(tool.isWrite, isFalse);
  });

  test('rejects a component outside the catalog', () async {
    final result = await tool.call({
      'component': 'ArbitraryHtml',
      'props': <String, dynamic>{},
    });
    expect(result.isError, isTrue);
    expect(result.message, contains('ArbitraryHtml'));
    expect(surfaced, isEmpty);
  });

  test('rejects the URL-taking Basic Catalog media components', () async {
    // Spec 5.5. These are excluded from the catalog precisely because
    // rendering one issues a GET to an agent-chosen host, with no tap and no
    // trace in the transcript. ExerciseVideo replaces Video, keyed by id.
    for (final banned in ['Image', 'Video', 'AudioPlayer']) {
      final result = await tool.call({
        'component': banned,
        'props': {'url': 'https://attacker.example/p.png?w=82.4'},
      });
      expect(result.isError, isTrue, reason: '$banned must not render');
      expect(surfaced, isEmpty, reason: '$banned must not reach a surface');
    }
  });

  test('accepts a Basic Catalog component', () async {
    final future = tool.call({
      'component': 'Card',
      'props': <String, dynamic>{},
    });
    await Future<void>.delayed(Duration.zero);
    surfaced.single.dismiss();
    expect((await future).isError, isFalse);
  });

  test('a Basic Catalog component mints no token even when it declares an intent', () async {
    // The case spec 5.2 exists to prevent: an agent putting a write intent on a
    // raw Button and labelling it however it likes.
    final future = tool.call({
      'component': 'Button',
      'props': {'text': 'Cancel'},
      'intent': {'tool': 'log_weight', 'arguments': {'value': 999.0}},
    });

    await Future<void>.delayed(Duration.zero);
    surfaced.single.complete({'tapped': true});

    final data = (await future).data as Map<String, dynamic>;
    expect(data['action'], 'submit');
    expect(data.containsKey('confirmationToken'), isFalse);
  });

  test('submitting returns values plus a token valid for the intended write', () async {
    final future = tool.call({
      'component': 'MetricEntryCard',
      'props': {'metric': 'weight', 'unit': 'kg'},
      'intent': {'tool': 'log_weight', 'arguments': {'value': 82.4, 'date': '2026-08-07'}},
    });

    await Future<void>.delayed(Duration.zero);
    expect(surfaced, hasLength(1));
    surfaced.single.complete({'value': 82.4, 'date': '2026-08-07'});

    final result = await future;
    expect(result.isError, isFalse);
    final data = result.data as Map<String, dynamic>;
    expect(data['action'], 'submit');

    // The token must actually validate for the declared write.
    expect(
      tokens.consume(
        token: data['confirmationToken'] as String,
        toolName: 'log_weight',
        arguments: {'value': 82.4, 'date': '2026-08-07'},
      ),
      TokenCheck.valid,
    );
  });

  test('dismissal returns no token at all', () async {
    final future = tool.call({
      'component': 'ConfirmationCard',
      'props': {'summary': 'Log 2 eggs?'},
      'intent': {'tool': 'log_nutrition_entry', 'arguments': {'id': 1}},
    });

    await Future<void>.delayed(Duration.zero);
    surfaced.single.dismiss();

    final result = await future;
    final data = result.data as Map<String, dynamic>;
    expect(data['action'], 'dismissed');
    expect(data.containsKey('confirmationToken'), isFalse);
  });

  test('a token is not minted when no intent is declared', () async {
    final future = tool.call({
      'component': 'MetricEntryCard',
      'props': {'metric': 'weight', 'unit': 'kg'},
    });

    await Future<void>.delayed(Duration.zero);
    surfaced.single.complete({'value': 82.4});

    final result = await future;
    final data = result.data as Map<String, dynamic>;
    expect(data['action'], 'submit');
    expect(data.containsKey('confirmationToken'), isFalse);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/genui/render_ui_tool_test.dart`
Expected: FAIL — `render_ui_tool.dart` does not exist

- [ ] **Step 3: Implement**

Key points: validate `component` against `knownComponents` before surfacing anything; hold a `Completer` per request; mint a token **only** on submit, **only** when `intent` names a tool and arguments, **and only** when the component is in `writeComponents`; never mint on dismissal.

Mint over the *resolved* argument values, not the declared template — spec §5.2's honesty guarantee requires the token to cover exactly what the user saw. If `intent.arguments` contains data-model paths, resolve them against the submitted values first, and use the resolved map for both the token and the returned payload.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/ai/genui/render_ui_tool_test.dart`
Expected: PASS (8 tests)

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/genui/ test/features/ai/genui/
git commit -m "feat(ai): add render_ui tool minting confirmation tokens on tap"
```

---

## Task 13: Provider settings screen

**Files:**
- Create: `lib/features/ai/settings/screens/ai_settings_screen.dart`
- Create: `lib/features/ai/settings/providers/ai_settings_notifier.dart`
- Test: `test/features/ai/settings/ai_settings_notifier_test.dart`
- Test: `test/features/ai/settings/ai_settings_screen_test.dart`

**Interfaces:**
- Consumes: `AiKeyStorage` (Task 4); `ProviderConfig`, `ProviderKind` (Task 2)
- Produces: `AiSettingsNotifier` with `addProvider(ProviderConfig, String apiKey)`, `removeProvider(String id)`, `selectProvider(String id)`; `AiSettingsScreen`

- [ ] **Step 1: Write failing notifier tests**

Assert: adding a provider persists its config and stores the key under the right namespace; removing a provider deletes both; selecting a provider persists the selection; the key is never present in any state object exposed to the UI (assert by serialising state and grepping for the key string).

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/features/ai/settings/`
Expected: FAIL — files do not exist

- [ ] **Step 3: Implement the notifier**

Use `@riverpod`, persist configs via `shared_preferences` (already a dependency), keys via `AiKeyStorage`. Then run:

```bash
dart run build_runner build --delete-conflicting-outputs
```

- [ ] **Step 4: Implement the screen**

Must include, as required by spec §6.3 and §6.4:
- A plain-language notice at key entry naming the provider the data will be sent to.
- The ACP section (desktop only) with **no** default binary path and **no** vendor named as recommended, plus a short notice that subscription credentials from any vendor are not supported.

- [ ] **Step 5: Write and run the screen widget test**

Assert: entering a key and saving calls through to storage; the egress notice is visible before a key can be saved; the ACP section is absent when the platform is mobile.

- [ ] **Step 6: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/settings/ test/features/ai/settings/
git commit -m "feat(ai): add provider and key configuration screen"
```

---

## Task 14: Chat screen

**Files:**
- Create: `lib/features/ai/chat/providers/chat_notifier.dart`
- Create: `lib/features/ai/chat/screens/chat_screen.dart`
- Test: `test/features/ai/chat/chat_notifier_test.dart`
- Test: `test/features/ai/chat/chat_screen_test.dart`

**Interfaces:**
- Consumes: `AgentBackend`, `AgentEvent` (Task 9); `RenderUiTool`, `SurfaceRequest` (Task 12); `OmniCatalog` (Tasks 10–11)
- Produces: `ChatNotifier` with `send(String)`, `cancel()`; `ChatScreen`

- [ ] **Step 1: Write failing notifier tests**

Using a fake `AgentBackend` that emits scripted `AgentEvent`s, assert: text events append to the transcript; a tool-started event shows an in-progress indicator; `AgentFailure` appends a visible, retriable system message rather than throwing; cancel stops the turn and leaves the transcript intact; a surfaced `SurfaceRequest` becomes an inline card in the transcript.

- [ ] **Step 2: Run tests to verify they fail**

Run: `flutter test test/features/ai/chat/`
Expected: FAIL — files do not exist

- [ ] **Step 3: Implement notifier and screen**

The screen renders the transcript with inline genui surfaces. Per spec §7, an unknown or malformed component renders a fallback "couldn't display this" card rather than crashing — add a widget test for exactly that.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/ai/chat/`
Expected: PASS

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/chat/ test/features/ai/chat/
git commit -m "feat(ai): add chat screen with inline generative UI surfaces"
```

---

## Task 15: Wire the module into the app

The only task permitted to modify files outside `lib/features/ai/`.

**Files:**
- Modify: `lib/main.dart` — one route registration for `ChatScreen` and one for `AiSettingsScreen`
- Modify: whichever navigation surface lists features (locate it by reading `lib/core/home_tabs_screen.dart` and `lib/core/dashboard.dart`)
- Create: `lib/features/ai/ai_module.dart` — single registration entry point
- Test: `test/features/ai/ai_module_test.dart`

**Interfaces:**
- Consumes: everything from Tasks 1–14
- Produces: `registerAiTools(ToolRegistry, Ref)` wiring all built-in tools plus `render_ui`

- [ ] **Step 1: Write the failing test**

```dart
// test/features/ai/ai_module_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:wger/features/ai/ai_module.dart';
import 'package:wger/features/ai/tools/confirmation_token.dart';
import 'package:wger/features/ai/tools/tool_registry.dart';

void main() {
  test('registers exactly the expected built-in tools', () {
    final registry = ToolRegistry(tokenService: ConfirmationTokenService());
    registerAiToolsForTest(registry);

    expect(
      registry.specs().map((s) => s.name).toSet(),
      {
        'get_weight_history',
        'log_weight',
        'get_nutrition_log',
        'search_ingredient',
        'log_nutrition_entry',
        'get_workout_log',
        'get_body_measurements',
        'search_exercises',
        'get_exercise_detail',
        'render_ui',
      },
    );
  });

  test('no tool description or schema leaks a media URL', () {
    // Spec 5.5: the agent must never learn a URL it could echo back into a
    // render request.
    final registry = ToolRegistry(tokenService: ConfirmationTokenService());
    registerAiToolsForTest(registry);

    for (final spec in registry.specs()) {
      final encoded = jsonEncode({'d': spec.description, 's': spec.inputSchema});
      expect(encoded, isNot(contains('http')), reason: '${spec.name} mentions a URL');
    }
  });

  test('every tool declares a non-empty description and an object schema', () {
    final registry = ToolRegistry(tokenService: ConfirmationTokenService());
    registerAiToolsForTest(registry);

    for (final spec in registry.specs()) {
      expect(spec.description, isNotEmpty, reason: '${spec.name} needs a description');
      expect(spec.inputSchema['type'], 'object', reason: '${spec.name} schema must be an object');
    }
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/ai_module_test.dart`
Expected: FAIL — `ai_module.dart` does not exist

- [ ] **Step 3: Implement the module registration**

- [ ] **Step 4: Add the routes and navigation entry**

Follow the pattern already used in `lib/main.dart` for existing feature screens. Keep the diff to these two additions.

- [ ] **Step 5: Run the full suite and build**

```bash
flutter analyze
flutter test
flutter build macos --debug
```
Expected: analyze clean, all tests pass, build succeeds

- [ ] **Step 6: Commit**

```bash
git add lib/ test/
git commit -m "feat(ai): register AI module and add chat and settings routes"
```

---

## Task 16: Acceptance test — the weight demo

The definition of done for the non-ACP portion of Slice 1.

**Files:**
- Create: `integration_test/ai_weight_flow_test.dart`
- Create: `test/features/ai/support/scripted_provider.dart` — shared fake, extracted from Task 9's test

**Interfaces:**
- Consumes: everything
- Produces: nothing — this is a verification task

- [ ] **Step 1: Extract the scripted provider into shared support**

Move `ScriptedProvider` from Task 9's test file into `test/features/ai/support/scripted_provider.dart` and import it from both places. Run `flutter test` to confirm nothing broke.

- [ ] **Step 2: Write the acceptance test**

Drive the full §6.1 flow against an in-memory Drift database and a scripted provider that requests `render_ui` then `log_weight`:

1. Pump the app to `ChatScreen`
2. Enter "I want to enter my weight for today" and send
3. Expect a `MetricEntryCard` to appear inline
4. Enter `82.4` and tap save
5. Expect the scripted provider's next turn to receive a `confirmationToken`
6. Expect a `WeightEntry` of 82.4 to exist in the local database
7. Expect a confirmation message in the transcript

- [ ] **Step 3: Add the negative acceptance test**

Same setup, but the scripted provider skips `render_ui` and calls `log_weight` directly with a fabricated token. Assert: no `WeightEntry` is written, and the transcript shows the agent being told to confirm first. **This test is the executable statement of the core invariant** — if it ever goes green while a write lands, the safety model is broken.

- [ ] **Step 4: Add the mislabelled-button acceptance test**

The end-to-end form of spec §5.2. The scripted provider renders a raw Basic Catalog `Button` labelled **Cancel**, carrying `intent: {tool: 'log_weight', arguments: {value: 999.0}}`. Tap it.

Assert: no token was minted, the `log_weight` call is rejected by the registry, **no `WeightEntry` of 999.0 exists in the database**, and the transcript shows the agent being told to render a confirmation.

Together with Step 3 this pins both halves of the safety model: Step 3 proves a fabricated token fails, and this proves the agent cannot obtain a real one by dressing a write up as something else.

- [ ] **Step 5: Run the acceptance tests**

Run: `flutter test integration_test/ai_weight_flow_test.dart`
Expected: PASS (3 tests)

- [ ] **Step 6: Commit**

```bash
git add integration_test/ test/features/ai/support/
git commit -m "test(ai): add weight-entry acceptance tests incl. both write-gate negatives"
```

---

## Task 17: MCP bridge (desktop only)

**Files:**
- Create: `lib/features/ai/mcp/mcp_bridge_server.dart`
- Test: `test/features/ai/mcp/mcp_bridge_server_test.dart`

**Interfaces:**
- Consumes: `ToolRegistry` (Task 6)
- Produces: `McpBridgeServer(registry)` with `Future<McpBridgeHandle> start()`, `Future<void> stop()`; `McpBridgeHandle(port, bearerToken)`

Exposes the same registry to an external ACP agent over loopback HTTP, so ACP tools and local tools are literally the same objects.

- [ ] **Step 1: Write the failing test**

Assert, with a real server on an ephemeral port:
- It binds `127.0.0.1` only — a connection to the machine's LAN address is refused
- A request without the bearer token gets 401 and does not reach the registry
- A request with a wrong bearer token gets 401
- A request with the correct token can list tools and receives the same names as `registry.specs()`
- A tool call through the bridge with a valid confirmation token executes exactly once
- `stop()` releases the port

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/mcp/mcp_bridge_server_test.dart`
Expected: FAIL — `mcp_bridge_server.dart` does not exist

- [ ] **Step 3: Implement**

Use `dart:io` `HttpServer.bind(InternetAddress.loopbackIPv4, 0)`. Generate a 32-byte `Random.secure()` bearer token per session. Reject any request whose `Authorization` header does not match, before any parsing.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/features/ai/mcp/mcp_bridge_server_test.dart`
Expected: PASS

- [ ] **Step 5: Analyze and commit**

```bash
flutter analyze
git add lib/features/ai/mcp/ test/features/ai/mcp/
git commit -m "feat(ai): add loopback MCP bridge with per-session bearer auth"
```

---

## Task 18: ACP agent backend (desktop only)

**Files:**
- Create: `lib/features/ai/agent/acp/acp_protocol.dart`
- Create: `lib/features/ai/agent/acp/acp_agent_backend.dart`
- Test: `test/features/ai/agent/acp/acp_protocol_test.dart`
- Test: `test/features/ai/agent/acp/acp_agent_backend_test.dart`
- Test fixture: `test/features/ai/agent/acp/fake_acp_agent.dart`

**Interfaces:**
- Consumes: `AgentBackend`, `AgentEvent` (Task 9); `McpBridgeServer` (Task 17)
- Produces: `AcpConnection(stdin, stdout)` with `Future<Map<String, dynamic>> request(String method, Map<String, dynamic> params)` and `Stream<Map<String, dynamic>> notifications`; `AcpAgentBackend({binaryPath, args, bridge})`

- [ ] **Step 1: Write the protocol test**

JSON-RPC 2.0 framing only — no process spawning. Assert: a request is encoded with `jsonrpc`, `id`, `method`, `params`; a response is matched to its request by id; out-of-order responses still resolve the right futures; a notification (no id) surfaces on the notification stream and never resolves a request; a JSON-RPC error response completes the future with an error; malformed JSON on the wire is logged and skipped without killing the connection.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/features/ai/agent/acp/acp_protocol_test.dart`
Expected: FAIL — `acp_protocol.dart` does not exist

- [ ] **Step 3: Implement the protocol layer**

- [ ] **Step 4: Write the fake ACP agent**

A small Dart script that reads JSON-RPC from stdin and writes scripted responses to stdout, supporting four modes selected by argument: `normal`, `crash-mid-turn`, `protocol-violation`, `hang`.

- [ ] **Step 5: Write the backend test**

Spawn the fake agent and assert: a normal session performs `initialize` then `session/new` then `session/prompt` and emits `AgentEvent`s; `session/new` is passed the MCP bridge URL and bearer token; a crash mid-turn produces a clear `AgentFailure` naming the cause and leaves no orphan process; a protocol violation disables the session rather than retrying; a hang is bounded by a timeout; **the advertised client capabilities include no filesystem and no terminal capability** — assert this explicitly, since it is what stops an ACP agent doing anything but health tools.

- [ ] **Step 6: Implement the backend**

Guard the whole surface behind `Platform.isMacOS || Platform.isWindows || Platform.isLinux`. Spawn via `Process.start`; always reap the subprocess in `dispose()`.

- [ ] **Step 7: Run tests to verify they pass**

Run: `flutter test test/features/ai/agent/acp/`
Expected: PASS

- [ ] **Step 8: Full verification**

```bash
flutter analyze
flutter test
flutter build macos --debug
```

- [ ] **Step 9: Commit**

```bash
git add lib/features/ai/agent/acp/ test/features/ai/agent/acp/
git commit -m "feat(ai): add desktop ACP agent backend over JSON-RPC stdio"
```

---

## Self-Review

**Spec coverage.** §3 architecture → Tasks 1–18 file structure. §3.1 two-backend split → Tasks 9, 18. §4.1 providers → Tasks 1–3. §4.2 key store → Task 4. §4.3 tool registry → Tasks 6–8. §4.4 agent loop → Task 9. §4.5 A2UI surface → Tasks 10–12. §4.6 MCP bridge → Task 17. §4.7 ACP backend → Task 18. §5.1 catalog composition → Tasks 10–11. §5.2 write rule and honesty guarantee → Task 10 step 7 (`writeComponents`), Task 12 rule 2, Task 16 step 4. §5.3 render_ui and the suspend-and-return deviation → Task 12. §5.4 data binding → Task 12 step 3 (resolving paths before minting). §5.5 no agent-supplied URLs → Task 8 step 7 (tools return ids, tested), Task 11 steps 6–8 (`ExerciseVideo` keyed by id, tested), Task 12 (media components rejected, tested), Task 15 (no tool schema mentions a URL, tested). §5.6 CC attribution → Task 11 step 7, two tests including the null-author case. §6.1 reference flow → Task 16. §6.2 confirmation tokens → Tasks 5, 6, 12, 16 step 3. §6.3 egress notice → Task 13 step 4. §6.4 ACP policy → Task 13 step 4, Task 3 doc comment. §7 error handling → Task 2 (provider errors), Task 6 (tool errors), Task 14 step 3 (malformed A2UI), Tasks 9 and 18 (cancellation, subprocess failure). §8 testing → every task.

**Known gaps, deliberate.** Spec §7's "in-flight tool calls complete or roll back" is only partially covered: Task 9 tests that cancellation stops the loop, but rollback of a partially-applied write is not implemented, because every Slice 1 write is a single Drift insert and therefore already atomic. Revisit when a tool performs multiple writes.

**Type consistency.** `ToolResult.ok/error` and `isError` are used identically in Tasks 6–8, 12, 17. `AgentEvent` variants are named identically in Tasks 9, 14, 18. `ProviderConfig` fields match between Tasks 2, 3, 13. `ConfirmationTokenService.mint/consume` signatures match between Tasks 5, 6, 12. `Tool.isWrite` is declared in Task 6 and implemented in every tool in Tasks 7, 8, 12.

**Two known-unknowns**, both handled by reading the installed package before writing code rather than by guessing: genui's exact `Catalog`/`CatalogItem` construction (Task 10 step 1) and `json_schema_builder`'s validation API (Task 6 step 5).
