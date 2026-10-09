---
name: upstream-protocol-sync
description: Scan the official Windows RemSound repo (Ednunp/RemSound) for commits since the last recorded scan, decide whether any of them change the wire protocol or interop-relevant behaviour, apply required changes to this Swift port, and ask the user how to confirm/release. Use when asked to "check upstream", "sync with the Windows repo", "check for protocol changes", or before cutting a release.
---

# Upstream protocol sync

Goal: keep this Apple port wire-compatible with the Windows app at
https://github.com/Ednunp/RemSound. The C# source there is the protocol spec.

## State

`last-scan.json` (next to this file) records the newest upstream commit already reviewed:

```json
{ "upstreamSha": "...", "upstreamVersion": "vX.Y", "scannedAt": "YYYY-MM-DD" }
```

Always finish a scan by updating this file to the newest commit you reviewed and committing
it with whatever else changed. If the file is missing or the SHA no longer exists upstream
(force-push), tell the user and fall back to scanning by date from `scannedAt`.
If the SHA still exists but is not in `main`'s history (upstream rewrote it — happened
2026-10, see `.claude-notes/upstream-sync-v6.1.md`), take the range from
`gh api 'repos/Ednunp/RemSound/compare/<sha>...main' --jq '.commits[].sha'` instead; its
`.files` list caps at 300, so triage per commit. For big ranges, `git fetch` the local clone
at `~/gitkeep/Ednunp/RemSound` (fetch only — its working tree has the user's staged changes)
and diff wire files with `git diff <old> origin/main -- <paths>`.

## Procedure

1. **Fetch new commits** (one shot per list — never poll):
   `gh api 'repos/Ednunp/RemSound/commits?per_page=50' --jq '.[] | .sha[0:8] + " " + .commit.author.date + " " + (.commit.message | split("\n")[0])'`
   Keep everything newer than `upstreamSha`. If none: report "up to date", update
   `scannedAt`, done.

2. **Triage each new commit by the files it touches**
   (`gh api repos/Ednunp/RemSound/commits/<sha> --jq '.files[].filename'`):
   - **Wire contract — MUST review the patch**: `src/RemSound.Core/RemPacket.cs`,
     `RemSoundCrypto.cs`, `AudioFormatInfo.cs`, `PeerDiscoveryService.cs`,
     `HeartbeatService.cs`, `PcmFrame*.cs`, `AudioTransportCodec.cs`, `TickProof.cs`,
     `AddrCheckEchoGate.cs`, `RelayGroupClient.cs`, `server/RELAY-GROUPS.md` (the server-group
     spec). Any change to packet layout, sizes, ports, crypto parameters, JSON keys, or timing
     constants likely needs mirroring here. `src/RemSound.App/SelfTest.CrossPort.cs` is
     upstream's own list of cross-port pins — read its diff too; a new `Pin(` is a new contract.
   - **Behavioural — review the patch, usually optional**: `src/RemSound.Receiver/**`,
     `src/RemSound.Sender/**`, `server/remsound-relay.py`. Windows-only rendering/device
     code (WASAPI/ASIO lanes, MultiOutput, timers) does not apply — this port has a single
     mixed output and no drift resampler. Jitter-buffer *constants* (SessionPlayout
     margins/trim) ARE mirrored here in `SessionPlayout.swift`; if upstream retunes them,
     propose the same retune.
   - **Ignore**: `src/RemSound.App/**` (WinForms UI), docs, sounds, installer, tests,
     release notes — unless the release notes mention "protocol", "wire", "packet",
     "encryption", or a header-version bump.
   - Relay: the v1 pairwise reflector AND, since 2026-10-02, server groups (header version
     2, `server/RELAY-GROUPS.md`) are in scope — see the "Server groups" wire-contract entry in
     CLAUDE.md. Server-only features (metronome timing, server status/ping) are optional.
   - Accept-connections behaviour lives in `src/RemSound.App/MainForm.AcceptConnections.cs`
     (an App file, but ported here as `PeerAccept.swift` — review its diff).

3. **Read patches** for every commit that survived triage:
   `gh api repos/Ednunp/RemSound/commits/<sha> --jq '.files[] | select(.filename == "PATH") | .patch'`

4. **Classify and act**:
   - *Wire-breaking / interop-required*: apply the mirrored change in
     `RemSoundKit/Sources/RemSoundKit/`, update the "Wire contract" section of `CLAUDE.md`,
     and add or update a test that pins the new behaviour (cross-impl vectors if crypto).
   - *Quality/behaviour worth porting*: describe it to the user with your recommendation;
     apply only if they agree (or if it is a clear bug we share).
   - *Windows-only*: list it as reviewed-and-skipped in your report.

5. **Finish**:
   - Update `last-scan.json` to the newest reviewed SHA + upstream version + today's date.
   - Commit everything. **Never `git push`** — pushing is the user's.
   - Validation is CI-only (this machine cannot compile Swift); remind the user to run
     the GitHub Actions workflow or provide its logs.
   - **Ask the user how they want to confirm/ship** (e.g. push and watch CI, tag a
     release, or just keep the commit local). Do not tag or release on your own.

## Baseline

The port was originally written against upstream v3.8/v3.9 (2026-06-12). First full scan
2026-07-03 covered everything through v4.9 (`d7f6d9fd`): no wire changes since v3.3;
the only interop-adjacent item was v3.9.1's drift-resampler depth feedback, which attaches
to the Windows Phase-4 resampler this port intentionally does not have (see the
"Known v1 simplifications" note in CLAUDE.md).
