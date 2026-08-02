# WristDeck

Drive Claude Code and OpenAI Codex on your Mac from an Apple Watch, by voice.

Speak into your wrist, the agent works on your Mac, and you get a glanceable
status, an approval prompt before anything public or costly happens, and a
screenshot of the result when it finishes.

> **Status:** working daily driver, not a packaged product. Setup needs Xcode and
> an Apple Developer account. Read [SECURITY.md](SECURITY.md) before enabling
> remote access.

## Why it is built this way

Everything runs on **your** Mac with **your** logins. There is no hosted service,
no account, no API key held by anyone else:

- Claude Code runs under your existing Claude Code login
- Codex runs under your existing ChatGPT login
- Remote access uses your own Tailscale tailnet
- The auth token is generated locally by `setup.sh` and never leaves your machine

Nobody operating this project can see your prompts, your code, or your usage.

## How it fits together

```
Apple Watch  ──HTTPS + bearer token──▶  Bridge (Node, your Mac)
   SwiftUI                                 ├─ Claude adapter  (Agent SDK)
   voice in / TTS out                      ├─ Codex adapter   (app-server)
                                           ├─ approval gate   (PreToolUse hook)
                                           └─ wristdeck-tools (MCP)

Mac menu-bar app  ──▶  shows live status under the notch, captures proof shots
```

Turns run **detached**: the watch POSTs a prompt, gets a `turnId`, and reads a
cursor-based event log. That is what lets you drop your wrist mid-task and pick
the thread back up without losing anything, which a held-open stream cannot do
on watchOS.

## What it does

- **Voice first.** Tap anywhere on the Speak screen, talk, done. Dictation
  submits directly, since the system sheet already has its own confirm step.
- **Both agents.** Claude Code and Codex, with per-agent model selection.
- **Approve from your wrist.** Anything that publishes, spends money, or cannot
  be undone pauses and asks, showing the exact command and folder.
- **Glanceable.** An animated orb plus two or three words about what is happening
  right now. Prompt and full output are one swipe away.
- **Results come to you.** The file the agent wrote opens on your Mac, and a
  screenshot of the result appears on your watch.
- **Mac indicator.** A pill under the notch while work runs; click "Done" to open
  what it produced. When an agent is parked on an approval, the pill turns amber
  with Allow and Deny right on it.
- **History that survives.** Every turn lands in a persistent ledger
  (`~/.wristdeck/`), with its prompt, summary, touched files and proof
  screenshot. Hover the notch for a drop-down panel of past turns and produced
  files, or use the menu bar icon. Come back after being away and one pill
  summarizes what finished while you were gone.

## Requirements

| | |
|---|---|
| Mac | macOS 14+, Node 22+ (24+ recommended: the bridge runs TypeScript directly) |
| Watch | Apple Watch, watchOS 10+ |
| Build | Xcode 15+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) |
| Account | Apple Developer account to install on a physical watch |
| Agents | [Claude Code](https://claude.com/claude-code) and/or the Codex CLI, each already logged in |
| Optional | [Tailscale](https://tailscale.com) for access away from home |

## Setup

```bash
git clone https://github.com/donalleniii/wristdeck.git
cd wristdeck
./setup.sh          # creates local.env, then tells you what to fill in
```

Put your Apple Developer Team ID in `local.env`, then run `./setup.sh` again. It
will install dependencies, generate an auth token, render the Xcode projects,
and install the bridge as a background service.

Then build the apps:

```bash
cd watch && ./build.sh device     # watch unlocked and on your wrist
cd ../mac && ./build.sh install   # menu-bar indicator (optional)
```

**Claude Code must be logged in from a terminal**, not just the desktop app. The
desktop app's login is not readable by the headless process the bridge spawns:

```bash
claude    # then /login
```

### Access away from home

By default the watch reaches your Mac over your local network only. For access
anywhere, enable a Tailscale Funnel (HTTPS certificates first, then Funnel), then
re-run `./setup.sh` and rebuild the watch app.

**This puts your Mac on the public internet behind a single bearer token.**
Please read [SECURITY.md](SECURITY.md) first.

## The permission model

Watch-initiated turns are deliberately more restricted than sitting at your Mac,
because nobody is there to catch a mistake.

| Tier | What | Examples |
|---|---|---|
| **Allow** | Reads and edits | `Read`, `Write`, `ls`, `git status`, `git commit` |
| **Ask** | Public, irreversible, or costs money | `git push`, `gh pr create`, `vercel deploy`, paid generation |
| **Deny** | Everything else | `rm -rf`, piped installs, anything with shell chaining |

Enforcement is a `PreToolUse` hook, not a permission callback. That matters:
settings-file allow rules are applied *before* a permission callback runs, so a
rule in your own `settings.json` could otherwise bypass the policy entirely.
See `bridge/src/hook.ts`.

Codex starts in a `workspace-write` sandbox. When it needs network access or a
write outside the selected project, app-server parks that exact request on the
same Watch approval card. An approval grants only the requested permission for
that turn; it does not switch Codex into unrestricted mode.

## Layout

```
bridge/          Node/TypeScript service (no build step)
  src/adapters/    Claude and Codex
  src/hook.ts      permission enforcement
  src/policy.ts    the three-tier classifier
  test/            run with `node test/<name>.mjs`
watch/           watchOS app (SwiftUI, XcodeGen)
  Sources/Design/  design tokens, motion, custom Canvas visuals
mac/             menu-bar indicator + proof-of-work capture
setup.sh         one-shot, idempotent setup
```

## Tests

The bridge tests run against a live local bridge:

```bash
cd bridge
node test/policy-test.mjs               # classifier, no bridge needed
node test/approval-test.mjs             # approval semantics
node test/permission-execution-test.mjs # permitted actions actually execute
node test/settings-bypass-test.mjs      # settings rules cannot bypass policy
node test/codex-appserver-test.mjs      # Codex resume, approval, abort, files
node test/history-test.mjs write        # persistent ledger (then restart the
node test/history-test.mjs verify       # bridge and run the verify phase)
```

`permission-execution-test.mjs` exists because of a real bug: the hook returned
"I do not object" rather than "permission granted", so every approval silently
failed while the suite stayed green, because the tests only exercised
auto-approved file writes. It deliberately never writes a file.

## Contributing

Issues and pull requests welcome. Please do not include tokens, tailnet
addresses, device identifiers, or team IDs in issues or diffs.

## License

[Apache License 2.0](LICENSE).

This software runs AI agents with file-write access on your machine. It is
provided without warranty. You are responsible for what you let it do.
