# Matrix: NPMplus + own PKI on the home server

All certificates come from your own CA, step-ca, named "Matrix". Every service lives under `*.matrix.internal`.

| Service | Role |
|---|---|
| **dnsmasq** | Answers every `*.matrix.internal` with `BIND_IP`, where NPMplus listens. step-ca uses it to check names, and your devices use it too. No aliases or `/etc/hosts` needed. |
| **step-ca** | Your CA. It issues server certs (7 days, auto-renewed) and client certs (1 year, one per device). It has no published port. |
| **NPMplus** | Reverse proxy. It listens only on `BIND_IP`. The admin UI is only on `127.0.0.1:81`. |

## Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | The three services on the internal `gateway` network (`172.30.10.0/24`; only dnsmasq has a fixed IP). NPMplus also joins your existing `nginxproxymanager_default` network to reach your apps |
| `.env.example` → `.env` | `ACME_EMAIL`, `TZ`, `BIND_IP` |
| `dnsmasq/dnsmasq.conf` | The `*.matrix.internal` wildcard rule |
| `pki-setup.sh` | One-time CA tuning: domain policy, lifetimes, server-only vs client-only certs |
| `client-cert.sh` | `new`, `renew` and `revoke` for device certificates |
| `step-templates/` | Certificate templates (server cert = serverAuth, client cert = clientAuth) |
| `data/custom_nginx/http.conf` | `$mtls_block` rule: blocks a request without a valid cert, or with a revoked one |
| `data/custom_nginx/revoked-serials.map` | Revoked device certs. `client-cert.sh revoke` maintains it |

## 1. Migrate from NPM to NPMplus and start the CA

The migration from NPM to NPMplus is **one-way**, so back up first.

```bash
cd /home/dev/Documents/Github/ISLAB
docker compose down                                   # stops the old NPM
cp -a data data.bak && cp -a letsencrypt letsencrypt.bak
# put the files from this package next to data/ and letsencrypt/
cp .env.example .env && nano .env                     # BIND_IP = the server's LAN IP for now
```

Start the CA first and tune it:
```bash
docker compose up -d step-ca
docker compose logs step-ca | grep "administrative password"     # save it in your password manager
./pki-setup.sh matrix.internal
```

Start everything:
```bash
docker compose up -d
docker compose logs -f npmplus
```
NPMplus copies your old certs and then prints *"All certbot certs have been copied, please remove the /etc/letsencrypt mountpoint and redeploy"*. When you see it:
1. Delete the `- ./letsencrypt:/etc/letsencrypt` line from `docker-compose.yml`.
2. Run `docker compose up -d`.
3. Wait for *"Account registered."* in the log. That's NPMplus signing up at your own CA.

**Admin UI:** it only listens on the server itself. From your laptop, open an SSH tunnel with `ssh -L 8181:127.0.0.1:81 dev@<server>`, then go to https://localhost:8181. Later, use the proxy host from step 4.

Your existing DuckDNS Let's Encrypt cert keeps renewing from Let's Encrypt until you delete it. Move each host to a `*.matrix.internal` cert, then delete the old one.

## 2. Let your devices resolve `*.matrix.internal`

dnsmasq listens on `BIND_IP:53`.
- **With WireGuard:** put `DNS = 10.8.0.1` in each device's WireGuard config. Done.
- **Before WireGuard:** set the device's DNS server to the server's LAN IP. If your router supports it, add a rule there that forwards `matrix.internal` to the server.

Check it from any device: `nslookup anything.matrix.internal <BIND_IP>` should return `BIND_IP`.

## 3. Trust the root CA on each device (once)

The file is `step-ca-data/certs/root_ca.crt`. Copy it over with AirDrop, USB or scp.

| OS | Install the root CA |
|---|---|
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root_ca.crt` |
| Windows | Double-click → Install Certificate → **Local Machine** → *Trusted Root Certification Authorities*. Or, as admin: `certutil -addstore -f Root root_ca.crt` |
| Android | Settings → Security → More security settings → Encryption & credentials → Install a certificate → **CA certificate** |
| iPhone/iPad | Open the file → Settings → *Profile Downloaded* → Install. Then Settings → General → About → Certificate Trust Settings → turn on **Matrix Root CA** |
| Linux (system) | `sudo cp root_ca.crt /usr/local/share/ca-certificates/matrix-root.crt && sudo update-ca-certificates` |
| Linux (Chrome) | `certutil -d sql:$HOME/.pki/nssdb -A -t "C,," -n "Matrix Root CA" -i root_ca.crt` |
| Firefox (any OS) | Settings → Privacy & Security → View Certificates → Authorities → Import |

## 4. Add a service

1. In NPMplus, go to Certificates → Add certificate → **Certbot via HTTP** → `grafana.matrix.internal`. Any name under `matrix.internal` works with no extra config. Other names are refused by the CA.
2. Add a proxy host for that name, pointing at the service's container name and port. The service's compose must join the `nginxproxymanager_default` network, as your existing stacks already do.
   - **TLS tab:** pick the cert, turn on Force HTTPS, set mTLS certificate = *Matrix client CA*, and turn on **Make mTLS Optional**.
   - **Advanced tab:** `if ($mtls_block) { return 403; }`
3. Do this once, before the first host: Certificates → Add certificate → **mTLS** → name it "Matrix client CA" → upload `step-ca-data/certs/root_ca.crt`.

Admin UI as a service: `npm.matrix.internal` → `https` `127.0.0.1` `81`. Add the same mTLS settings once your own device cert works. Keep the SSH tunnel as your way back in.

**Why "optional" + the rule:** "required" would also block the CA's renewal check, and server certs would stop renewing. The rule still returns 403 to anyone without a valid, non-revoked cert. Fake or foreign certs are rejected during the handshake.

## 5. Device certificates

Use one cert per device, so you can revoke a single device:
```bash
./client-cert.sh new macbook        # prints the .p12 password
./client-cert.sh new pixel
./client-cert.sh renew macbook      # yearly, before it expires
./client-cert.sh revoke pixel       # lost or retired device: blocked immediately
```
The `.p12` is the same file for every OS. Only the way you import it differs:

| OS | Import `<device>.p12` |
|---|---|
| macOS | Double-click → login keychain → enter the printed password |
| Windows | Double-click → **Current User** → let Windows pick the store → enter the password |
| Android | Encryption & credentials → Install a certificate → **VPN & app user certificate** |
| iPhone/iPad | Open the file → install the profile → enter the password |
| Linux (Chrome) | `pk12util -d sql:$HOME/.pki/nssdb -i pixel.p12` |
| Firefox (any OS) | Settings → View Certificates → **Your Certificates** → Import |

After importing, fully quit and reopen the browser. The browser asks which certificate to use the first time.

Copy `.p12` files with AirDrop, USB or scp, not over chat or email. The private key is inside, protected only by the printed password.

**Revoking** does two things:
- It adds the cert's serial to `revoked-serials.map` and reloads NPMplus, so the device gets 403 immediately.
- It marks the cert revoked in step-ca, so it can never be renewed.

The files move to `client-certs/revoked/`.

## 6. Later: WireGuard only

Once WireGuard runs on the server (e.g. `wg0` = `10.8.0.1`):
1. In `.env`, set `BIND_IP=10.8.0.1` and run `docker compose up -d`. NPMplus and dnsmasq then listen only on the VPN.
2. Docker must start **after** WireGuard, or binding to `10.8.0.1` fails at boot:
   ```bash
   sudo systemctl enable wg-quick@wg0
   sudo systemctl edit docker      # add the two lines below
   # [Unit]
   # After=wg-quick@wg0.service
   ```
3. On the router, forward only UDP 51820 to the server.

## Backups

`step-ca-data/` holds the CA keys: anyone who has it can issue valid certs. Back it up encrypted and off the server, and never commit it. The `.gitignore` already excludes it, along with `client-certs/`, `letsencrypt/`, `.env`, `*.key` and `*.p12`.

## Test status

Tested on 7 Nov 2026 in a clean test environment (NPMplus 2026-10-22-r1, step-ca 0.30.2, dnsmasq 2.93):

| Check | Result |
|---|---|
| CA named Matrix (Matrix Root CA → Matrix Intermediate CA) | ✅ |
| dnsmasq answers any `*.matrix.internal` with `BIND_IP`; step-ca validates through it, and a device reaches the app through it | ✅ |
| Certs for `app.`, `npm.` and a never-configured `brand-new.matrix.internal`, no aliases | ✅ |
| Cert for `evil.example.com` | refused ✅ |
| Client cert valid for 1 year | ✅ |
| No client cert → 403, valid device cert → 200 | ✅ |
| `revoke pixel` → pixel gets 403 immediately, macbook still 200, pixel can't renew | ✅ |
| Forced server-cert renewal with mTLS active | ✅ |
| NPMplus migration message with a `letsencrypt` mount | ✅ (with an empty folder) |

**Not tested yet:**
- Migration with your real NPM data and the DuckDNS cert
- WireGuard
- Importing the `.p12` on Windows, Android and Linux (only macOS so far)
