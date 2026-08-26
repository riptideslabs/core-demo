#!/usr/bin/env bash
# Mint a throwaway CA and a Redis server certificate, so Redis can do its own
# TLS and the demo can show riptides passing an already-encrypted flow through.
#
# riptides cannot supply these: sysfs credential propagation delivers
# CONFIG/CREDENTIAL/TOKEN files, not X.509 keypairs, so there is no SVID-to-file
# path an application could use as its own server certificate.
#
# Runs in the VM (or anywhere with openssl) and writes into app/.certs/, which is
# gitignored. Idempotent: existing, still-valid certs are left alone.
set -euo pipefail

CERT_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/.certs}"
DAYS=30

mkdir -p "$CERT_DIR"
cd "$CERT_DIR"

if [[ -s redis.crt ]] && openssl x509 -in redis.crt -checkend 86400 >/dev/null 2>&1; then
    echo "certs already present and valid: $CERT_DIR"
    exit 0
fi

# The CA. Throwaway — it exists to make Redis' own TLS real rather than skipped
# with --insecure, nothing more.
#
# The explicit extensions matter: without keyUsage, modern OpenSSL rejects the
# chain with "CA cert does not include key usage extension". redis-cli happens to
# accept such a CA, Python's ssl module does not — and the probe is the whole
# point of the act.
openssl req -x509 -newkey rsa:2048 -sha256 -days "$DAYS" -nodes \
    -keyout ca.key -out ca.crt -subj "/CN=riptides-demo-redis-ca" \
    -addext "basicConstraints=critical,CA:TRUE" \
    -addext "keyUsage=critical,digitalSignature,cRLSign,keyCertSign" 2>/dev/null

# The server cert. redis-cli connects to 127.0.0.1, so the IP SAN is what makes
# verification succeed; without it redis-cli would need --insecure and the
# "the app does its own real TLS" claim would be hollow.
openssl req -newkey rsa:2048 -nodes -keyout redis.key -out redis.csr \
    -subj "/CN=demo-redis" 2>/dev/null

openssl x509 -req -in redis.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -days "$DAYS" -sha256 -out redis.crt \
    -extfile <(printf 'subjectAltName=DNS:localhost,DNS:demo-redis,IP:127.0.0.1\nbasicConstraints=CA:FALSE\nextendedKeyUsage=serverAuth\n') \
    2>/dev/null

rm -f redis.csr ca.srl

# The container runs redis as its own uid, and the key is bind-mounted read-only.
# World-readable is fine for a cert that lives for 30 days and protects nothing.
chmod 644 ca.crt ca.key redis.crt redis.key

echo "minted in $CERT_DIR:"
openssl x509 -in redis.crt -noout -subject -issuer -ext subjectAltName |
    sed 's/^/  /'
