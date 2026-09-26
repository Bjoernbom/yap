# Releasing yap

A tag `v1.*` on main builds, signs and publishes a GitHub release
(`.github/workflows/release.yml`). A plain version (`v1.0.0`) becomes the
**latest** release, so `https://github.com/Bjoernbom/yap/releases/latest/download/yap.dmg` always serves the newest yap. A tag with a
suffix (`v1.1.0-beta.1`) is a pre-release: it never becomes latest and the
install script skips it unless asked for it by name (`YAP_VERSION=v1.1.0-beta.1`).

yap 0.4 updated itself from `releases/latest/download/latest.json`. 1.x
doesn't ship that file, so 0.4 stops seeing updates; its users install 1.x by
hand.

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
   Without them a tag still makes a release, but ad-hoc signed and without
   an appcast entry (a test build).
4. **Homebrew tap.** Create the public repo `Bjoernbom/homebrew-tap` with a
   `Casks/` folder. Users then run `brew install --cask bjoernbom/tap/yap`.
5. The release workflow pushes `appcast.xml` to main. If you protect main
   later, let `github-actions[bot]` push or the appcast step fails.

## Per release

1. On an up-to-date main: `git tag v1.0.0 && git push origin v1.0.0`.
   The build number is the commit count on main; Sparkle compares it.
2. Watch the `release` workflow. It tests, packages, creates the release
   with `yap-<version>.zip`, `.dmg`, a fixed-name `yap.dmg`, `SHA256SUMS` and
   `install.sh`, then
   commits the appcast item to main (installed apps see it within a day;
   raw.githubusercontent.com caches for about 5 minutes).
3. Copy the cask from the run summary into `Casks/yap.rb` in the tap and push.
   Template: `packaging/homebrew/yap.rb`.
4. Install once yourself:
   `curl -fsSL https://raw.githubusercontent.com/Bjoernbom/yap/main/scripts/install.sh | sh`

Locally, `scripts/release/package.sh --dry-run` makes the same artifacts in
`dist/` without secrets (ad-hoc signed, unsigned appcast item).

## Size

The download is the zip, about 6 MB (budget: 15 MB); the app is 13 MB on
disk. Release builds strip symbols (the dSYM keeps them). FluidAudio's
NemoTextProcessing trait is off and really absent from Xcode builds: no
`rustfst`/`text_processing_rs` symbols. The "Nemo" symbols left are
Nemotron ASR and a pass-through Swift shim.
