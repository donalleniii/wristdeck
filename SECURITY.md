# Security

WristDeck lets a voice command from a watch run an AI agent that can write files
on your Mac. That is the point of it, and it deserves to be stated plainly rather
than buried.

## What the design already does for you

- **Nothing leaves your machine.** No hosted service, no account, no telemetry.
  Your prompts, code, and agent logins stay on your Mac.
- **The token is yours.** `setup.sh` generates it locally with `openssl rand`. No
  maintainer of this project ever sees it.
- **Every route requires it**, including `/health`, compared with a
  timing-safe hash.
- **Agents are restricted from the watch.** Publishing, spending, and destructive
  actions either pause for your approval or are refused. See the permission table
  in the [README](README.md#the-permission-model).
- **The `open` capability is validated**, not a shell call: it refuses URLs and
  any file type macOS would execute rather than display, and resolves symlinks
  before deciding.

## What you are taking on

### Enabling Tailscale Funnel puts your Mac on the public internet

This is the big one. With Funnel on, your bridge has a real public HTTPS address.
The only thing between the internet and an agent with write access to your files
is one bearer token.

That token lives in two places: `bridge/.env` on your Mac, and a plist inside the
watch app bundle. If it leaks, rotate immediately:

```bash
./setup.sh --rotate          # new token
cd watch && ./build.sh device # rebuild so the watch has it
```

If you do not need remote access, **do not enable Funnel**. The local-network
path is the default and is meaningfully safer.

### Known gaps in the current build

Being honest about what is not there yet:

- **No rate limiting.** A leaked token can be used as fast as the attacker likes.
- **No audit log.** There is no durable record of what ran, when, or from where.
- **Turns are in memory.** A bridge restart loses in-flight work and history.
- **One static token, no expiry.** Rotation is manual.

If you are running this on a machine with anything sensitive on it, weigh those
before enabling Funnel.

### Screen recording and screenshots

Proof-of-work screenshots capture your **main display** and send them to your
watch over the same authenticated channel. They are stored in a temp directory
and pruned to the last few turns. The capture is done by the menu-bar app, not
the bridge, specifically so the permission is scoped to one signed app rather
than granting a general-purpose Node runtime permanent screen access.

If you would rather not have this, do not grant Screen Recording to
WristDeckNotch; everything else keeps working.

### The Codex difference

Codex is not gated by the approval prompt. Its sandbox has no network access, so
it cannot push, deploy, or call an API, but it **can** run shell commands inside
its working directory. Do not assume the two agents are equally restricted.

## Reporting a vulnerability

Open an issue describing the problem without including your token, tailnet
address, or device identifiers. If the issue is sensitive, say so in the issue and
ask for a private channel before sharing details.

## Never commit these

`setup.sh` and `.gitignore` keep them out, but for the record:

- `local.env` (your Apple Team ID, device id)
- `bridge/.env` (your bearer token)
- `watch/Sources/Config.plist` (token and your tailnet URL)
- `watch/project.yml`, `mac/project.yml` (generated; contain your team id and
  tailnet IP, which is why the tracked files are `*.template.yml`)
