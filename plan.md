# Plan: RemSound iOS → TestFlight via GitHub Actions + Releases

Goal state (matches how you want to work):

- **Push to any branch** → existing `build.yml` runs tests + unsigned builds. (Already true.)
- **Publish a GitHub Release** (tag `vX.Y.Z` + notes) → new `release.yml` runs tests, builds a
  **signed IPA**, **uploads it to TestFlight** with the release notes as the TestFlight
  "What to Test" text, and **attaches the IPA to the GitHub release**.
- A `/release` Claude skill drives the whole thing: drafts notes, bumps the version, creates
  the release after your confirmation, and watches the workflow.

The workflow (`.github/workflows/release.yml`) and the skill
(`.claude/skills/release/SKILL.md`) are already committed. What remains is the Apple-side
setup you must do once, plus one repo gap (the app icon). Nothing here can be tested from
this Windows machine — expect the first release to take one or two iterations of reading
the Actions logs.

---

## Phase 1 — one-time Apple setup (you, ~30–45 min in the browser)

1. **Enrolled Apple Developer account** — done (prerequisite).

2. **Find your Team ID**: developer.apple.com → Membership details → 10-character Team ID.

3. **Register the App ID** (bundle ID decided 2026-07-03: the iOS app is
   **`com.jonathan859.remsound`** — no `.ios` suffix; already renamed in the project.
   macOS stays `com.jonathan859.remsound.mac`; iOS/macOS are separate app records so
   there is no conflict, and the suffix-free iOS name keeps Mac App Store "universal
   purchase" possible later, which would require one shared ID).

   developer.apple.com → Certificates, Identifiers & Profiles → Identifiers → “+” →
   App IDs → App → **explicit** bundle ID `com.jonathan859.remsound`, description
   "RemSound". No extra capabilities needed (background audio is an Info.plist mode, not
   a capability; we deliberately do NOT request multicast).

4. **Create an Apple Distribution certificate** (Windows-friendly, no Mac needed):
   - In Git Bash: generate a private key + certificate signing request:
     ```
     openssl genrsa -out dist.key 2048
     openssl req -new -key dist.key -out dist.csr -subj "/emailAddress=accounts@jonathan859.com/CN=Jonathan Distribution/C=DE"
     ```
   - Portal → Certificates → “+” → **Apple Distribution** → upload `dist.csr` → download
     `distribution.cer`.
   - Convert to a password-protected .p12:
     ```
     openssl x509 -in distribution.cer -inform DER -out dist.pem
     openssl pkcs12 -export -inkey dist.key -in dist.pem -out dist.p12
     ```
     (Choose a strong export password — it becomes a GitHub secret.)
   - Keep `dist.key`/`dist.p12` somewhere safe and OFF the repo.

5. **Create an App Store Connect API key**: App Store Connect → Users and Access →
   Integrations → App Store Connect API → Team Keys → “+”, role **App Manager**.
   Note the **Key ID** and **Issuer ID**, download the `.p8` file (one chance only).

6. **Create the app record**: App Store Connect → Apps → “+” → New App → iOS,
   name "RemSound" (or "RemSound Receiver" if taken), primary language, the bundle ID you
   registered, any SKU (e.g. `remsound-ios`).

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
   - Distribution to external groups is a manual click per build by default (TestFlight →
     build → add to the external group). Keep that manual — you decide which builds the
     public sees; internal group gets every build automatically.

## Phase 2 — GitHub repository secrets (you, ~10 min)

Repo → Settings → Secrets and variables → Actions → New repository secret. The
`release.yml` workflow expects exactly these names:

- `APPLE_TEAM_ID` — the 10-character Team ID.
- `APPLE_DISTRIBUTION_CERT_P12_BASE64` — `base64 -w0 dist.p12` output (Git Bash).
- `APPLE_DISTRIBUTION_CERT_PASSWORD` — the .p12 export password.
- `KEYCHAIN_PASSWORD` — any random string (protects the throwaway CI keychain).
- `APP_STORE_CONNECT_API_KEY_ID` — the API key's Key ID.
- `APP_STORE_CONNECT_API_ISSUER_ID` — the Issuer ID.
- `APP_STORE_CONNECT_API_PRIVATE_KEY` — the full text content of the `.p8` file.

## Phase 3 — repo gaps to close before the first upload (Claude, needs your input)

1. **App icon — DONE (2026-07-03)**: `Apps/iOS/Assets.xcassets` now carries a single-size
   1024×1024 AppIcon (white pixel-style "RS" on blue, 24-bit PNG without alpha — App
   Store Connect rejects alpha in the marketing icon), wired into the pbxproj resources
   phase with `ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon`. To rebrand later, just
   replace `AppIcon.appiconset/AppIcon.png` with another 1024×1024 no-alpha PNG.

2. **Export compliance** (verified against Apple's docs 2026-07-03): the plist shortcut
   `ITSAppUsesNonExemptEncryption = false` is documented for apps whose only encryption
   is OS-standard protocol use (e.g. HTTPS via URLSession). RemSound does its own
   end-to-end audio encryption — via Apple's CryptoKit/CommonCrypto, but for a custom
   protocol — so the honest declaration is: **uses encryption: yes; only standard
   algorithms (no proprietary crypto): yes**. Practical setup:
   - Answer the encryption questions **once at app level** in App Store Connect (App
     Information → App Encryption Documentation) so builds don't prompt individually.
   - File the annual **BIS self-classification report** (due Feb 1 each year — a short
     spreadsheet email; mass-market standard-crypto apps qualify for this simple route).
   - France requires an extra declaration if you distribute there.

3. Nothing else: versions are already wired (`CFBundleShortVersionString` =
   `$(MARKETING_VERSION)`, `CFBundleVersion` = `$(CURRENT_PROJECT_VERSION)`), so the
   workflow injects them at build time — tag `v1.2.3` becomes marketing version `1.2.3`
   and the workflow run number becomes the ever-increasing build number. The `0.1.0` in
   the pbxproj is only the local/Xcode fallback; the release skill keeps it in sync.

## Phase 4 — how a release then works (repeatable)

1. Say "cut a release" (or invoke `/release`). The skill will:
   - check the working tree is clean and CI is green on `main`,
   - propose the next semver + plain-text release notes drafted from the commits since the
     last tag (plain text on purpose — TestFlight shows "What to Test" without markdown),
   - sync `MARKETING_VERSION` in the pbxproj and commit,
   - after your explicit go-ahead: push and `gh release create vX.Y.Z`.
2. Publishing the release triggers `release.yml`:
   - `swift test`,
   - signed archive (cloud-managed provisioning via the API key — no profiles to maintain),
   - export IPA → **upload to TestFlight with the release body as the changelog**
     (fastlane pilot waits for processing, then sets "What to Test"),
   - attach `RemSound-iOS-vX.Y.Z.ipa` to the GitHub release,
   - throwaway keychain deleted even on failure.
3. TestFlight processing takes ~5–15 min; internal testers get the build automatically.

## Phase 5 — later / optional

- **macOS**: TestFlight for macOS is possible too (needs Developer ID / Mac App Store
  signing decisions + sandbox review for the network client entitlement) — separate plan
  when wanted; the unsigned zip from `build.yml` stays the macOS distribution meanwhile.
- Screenshots, the full App Privacy questionnaire, and the App Store listing only matter
  for an actual App Store release, not TestFlight.

## Verification notes (researched 2026-07-03)

The mechanics above were checked against current Apple/GitHub/fastlane documentation:

- Confirmed: the keychain-import steps match GitHub's official macOS-runner signing guide
  (including `base64 --decode -o`); fastlane is preinstalled on `macos-15` runners
  (default Xcode 16.4, fine for the iOS 18 target); `method = app-store-connect` is the
  current export method name (`app-store` is deprecated); pilot's `--changelog` sets
  "What to Test" once the build appears in App Store Connect; internal TestFlight is
  limited to App Store Connect users (max 100), external to 10 000 with Beta App Review
  on the first build per version.
- Fixed after verification: build numbers now include the run **attempt**
  (`run_number.run_attempt`) because re-running a failed workflow keeps the same
  run_number — a re-run after a partially-successful upload would otherwise collide;
  pilot now passes `--skip_waiting_for_build_processing` alongside the changelog (waits
  only until the build appears, then exits); the export-compliance guidance above was
  tightened from "declare false" to the yes-with-standard-algorithms declaration.
- Watch item: GitHub is migrating `macos-latest` to macOS 26 (mid-2026); the workflows
  pin `macos-15` deliberately — revisit the pin when GitHub announces its retirement.

## First-release checklist (condensed)

1. Phase 1 steps 2–7 done, Phase 2 secrets set.
2. Icon PNG handed to Claude → icon commit lands; encryption key decision made.
3. `/release` → confirm version + notes → release published.
4. Watch the `Release` workflow (`gh run watch` or share the logs); iterate if the first
   signing/upload attempt fails — that is normal.
5. Build appears in TestFlight → install via the TestFlight app on the iPhone.
