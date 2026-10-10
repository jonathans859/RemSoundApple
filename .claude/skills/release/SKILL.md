---
name: release
description: Cut a RemSound release - a Sonnet release-manager subagent reads the commits since the last tag, drafts plain-text "What to Test" notes, bumps the version, and (after explicit user confirmation) publishes the GitHub Release that distributes the build to external TestFlight testers. Use when asked to "cut a release", "publish a release", "ship to TestFlight", or "make a new version".
---

# Release RemSound (push builds → GitHub Release promotes them → external TestFlight)

Two workflows, both thin callers of the shared `jonathans859/apple-ci` workflows (`@v1`),
cloud-signed with the App Store Connect API key, both platforms (iOS IPA + macOS PKG,
one shared app record / universal purchase):

- **`.github/workflows/testflight.yml` (run name "TestFlight") — every push to `main`**:
  `swift test`, then archives, signs and uploads both builds; internal testers receive
  them automatically. Build number = `<commit count>.0.<run attempt>`, marketing version
  read from the pbxproj `MARKETING_VERSION`. `paths-ignore` skips pushes that touch ONLY
  `**.md`, `docs/**`, `.claude/**`, `.github/**` and a few dotfiles — such a commit has no
  build at all.
- **`.github/workflows/release.yml` (run name "Release") — a published GitHub Release
  `vX.Y.Z` / `vX.Y.Z-bN`**: does NOT rebuild. Per platform, one `ubuntu-latest` job
  ("ios / External testers", "macos / External testers") validates the tag against the
  pbxproj `MARKETING_VERSION` (`-bN` stripped — a mismatch fails the run), rejects an empty
  body, **waits up to 30 min for a successful `testflight.yml` run of the exact tagged
  SHA**, attaches that run's IPA / PKG to the release, and distributes the same binary to
  the external group(s) (repo variable `TESTFLIGHT_EXTERNAL_GROUPS`, currently and by
  default "External") with the release body as "What to Test". External testers get the
  byte-identical binary internal testers already ran.

Two tag forms select the release tier (Beta App Review is per marketing VERSION, not per
build — that's the whole point of the split):
  - **`vX.Y.Z-bN`** (e.g. `v0.3.0-b2`) — re-release of the CURRENT marketing version:
    external testers get it, usually with no fresh review. **The default** for minor
    fixes and iteration.
  - **`vX.Y.Z`** — raises the marketing version: its first build waits in Beta App
    Review (hours, per platform) before external testers see it. For meaningful
    feature milestones and anything headed for the App Store.

This skill publishes that release by driving the `release-manager` subagent (Sonnet —
see `.claude/agents/release-manager.md`). One-time Apple/secrets setup lives in
`docs/plan.md`.

## Hard rules

- **Creating the release and pushing are outward-facing** — a release reaches external
  testers. The subagent prepares everything; you show the user the exact version + notes
  and only tell the subagent to publish after they say go.
- Tag format must be `vMAJOR.MINOR.PATCH` or `vMAJOR.MINOR.PATCH-b<N>`, and the tag's
  `X.Y.Z` must equal the pbxproj `MARKETING_VERSION` **at the tagged commit** — the
  release run fails otherwise. A raise therefore REQUIRES the version commit (prepare
  step 4); it is not a cosmetic fallback.
- **Tag only a commit that `testflight.yml` built.** A docs-, `.claude/`- or CI-only
  commit is skipped by `paths-ignore`, so the release run waits 30 min for a build that
  never comes and fails. If HEAD is such a commit, tag the latest commit that built
  (`--target <sha>`), or — for a raise — the version commit, which touches the pbxproj
  and therefore always builds. A `-bN` tag must also sit on a later commit than the base
  tag: a new binary needs a new build number, i.e. a higher commit count.
- Release notes become TestFlight "What to Test" verbatim: **3–8 plain sentences, no
  markdown tables/headings/links** (TestFlight renders raw text; the user's testers may
  use screen readers — plain prose reads best). The workflow fails an empty release body
  on purpose.
- This machine cannot compile Swift — never try to validate locally; the workflow is the
  validation.

## Procedure (orchestrator — you)

1. **Spawn the subagent, phase "prepare"**: launch the `release-manager` agent
   (`subagent_type: "release-manager"`) with the prompt: `Phase "prepare"` plus anything
   the user specified (e.g. a forced version or notes emphasis). It does the work below
   and reports back without publishing.
2. **Confirm with the user**: relay the proposed tag, the exact notes text, and what will
   be pushed. Check the notes against the 3–8 sentence rule before relaying. Wait for an
   explicit yes. If the user edits the notes/version, relay the edits to the same agent
   via SendMessage and re-confirm.
3. **Publish**: SendMessage to the same agent: `Phase "publish"` — approved as shown (or
   with the user's final edits, pasted verbatim). It pushes, creates the release, watches
   the runs, and reports.
4. **Relay the outcome**: link the release, confirm both the IPA and PKG assets are
   attached, and remind the user that external testers wait for Beta App Review on a new
   marketing version.

## Procedure (subagent — release-manager)

**Phase "prepare"**

1. Preflight: `git status` clean, on `main`, the latest `TestFlight` runs on main green
   (`gh run list --workflow TestFlight --branch main --limit 3`). Unpushed local commits
   are fine — they go up with the release push — but report that they'll be included.
   Secrets check (`gh secret list`): `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`,
   `ASC_KEY_P8`, `APPLE_DEV_CERT_P12`, `APPLE_DEV_CERT_P12_PASSWORD`. If missing, stop and
   point at `docs/plan.md`.
2. Pick the tier and version: `git describe --tags --abbrev=0` (or `gh release list`)
   for the latest tag. **Default to a same-version re-release** (`vX.Y.Z-bN`, N = next
   free suffix for the current version) — minor fixes and iteration should reach
   external testers without a Beta App Review wait. Propose a version RAISE (`vX.Y.Z`,
   semver bump implied by the changes) only for substantial feature milestones or when
   the user asked for one. Always state which tier you chose and why — the user decides.
3. Draft the notes from `git log <lasttag>..HEAD --oneline` plus reading the diffs where
   the subject line is unclear: 3–8 plain sentences aimed at a tester ("what changed,
   what to try"). Not a commit list, no markdown. Pick the most noticeable changes; a big
   release still gets at most 8 sentences.
4. **Version commit — only when the marketing version RAISES**: update all
   `MARKETING_VERSION = <old>;` occurrences in `RemSound.xcodeproj/project.pbxproj` to
   the new version (iOS and macOS configs — keep them identical) and commit. Required:
   the build reads its version from here and the release run checks the tag against it.
   For a `vX.Y.Z-bN` re-release the version already matches — skip this step.
5. Decide the commit to tag: HEAD after step 4 if it touches anything outside the
   `paths-ignore` list (`git diff --name-only <prev>..HEAD` for unpushed commits, or the
   presence of a `TestFlight` run for that SHA for pushed ones); otherwise the latest
   commit that did build. Report it.
6. Report and stop — no push, no release.

**Phase "publish"**

7. `git push`, then create the release with the notes via a body file (avoids quoting
   issues):
   `gh release create <tag> --target <sha from step 5> --title "RemSound <tag without v>" --notes-file <file>`
   The push starts the `TestFlight` run that builds the tagged commit; the `Release` run
   starts at the same time and simply waits for it — no need to sequence them.
8. Watch both runs: `gh run list --workflow TestFlight --commit <sha> --limit 1` (the
   build, ~6 min; internal testers get it after ASC processing) and
   `gh run list --workflow Release --event release --limit 1` (~8 min end-to-end
   including the wait), each with `gh run watch <id> --exit-status`. The Release run's
   two jobs are independent per platform — check both. On failure, read
   `gh run view <id> --log-failed`:
   - a **build** failure (TestFlight run) fails the Release run's wait step too. Fix it
     with a new commit, push, and cut a new `-bN` tag on that commit (the old tag points
     at a commit with no good build); deleting the failed release/tag
     (`gh release delete <tag> --cleanup-tag`) needs the user's OK via the orchestrator.
   - a **distribution / attach** failure (Release run only): `gh run rerun <id> --failed`.
     It is idempotent and rebuilds nothing — this is also the escape hatch for a stranded
     distribution. A rerun executes the YAML of the **tagged commit**, so a fix to
     `release.yml` itself needs a re-created tag.
9. Report: release URL, whether the IPA and PKG assets are both attached
   (`gh release view <tag>`), both runs' results, and the Beta App Review caveat for new
   versions.

## Known failure modes

- **Release — "Tag vX.Y.Z implies version X.Y.Z but the project says …"**: the raise
  went out without the version commit, or the tag points at a commit before it. Delete
  the release + tag (user OK), then re-create it on the version commit.
- **Release — "Timed out waiting for a successful testflight.yml run for <sha>"**: the
  tagged commit was skipped by `paths-ignore` (docs/CI/`.claude`-only), or its build is
  still queued behind the `testflight-upload` concurrency group for over 30 min. For the
  first, re-tag a commit that built; for the second, `gh run rerun <id> --failed` once
  the build is green.
- **External distribution — "Another build is in review" (Spaceship::UnexpectedResponse)**
  (first hit v0.3.0-b1, 2026-07-12): Apple allows ONE build per version train and platform
  in Beta App Review at a time. A `-bN` re-release published while the base `vX.Y.Z`'s
  first build is still "Waiting for Review" fails at the distribute step — the build is
  already uploaded and with internal testers; only external distribution is missing. Do
  NOT delete the release: wait for the pending review to clear (ASC → TestFlight; the
  account gets an email), then `gh run rerun <id> --failed` on the Release run — it
  re-distributes the same build, no rebuild. Takeaway for tier advice: a `-bN`
  re-release skips a NEW review, but cannot jump a review that is still in progress for
  the same version.
- **Archive — "Your account has reached the maximum number of certificates" + "No signing
  certificate 'Mac Development' / no iOS App Development profiles"** (first hit v0.3.0,
  2026-07-11): xcodebuild's ARCHIVE step signs with an Apple **Development** identity, and
  on an ephemeral runner `-allowProvisioningUpdates` mints a fresh Development certificate
  every run (the private key never persists), until Apple's per-account cap is hit. Fix:
  the user revokes the CI-minted Apple Development certificates — `asc certificates list
  --certificate-type DEVELOPMENT` then `asc certificates revoke --id <id> --confirm`, do
  NOT touch the cloud-managed **Apple Distribution** or the **Developer ID** certificate
  — then rerun the failed `TestFlight` run. Since 2026-08-29 the shared apple-ci workflow
  imports ONE shared Apple Development certificate from `APPLE_DEV_CERT_P12`, the same
  certificate every repo on the account uses, so nothing is minted at all. (It previously
  cached a keychain via actions/cache, which leaked: GitHub evicts a cache untouched for
  7 days, the recreate-on-failure path minted by design, and the two signing jobs run in
  parallel.) **A green build does not prove this is working** — a revoked .p12 still
  imports cleanly and still passes `find-identity`, which is how the previous
  certificate's loss went unnoticed for weeks. Verify with `asc certificates list` after a
  build and confirm no new certificate appeared.
- **macOS archive — "Your team has no devices from which to generate a provisioning
  profile" + "no Mac App Development provisioning profiles"** (first hit 2026-07-20, the
  iCloud profile-sync change): triggered by giving the macOS target an **App-ID-level
  capability** (here `com.apple.developer.ubiquity-kvstore-identifier`). Plain entitlements
  — App Sandbox, network client/server, audio input — need no provisioning profile, so the
  macOS archive never asked for one before; an App-ID capability makes automatic signing
  demand a *Mac App Development* profile for the archive step. Apple issues iOS development
  profiles to a team with **zero registered devices but not Mac ones**, which is why the
  iOS job kept passing while macOS failed. There is no Mac to register (development happens
  on Windows), so this is a dead end, not a setup gap — do NOT go hunting in the portal,
  the App ID and its iCloud capability are fine.
  **Fix (already in the shared apple-ci `testflight.yml`)**: the macOS archive is
  **ad-hoc signed** (`CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-"
  PROVISIONING_PROFILE_SPECIFIER=""`), and export does the real signing with the
  cloud-managed distribution certificate — a Mac App Store profile is not device-bound.
  Note the intermediate trap: archiving with `CODE_SIGNING_ALLOWED=NO` also clears the
  profile error but produces a binary with **no entitlements**, which ASC rejects at
  upload with *"App sandbox not enabled … (90296)"*. Ad-hoc signing is what embeds
  entitlements without contacting Apple. The "Verify the archive kept its entitlements"
  step exists to catch a regression here at archive time instead of minutes later at
  upload.
- **Archive/export — "Cloud signing permission error" / "No profiles found"**: the App ID
  `com.jonathan859.remsound` and its App Store Connect app record must exist, and the API
  key must be **Admin** (App Manager is refused for cloud signing).
- **macOS job — upload rejected / app not found**: the shared app record must have the
  **macOS platform added** (App Store Connect → RemSound → Add Platform → macOS, same
  bundle id — one-time, see `docs/plan.md` Phase 1 step 6). Both platform jobs are
  independent in both workflows: one can succeed while the other fails, so check both
  before declaring the release done.
- **Archive — HTTP 401 on `listTeams`**: the API-key secrets don't line up — wrong Key ID /
  Issuer ID, or a mangled `.p8`. Re-set `ASC_KEY_P8` from the file
  via stdin (`gh secret set … < AuthKey_XXXX.p8`); brand-new keys take a few minutes to
  activate.
- **Upload — "Validation failed (409) … iOS 26 SDK"**: Apple's SDK floor. The shared
  workflow's signing job runs on a `macos-26` runner with the newest Xcode for this
  reason — do not drop it to `macos-15` (only the `swift test` job may stay there).
- **External distribution — group not found**: the repo variable
  `TESTFLIGHT_EXTERNAL_GROUPS` (currently "External"; `release.yml` also defaults to
  "External") must exactly match an external group name in App Store Connect →
  TestFlight.
- **External distribution — stuck "Waiting for Review"**: normal for the first build of a
  new marketing version; Beta App Review usually clears within a day. Nothing to fix.
