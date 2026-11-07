#!/usr/bin/env bash
# Issue or renew an mTLS client certificate from the private CA.
#   ./client-cert.sh new   <name>   -> client-certs/<name>.{crt,key,p12}  (30 days)
#   ./client-cert.sh renew <name>   -> renews before expiry, rebuilds the .p12
# Import the .p12 into macOS Keychain (double-click) to use it in Safari/Chrome.
set -euo pipefail
cmd="${1:-}"; name="${2:-}"
[ -n "$cmd" ] && [ -n "$name" ] || { sed -n 2,5p "$0"; exit 1; }
cd "$(dirname "$0")"
mkdir -p client-certs
STEP=(docker compose exec -T step-ca step)
CA=(--ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt)
W=/home/step/client-work; docker compose exec -T step-ca sh -c "rm -rf $W && mkdir -p $W"

case "$cmd" in
  new)
    "${STEP[@]}" ca certificate "$name" "$W/$name.crt" "$W/$name.key" \
      --provisioner clients --provisioner-password-file /home/step/secrets/password \
      --kty EC --curve P-256 --force "${CA[@]}" ;;
  renew)
    for f in crt key; do docker compose exec -T step-ca sh -c "cat > $W/$name.$f" < "client-certs/$name.$f"; done
    "${STEP[@]}" ca renew "$W/$name.crt" "$W/$name.key" --force "${CA[@]}" ;;
  *) echo "unknown command: $cmd"; exit 1 ;;
esac

P12PASS="$(openssl rand -hex 12)"
docker compose exec -T step-ca sh -c "printf %s '$P12PASS' > $W/p12pass && \
  step certificate p12 $W/$name.p12 $W/$name.crt $W/$name.key --password-file $W/p12pass --legacy --force >/dev/null"
for f in crt key p12; do docker compose exec -T step-ca cat "$W/$name.$f" > "client-certs/$name.$f"; done
docker compose exec -T step-ca rm -rf "$W"
chmod 600 client-certs/"$name".key client-certs/"$name".p12
"${STEP[@]}" certificate inspect --short - < "client-certs/$name.crt"
echo "p12 import password: $P12PASS"
