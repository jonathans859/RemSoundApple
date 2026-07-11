# Plan: RemSound iOS → TestFlight via GitHub Actions + Releases

Goal state (matches how you want to work; revised 2026-07-11 — cloud signing + continuous
internal TestFlight):

- **Push to any branch** → existing `build.yml` runs tests + unsigned builds. (Already true.)
- **Push to `main`** → `testflight.yml` builds a **cloud-signed iOS IPA and macOS PKG**
  (Apple holds the distribution key; nothing but the API key in secrets) and uploads both
  to TestFlight — the **internal** group receives them via automatic distribution,
  "What to Test" = the head commit subject. (macOS added 2026-07-11: same app record,
  parallel `testflight-macos` job.)
- **Publish a GitHub Release** (tag `vX.Y.Z` + notes) → same workflow uploads builds with
  the release notes as "What to Test", **distributes them to the external group(s)**
  (repo variable `TESTFLIGHT_EXTERNAL_GROUPS`, default "Beta"), and **attaches the IPA +
  PKG to the GitHub release**.
- A `/release` Claude skill drives releases via a Sonnet `release-manager` subagent
  (`.claude/agents/release-manager.md`): it reads the commits since the last tag, drafts
  the notes, bumps the version, and publishes after your confirmation.

The workflow (`.github/workflows/testflight.yml`, which replaced `release.yml` on
2026-07-11) and the skill (`.claude/skills/release/SKILL.md`) are committed. Nothing here
can be tested from this Windows machine — validation is reading the Actions logs.

---

## Phase 1 — one-time Apple setup (you, ~30–45 min in the browser)

1. **Enrolled Apple Developer account** — done (prerequisite).

2. **Find your Team ID**: developer.apple.com → Membership details → 10-character Team ID.

3. **Register the App ID** (bundle ID decided 2026-07-03, revised 2026-07-11: **both**
   platforms now use **`com.jonathan859.remsound`** — the macOS target was renamed from
   `.mac` pre-ship so iOS and macOS share ONE app record as a universal purchase; the
   `.mac` App ID, if it was ever registered, is unused).

   developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → “+” →
   App IDs → App → **explicit** bundle ID `com.jonathan859.remsound`, description
   "RemSound". No extra capabilities needed (background audio is an Info.plist mode, not
   a capability; we deliberately do NOT request multicast).

4. **Apple Distribution certificate — OBSOLETE since 2026-07-11.** The pipeline now uses
   Apple **cloud signing**: `xcodebuild -allowProvisioningUpdates` with the Admin API key
   creates and uses a cloud-managed Apple Distribution certificate whose private key
   never leaves Apple. No CSR, no `.cer`, no `.p12`, no CI keychain. (Historical gotcha,
   kept for reference: a locally-managed `.p12` had to be exported with OpenSSL's
   `-legacy` flag or the runner's `security import` rejected the passphrase.) The old
   locally-created certificate can be revoked in the portal once a cloud-signed release
   has succeeded.

5. **Create an App Store Connect API key**: App Store Connect → Users and Access →
   Integrations → App Store Connect API → Team Keys → “+”, role **Admin** (an App Manager
   key was refused with "Cloud signing permission error" during `-allowProvisioningUpdates`
   on the first release — use Admin for cloud signing). Note the **Key ID** and
   **Issuer ID**, download the `.p8` file (one chance only).

6. **Create the app record**: App Store Connect → Apps → “+” → New App → iOS,
   name "RemSound" (or "RemSound Receiver" if taken), primary language, the bundle ID you
   registered, any SKU (e.g. `remsound-ios`).

   **Add the macOS platform (one-time, added 2026-07-11, required before the first macOS
   TestFlight upload)**: App Store Connect → the RemSound app → App Store tab → the
   platform "+" (Add Platform) → **macOS**. Same bundle ID `com.jonathan859.remsound` —
   that's what makes it a universal purchase under the existing record. TestFlight tester
   groups are shared; the first macOS build goes through its own Beta App Review.

7. **TestFlight internal group**: in the app → TestFlight → Internal Testing → create a
   group (e.g. "Core") with automatic distribution and add yourself. Internal testers need
   no review; builds appear as soon as processing finishes. Use this for the first builds
   even though the goal is external testing — it proves the pipeline without review delays.
   (Internal testers must be App Store Connect users on your account — you can invite up
   to 100 via Users and Access, also on an individual membership.)

8. **External testers (wanted)** — one-time prerequisites in App Store Connect:
   - App → App Information / TestFlight → fill in **Beta App Information**: feedback
     email, a **privacy policy URL** (required for external TestFlight), and Beta App
     Review contact details.
   - TestFlight → External Testing → create a group (e.g. "Beta"), add testers by email
     or enable a **public link** (up to 10 000 testers).
   - The **first build** you add to an external group goes through **Beta App Review**
     (usually hours to ~1 day; describe what the app does and that it needs a Windows
     RemSound peer — offer the public relay hostname as the way reviewers can see it
     connect, or state clearly that audio requires a second machine). Later builds of the
     same version usually skip re-review; new marketing versions get a (fast) re-review.
   - Distribution to external groups is automated since 2026-07-11: publishing a GitHub
     Release adds that build to the group(s) named by the repo variable
     `TESTFLIGHT_EXTERNAL_GROUPS` (default "Beta"). You still decide which builds the
     public sees — by deciding what becomes a release; plain pushes to `main` only reach
     the internal group.

## Phase 2 — GitHub repository secrets (you, ~10 min)

Repo → Settings → Secrets and variables → Actions → New repository secret. The
`testflight.yml` workflow expects exactly these names:

- `APPLE_TEAM_ID` — the 10-character Team ID.
- `APP_STORE_CONNECT_API_KEY_ID` — the API key's Key ID.
- `APP_STORE_CONNECT_API_ISSUER_ID` — the Issuer ID.
- `APP_STORE_CONNECT_API_PRIVATE_KEY` — the full text content of the `.p8` file.

Optional repository **variable** (Variables tab, not Secrets):

- `TESTFLIGHT_EXTERNAL_GROUPS` — comma-separated external TestFlight group names that
  releases distribute to; defaults to `Beta` when unset. Must match App Store Connect
  exactly.

Removed 2026-07-11 with the switch to cloud signing (delete them from the repo settings):
`APPLE_DISTRIBUTION_CERT_P12_BASE64`, `APPLE_DISTRIBUTION_CERT_PASSWORD`,
`KEYCHAIN_PASSWORD`.

## Phase 3 — repo gaps to close before the first upload (Claude, needs your input)

1. **App icon — DONE (2026-07-03)**: `Apps/iOS/Assets.xcassets` now carries a single-size
   1024×1024 AppIcon (white pixel-style "RS" on blue, 24-bit PNG without alpha — App
   Store Connect rejects alpha in the marketing icon), wired into the pbxproj resources
   phase with `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. To rebrand later, just
   replace `AppIcon.appiconset/AppIcon.png` with another 1024×1024 no-alpha PNG.

2. **Export compliance** (verified against Apple's docs 2026-07-03): RemSound does its
   own end-to-end audio encryption — via Apple's CryptoKit/CommonCrypto, but for a custom
   protocol — so the honest declaration is: **uses encryption: yes; only standard
   algorithms (no proprietary crypto): yes**, which is exempt from export documentation.
   Since 2026-07-11 both Info.plists carry `ITSAppUsesNonExemptEncryption = false`, so
   builds on **both platforms** never prompt in App Store Connect (adding the macOS
   platform had re-surfaced the per-build question — the app-level ASC answers from
   2026-07-03 covered iOS only). Still applies regardless of the plist key:
   - File the annual **BIS self-classification report** (due Feb 1 each year — a short
     spreadsheet email; mass-market standard-crypto apps qualify for this simple route).
   - France requires an extra declaration if you distribute there.

3. Nothing else: versions are already wired (`CFBundleShortVersionString` =
   `$(MARKETING_VERSION)`, `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`), so the
   workflow injects them at build time — tag `v1.2.3` becomes marketing version `1.2.3`
   and the workflow run number becomes the ever-increasing build number. The `0.1.0` in
   the pbxproj is only the local/Xcode fallback; the release skill keeps it in sync.

## Phase 4 — how distribution then works (repeatable; revised 2026-07-11)

1. **Internal testers need no ceremony**: every push to `main` triggers `testflight.yml`
   (tests → cloud-signed archive → IPA → TestFlight upload with the head commit subject
   as "What to Test"). The internal group's automatic distribution delivers it once
   Apple's ~5–15 min processing finishes.
2. **External testers get releases.** Say "cut a release" (or invoke `/release`). The
   skill spawns the Sonnet `release-manager` subagent, which:
   - checks the working tree is clean and CI is green on `main`,
   - proposes the next semver + plain-text release notes drafted from the commits since
     the last tag (plain text on purpose — TestFlight shows "What to Test" without
     markdown),
   - syncs `MARKETING_VERSION` in the pbxproj and commits,
   - after your explicit go-ahead (relayed by the main session): pushes and
     `gh release create vX.Y.Z`, then watches the run.
3. Publishing the release triggers `testflight.yml`'s release path: `swift test` →
   cloud-signed archive → IPA → upload with the release body as "What to Test" → wait for
   processing → distribute to the external group(s) (first build of a new version passes
   Beta App Review, usually within a day) → attach `RemSound-iOS-vX.Y.Z.ipa` to the
   GitHub release.

## Phase 5 — later / optional

- **macOS**: TestFlight for macOS is possible too (needs Developer ID / Mac App Store
  signing decisions + sandbox review for the network client entitlement) — separate plan
  when wanted; the unsigned zip from `build.yml` stays the macOS distribution meanwhile.
- Screenshots, the full App Privacy questionnaire, and the App Store listing only matter
  for an actual App Store release, not TestFlight.

## Verification notes (researched 2026-07-03; revised 2026-07-11 for cloud signing)

The mechanics above were checked against current Apple/GitHub/fastlane documentation:

- Confirmed: fastlane is preinstalled on GitHub macOS runners; `method =
  app-store-connect` is the current export method name (`app-store` is deprecated);
  pilot's `--changelog` sets "What to Test" once the build appears in App Store Connect;
  `--distribute_external true --groups …` waits for processing, submits the first build
  of a version to Beta App Review, and adds it to the group; internal TestFlight is
  limited to App Store Connect users (max 100), external to 10 000 with Beta App Review
  on the first build per version.
- Cloud signing (2026-07-11): archive + export run with `-allowProvisioningUpdates` and
  the Admin API key only — Xcode creates/uses a **cloud-managed Apple Distribution
  certificate** (WWDC21 "cloud signing"); no keychain, `.p12`, or profile on the runner.
  The old keychain-import steps and their secrets are gone.
- Build numbers (2026-07-11): now `commit-count.kind.run-attempt` (kind: 0 = push build,
  1 = release build) because two triggers upload builds — the release is usually tagged
  on a commit whose push already uploaded a build of the same marketing version, so
  run-number-based schemes would collide across the two events. Commit count is monotonic
  on `main`; the attempt keeps re-runs unique after a partially-successful upload.
- Runner pins: `testflight.yml`'s signing/upload job runs on **`macos-26`** (Xcode 26)
  because App Store Connect rejects uploads not built with the iOS 26 SDK (hit on the
  first release, 2026-07-04). `build.yml` and the test jobs stay on `macos-15` — only
  uploads have the SDK floor. Revisit both when GitHub retires `macos-15`.

## First-release checklist (condensed; completed 2026-07-04 with v0.1.0)

1. Phase 1 steps 2–7 done, Phase 2 secrets set.
2. Icon PNG handed to Claude → icon commit lands; encryption key decision made.
3. `/release` → confirm version + notes → release published.
4. Watch the `TestFlight` workflow (`gh run watch` or share the logs); iterate if the
   first signing/upload attempt fails — that is normal.
5. Build appears in TestFlight → install via the TestFlight app on the iPhone.
