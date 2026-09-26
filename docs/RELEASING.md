# Releasing yap

A tag `v1.*` on main builds, signs and publishes a GitHub **pre-release**
(`.github/workflows/release.yml`). 1.x never becomes "latest" while yap 0.4
users update from `releases/latest/download/latest.json` (PLAN.md section 8).

## One-time setup

Everything here is yours to run; nothing in the repo does it for you.

1. **Signing certificate.** `scripts/signing/make-certificate.sh` writes
   `~/yap-signing/`. Back up `yap-signing.p12` and `yap-signing.password`
   (password manager); losing them means every user re-grants permissions.
   Import and trust it on this Mac only if you want signed local builds:
   [SIGNING.md](SIGNING.md#use-it-on-this-mac-optional).
2. **Sparkle keys.** Build once (`scripts/release/package.sh --dry-run`), then:
   ```sh
   bin=build/release/SourcePackages/artifacts/sparkle/Sparkle/bin
   $bin/generate_keys                      # stores the private key in your login keychain, prints the public key
   $bin/generate_keys -x ~/yap-signing/sparkle-private-key.txt
   ```
   Put the printed public key in `project.yml` (`SPARKLE_PUBLIC_KEY: "…"`)
   and merge that. Until then the updater stays off and releases refuse to build.
3. **GitHub secrets** (repo → Settings → Secrets and variables → Actions):
   ```sh
   gh secret set SIGNING_CERTIFICATE_P12      < ~/yap-signing/yap-signing.p12.base64
   gh secret set SIGNING_CERTIFICATE_PASSWORD < ~/yap-signing/yap-signing.password
   gh secret set SPARKLE_PRIVATE_KEY          < ~/yap-signing/sparkle-private-key.txt
   ```
   Without them a tag still makes a pre-release, but ad-hoc signed and
   without an appcast entry (a test build).
4. **Homebrew tap.** Create the public repo `Bjoernbom/homebrew-tap` with a
   `Casks/` folder. Users then run `brew install --cask bjoernbom/tap/yap`.
5. The release workflow pushes `appcast.xml` to main. If you protect main
   later, let `github-actions[bot]` push or the appcast step fails.

## Per release

1. On an up-to-date main: `git tag v1.0.0-beta.1 && git push origin v1.0.0-beta.1`.
   The build number is the commit count on main; Sparkle compares it.
2. Watch the `release` workflow. It tests, packages, creates the pre-release
   with `yap-<version>.zip`, `.dmg`, `SHA256SUMS` and `install.sh`, then
   commits the appcast item to main (installed apps see it within a day;
   raw.githubusercontent.com caches for about 5 minutes).
3. Copy the cask from the run summary into `Casks/yap.rb` in the tap and push.
   Template: `packaging/homebrew/yap.rb`.
4. Install once yourself:
   `curl -fsSL https://raw.githubusercontent.com/Bjoernbom/yap/main/scripts/install.sh | sh`
   (the one-liner in PLAN.md, `releases/latest/download/install.sh`, only
   works once 1.x is allowed to be "latest").

Locally, `scripts/release/package.sh --dry-run` makes the same artifacts in
`dist/` without secrets (ad-hoc signed, unsigned appcast item).

## Size

The download is the zip, about 6 MB (budget: 15 MB); the app is 13 MB on
disk. Release builds strip symbols (the dSYM keeps them). FluidAudio's
NemoTextProcessing trait is off and really absent from Xcode builds: no
`rustfst`/`text_processing_rs` symbols. The "Nemo" symbols left are
Nemotron ASR and a pass-through Swift shim.
