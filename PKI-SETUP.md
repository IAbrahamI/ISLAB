# Private PKI + mTLS for NPMplus

## What this sets up

```
 Browser / client ──mTLS──▶ NPMplus :443 ──▶ your app containers
   (client cert)              │  ▲
                              │  │ server cert (ACME, auto-renewed)
                       certbot│  │
                              ▼  │
                        step-ca :9000  (private Root + Intermediate CA)
```

- **step-ca** (smallstep) is your private CA. It runs next to NPMplus, and its port is bound to `127.0.0.1` only.
- **Server certificates**: NPMplus uses step-ca as its ACME server (`ACME_SERVER`). Every cert you request in the NPMplus UI is issued by your CA and renewed automatically. Certs last 7 days and certbot renews them at half their lifetime. certbot runs every 3 hours (`CERTBOT_RUN_INTERVAL`).
- **Client certificates (mTLS)**: issued by a separate `clients` provisioner and valid for 30 days. NPMplus checks them against your root CA on each proxy host where you enable mTLS.
- **Hardening**:
  - The ACME provisioner only issues certificates for `*.islab.internal`.
  - Server certs have the `serverAuth` usage only and client certs have `clientAuth` only, so a server cert can never be used as a client cert.

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | step-ca + NPMplus |
| `pki-setup.sh` | One-time hardening of the CA: domain policy, lifetimes, templates, `clients` provisioner |
| `step-templates/` | Certificate templates (server = serverAuth, client = clientAuth) |
| `client-cert.sh` | Issue or renew client certs. Writes `.crt`, `.key` and `.p12` |
| `npmplus-data/custom_nginx/http.conf` | `$mtls_block` map. It lets ACME renewals through on mTLS hosts |

## First-time setup

1. **Hostnames**: point your names at your Mac. Without local DNS, add them to `/etc/hosts`:
   ```bash
   echo "127.0.0.1 app.islab.internal" | sudo tee -a /etc/hosts
   ```
2. **Start the CA alone first**, so it can initialise:
   ```bash
   docker compose up -d step-ca
   docker compose logs step-ca | grep "administrative password"   # store this in your password manager
   ```
3. **Harden the CA** (run once; it is safe to re-run):
   ```bash
   ./pki-setup.sh islab.internal
   ```
4. **Trust the root CA on your Mac**, so browsers accept the server certs:
   ```bash
   sudo security add-trusted-cert -d -r trustRoot \
     -k /Library/Keychains/System.keychain step-ca-data/certs/root_ca.crt
   ```
5. **Start NPMplus**:
   ```bash
   docker compose up -d --force-recreate npmplus
   docker compose logs npmplus | grep "Account registered"
   ```

## Add a proxy host with mTLS

1. Add the hostname as a network **alias** under `npmplus` in `docker-compose.yml`, then run `docker compose up -d npmplus`. This step is required: step-ca reaches the hostname over the Docker network to validate it.
2. NPMplus UI → **Certificates → Add certificate**, using the default ACME/HTTP provider, for `app.islab.internal`. The issuer shown is *ISLAB Private CA Intermediate CA*.
3. **Certificates → Add mTLS certificate**: name it "ISLAB client CA" and upload `step-ca-data/certs/root_ca.crt`. You only need to do this once.
4. Create or edit the **proxy host**:
   - SSL tab: choose the certificate, turn on **Force SSL**, choose **mTLS certificate = ISLAB client CA**, and turn on **verify client optional**.
   - Advanced tab, custom config:
     ```nginx
     if ($mtls_block) { return 403; }
     ```

   **Why "optional" plus the snippet, and not "required"?** With "required", the CA's renewal check (`http://…/.well-known/acme-challenge/` gets redirected to HTTPS by Force SSL) fails the TLS handshake because the CA has no client cert. Every renewal would then fail. "Optional" plus the snippet still blocks every request that lacks a valid client cert, and leaves only the challenge path open. An invalid or foreign client cert is still rejected during the TLS handshake.

## Client certificates

```bash
./client-cert.sh new  macbook     # -> client-certs/macbook.{crt,key,p12} + p12 password
./client-cert.sh renew macbook    # renew before it expires (30 days)
```

- **Browser**: double-click `client-certs/macbook.p12` to import it into Keychain, using the printed password. Safari and Chrome then offer the cert when you open the site.
- **curl or services**: `curl --cert client-certs/macbook.crt --key client-certs/macbook.key https://app.islab.internal/`
- **Automatic renewal on a machine that has the `step` CLI**: `step ca renew --daemon macbook.crt macbook.key`. It renews at about 2/3 of the lifetime. Renewal authenticates with the current cert, so it must happen *before* the cert expires.
- Your upstream app can read who connected. Add `proxy_set_header X-Client-DN $ssl_client_s_dn;` to the Advanced config.

## Verified in a test run (step-ca 0.30.2, NPMplus 2026-10-22-r1)

| Check | Result |
|---|---|
| NPMplus registers an ACME account at step-ca with TLS verification on | ✅ |
| Cert for `app.islab.internal` issued by the private CA (7 days) | ✅ |
| Cert for `evil.example.com` refused by the domain policy | ✅ refused |
| Forced renewal with mTLS active on the host | ✅ success |
| No client cert | 403 |
| Valid client cert | 200 |
| Server cert presented as a client cert | 400 (rejected) |
| Self-signed foreign client cert | 400 (rejected) |
| `client-cert.sh new` / `renew` | ✅ |

## Good to know

- With `ACME_SERVER` changed, **all** new certificates in this NPMplus come from your private CA. If you later need public Let's Encrypt certs too, run a second NPMplus, or upload those certs as custom certs.
- **Back up `step-ca-data/`**. It holds the CA keys, and losing it means re-issuing everything. Never commit it to git. The same applies to `client-certs/`.
- The CA key password is in `step-ca-data/secrets/password`. That is fine for a local lab. For anything shared, move it out of the folder.
