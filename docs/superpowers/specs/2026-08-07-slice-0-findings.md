# Slice 0 — Fork Evaluation Spike: Findings

**Date:** 2026-08-07
**Spec:** [2026-08-07-omnihealth-ai-spine-design.md](2026-08-07-omnihealth-ai-spine-design.md) §2
**Subject:** [wger-project/flutter](https://github.com/wger-project/flutter) @ `master`, shallow clone (depth 50)

**Verdict: fork is viable and the design holds.** One material correction to the spec (§3 below) and
several simplifications. No blocking problems found.

---

## Environment

| Tool | Version |
|---|---|
| Flutter | 3.44.7 (stable) |
| Dart | 3.12.2 |
| Xcode | 26.6 (17F113) |
| Docker | 29.6.2 |

wger's `pubspec.yaml` requires Dart `>=3.10.0 <4.0.0`. The local toolchain satisfies it.
`flutter pub get` succeeded with no resolution conflicts.

---

## 1. Does `flutter/genui` core accept a non-Gemini provider?

**Yes. Resolved — we do not write an A2UI renderer.**

This was the largest risk in the spec. The `genui` package is backend-agnostic. The seam is
`A2uiTransportAdapter`, which takes an `onSend` callback and accepts streamed model output via
`addChunk()`:

```dart
final adapter = A2uiTransportAdapter(onSend: (message) async {
  // send to any provider
});
await for (final chunk in providerStream) {
  adapter.addChunk(chunk.text ?? '');
}
```

Any provider that streams text works. The Firebase AI and A2A/WebSocket paths are optional
built-ins, not requirements.

**Classes we build against:** `Conversation` (interaction loop facade), `SurfaceController`
(surface lifecycle), `Catalog` / `CatalogItem` (the approved component set), `DataModel`
(observable UI state), `Surface` (renders a surface by id), `A2uiTransportAdapter`.

**Transitive dependencies of note:** `a2ui_core`, `genai_primitives`, `json_schema_builder`. The
last is directly reusable for tool `inputSchema` definitions, so we do not need a separate
JSON Schema library.

**Consequence:** spec §2.3's fallback ("implement a minimal A2UI renderer ourselves") is not needed.

---

## 2. Does wger/flutter build, and what are its conventions?

### Architecture — feature-first, which the spec's module boundary already matches

```
lib/
├── core/           app-wide: network, widgets, formatting, exceptions
│   └── network/    auth, http client, secure token storage, base provider
├── database/       drift schema
│   └── powersync/  tables/ — the synced schema
├── features/       account, auth, exercises, gallery, measurements,
│                   nutrition, routines, trophies, weight
├── l10n/           translations
├── powersync/      sync engine wiring + api_client
└── theme/
```

379 Dart files. Each feature follows `<feature>/{models,providers,screens,widgets}/`, where
`providers/` holds both Riverpod notifiers and repositories.

**`lib/features/ai/` fits this convention exactly** — the spec's module boundary requires no
deviation from house style.

### Stack

| Concern | What they use |
|---|---|
| State management | `flutter_riverpod` ^3.3.2 with `riverpod_annotation` / `riverpod_generator` codegen (`*_notifier.g.dart`) |
| Dependency injection | Riverpod itself — no separate DI package |
| Local database | `drift` + `drift_sqlite_async` |
| Sync | `powersync` |
| HTTP | `http` ^1.6.0 |
| Secure storage | `flutter_secure_storage` ^10.3.1 |
| Charts | `fl_chart` |
| Barcode scanning | `flutter_zxing` |
| Immutable models | `freezed_annotation`, `json_annotation` |

### Conventions to follow

- **Every file carries the AGPL header block.** New files must too.
- Repositories are plain classes exposed via a Riverpod `Provider`; notifiers are
  `@riverpod final class X extends _$X` with a generated part file.
- Interfaces use `abstract interface class`, with the platform implementation separate and a
  Riverpod provider binding them — see `core/network/secure_token_storage.dart`. This is the exact
  pattern for our key store.

### Dependencies we get for free

Four spec components need no new dependency:

- **Key store** — `flutter_secure_storage` is already present, and `SecureTokenStorage` is a
  ready-made pattern to mirror.
- **`MetricChart`** — `fl_chart` is already present.
- **Tool `inputSchema`** — `json_schema_builder` arrives transitively with genui.
- **Barcode scanning** (future slices) — `flutter_zxing` is already present.

### Build status

See §5.

---

## 3. Is wger's REST API sufficient for the built-in tools?

**The question was wrong, and the real answer is better. This is a material correction to spec §4.3.**

wger's Flutter app is **local-first**. Feature repositories do not POST to the REST API — they write
to the local Drift database, and PowerSync replicates to the server. From
`features/weight/providers/body_weight_repository.dart`:

```dart
Future<void> addLocalDrift(WeightEntry entry) async {
  await _db.into(_db.weightEntryTable).insert(entry.toCompanion());
}
Stream<List<WeightEntry>> watchAllDrift() { ... }
```

Only a handful of files still perform REST writes (`auth_notifier`, `base_provider`,
`account_repository`, `add_exercise_repository`, `routines_repository`, `powersync/api_client`) —
authentication and server-authoritative catalog operations.

**Every domain slice 1 needs is PowerSync-backed.** Confirmed Drift tables include
`WeightEntryTable`, `LogItemTable`, `MealTable`, `MealItemTable`, `NutritionalPlanTable`,
`MeasurementEntryTable`, `MeasurementCategoryTable`, `WorkoutLogTable`, `WorkoutSessionTable`,
`RoutineTable`, `IngredientTable`.

### Correction to §4.3

Tools must call the **existing repositories**, not raw HTTP. Revised mapping:

| Tool | Calls |
|---|---|
| `get_weight_history` | `BodyWeightRepository.watchAllDrift()` |
| `log_weight` | `WeightEntryNotifier.addEntry(...)` |
| `get_nutrition_log` | `NutritionRepository.watchAllLogsHydrated()` |
| `search_ingredient` | `IngredientRepository.search(...)` |
| `log_nutrition_entry` | `NutritionRepository.addLogLocalDrift(...)` |
| `get_workout_log` | `WorkoutLogsRepository` |
| `get_body_measurements` | `MeasurementRepository` |
| `render_ui` | none — genui surface |

`IngredientRepository` is especially convenient: `search()` already picks server or local transport
automatically, and `searchIngredientByBarcode()` exists for later slices.

### Why this is better than what was specced

1. **Tools work offline.** Spec §7 said chat degrades to unavailable offline. Only the *provider
   call* needs network now; every read and write tool works against local Drift.
2. **Writes are reactive for free.** Repositories expose Drift streams, so when the agent logs a
   weight the weight screen updates live with no extra wiring.
3. **No REST plumbing in the tool layer at all.** Tools become thin adapters over methods that
   already exist and are already tested.
4. **Sync, conflict handling, and retry are inherited** from PowerSync rather than reimplemented.

---

## 4. Recommendation

Proceed with the fork as designed. Amend the spec:

- **§4.3** — replace the endpoint table with the repository mapping above.
- **§7** — offline row: tools remain fully functional offline; only the provider call fails.
- **§2.3** — drop the "write our own A2UI renderer" fallback; it is not needed.
- **§4.2** — note that `flutter_secure_storage` is already a dependency and that
  `SecureTokenStorage` is the pattern to mirror.

No change is needed to the module boundary, the two-backend split, the MCP-shaped tool interface,
or the confirmation-token invariant.

---

## 5. Build results

| Check | Result |
|---|---|
| `flutter pub get` | Clean, no resolution conflicts |
| `flutter analyze` | **No issues found** (11.3s) — a zero-issue baseline to preserve |
| `flutter build macos --debug` | **Success** — `✓ Built build/macos/Build/Products/Debug/wger.app` |
| `flutter build ios --debug --simulator` | **Success** (60.4s) — `✓ Built build/ios/iphonesimulator/Runner.app` |
| Android | **Not verified** — Android toolchain is not installed on this host |
| Windows | **Not verified** — cannot be built from macOS |

The only build noise is deprecation warnings from a transitive AVFoundation dependency
(`AVKeyValueStatus`, deprecated in macOS 13) and an Xcode run-script phase lacking declared
outputs. Neither is an error and neither originates in wger's own code.

**Zero analyzer issues is the baseline.** Every task in the implementation plan runs
`flutter analyze` before committing so this does not silently rot.

### Unverified platforms

Two of the four target platforms could not be checked from this machine. Neither is believed to be
at risk — wger ships to both, and this repository contains `android/` and `windows/` runner
projects — but the claim is untested here. To close the gap:

- **Android** — install the Android SDK and command-line tools, accept licenses, then
  `flutter build apk --debug`.
- **Windows** — requires a Windows host with Visual Studio and the Desktop development with C++
  workload, then `flutter build windows --debug`.
