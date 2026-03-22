---
name: release
description: Release a new version of Wave Terminal
user-invocable: true
---

# Release a new version of Wave Terminal

When the user asks to release, cut a release, or bump the version:

## Steps

1. **Bump the version** in `project.yml` under `MARKETING_VERSION`
2. **Commit and push** the version bump
3. **Tag** with `v{version}` and push the tag
4. **Watch** the release workflow to confirm it passes
5. **Update the Homebrew cask** in the `shkumbinhasani/homebrew-tap` repo:
   - Clone `/tmp/homebrew-tap` from `https://github.com/shkumbinhasani/homebrew-tap.git`
   - Download the zip from the new release and compute `shasum -a 256`
   - Update `version` and `sha256` in `Casks/wave.rb`
   - Commit and push

## Important details

- The release workflow (`.github/workflows/release.yml`) triggers on `v*` tags
- It builds GhosttyKit, builds the app, signs the zip with Sparkle EdDSA, generates an appcast, and creates a GitHub Release
- The app is adhoc-signed with identifier `com.wave.terminal` and `codesign -s - --force --deep --identifier com.wave.terminal`
- The Sparkle private key is stored as the `SPARKLE_PRIVATE_KEY` GitHub secret
- The `MARKETING_VERSION` in `project.yml` is the dev version; CI overrides it from the git tag via `MARKETING_VERSION="$VERSION"` in the build step
- The Homebrew tap repo is `shkumbinhasani/homebrew-tap`

## Example

```bash
# 1. Bump version
sed -i '' 's/MARKETING_VERSION: "0.1.14"/MARKETING_VERSION: "0.2.0"/' project.yml

# 2. Commit and push
git add -A && git commit -m "Release v0.2.0" && git push

# 3. Tag
git tag v0.2.0 && git push origin v0.2.0

# 4. Watch CI
gh run watch $(gh run list --repo shkumbinhasani/wave --workflow release.yml -L1 --json databaseId --jq '.[0].databaseId') --repo shkumbinhasani/wave --exit-status

# 5. Update cask
SHA=$(curl -sL https://github.com/shkumbinhasani/wave/releases/download/v0.2.0/wave-macos-arm64.zip | shasum -a 256 | awk '{print $1}')
cd /tmp && rm -rf homebrew-tap && git clone https://github.com/shkumbinhasani/homebrew-tap.git && cd homebrew-tap
sed -i '' 's/version "[^"]*"/version "0.2.0"/' Casks/wave.rb
sed -i '' "s/sha256 \"[^\"]*\"/sha256 \"$SHA\"/" Casks/wave.rb
git add -A && git commit -m "Update wave to 0.2.0" && git push
```
