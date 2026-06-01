# ClaudeBar

A macOS menu bar app that shows your Claude Code usage limits and tells you when it's safe to keep working.

## Requirements

- macOS 13+
- Xcode (provides a working Swift toolchain for `swift build`)
- Claude Code logged in (`claude login`) — ClaudeBar reads the token the CLI keeps in your keychain

## Install

```bash
./install.sh   # build, install to ~/.local/bin, autostart at login
```

Other scripts:

```bash
./run.sh       # build and run in the background (dev)
./package.sh   # build ClaudeBar.app into /Applications
```
