#!/usr/bin/env bash
# One-time hardening of the step-ca config created on first start.
# Usage: ./pki-setup.sh islab.internal
#   - ACME provisioner: only issues for *.<domain>, server-only certs, 7-day lifetime
#   - new "clients" provisioner: client-only certs (for mTLS), 30-day lifetime
# Safe to re-run.
set -euo pipefail
DOMAIN="${1:-islab.internal}"
cd "$(dirname "$0")"

docker compose exec -T step-ca test -f /home/step/config/ca.json \
  || { echo "step-ca is not initialised yet. Run: docker compose up -d step-ca"; exit 1; }

mkdir -p step-ca-data/templates
cp step-templates/server.tpl step-templates/client.tpl step-ca-data/templates/

docker compose exec -T -e DOMAIN="$DOMAIN" step-ca sh -euc '
  cd /home/step/config
  if ! jq -e ".authority.provisioners[] | select(.name == \"clients\")" ca.json >/dev/null; then
    step ca provisioner add clients --type JWK --create \
      --password-file /home/step/secrets/password \
      --x509-template /home/step/templates/client.tpl \
      --x509-default-dur 720h --x509-max-dur 2160h \
      --ca-config /home/step/config/ca.json
  fi
  cp ca.json ca.json.bak
  jq --arg d "*.$DOMAIN" "
    .authority.provisioners |= map(
      if .type == \"ACME\" then
        .claims = {defaultTLSCertDuration: \"168h\", maxTLSCertDuration: \"720h\"}
        | .options.x509.templateFile = \"/home/step/templates/server.tpl\"
        | .policy.x509.allow.dns = [\$d]
      else . end)" ca.json.bak > ca.json

'
docker compose restart step-ca
echo
echo "Done. Root CA: $(pwd)/step-ca-data/certs/root_ca.crt"
docker compose exec -T step-ca step certificate fingerprint /home/step/certs/root_ca.crt | sed 's/^/Root fingerprint: /'
