#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# generate-certs.sh — Generate self-signed CA + server certificate
# for local Forgejo SSL at forgejo.local
# ---------------------------------------------------------------------------
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CERT_DIR="$SCRIPT_DIR"

info()  { echo -e "\033[1;34m[INFO]\033[0m  $*"; }
ok()    { echo -e "\033[1;32m[ OK ]\033[0m  $*"; }

info "Generating self-signed SSL certificates for Forgejo..."

# 1. Generate CA key + certificate (if not already present)
if [[ -f "$CERT_DIR/ca-cert.pem" ]] && [[ -f "$CERT_DIR/ca-key.pem" ]]; then
  info "CA certificate already exists, skipping CA generation."
else
  info "Generating CA key and certificate..."
  openssl req -x509 -newkey rsa:4096 \
    -keyout "$CERT_DIR/ca-key.pem" \
    -out "$CERT_DIR/ca-cert.pem" \
    -days 3650 -nodes \
    -subj "/CN=local-forgejo-ca"
  ok "CA certificate created."
fi

# 2. Generate server key + CSR
info "Generating server key and CSR..."
openssl req -newkey rsa:4096 \
  -keyout "$CERT_DIR/server-key.pem" \
  -out "$CERT_DIR/server.csr" \
  -nodes \
  -subj "/CN=forgejo.local"

# 3. Create SAN extension file
cat > "$CERT_DIR/ext.cnf" <<'EOF'
subjectAltName = DNS:forgejo.local, DNS:localhost, DNS:forgejo, IP:127.0.0.1
EOF

# 4. Sign the server certificate with the CA
info "Signing server certificate..."
openssl x509 -req \
  -in "$CERT_DIR/server.csr" \
  -CA "$CERT_DIR/ca-cert.pem" \
  -CAkey "$CERT_DIR/ca-key.pem" \
  -CAcreateserial \
  -out "$CERT_DIR/server-cert.pem" \
  -days 3650 \
  -extfile "$CERT_DIR/ext.cnf"

# 5. Clean up CSR (not needed after signing)
rm -f "$CERT_DIR/server.csr"

# 6. Verify
echo ""
info "Certificate details:"
openssl x509 -in "$CERT_DIR/server-cert.pem" -text -noout | grep -E "(Subject:|Issuer:|Subject Alternative|Not Before|Not After)" | sed 's/^/  /'

echo ""
ok "Certificates generated in: $CERT_DIR"
echo ""
echo "  CA cert:      $CERT_DIR/ca-cert.pem"
echo "  Server cert:  $CERT_DIR/server-cert.pem"
echo "  Server key:   $CERT_DIR/server-key.pem"
echo ""
echo "To trust this CA on your system (so browsers don't warn):"
echo "  sudo cp $CERT_DIR/ca-cert.pem /etc/pki/ca-trust/source/anchors/"
echo "  sudo update-ca-trust"
