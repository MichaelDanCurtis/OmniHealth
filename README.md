# OmniHealth

An AI-native health app for iOS, Android, macOS, and Windows.

OmniHealth is a fork of [wger-project/flutter](https://github.com/wger-project/flutter) that adds an
on-device AI assistant able to read and write your health data through generative UI — you say
"I want to log my weight", a native card appears in the chat, you fill it in and tap save.

Licensed **AGPL-3.0-or-later**, same as wger.

## Status

Early. The design and implementation plan are written; the AI layer is being built.

- [Design spec](docs/superpowers/specs/2026-08-07-omnihealth-ai-spine-design.md)
- [Fork evaluation findings](docs/superpowers/specs/2026-08-07-slice-0-findings.md)
- [Implementation plan](docs/superpowers/plans/2026-08-07-omnihealth-ai-spine.md)

## How this fork is organised

Everything OmniHealth adds lives in **`lib/features/ai/`**. Outside that directory the tree is
wger's, and changes to it are limited to a navigation entry and a Riverpod registration. Two reasons:
merges from upstream stay cheap, and the AI layer could be offered back to wger as an optional
feature rather than living forever in a divergent fork.

Upstream is tracked as a git remote:

```bash
git fetch upstream
git merge upstream/master
```

## Bring your own key

OmniHealth has no server of its own and no subscription. You supply an API key for a provider you
choose, and it is stored in your device's secure keychain — it never leaves the device except in the
request to that provider.

Supported providers: OpenAI, Grok, Kimi, and GLM through one OpenAI-compatible adapter, plus
Anthropic through its own. On desktop you can alternatively point OmniHealth at a local
[ACP](https://agentclientprotocol.com) agent binary you already run.

**Provider API keys only.** OmniHealth does not support signing in with a consumer AI subscription
from any vendor. Several vendors — Anthropic explicitly — restrict subscription credentials to their
own first-party applications and enforce that server-side, so wiring a subscription into a
third-party app risks the user's account. If you want to use Claude, use a Console API key.

## Your data

Health data is yours. It syncs to whichever wger server you point the app at — your own, or a public
one — using wger's existing PowerSync setup, and it works offline.

The AI is the one place data leaves that boundary: your conversation and any tool results are sent to
the provider you configured. The app tells you which provider that is before you enter a key. If
that is not a trade you want to make, the app works fine with the AI features switched off.

### Nothing writes without a tap

The assistant proposes UI; only you cause a write. When it wants to record something it must render
a card, and only your tap on that card mints the single-use token its write is checked against. This
is enforced in code, not in the prompt.

## Not a medical device

OmniHealth does not diagnose, treat, or give medical advice, and nothing it says should be taken as
such. Talk to a clinician.

## Credits

Built on the work of the [wger](https://github.com/wger-project) team, who wrote nearly all of the
tracking application this forks. Generative UI uses [A2UI](https://github.com/google/A2UI) via
Flutter's [genui](https://github.com/flutter/genui) SDK.
