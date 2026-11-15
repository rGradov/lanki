# Releasing Lanki

Lanki updates itself through [Sparkle](https://sparkle-project.org) and is
installed through a Homebrew cask (this repo is the tap). A release is: bump the
version → build & notarize a DMG → regenerate `appcast.xml` → publish a GitHub
release. The cask then updates itself via the `update-cask.yml` workflow.

Everything below is done **once**, except the per-release steps.

## One-time setup

### 1. GitHub repo (this repo is also the Homebrew tap)

- Push this repo to `github.com/rGradov/lanki`.
- The cask lives at `Casks/lanki.rb` in this repo, so users install with
  `brew tap rGradov/lanki && brew install --cask lanki`. No separate tap repo or
  secret is needed — `update-cask.yml` commits back to this repo using its own
  `GITHUB_TOKEN` (it has `contents: write`).

### 2. Sparkle signing keys

Sparkle signs every update with an Ed25519 key. The **private** key lives in
your macOS Keychain; only the **public** key is embedded in the app.

```bash
# The Homebrew `sparkle` cask is disabled (fails Gatekeeper), so get the tools
# straight from the Sparkle GitHub release instead:
mkdir -p ~/Sparkle && cd ~/Sparkle
curl -fsSL -o Sparkle.tar.xz https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz
tar -xJf Sparkle.tar.xz
./bin/generate_keys
```

(Bump `2.10.1` to the latest tag on the [releases page](https://github.com/sparkle-project/Sparkle/releases) if newer.)

`generate_keys` stores the private key in your **Keychain** and prints the public
key. When macOS asks, click **Always Allow** so `generate_appcast` can sign
without prompting. Copy the printed `SUPublicEDKey` value into `Lanki-Info.plist`,
replacing `PASTE_YOUR_SPARKLE_ED25519_PUBLIC_KEY_HERE`.

> The private key normally stays in the Keychain and never becomes a file. If
> you ever export it (`generate_keys -x`), keep it somewhere safe and never
> commit it — losing the key means users can no longer verify your updates and
> you must regenerate and re-release with a new public key.

### 3. Apple Developer ID (signing + notarization)

You already have a **Developer ID Application** certificate (`Developer ID
Application: Uladzislau Rudzenia (97S3QGCCV4)`), so only the notarytool profile
is missing. Generate an **app-specific password** at
https://account.apple.com → Sign-In and Security → App-Specific Passwords, then:

```bash
xcrun notarytool store-credentials lanki-notary \
  --apple-id "your-developer-apple-id@example.com" \
  --team-id "97S3QGCCV4" \
  --password "xxxx-xxxx-xxxx-xxxx"
```

Use the Apple ID you log into developer.apple.com with (team id `97S3QGCCV4`)
and the app-specific password as `--password`.

Export your identity and set it in the release shell:

```bash
export DEVELOPER_ID_IDENTITY="Developer ID Application: Uladzislau Rudzenia (97S3QGCCV4)"
export NOTARY_PROFILE="lanki-notary"
```

## Per-release steps

1. **Bump the version** in `Lanki.xcodeproj` (target **Lanki**, both Debug and
   Release):
   - `MARKETING_VERSION` → semantic version, e.g. `1.0.0` (this becomes the
     `CFBundleShortVersionString` the user sees, and the release tag without `v`).
   - `CURRENT_PROJECT_VERSION` → a **larger integer than any previous build**
     (Sparkle compares this, not `MARKETING_VERSION`). Example: `29` → `30`.

2. **Archive and export** a signed, hardened-runtime `.app`:

   ```bash
   xcodebuild archive -project Lanki.xcodeproj -scheme Lanki \
     -configuration Release -archivePath build/Lanki.xcarchive \
     CODE_SIGN_IDENTITY="$DEVELOPER_ID_IDENTITY" DEVELOPMENT_TEAM="97S3QGCCV4"

   # ExportOptions.plist: { "method": "developer-id", "teamID": "97S3QGCCV4",
   #   "signingStyle": "manual",
   #   "signingCertificate": "Developer ID Application" }
   xcodebuild -exportArchive -archivePath build/Lanki.xcarchive \
     -exportPath build/export -exportOptionsPlist ExportOptions.plist
   ```

   The app is at `build/export/Lanki.app`.

3. **Build and notarize the DMG**, and print the release values (sha256, build):

   ```bash
   ./scripts/make-dmg.sh 2.0.0 build/export/Lanki.app
   ```

4. **Regenerate the appcast** (this also signs the DMG for Sparkle):

   ```bash
   # Put the DMG (and an optional Lankiv2.0.0.md release-notes file) in a folder.
   mkdir -p "$HOME/Downloads/Lanki/feed"
   cp "$HOME/Downloads/Lanki/Lankiv2.0.0.dmg" "$HOME/Downloads/Lanki/feed/"
   ~/Sparkle/bin/generate_appcast \
     --download-url-prefix "https://github.com/rGradov/lanki/releases/download/v2.0.0/" \
     -o appcast.xml \
     "$HOME/Downloads/Lanki/feed/"
   ```

   Commit and push the generated `appcast.xml`.

5. **Publish the GitHub release**:
   - Tag: `v2.0.0` (must match `MARKETING_VERSION` with a leading `v`).
   - Attach `Lankiv2.0.0.dmg` and a `Lankiv2.0.0.dmg.sha256` containing
     `shasum -a 256` of the DMG.
   - On `released`, `update-cask.yml` updates the Homebrew cask automatically.

Installed copies will offer the update within a day, and `brew upgrade --cask
lanki` picks it up immediately.

## What gets published (and what never does)

Published to GitHub/Homebrew:

- The signed, notarized **DMG** (app binary + Info.plist).
- `appcast.xml` (public: version, build number, release notes, URL, signature,
  file length).
- The **cask** (`lanki.rb`): public app name, version, download URL and sha256.

Never published:

- Your **API keys** (Pexels, translation) — they live in each user's
  `~/Library/Preferences/com.lanki.app.plist` and are never baked into the app.
- Your **Sparkle private key** — stored in your macOS Keychain, never on disk
  unless you explicitly export it.
- Your **Apple ID / app-specific password** — used only by `notarytool` locally.

The only identity-ish value in the repository is `DEVELOPMENT_TEAM` in
`Lanki.xcodeproj/project.pbxproj` (an Apple team identifier used for Xcode's
automatic signing). It is not a secret — it appears in every signed app — but if
you prefer to hide it you can move it to a git-ignored `Config.xcconfig`.
