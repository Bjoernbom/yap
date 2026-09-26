#!/bin/sh
# Creates yap's self-signed code-signing certificate and private key as a
# password-protected .p12. It does not touch any keychain: importing and
# trusting the certificate is a separate, deliberate step (docs/SIGNING.md).
#
# Usage: scripts/signing/make-certificate.sh [output-dir]
# Default output dir: ~/yap-signing (created with mode 700).
#
# Make this once and keep it forever. Every build signed with it has the same
# designated requirement, which is what keeps Microphone and Accessibility
# permissions across updates. A new certificate means every user grants them
# again.
set -eu

name="yap self-signed (bjornbom)"
days=7300 # 20 years: signatures aren't timestamped, so the cert must outlive the app
out=${1:-"$HOME/yap-signing"}

if [ -e "$out/yap-signing.p12" ]; then
	echo "error: $out/yap-signing.p12 already exists. Keep using it; don't make a second one." >&2
	exit 1
fi

umask 077
mkdir -p "$out"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $name
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

openssl req -x509 -newkey rsa:3072 -sha256 -nodes -days "$days" \
	-config "$work/cert.cnf" -keyout "$work/key.pem" -out "$out/yap-signing.cer.pem" 2>/dev/null

password=$(openssl rand -base64 30 | tr -d '/+=' | cut -c1-32)
printf '%s\n' "$password" > "$out/yap-signing.password"

# SHA1-3DES PBE and a SHA1 MAC: the one .p12 flavour macOS `security import`
# reads on every version, from both OpenSSL 3 and LibreSSL.
openssl pkcs12 -export -name "$name" \
	-inkey "$work/key.pem" -in "$out/yap-signing.cer.pem" \
	-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
	-passout "pass:$password" -out "$out/yap-signing.p12"

# One line of base64 for the SIGNING_CERTIFICATE_P12 GitHub secret.
base64 < "$out/yap-signing.p12" | tr -d '\n' > "$out/yap-signing.p12.base64"

echo "Created in $out:"
echo "  yap-signing.p12          certificate + private key (keep it safe, back it up)"
echo "  yap-signing.password     its password"
echo "  yap-signing.p12.base64   for the SIGNING_CERTIFICATE_P12 GitHub secret"
echo "  yap-signing.cer.pem      the public certificate"
echo
openssl x509 -in "$out/yap-signing.cer.pem" -noout -subject -enddate -fingerprint -sha1
echo
echo "Nothing was imported. Next steps: docs/SIGNING.md."
