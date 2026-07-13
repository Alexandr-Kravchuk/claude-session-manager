# ClaudeBar

A macOS menu bar app that shows your Claude Code usage limits and tells you when it's safe to keep working.

## Features

- Live usage bars for the 5-hour session window and the 7-day weekly windows (including the Sonnet/Opus split where your plan reports it)
- Pace projection: where each window is headed at reset, with deviation-band bars and headroom advice
- Menu bar icon colored by projected usage, so a glance is enough
- Context-aware recommendations — keep going, slow down, or when the window stabilizes
- Launch at Login toggle
- Optional auto-update from this repo's GitHub releases (toggle in the menu)

## Requirements

- macOS 13+
- Apple Swift 5.9+ from Xcode or the Command Line Tools
- Claude Code logged in (`claude login`) — ClaudeBar reads the token the CLI keeps in your keychain

## Install

```bash
./install.sh   # build, install to ~/.local/bin, autostart at login (LaunchAgent)
```

Other scripts:

```bash
./run.sh                    # build and run in the background (dev)
./package.sh                # build a universal ClaudeBar.app into /Applications
VERSION=x.y.z ./release.sh  # build and zip a universal release asset into dist/
```

## Uninstall

```bash
launchctl unload ~/Library/LaunchAgents/com.claudebar.app.plist 2>/dev/null || true
rm -f ~/Library/LaunchAgents/com.claudebar.app.plist ~/.local/bin/ClaudeBar
rm -rf /Applications/ClaudeBar.app
defaults delete com.claudebar.app 2>/dev/null || true
```

## Security & privacy

ClaudeBar touches your Claude credentials, so here is exactly what it does:

- It reads the Claude Code CLI's keychain item **`Claude Code-credentials`** by invoking `/usr/bin/security find-generic-password`. macOS will therefore show a keychain prompt attributed to `security`, not ClaudeBar. Note that "Always Allow" grants the `security` tool itself — and thus any process that invokes it — prompt-free access to that item; choose "Allow" each time if that trade-off bothers you.
- Only the **access token** is parsed from that item; the refresh token is ignored.
- The token is sent to exactly one place: `https://api.anthropic.com/api/oauth/usage` — the same endpoint Claude Code itself queries — as an `Authorization` header over HTTPS. It is never logged, written to disk, or sent anywhere else.
- `~/.claude` is watched via FSEvents only to detect Claude Code activity (write events on `history.jsonl`); file contents are never read.
- When auto-update is enabled, the app polls `api.github.com` for releases of this repository. The OAuth token is never sent there.

The usage endpoint is undocumented and gated to the official client, so ClaudeBar identifies itself with the CLI's User-Agent. It may change or stop working at any time.

## Disclaimer

ClaudeBar is an unofficial tool. It is not affiliated with, endorsed by, or supported by Anthropic.

## License

[MIT](LICENSE)
