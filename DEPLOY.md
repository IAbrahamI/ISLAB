# Deploy guide: NPMplus with your own CA on the Raspberry Pi

Follow this from top to bottom once. Parts A and B are the migration and first deploy. Part C is everyday use. Part D is for later.

**What you end up with:** every service under `*.matrix.internal`, with all certificates from your own CA ("Matrix"), and every site locked to devices that hold one of your device certs.

| Container | Role |
|---|---|
| **dnsmasq** | Answers every `*.matrix.internal` with `BIND_IP`, so new services need no DNS entry |
| **step-ca** | Your CA. Server certs last 7 days and renew on their own. Device certs last 1 year. No open port |
| **NPMplus** | Reverse proxy on `BIND_IP` (80, 443). Admin UI only on the Pi itself (`127.0.0.1:81`) |

| File | Purpose |
|---|---|
| `docker-compose.yml` | The three containers. NPMplus also joins your existing `nginxproxymanager_default` network |
| `.env.example` | Copy to `.env`: `ACME_EMAIL`, `TZ`, `BIND_IP` |
| `dnsmasq/dnsmasq.conf` | DNS settings for dnsmasq |
| `pki-setup.sh` | One-time CA setup: only `*.matrix.internal`, lifetimes, server-only vs device-only certs |
| `step-templates/` | What each cert may be used for (website or device) |
| `client-cert.sh` | `new`, `renew` and `revoke` device certs |
| `nginx/http.conf` | The mTLS rule: blocks requests without a valid, non-revoked device cert |
| `nginx/revoked-serials.map` | Revoked devices. `client-cert.sh revoke` fills it |

---

## A. Before you start (on the Pi)

1. **64-bit OS:** `uname -m` must say `aarch64`. ✅
2. **Docker with the compose plugin and git:** `docker compose version` and `git --version` both answer.
3. **The Pi's LAN IP:** `hostname -I`. The first address, e.g. `192.168.1.10`, is your `BIND_IP` for now.
4. **Port 53 is free on that IP:** `sudo ss -lunp 'sport = :53'` should list nothing on `BIND_IP` or `0.0.0.0`. If Pi-hole or AdGuard runs on the Pi, stop here and sort that out first.
5. **Where your old NPM lives.** The commands below use `OLD=~/nginxproxymanager`. Change it if your folder is elsewhere.

## B. Migrate and deploy

### B1. Stop the old NPM and back it up
```bash
OLD=~/nginxproxymanager            # your old NPM folder
cd $OLD
docker compose down
sudo cp -a data data.bak && sudo cp -a letsencrypt letsencrypt.bak
ls data/custom_nginx 2>/dev/null   # should be empty or missing. If not, keep a copy of those files
```
The migration to NPMplus is one-way. The `.bak` folders are your way back.

Your app stacks use the network `nginxproxymanager_default`. `docker compose down` may have removed it, so make sure it exists:
```bash
docker network inspect nginxproxymanager_default >/dev/null 2>&1 || docker network create nginxproxymanager_default
```

### B2. Get the repo and bring over your data
```bash
git clone https://github.com/IAbrahamI/ISLAB.git ~/gateway
cd ~/gateway
git checkout server-matrix-pki     # skip once it's merged into main
sudo cp -a $OLD/data ./data
sudo cp -a $OLD/letsencrypt ./letsencrypt
cp .env.example .env
nano .env                          # ACME_EMAIL = your real email, BIND_IP = the Pi's LAN IP
```

### B3. Start the CA and set it up
```bash
mkdir -p step-ca-data && sudo chown 1000:1000 step-ca-data
docker compose up -d step-ca
docker compose logs step-ca | grep -i "password"     # save it in your password manager
./pki-setup.sh
```
The script ends by printing where `root_ca.crt` is and its fingerprint. If step-ca keeps restarting with "Permission denied", the `chown` step was skipped.

### B4. Start everything and finish the migration
```bash
docker compose up -d
docker compose logs -f npmplus
```
1. Wait for *"All certbot certs have been copied, please remove the /etc/letsencrypt mountpoint and redeploy"*.
2. Press Ctrl+C, then delete the line `- ./letsencrypt:/etc/letsencrypt` from `docker-compose.yml`.
3. Run `docker compose up -d` and `docker compose logs -f npmplus` again. Wait for *"Account registered."* That means NPMplus has signed up with your CA.

Check it:
```bash
docker compose ps                                     # all three "Up", step-ca "healthy"
nslookup test.matrix.internal <BIND_IP>               # answers <BIND_IP>
```

### B5. Open the admin UI
The UI only listens on the Pi. From your laptop:
```bash
ssh -L 8181:127.0.0.1:81 <user>@<pi-ip>
```
Then open https://localhost:8181 and log in with your old NPM account. Your browser warns about the certificate this one time. That's fine.

### B6. Set up your first device
Do this on the laptop you'll test with. Part C has the details for each OS.
1. Point its DNS at the Pi (`BIND_IP`).
2. Install the root CA: copy `step-ca-data/certs/root_ca.crt` from the Pi.
3. Make and install a device cert. On the Pi: `./client-cert.sh new macbook`. Copy `client-certs/macbook.p12` over and import it with the printed password.

### B7. Turn on mTLS (once)
In NPMplus, go to Certificates → Add certificate → **mTLS**. Name it `Matrix client CA` and upload `step-ca-data/certs/root_ca.crt`.

### B8. Move your services to `*.matrix.internal`
For each existing proxy host:
1. Certificates → Add certificate → **Certbot via HTTP** → `<name>.matrix.internal`.
2. Edit the proxy host:
   - **Details:** replace the DuckDNS name with `<name>.matrix.internal`. The forward host stays the container name.
   - **TLS:** pick the new cert, turn on Force HTTPS, set mTLS certificate = `Matrix client CA`, and turn on **Make mTLS Optional**.
   - **Advanced:** add `if ($mtls_block) { return 403; }`
3. Open `https://<name>.matrix.internal` on your laptop. It should load without a warning, and give a 403 on a device without a cert.

Then do the admin UI: add a proxy host `npm.matrix.internal` → `https`, `127.0.0.1`, `81`, with the same TLS and Advanced settings. Keep the SSH tunnel as your way back in.

**Why "optional" plus the Advanced line:** "required" also blocks your CA's renewal check on port 80, and certs would stop renewing after 7 days. The line still returns 403 to anyone without a valid, non-revoked device cert.

### B9. Clean up
Once every service works under `matrix.internal`:
1. In NPMplus, delete the old DuckDNS wildcard cert.
2. On the Pi: `rm -rf ~/gateway/letsencrypt`. Later, once you're sure, also delete `$OLD`.
3. Stop the DuckDNS updater if you run one, and remove any router port forwards for 80/443.

From now on your services are only reachable on your home network, and later over WireGuard (part D).

---

## C. Everyday use

### Add a new service
1. Its compose file joins the network `nginxproxymanager_default`, like your other stacks:
   ```yaml
   services:
     myapp:
       networks:
         - nginxproxymanager_default
   networks:
     nginxproxymanager_default:
       external: true
       name: nginxproxymanager_default
   ```
2. In NPMplus, do B8 for the new name. Any `<name>.matrix.internal` works with no DNS change. Names outside `matrix.internal` are refused by the CA.

### Devices
One cert per device, so you can block one without touching the others:
```bash
./client-cert.sh new pixel        # prints the .p12 password
./client-cert.sh renew pixel      # yearly, before it expires
./client-cert.sh revoke pixel     # lost or retired: blocked immediately, and can never be renewed
```
Copy `.p12` files with scp, USB or AirDrop, never over chat or email. The private key is inside.

**Install the root CA** (once per device, file `step-ca-data/certs/root_ca.crt`):

| OS | How |
|---|---|
| macOS | `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain root_ca.crt` |
| Windows | Double-click → Install Certificate → **Local Machine** → *Trusted Root Certification Authorities* |
| Android | Settings → Security → More security settings → Encryption & credentials → Install a certificate → **CA certificate** |
| iPhone/iPad | Open the file → install the profile → Settings → General → About → Certificate Trust Settings → turn on **Matrix Root CA** |
| Linux | `sudo cp root_ca.crt /usr/local/share/ca-certificates/matrix-root.crt && sudo update-ca-certificates` |
| Firefox (any OS) | Settings → Privacy & Security → View Certificates → Authorities → Import |

**Install the device cert** (`<device>.p12`, with the printed password):

| OS | How |
|---|---|
| macOS | Double-click → login keychain |
| Windows | Double-click → **Current User** → let Windows pick the store |
| Android | Encryption & credentials → Install a certificate → **VPN & app user certificate** |
| iPhone/iPad | Open the file → install the profile |
| Linux (Chrome) | `pk12util -d sql:$HOME/.pki/nssdb -i <device>.p12` |
| Firefox (any OS) | Settings → View Certificates → **Your Certificates** → Import |

Afterwards, fully quit and reopen the browser. It asks which certificate to use the first time.

**DNS:** each device needs the Pi (`BIND_IP`) as its DNS server. That's easiest on the router (DHCP DNS = the Pi), or per device. With WireGuard it's one line in the VPN config.

### Update
```bash
cd ~/gateway && git pull && docker compose pull && docker compose up -d
```

### Backups
`step-ca-data/` holds your CA's keys. Anyone who has it can issue valid certs. Back it up encrypted and off the Pi, and never commit it. Also back up `data/` (NPMplus's database) and `client-certs/`. `.gitignore` already keeps all three out of git.

---

## D. Later: WireGuard only
Once WireGuard runs on the Pi (e.g. `wg0` = `10.8.0.1`):
1. In `.env`, set `BIND_IP=10.8.0.1` and run `docker compose up -d`. NPMplus and dnsmasq then listen only on the VPN.
2. Docker has to start after WireGuard, or binding to `10.8.0.1` fails at boot:
   ```bash
   sudo systemctl enable wg-quick@wg0
   sudo systemctl edit docker      # add the two lines below
   # [Unit]
   # After=wg-quick@wg0.service
   ```
3. Put `DNS = 10.8.0.1` in each device's WireGuard config.
4. On the router, forward only UDP 51820 to the Pi.
