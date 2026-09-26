# Signing

yap has no paid Apple Developer account (PLAN.md section 8), so it can't be
notarized. It is still signed, with one self-signed certificate that never
changes. That is what keeps permissions working across updates.

## Why a stable certificate keeps permissions

When you grant yap Microphone or Accessibility, macOS (TCC) stores yap's
*designated requirement*: the rule a binary must satisfy to count as "this
app". Every later check runs the new binary against that stored rule.

- **Ad-hoc** signing (`-`) has no certificate, so the requirement is the hash
  of that exact build: `cdhash H"e1b2…"`. The next build has another hash,
  fails the rule, and is a stranger to TCC. The switch in System Settings still
  looks on, but nothing works until the user removes and re-adds yap.
- **Self-signed** gives a requirement anchored to the certificate itself:
  `identifier "com.bjornbom.yap" and certificate leaf = H"<cert SHA-1>"`. Every
  build signed with the same certificate satisfies it, so updates keep their
  permissions.

Sparkle uses the same rule: an update must satisfy the installed app's
designated requirement as well as carry a valid EdDSA signature.

Check a build with `codesign -d -r- yap.app`. Anything with `cdhash` is ad-hoc.

The certificate does not make Gatekeeper happy (only notarization does), and
users never have to trust it. The install script and Homebrew avoid the
quarantine flag instead, and Sparkle downloads are not quarantined.

Hardened runtime is on, with one exception: `disable-library-validation`.
Library validation only loads frameworks signed with the app's Apple Team ID,
and self-signed or ad-hoc code has none, so it would refuse Sparkle.framework.
With a Developer ID this entitlement can go.

**Never replace the certificate.** A new one means every user grants
permissions again. Back up the .p12 and its password (e.g. in a password
manager). It is valid for 20 years; signatures aren't timestamped (Apple's
timestamp service only serves Apple-issued certificates).

## Create it (once)

```sh
scripts/signing/make-certificate.sh          # writes ~/yap-signing/
```

It only writes files: `yap-signing.p12`, `yap-signing.password`,
`yap-signing.p12.base64` (for the GitHub secret) and `yap-signing.cer.pem`.
Nothing is imported into any keychain.

## Use it on this Mac (optional)

Only needed to make signed Release builds locally; CI signs releases on its own.
These commands change your login keychain, so run them yourself:

```sh
cd ~/yap-signing
# Import certificate + key; only codesign may use the key without asking.
security import yap-signing.p12 -k ~/Library/Keychains/login.keychain-db \
	-P "$(cat yap-signing.password)" -T /usr/bin/codesign
# Trust it for code signing (asks for your password). Xcode only offers
# trusted identities; the codesign tool alone doesn't need this.
security add-trusted-cert -r trustRoot -p codeSign \
	-k ~/Library/Keychains/login.keychain-db yap-signing.cer.pem
# Must list "yap self-signed (bjornbom)" as a valid identity:
security find-identity -v -p codesigning
```

Then tell Release builds to use it, either per shell or permanently:

```sh
export YAP_SIGN_IDENTITY="yap self-signed (bjornbom)"
echo 'YAP_SIGN_IDENTITY = yap self-signed (bjornbom)' > App/Signing.local.xcconfig  # git-ignored
```

Without it, Release builds are ad-hoc signed and print a warning.

To undo: Keychain Access → login → My Certificates → delete
"yap self-signed (bjornbom)".
