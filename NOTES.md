# ISLAB – work log

Short record of what we did, kept for later documentation.

## 1. Chose the reverse proxy
- Compared Nginx Proxy Manager (NPM) with NPMplus (`zoeyvid/npmplus`).
- Checked the release and update timeline of both. NPMplus is updated more often, and that includes security fixes.
- **Decision:** NPMplus.

## 2. Created the compose file (macOS, Docker Desktop)
- Image `docker.io/zoeyvid/npmplus:latest`.
- Port mappings 80, 443 tcp+udp (HTTP/3), and 81 (admin UI). Host networking is not used, because it doesn't work on Docker Desktop for Mac.
- Volume `./npmplus-data:/data`, `TZ=Europe/Zurich`, `ACME_EMAIL`.

## 3. Tested it
- The admin UI at https://localhost:81 returned "connection reset".
- `docker ps` showed the ports mapped correctly.
- The logs showed certbot rejecting the placeholder `ACME_EMAIL=you@example.com`.
- **Fix:** set a real email and run `docker compose up -d --force-recreate`. After that, NPMplus ran.

## 4. Own PKI with mTLS and automatic renewal
- Checked the NPMplus docs and source:
  - It supports a custom ACME server (`ACME_SERVER`).
  - It supports mTLS per host. You upload a CA as an "mTLS certificate" and select it on the host.
- Chose **smallstep step-ca** as the private CA, running next to NPMplus with ACME enabled.
- NPMplus now requests and renews its server certs from step-ca. certbot trusts the CA through `REQUESTS_CA_BUNDLE`.
- Hardened the CA (`pki-setup.sh`):
  - It only issues for `*.islab.internal`.
  - Server certs last 7 days and have serverAuth only.
  - A separate `clients` provisioner issues 30-day client certs with clientAuth only.
- Tested the whole stack before rollout. Found that "mTLS required" breaks automatic renewal, because the CA's HTTP-01 check can't present a client cert.
  - **Fix:** use "verify client optional" plus an nginx rule that returns 403 without a valid client cert and leaves only the ACME challenge path open.
  - Re-tested: renewal works, and requests without a valid client cert are blocked.
- Added `client-cert.sh` to issue and renew client certs, including a `.p12` for the macOS Keychain.
- Setup steps: see `PKI-SETUP.md`.
