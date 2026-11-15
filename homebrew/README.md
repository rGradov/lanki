# Homebrew tap for Lanki

This folder is the source of the Homebrew cask for Lanki. It lives here so the
main repo stays the single place to review the install definition, but the
actual tap is a **separate** GitHub repository:

```
rGradov/homebrew-tap
```

The cask file lives there at `Casks/lanki.rb`. The `update-cask.yml` workflow in
the main repo updates that file automatically on every release, so after the
one-time setup below you never touch the tap again.

## One-time setup

1. Create a new public repo `rGradov/homebrew-tap` on GitHub.

2. Copy this `Casks/` folder into it (commit `Casks/lanki.rb` to its `main`
   branch).

3. Create a Personal Access Token with the `repo` scope for that repo:
   GitHub → Settings → Developer settings → Personal access tokens → Fine-grained
   token → give it **Contents: read-write** on `rGradov/homebrew-tap`.

4. In the **main** repo (`rGradov/lanki`) add a secret named
   `HOMEBREW_TAP_TOKEN` with that token (Settings → Secrets and variables →
   Actions).

## Installing Lanki with Homebrew

Once the tap and cask exist:

```bash
brew tap rGradov/homebrew-tap
brew install --cask lanki
```

## Notes

- The cask `version` must equal the app's `MARKETING_VERSION` and the GitHub
  release tag **without** the leading `v` (e.g. tag `v1.0.0` → `version "1.0.0"`).
- Homebrew verifies the DMG `sha256`, so a wrong checksum blocks install rather
  than installing something altered in transit.
- The DMG should be signed and notarized before releasing, otherwise macOS
  Gatekeeper will warn "unidentified developer" (see `RELEASE.md`).
- No secrets live in the cask: only the public app name, download URL, version
  and checksum. API keys stay in the user's own `~/Library/Preferences` and are
  never part of the cask or the DMG.
