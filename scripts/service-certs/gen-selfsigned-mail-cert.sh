#!/usr/bin/env bash
set -euo pipefail

# Generate a self-signed certificate for mail.example.com
# - Creates: ./mail.example.com.key (2048-bit RSA), ./mail.example.com.crt (SHA256, 825 days)
# - SAN: DNS:mail.example.com
# - Idempotent: won't overwrite existing files unless -f is specified.
# - Optionally change domain via -d <fqdn>.

usage() {
  cat <<USAGE
Usage: $0 [-d fqdn] [-f]
  -d fqdn   FQDN to use (default: mail.example.com)
  -f        Force overwrite of existing key/cert
USAGE
}

FQDN="mail.example.com"
FORCE=0

while getopts ":d:fh" opt; do
  case "$opt" in
    d) FQDN="$OPTARG" ;;
    f) FORCE=1 ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG requires an argument" >&2; usage; exit 1 ;;
    \?) echo "Unknown option -$OPTARG" >&2; usage; exit 1 ;;
  esac
done

KEY_FILE="${FQDN}.key"
CRT_FILE="${FQDN}.crt"
CSR_FILE="${FQDN}.csr"
OPENSSL_CFG=".${FQDN}.openssl.cnf"

if [[ $FORCE -eq 0 ]] && { [[ -f "$KEY_FILE" ]] || [[ -f "$CRT_FILE" ]]; }; then
  echo "Refusing to overwrite existing $KEY_FILE or $CRT_FILE. Use -f to force." >&2
  exit 2
fi

# Create a minimal OpenSSL config to include SAN
cat > "$OPENSSL_CFG" <<CFG
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
req_extensions     = v3_req
prompt             = no

[ req_distinguished_name ]
CN = $FQDN
O  = Self-Signed
C  = US

[ v3_req ]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = $FQDN
CFG

# Generate key and certificate
openssl req -x509 -newkey rsa:2048 \
  -keyout "$KEY_FILE" -out "$CRT_FILE" \
  -sha256 -days 825 -nodes \
  -config "$OPENSSL_CFG" -extensions v3_req

chmod 600 "$KEY_FILE"

# Cleanup CSR placeholder and temp config if present
rm -f "$CSR_FILE" "$OPENSSL_CFG"

echo "Generated: $CRT_FILE (self-signed) and $KEY_FILE for $FQDN"
