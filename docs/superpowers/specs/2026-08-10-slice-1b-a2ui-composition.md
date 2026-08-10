# Slice 1b — A2UI Composition

**Date:** 2026-08-10
**Status:** Specified, not started
**Depends on:** Slice 1 (complete — 258 tests)

## The gap

`render_ui` takes **one component plus props**:

```json
{"component": "MetricEntryCard", "props": {"metric": "weight", "unit": "kg"}}
```

That cannot express a tree. A2UI's actual model is a flat **adjacency list** where
structure emerges from id references:

```json
{"components": [
  {"id": "root", "component": "Column", "children": ["title", "field"]},
  {"id": "title", "component": "Text", "text": "Morning check-in"},
  {"id": "field", "component": "TextField", "label": "Weight"}
]}
```

Spec §5.1's design — *primitives gather, our components commit* — assumes the
second form. With the first, the agent can render `MetricEntryCard` but not a
three-field morning check-in built from `Column` + `TextField` + `Slider`, which
was the whole argument for adopting the Basic Catalog.

**Current behaviour:** the chat renders OmniHealth's four components directly and
shows a visible "Couldn't display this" card for anything else. The weight demo
works. A composed form does not.

## What was already established

The genui 0.10.1 API needed for this is known; no further investigation required.

| Piece | Signature |
|---|---|
| Controller | `SurfaceController({required List<Catalog> catalogs, Duration pendingUpdateTimeout})` |
| Feed it | `void handleMessage(core.A2uiMessage message)` — it implements `A2uiMessageSink` |
| Get a surface | `SurfaceContext contextFor(String surfaceId)` |
| Render it | `Surface({required SurfaceContext surfaceContext, WidgetBuilder? defaultBuilder, ActionDelegate actionDelegate})` |
| User actions out | `Stream<ChatMessage> get onSubmit`, and `void handleUiEvent(UiEvent event)` |

Two constraints found by reading the implementation:

- **`Surface` requires a component with id `root`.** A document without one logs a
  warning and renders `SizedBox.shrink()` — an invisible failure, so validate for
  `root` before handing anything over and fall back visibly if it is missing.
- Message order is `createSurface` → `updateComponents` → `updateDataModel` →
  `beginRendering`, per the A2UI spec.

## Design

### `render_ui` takes a document

```json
{
  "surface": {
    "components": [ ...adjacency list... ]
  },
  "intent": {"tool": "log_weight", "arguments": {...}}
}
```

The existing single-component form should keep working — it is the common case
and is what every current test exercises. Accept both: when `component` is
present, wrap it into a one-element document with id `root`.

### Token minting has to change, and this is the delicate part

Today the rule is *"the root component is in `writeComponents`"*. In a document,
the committing control is somewhere **inside** the tree — a `ConfirmationCard`
nested in a `Column`.

The rule becomes: **a token is minted only if the component that raised the
action is in `writeComponents`.** `UiEvent.sourceComponentId` identifies it, and
the document says which type that id is. A tap on a plain `Button` nested
anywhere in the tree still mints nothing.

This must not become "any submit from a surface containing a write component" —
that would let a `Column` holding both a `ConfirmationCard` and a `Button` mint a
token from the wrong tap.

### Suspension

Unchanged from §5.3: a document containing a write component suspends until a
write component raises an action; one containing none renders and returns
immediately. The read-component non-suspension rule from slice 1 generalises to
"no write component anywhere in the document".

## Tests to write

Beyond porting the existing `render_ui` suite to documents:

1. A composed document renders — `Column` with `Text` and `TextField` children.
2. A document without a `root` component fails **visibly**, not silently.
3. A tap on a nested `ConfirmationCard` mints a token.
4. A tap on a nested plain `Button` mints nothing, **even when the same document
   contains a `ConfirmationCard`**. This is the new attack surface.
5. A document containing no write component does not suspend.
6. Unknown component types anywhere in the tree degrade visibly.
7. The single-component form still behaves exactly as it does today.
8. `Image`, `Video`, `AudioPlayer` are still rejected anywhere in a document, not
   just at the root — §5.5 must not become root-only by accident.

Test 8 is the one most likely to be forgotten, and it is the one that would
quietly reopen the egress hole.

## Files

- Modify: `lib/features/ai/genui/render_ui_tool.dart` — accept documents
- Modify: `lib/features/ai/chat/providers/chat_notifier.dart` — hold a
  `SurfaceController`
- Modify: `lib/features/ai/chat/screens/chat_screen.dart` — render via `Surface`
  for documents, keep the direct path for single components
- Modify: `test/features/ai/genui/render_ui_tool_test.dart`
- Modify: `test/features/ai/chat/chat_screen_test.dart`
- Modify: `test/features/ai/acceptance/weight_flow_test.dart` — add a composed
  case alongside the existing single-component one

## Why this was not done in slice 1

It touches `render_ui`, the chat notifier, the chat screen, and roughly forty
existing tests. Slice 1's acceptance criterion — the weight demo — is met without
it, and the fallback is visible rather than silent. Shipping a half-migrated
render path would have been worse than a documented boundary.
