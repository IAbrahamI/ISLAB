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
- Setup steps were in the Mac test guide (removed from the repo; see git history).

## 5. Live test on the Mac (2026-11-01)
- Ran it in this order: `docker compose up -d step-ca`, then `./pki-setup.sh islab.internal`, then trusted the root CA in Keychain, then `docker compose up -d npmplus`.
- Created the "Certbot via HTTP" certs `npm.islab.internal` and `app.islab.internal`. Both were issued by the private CA and are valid for 7 days.
- Set up the admin UI behind `https://npm.islab.internal` (proxy to `https://127.0.0.1:81`, no mTLS).
- Set up the test app `app.islab.internal` (proxy to the `whoami` container) with mTLS set to optional and `if ($mtls_block) { return 403; }`.
  - Without a client cert the page returns 403. With the `macbook` client cert (curl and browser) the whoami page loads.
- Problem found: the macOS Keychain couldn't import the `.p12` ("Unable to decode the provided data").
  - Fix: `client-cert.sh` now builds the `.p12` with `--legacy` (SHA1/3DES), which Keychain accepts.
- Browser tip: after importing a client cert, quit the browser fully (Cmd+Q) before retrying. Otherwise it keeps reusing the old connection that had no cert.

## 6. Plan for the home server (2026-11-07)
- Pushed the Mac test setup to GitHub (private repo `ISLAB`). Secrets are kept out by `.gitignore`.
- Decided that **all** certificates, server certs included, come from our own CA, not Let's Encrypt.
- Naming: rejected `*.aby-host-network.duckdns.org`, because we don't own that name, and `aby.internal`. Chose **`*.matrix.internal`**.
  - `.internal` is officially reserved for private networks, so it never clashes with a real site.
- Server package (`SERVER-SETUP.md`):
  - Migrates NPM to NPMplus; NPM's `letsencrypt` folder is mounted once.
  - Fresh CA named "Matrix".
  - **dnsmasq** wildcard: `*.matrix.internal` → NPMplus. New services need no aliases and no `/etc/hosts`.
  - step-ca has no published port. NPMplus listens only on `BIND_IP` (LAN IP now, WireGuard IP later). Admin UI only on `127.0.0.1:81`.
  - Client certs last 1 year, one per device. Added `./client-cert.sh revoke <device>`, which blocks the device in NPMplus immediately (revoked-serials list) and marks it revoked in step-ca.
- Tested everything in a clean test environment except the real NPM data migration, WireGuard and non-Mac imports.
- Networks: the stack is called **gateway** (no project name in it). NPMplus also joins the existing `nginxproxymanager_default` network, so the app stacks stay unchanged.
- Fix: dnsmasq first answered with NPMplus's Docker IP (172.30.10.10), which devices can't reach. It now answers with `BIND_IP`, which devices and step-ca both reach. Only dnsmasq keeps a fixed IP (172.30.10.53), because step-ca's `dns:` setting needs an IP. Tested.

## 7. Clean repo and deploy guide (2026-11-07)
- The server is a **Raspberry Pi** (aarch64). All three images have arm64 builds. cachyOS is only where I edit the repo.
- Removed the Mac test guide. Moved the two mTLS files from `data/custom_nginx/` to `nginx/` (mounted into NPMplus), so `data/` is purely runtime and fully ignored by git.
- One guide to follow: `DEPLOY.md` (migration, first deploy, everyday use, WireGuard later). It replaces `SERVER-SETUP.md`.

## 8. Deployed on the Pi (2026-11-07)
- Cloned to `~/NPMPlus`, next to the old NPM folder. Copied `data/` and `letsencrypt/`, and the old proxy hosts and login carried over.
- Router: first DNS server = the Pi, second empty. dnsmasq forwards other names to Quad9/Cloudflare. If the Pi is down: open the router by IP and set DNS back to automatic.
- First host on the private CA: `npm.matrix.internal` (admin UI) with mTLS. Root CA and device cert installed on the Mac.
- Found: NPMplus renews **every** cert through `ACME_SERVER` (now our CA), so the DuckDNS Let's Encrypt cert can't renew. Decided to move all services to `matrix.internal`, with mTLS only where needed, before that cert expires.
