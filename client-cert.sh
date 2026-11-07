#!/usr/bin/env bash
# Issue, renew or revoke an mTLS client certificate from the private CA.
#   ./client-cert.sh new    <device>  -> client-certs/<device>.{crt,key,p12}  (1 year)
#   ./client-cert.sh renew  <device>  -> renews before expiry, rebuilds the .p12
#   ./client-cert.sh revoke <device>  -> blocks the cert in NPMplus immediately
# One cert per device (e.g. macbook, pixel, thinkpad). Import guide: DEPLOY.md
set -euo pipefail
cmd="${1:-}"; name="${2:-}"
[ -n "$cmd" ] && [ -n "$name" ] || { sed -n 2,6p "$0"; exit 1; }
cd "$(dirname "$0")"
mkdir -p client-certs
STEP=(docker compose exec -T step-ca step)
CA=(--ca-url https://localhost:9000 --root /home/step/certs/root_ca.crt)
W=/home/step/client-work; docker compose exec -T step-ca sh -c "rm -rf $W && mkdir -p $W"

if [ "$cmd" = revoke ]; then
  crt="client-certs/$name.crt"
  [ -f "$crt" ] || { echo "No $crt found."; exit 1; }
  map=nginx/revoked-serials.map
  serial_hex="$(openssl x509 -noout -serial -in "$crt" | cut -d= -f2)"
  if grep -q "^$serial_hex " "$map" 2>/dev/null; then echo "$name is already revoked."; exit 0; fi
  # 1) NPMplus: block this serial right away
  echo "$serial_hex 1;  # $name, revoked $(date +%F)" >> "$map"
  if docker compose exec -T npmplus nginx -t >/dev/null 2>&1; then docker compose exec -T npmplus nginx -s reload; else echo "WARNING: nginx config test failed, check $map"; fi
  # 2) step-ca: mark revoked, so the cert can never be renewed
  for f in crt key; do docker compose exec -T step-ca sh -c "cat > $W/$name.$f" < "client-certs/$name.$f"; done
  "${STEP[@]}" ca revoke --cert "$W/$name.crt" --key "$W/$name.key" --reason "device removed" "${CA[@]}"
  docker compose exec -T step-ca rm -rf "$W"
  mkdir -p client-certs/revoked
  mv client-certs/"$name".* client-certs/revoked/
  echo "Revoked $name (serial $serial_hex). Files moved to client-certs/revoked/."
  exit 0
fi

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
