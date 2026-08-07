# OmniHealth — Slice 0+1: Fork Spike and AI Spine

**Date:** 2026-08-07
**Status:** Approved design, ready for implementation planning
**Scope:** Slice 0 (fork evaluation spike) and Slice 1 (multi-provider agent + A2UI generative UI)

---

## 1. Context

OmniHealth is an open-source, AGPL-licensed cross-platform health application: a fork of
[wger-project/flutter](https://github.com/wger-project/flutter) with an AI agent layer added as an
isolated, upstreamable feature module. It targets iOS, Android, macOS, and Windows.

The long-term goal is MyFitnessPal-class tracking breadth plus an AI assistant that can read and
write the user's health data through generative UI, backed by a plugin system, a memory system,
clinical terminology, EHR import, and drug interaction checking.

This document specifies only the first two slices. Later slices get their own specs.

### 1.1 Decisions already made

These were settled during design and are treated as fixed constraints below.

| Decision | Choice | Rationale |
|---|---|---|
| Project type | Open-source community project, AGPL-3.0+ | wger is AGPL; forking is only viable if we embrace it. Removes licensing as a blocker. |
| AI funding model | Bring-your-own-key only | Zero inference cost to the project, no billing infrastructure, no per-user cost ceiling. |
| Agent location | On-device, in Flutter/Dart | The user's API key never leaves the device. Enables use against *any* wger instance, including public wger.de, without trusting the operator with AI conversations or credentials. |
| Relationship to wger | Fork `wger-project/flutter`; AI as an isolated module; **stock** wger server | Inherits tracking UI, translations, and the AGPL app-store exception. Keeps upstream merges cheap. Requires zero Django changes in Slice 1. |
| Tool substrate | MCP-shaped internal interface; remote MCP for future plugins | Gets MCP ecosystem compatibility without paying for MCP transport plumbing on built-in tools. Makes the ACP bridge and future Hermes integration thin adapters. |
| ACP | In scope for Slice 1, desktop-only | User priority. Delivered as a second *agent backend*, not a provider. |

### 1.2 Corrections to initial assumptions

Recorded because they shaped the design and should not be re-litigated later.

- **Claude via ACP does not unlock subscription billing.** Anthropic restricted Claude Free/Pro/Max
  OAuth tokens to first-party products in February–March 2026, with server-side enforcement. Routing
  third-party users' subscription credentials would risk *their* accounts. The supported paths are a
  user-supplied Console API key, Bedrock, or Vertex. See §6.4 for the resulting policy.
- **ACP cannot be the primary transport.** ACP is JSON-RPC 2.0 over stdio, where the client spawns
  the agent as a local subprocess. iOS and Android do not permit arbitrary subprocess spawning, so
  ACP is inherently desktop-only.
- **A2UI is a good fit and is well-supported on Flutter.** Google's A2UI v0.9 (Apache 2.0) is
  declarative and catalog-bound: the agent may only request components the client has pre-approved,
  and cannot ship executable code. Flutter has a first-party path via
  [`flutter/genui`](https://github.com/flutter/genui).
- **The obvious drug-interaction API is dead.** NLM retired the RxNav drug-drug interaction endpoint
  in January 2024; DrugBank retires its free checker in March 2026. RxNorm normalization survives.
  This is a Slice 5 problem and is called out here only so it is not discovered late.

---

## 2. Slice 0 — Fork evaluation spike

A timeboxed investigation (target: one week) whose deliverable is **written findings and a
recommendation**, not a feature. Slice 1's design bends around the answers.

### 2.1 Questions to answer

1. **Does `flutter/genui` core accept a non-Gemini provider?** genui was built Gemini/Firebase-first.
   The `genui_a2ui` package targets a *server-side* agent over WebSocket, which our on-device
   architecture rules out. If genui core cannot be driven by an arbitrary local provider, we render
   A2UI documents ourselves against the published v0.9 schema.
2. **Does `wger-project/flutter` build clean on iOS, Android, macOS, and Windows?** Record Flutter
   and Dart SDK versions, per-platform build failures, and the effort to fix each. Identify the
   state management approach in use, and the dependency-injection seam where a feature module
   registers itself.
3. **Is wger's REST API sufficient for the built-in tools in §4.3?** For each planned tool, confirm
   an endpoint exists with adequate filtering and write support. Any gap that would force Django
   changes must surface now, not mid-implementation.

### 2.2 Exit criteria

A findings document committed to `docs/superpowers/specs/2026-08-07-slice-0-findings.md`, stating
for each question what was observed and what it implies. Slice 1 does not begin until this exists.

### 2.3 Fallback positions

- ~~If genui core is unusable: implement a minimal A2UI renderer ourselves.~~ **Not needed.** The
  spike confirmed genui is backend-agnostic via `A2uiTransportAdapter`; see findings §1.
- If a platform fails to build: proceed on the platforms that work; record the failure and treat the
  fix as separate work. macOS is the priority development target.
- If REST gaps exist: implement the tools that are possible, document the gaps, and schedule a
  server-side slice earlier than planned.

---

## 3. Slice 1 architecture

All new code lives under `lib/features/ai/`. Outside that directory, only two changes are permitted:
a navigation entry point and a dependency-injection registration. This boundary is what makes the
module offerable upstream to wger and keeps merges from upstream cheap.

```
OmniHealth  (fork of wger-project/flutter)
│
│  existing wger app — workouts, nutrition, weight, measurements, i18n
│
└── lib/features/ai/
      │
      ├── chat/          conversation UI, turn history
      ├── agent/         AgentBackend interface + two implementations
      │     ├── local/   our Dart loop, driving an LlmProvider
      │     └── acp/     ACP client (desktop only)
      ├── providers/     LlmProvider interface + OpenAI-compat, Anthropic
      ├── tools/         MCP-shaped registry + built-in wger tools
      ├── genui/         A2UI catalog + renderer
      ├── credentials/   secure key storage
      └── mcp/           localhost MCP bridge (exposes tools to ACP agents)
                │
                ↓
        existing wger REST client
                │
                ↓  HTTPS
        stock wger server (Docker, unmodified)
```

### 3.1 The two-backend split

ACP does not belong beside the model providers. An ACP agent is a *complete agent* that runs its own
tool-calling loop; a chat-completions endpoint is not. Conflating them produces a leaky interface.
The split is therefore at the level above:

```
AgentBackend  (interface)
├── LocalAgentBackend   we own the loop; drives an LlmProvider
│                       └── LlmProvider: OpenAiCompatProvider | AnthropicProvider
└── AcpAgentBackend     desktop only; external process owns the loop; we are the ACP client
```

Both backends consume the same `ToolRegistry` and both render A2UI through the same catalog. The
user picks a backend in settings; the chat UI is identical either way.

---

## 4. Components

Five core units (§4.1–§4.5), plus the MCP bridge and ACP backend that exist only on desktop
(§4.6–§4.7). Each is independently testable and has a single responsibility.

### 4.1 Provider layer — `lib/features/ai/providers/`

```dart
abstract class LlmProvider {
  String get id;
  Stream<LlmEvent> stream({
    required List<Message> messages,
    required List<ToolSpec> tools,
    CancellationToken? cancel,
  });
}
```

`LlmEvent` is a sealed type: `TextDelta`, `ToolCallRequested`, `TurnComplete`, `ProviderError`.

Two implementations:

- **`OpenAiCompatProvider`** — covers OpenAI, Grok, Kimi, and GLM. These differ only by base URL,
  model identifier, and auth header format. Configuration is data, not code; adding DeepSeek or a
  local Ollama endpoint later is a config entry.
- **`AnthropicProvider`** — Anthropic's Messages API differs enough in request shape, tool-call
  encoding, and streaming events to warrant its own adapter.

Provider configuration is a persisted record of `{displayName, kind, baseUrl, modelId, keyRef}`.
The key itself is never stored in this record — only a reference into the key store.

### 4.2 Key store — `lib/features/ai/credentials/`

A thin wrapper over `flutter_secure_storage`, backed by iOS/macOS Keychain, Android Keystore, and
Windows DPAPI. The package is **already a wger dependency** (^10.3.1), and
`core/network/secure_token_storage.dart` is the house pattern to mirror: an `abstract interface
class`, a separate platform implementation, and a Riverpod `Provider` binding them.

Invariants, each with a corresponding test:

- Keys are never written to logs, chat transcripts, crash reports, or analytics.
- Keys are never included in a `toString()`, `toJson()`, or debug representation of any object.
- Reading a key requires an explicit call; no ambient/global access.

### 4.3 Tool registry — `lib/features/ai/tools/`

MCP-shaped, so the bridge in §4.6 and future remote plugins are thin adapters:

```dart
abstract class Tool {
  String get name;
  String get description;
  Map<String, dynamic> get inputSchema;   // JSON Schema
  Future<ToolResult> call(Map<String, dynamic> args);
}
```

The registry is the **only** surface an agent can invoke. Built-in tools for Slice 1:

| Tool | Operation | Backed by |
|---|---|---|
| `get_weight_history` | read | `BodyWeightRepository.watchAllDrift()` |
| `log_weight` | write | `WeightEntryNotifier.addEntry(...)` |
| `get_nutrition_log` | read | `NutritionRepository.watchAllLogsHydrated()` |
| `search_ingredient` | read | `IngredientRepository.search(...)` |
| `log_nutrition_entry` | write | `NutritionRepository.addLogLocalDrift(...)` |
| `get_workout_log` | read | `WorkoutLogsRepository` |
| `get_body_measurements` | read | `MeasurementRepository` |
| `render_ui` | UI | none — see §5.2 |

**Tools call wger's existing repositories, not its REST API.** The Slice 0 spike established that
wger's Flutter app is local-first: feature repositories write to a local Drift database and
PowerSync replicates to the server. Every domain Slice 1 touches is PowerSync-backed. Three
consequences follow: tools work offline, writes are reactive (logging a weight updates the weight
screen live through its existing Drift stream), and the tool layer carries no HTTP plumbing.

See [2026-08-07-slice-0-findings.md](2026-08-07-slice-0-findings.md) §3.

All arguments are validated against `inputSchema` before `call()` executes. A schema violation
returns a `ToolResult.error` describing the violation — it does not throw, because the error is
routed back to the model as a tool result so it can correct itself.

### 4.4 Agent loop — `lib/features/ai/agent/local/`

Provider-agnostic and widget-agnostic. It knows nothing about HTTP or Flutter.

Responsibilities: assemble the message list and tool specs, call the provider, stream text to the
UI, dispatch tool calls to the registry, feed results back, and repeat until the turn completes.
It owns turn state and cancellation.

A hard iteration cap (default 12 tool round-trips per turn) prevents runaway loops; exceeding it
ends the turn with a visible message rather than silently stopping.

### 4.5 A2UI surface — `lib/features/ai/genui/`

Holds the component catalog (§5) and the renderer. The renderer maps an A2UI document onto Flutter
widgets drawn from the catalog and nothing else. Unknown component types render a fallback card.

### 4.6 MCP bridge — `lib/features/ai/mcp/`

Desktop only. Exposes the `ToolRegistry` as an MCP server bound to `127.0.0.1` on an ephemeral port,
so an external ACP agent can reach the same tools the local loop uses.

- Bound to loopback only; never to `0.0.0.0`.
- A per-session bearer token is generated at spawn and passed to the agent; requests without it are
  rejected. This prevents other local processes from driving the user's health data.
- The server's lifetime is scoped to the ACP session; it is torn down when the session ends.

### 4.7 ACP backend — `lib/features/ai/agent/acp/`

Desktop only (`Platform.isMacOS || Platform.isWindows || Platform.isLinux`). Hidden entirely in the
UI on mobile.

OmniHealth acts as the ACP **client**: it spawns a user-configured agent binary as a subprocess and
speaks JSON-RPC 2.0 over stdio. It performs `initialize`, then `session/new` — passing the §4.6 MCP
server so the agent gains the wger tools — then `session/prompt` per turn, consuming `session/update`
notifications and mapping them onto the same UI events the local backend emits.

Capabilities we advertise are deliberately minimal. OmniHealth is not an editor: we do **not** grant
filesystem or terminal capabilities. An ACP agent connected to OmniHealth can use the health tools
and nothing else.

Configuration is entirely user-supplied: binary path plus arguments. The app ships **no** default
pointing at any specific vendor's agent (see §6.4).

---

## 5. The v1 component catalog

### 5.1 Components

| Component | Purpose |
|---|---|
| `MetricEntryCard` | One numeric value with unit and date. Serves weight, body fat, blood pressure, and any future scalar metric. |
| `ConfirmationCard` | Approve-before-write. "Log 2 eggs, 140 kcal?" with explicit accept/reject. |
| `MetricChart` | Trend line over a returned series. |
| `ChoiceList` | Disambiguation. "Which of these four ingredients did you mean?" |
| `SummaryCard` | Read-only formatted text plus key/value rows. |

Deliberately excluded from v1: any free-form component, anything that renders agent-supplied markup
or HTML as UI, and anything capable of triggering a write without a user tap.

### 5.2 How A2UI is delivered

A2UI documents arrive as a **tool call** — `render_ui` — in both backends. This is the design's main
simplification: it makes generative UI work identically whether the local Dart loop or an external
ACP agent produced it, and requires no special content-block handling in the ACP path.

`render_ui` accepts an A2UI document, renders it, and **suspends until the user acts**. The user's
interaction (submitted values, or a dismissal) becomes the tool result returned to the agent.

---

## 6. Data flow and safety

### 6.1 The reference flow

1. User types *"I want to enter my weight for today"*.
2. Backend sends the message plus tool specs to the provider (or to the ACP agent).
3. Agent calls `render_ui` with an A2UI document requesting
   `MetricEntryCard{metric: weight, unit: kg, date: today}`.
4. Renderer draws a native Flutter card inline in the chat.
5. User enters `82.4` and taps **Save**.
6. `render_ui` returns
   `{action: "submit", values: {value: 82.4, unit: "kg", date: "2026-08-07"}, confirmationToken: "<single-use>"}`.
   The token is minted by the renderer at the moment of the tap (§6.2).
7. Agent calls `log_weight` with those values and the token.
8. Registry executes `POST /api/v2/weightentry/`.
9. Result returns to the agent, which confirms in text. The card collapses to a receipt.

### 6.2 The core invariant

> **The agent proposes UI; only a human tap produces a mutation.**

No path from model output reaches a write without an intervening user interaction. Concretely:

- Every write-capable tool (`log_weight`, `log_nutrition_entry`, …) requires a
  `confirmationToken` argument.
- Tokens are minted **only** by the renderer, **only** in response to a user tap, and are
  single-use, bound to one tool name and one argument set, and expire after 5 minutes.
- A write tool called without a valid token returns an error instructing the agent to render a
  confirmation first.

This is enforced in the registry, not in prompts. Prompt-level instructions are not a security
boundary; the token check is.

### 6.3 Data egress

The user's health data is sent to whichever provider they configured — that is the point of the
feature, and it must be stated plainly in the UI at key-entry time, naming the provider. Slice 1
sends only what a turn requires: the conversation and tool results, never a bulk export.

### 6.4 ACP and Anthropic's terms

Documented in the repository and surfaced in the ACP configuration screen:

- OmniHealth ships **no** default ACP agent configuration and names no vendor as a recommended
  target. The user supplies a binary path.
- Documentation must **not** present ACP as a way to use a Claude Free/Pro/Max subscription with
  OmniHealth. Anthropic restricts subscription OAuth to first-party products and enforces this
  server-side; presenting it as a feature would put users' accounts at risk.
- The supported Anthropic path is a Console API key via `AnthropicProvider`.

---

## 7. Error handling

| Class | Behavior |
|---|---|
| **Provider errors** — invalid key, rate limit, model refusal, network failure | Surfaced in chat as a system message with a retry affordance. Never silently swallowed. Auth failures link to the key settings screen. |
| **Tool errors** — wger 4xx/5xx, offline, schema violation | Returned *to the agent* as a `ToolResult.error` so it can explain or retry, and shown to the user. A failed write never appears as success. |
| **Malformed A2UI** — unknown component, schema violation, missing required field | Renders a fallback "couldn't display this" card. Raw document logged in debug builds only. The chat never crashes. |
| **Cancellation** | Every turn is cancellable mid-stream. In-flight tool calls either complete or roll back; a cancelled turn never leaves a half-write. |
| **ACP subprocess failure** — binary missing, crash, protocol violation, hang | Session ends with a clear message naming the cause. The subprocess is reaped; no orphans. A protocol violation disables the session rather than retrying blindly. |

Offline behavior: only the *provider call* requires network. Because tools run against local Drift
(§4.3), every read and write tool remains fully functional offline — a queued turn replays cleanly
once connectivity returns. All existing wger tracking continues to work exactly as it does upstream.

---

## 8. Testing

**No test may make a live LLM API call.** A test asserts that no test process reads a real API key
from the environment; this is itself part of the suite.

| Unit | Approach |
|---|---|
| Provider adapters | Golden tests against recorded response fixtures per provider, covering streaming text, tool calls, and error envelopes. |
| Key store | Assertions that keys never appear in logs, serialized objects, or debug output. |
| Tool registry | Each tool against a mock wger server. Schema-validation tests for malformed arguments. Confirmation-token tests: missing, expired, reused, and mismatched-argument tokens must all fail. |
| Agent loop | Driven by a fake provider emitting scripted event sequences: single tool call, parallel calls, malformed response, mid-stream cancel, iteration-cap exceeded. |
| A2UI renderer | Widget and golden tests per catalog component, plus explicit unknown-component and malformed-document cases. |
| MCP bridge | Tests that it binds loopback only, and rejects requests with absent, wrong, or expired tokens. |
| ACP backend | Tests against a fake ACP agent process: normal session, crash mid-turn, protocol violation, hang, and non-zero exit. |
| **Acceptance** | The §6.1 flow end to end against a Dockerized stock wger with a scripted provider. This is the definition of done for Slice 1. |

---

## 9. Out of scope for Slice 1

Health memory system · plugin system and Withings · Apple Health / Google Health Connect ·
MyChart / FHIR import-export · SNOMED CT via Hermes · drug and supplement interaction checking ·
proactive or background AI · voice input · barcode and photo food logging beyond what wger already
provides · any Django server modification.

---

## 10. Roadmap context

Slice 1 is the second of six. Later slices each get their own spec.

| Slice | Contents |
|---|---|
| 0 | Fork evaluation spike *(this document)* |
| 1 | AI spine — providers, ACP, tools, A2UI *(this document)* |
| 2 | Health memory system |
| 3 | Plugin system, with Withings as the first plugin |
| 4 | Health data import — HealthKit / Health Connect first, then FHIR / MyChart |
| 5 | Clinical layer — SNOMED CT via Hermes, drug and supplement interactions, safety eval harness |

Slice 5 carries the project's real regulatory exposure: a consumer-facing drug-interaction checker
combined with LLM health advice may constitute FDA-regulated clinical decision support software.
It is sequenced last deliberately, and requires its own risk analysis before design begins.
