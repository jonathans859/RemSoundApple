---
name: release
description: Cut a RemSound release - a Sonnet release-manager subagent reads the commits since the last tag, drafts plain-text "What to Test" notes, bumps the version, and (after explicit user confirmation) publishes the GitHub Release that distributes the build to external TestFlight testers. Use when asked to "cut a release", "publish a release", "ship to TestFlight", or "make a new version".
---

# Release RemSound (GitHub Release → cloud-signed IPA + PKG → external TestFlight)

`.github/workflows/testflight.yml` handles all TestFlight distribution for BOTH platforms
(iOS IPA + macOS PKG, parallel jobs, one shared app record / universal purchase) with
Apple cloud signing (App Store Connect API key, no local certificates):

- **Every push to `main`** already uploads builds that internal testers receive
  automatically — no release needed for that.
- **Publishing a GitHub Release** (tag `vX.Y.Z`) uploads both builds with the release
  body as "What to Test", distributes them to the **external** tester group(s)
  (repo variable `TESTFLIGHT_EXTERNAL_GROUPS`, default "Beta"), and attaches the IPA and
  PKG to the release. The first build of a new marketing version waits in Beta App Review
  (hours, per platform) before external testers see it.

This skill publishes that release by driving the `release-manager` subagent (Sonnet —
see `.claude/agents/release-manager.md`). One-time Apple/secrets setup lives in `plan.md`.

## Hard rules

- **Creating the release and pushing are outward-facing** — a release reaches external
  testers. The subagent prepares everything; you show the user the exact version + notes
  and only tell the subagent to publish after they say go.
- Tag format must be `vMAJOR.MINOR.PATCH` — the workflow rejects anything else.
- Release notes become TestFlight "What to Test" verbatim: **plain sentences, no markdown
  tables/headings/links** (TestFlight renders raw text; the user's testers may use screen
  readers — plain prose reads best). The workflow fails an empty release body on purpose.
- This machine cannot compile Swift — never try to validate locally; the workflow is the
  validation.

## Procedure (orchestrator — you)

1. **Spawn the subagent, phase "prepare"**: launch the `release-manager` agent
   (`subagent_type: "release-manager"`) with the prompt: `Phase "prepare"` plus anything
   the user specified (e.g. a forced version or notes emphasis). It does the work below
   and reports back without publishing.
2. **Confirm with the user**: relay the proposed tag, the exact notes text, and what will
   be pushed. Wait for an explicit yes. If the user edits the notes/version, relay the
   edits to the same agent via SendMessage and re-confirm.
3. **Publish**: SendMessage to the same agent: `Phase "publish"` — approved as shown (or
   with the user's final edits). It pushes, creates the release, watches the run, and
   reports.
4. **Relay the outcome**: link the release, confirm the IPA asset is attached, and remind
   the user that internal testers get the build after processing while external testers
   wait for Beta App Review on a new version.

## Procedure (subagent — release-manager)

**Phase "prepare"**

1. Preflight: `git status` clean, on `main`, `main`'s CI green
   (`gh run list --branch main --limit 3`). Unpushed local commits are fine — they go up
   with the release push — but report that they'll be included. Secrets check
   (`gh secret list`): `APPLE_TEAM_ID`, `APP_STORE_CONNECT_API_KEY_ID`,
   `APP_STORE_CONNECT_API_ISSUER_ID`, `APP_STORE_CONNECT_API_PRIVATE_KEY`. If missing,
   stop and point at `plan.md`.
2. Pick the version: `git describe --tags --abbrev=0` (or `gh release list`) for the
   latest `vX.Y.Z`; propose the semver bump implied by the changes (flag it for the user
   if ambiguous).
3. Draft the notes from `git log <lasttag>..HEAD --oneline` plus reading the diffs where
   the subject line is unclear: 3–8 plain sentences aimed at a tester ("what changed,
   what to try"). Not a commit list, no markdown.
4. Sync the fallback version: update all `MARKETING_VERSION = <old>;` occurrences in
   `RemSound.xcodeproj/project.pbxproj` to the new version (iOS and macOS configs — keep
   them identical) and commit. The workflow injects the real version from the tag; this
   keeps local Xcode builds and the push-triggered TestFlight builds honest.
5. Report and stop — no push, no release.

**Phase "publish"**

6. `git push`, then create the release with the notes via a body file (avoids quoting
   issues):
   `gh release create vX.Y.Z --target main --title "RemSound vX.Y.Z" --notes-file <file>`
   (The push also triggers a push-event TestFlight run for internal testers; that is
   expected and harmless alongside the release run.)
7. Watch the run: `gh run list --workflow TestFlight --event release --limit 1`, then
   `gh run watch <id> --exit-status` (the external-distribution step waits out the full
   5–15 min App Store Connect processing). On failure, read the failed step's log
   (`gh run view <id> --log-failed`), fix, and either re-run
   (`gh run rerun <id> --failed`) for infra flakes / secret fixes or — for a
   `testflight.yml` change — delete the release + tag
   (`gh release delete vX.Y.Z --cleanup-tag`, only with user OK via the orchestrator),
   push the fix, and re-create the release. A workflow edit only takes effect on a
   re-created tag: the run executes the workflow from the **tagged commit**, so a plain
   `rerun` reuses the old YAML.
8. Report: release URL, whether the IPA and PKG assets are both attached
   (`gh release view vX.Y.Z`), and the Beta App Review caveat for new versions.

## Known failure modes

- **Archive/export — "Cloud signing permission error" / "No profiles found"**: the App ID
  `com.jonathan859.remsound` and its App Store Connect app record must exist, and the API
  key must be **Admin** (App Manager is refused for cloud signing).
- **macOS job — upload rejected / app not found**: the shared app record must have the
  **macOS platform added** (App Store Connect → RemSound → Add Platform → macOS, same
  bundle id — one-time, see `plan.md` Phase 1 step 6). Both platform jobs are independent:
  one can succeed while the other fails, so check both before declaring the release done.
- **Archive — HTTP 401 on `listTeams`**: the API-key secrets don't line up — wrong Key ID /
  Issuer ID, or a mangled `.p8`. Re-set `APP_STORE_CONNECT_API_PRIVATE_KEY` from the file
  via stdin (`gh secret set … < AuthKey_XXXX.p8`); brand-new keys take a few minutes to
  activate.
- **Upload — "Validation failed (409) … iOS 26 SDK"**: Apple's SDK floor. The signing job
  runs on `macos-26` with the newest Xcode for this reason — do not drop it to `macos-15`.
- **External distribution — group not found**: the repo variable
  `TESTFLIGHT_EXTERNAL_GROUPS` (default "Beta") must exactly match an external group name
  in App Store Connect → TestFlight.
- **External distribution — stuck "Waiting for Review"**: normal for the first build of a
  new marketing version; Beta App Review usually clears within a day. Nothing to fix.
