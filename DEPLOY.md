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
| `TODO.md` | Open points for later |

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
git clone https://github.com/IAbrahamI/ISLAB.git ~/NPMPlus    # any folder name works
cd ~/NPMPlus
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
The UI only listens on the Pi itself:
- **On the Pi's desktop:** open https://localhost:81
- **From your laptop:** run `ssh -L 8181:127.0.0.1:81 <user>@<pi-ip>`, then open https://localhost:8181

Log in with your old NPM account. All your old proxy hosts are there. The browser warns about the certificate this one time. That's fine.

### B6. Let your devices find `*.matrix.internal`, then set up your first device
Only dnsmasq on the Pi knows the `matrix.internal` names, so your devices have to ask the Pi for them. dnsmasq passes every other name on to public DNS (Quad9, Cloudflare). We did this in two steps.

**Step 1 (first setup): the router sends all devices to the Pi.**
In the router's DNS settings, set the first DNS server to the Pi's IP and leave the second one empty. A public server as the second one would answer "unknown" for `matrix.internal` now and then. Turn Wi-Fi off and on on each device so it picks up the change.
- Pro: no setup per device, and phones work too.
- Con: if the Pi is down, name lookups stop working for the whole house. The fix is to open the router by its IP (e.g. `http://192.168.1.1`) and set DNS back to automatic.

**Step 2 (current setup): split DNS per computer.**
To make the internet independent of the Pi, each computer gets **one rule, once**: names ending in `.matrix.internal` go to the Pi, and everything else goes to the router as usual. New services need nothing extra. If the Pi is down, only the internal sites are affected. Set up the rule on each computer first, then set the router's DNS back to automatic.

Replace `<Pi-IP>` with the Pi's IP:

| Device | Set up once | Test |
|---|---|---|
| Mac | `sudo mkdir -p /etc/resolver && echo "nameserver <Pi-IP>" \| sudo tee /etc/resolver/matrix.internal` | `dscacheutil -q host -a name npm.matrix.internal` |
| Linux (systemd-resolved, e.g. CachyOS) | `sudo mkdir -p /etc/systemd/resolved.conf.d && printf '[Resolve]\nDNS=<Pi-IP>\nDomains=~matrix.internal\n' \| sudo tee /etc/systemd/resolved.conf.d/matrix.conf && sudo systemctl restart systemd-resolved` | `resolvectl query npm.matrix.internal` |
| Windows (PowerShell as admin) | `Add-DnsClientNrptRule -Namespace ".matrix.internal" -NameServers "<Pi-IP>"` | `Resolve-DnsName npm.matrix.internal` |
| Phones | Not possible per name. They reach internal sites through WireGuard (part D) | |

Each test should answer the Pi's IP. On a Mac, `nslookup` ignores the resolver file, so use the command above.

Then on the laptop you'll test with (part C has the details for each OS):
1. Install the root CA: copy `step-ca-data/certs/root_ca.crt` from the Pi.
2. Make and install a device cert. On the Pi: `./client-cert.sh new macbook`. Copy `client-certs/macbook.p12` over and import it with the printed password.

### B7. Turn on mTLS (once)
In NPMplus, go to Certificates → Add certificate → **mTLS**. Name it `Matrix client CA` and upload `step-ca-data/certs/root_ca.crt`.

### B8. Move your services to `*.matrix.internal`
**All** services have to move. NPMplus sends every certificate, renewals included, to the one CA in `ACME_SERVER`, which is now yours. Your old DuckDNS Let's Encrypt cert therefore can't renew any more. Check its expiry date under Certificates and finish the move before then.

**Start with the admin UI.** Add a proxy host:
- **Details:** `npm.matrix.internal`, scheme `https://`, forward host `127.0.0.1`, port `81`
- **TLS:** *Request a new certificate* (Certbot via HTTP), Force HTTPS on, mTLS certificate = `Matrix client CA`, **Make mTLS Optional** on
- **Advanced:** `if ($mtls_block) { return 403; }`

Open `https://npm.matrix.internal` on your laptop. It should load with no warning. A device without a device cert gets 403. `https://localhost:81` on the Pi stays your way back in.

**Then each other service.** Edit its proxy host, and for each one decide whether it needs mTLS:

| | Open to every home device | Locked to devices with a device cert (mTLS) |
|---|---|---|
| Details | Replace the DuckDNS name with `<name>.matrix.internal`. The forward host stays the container name | Same |
| TLS | *Request a new certificate* (Certbot via HTTP), Force HTTPS on | Same, plus mTLS certificate = `Matrix client CA` and **Make mTLS Optional** on |
| Advanced | Nothing | `if ($mtls_block) { return 403; }` |
| Device needs | The root CA | The root CA and its device cert |

**Why "optional" plus the Advanced line:** "required" also blocks your CA's renewal check on port 80, and certs would stop renewing after 7 days. The line still returns 403 to anyone without a valid, non-revoked device cert.

### B9. Clean up
Once every service works under `matrix.internal`:
1. In NPMplus, delete the old DuckDNS wildcard cert.
2. On the Pi: `rm -rf ~/NPMPlus/letsencrypt`. Later, once you're sure, also delete `$OLD`.
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
2. In NPMplus, add a proxy host as in B8: open, or locked with mTLS. Any `<name>.matrix.internal` works with no DNS change. Names outside `matrix.internal` are refused by the CA.

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

**DNS:** each computer has the one `matrix.internal` rule from B6 (step 2). Phones use WireGuard (part D).

### If the Pi is down
- **With split DNS (current):** only the `matrix.internal` sites stop working. Everything else uses the router's DNS and isn't affected.
- **With the router pointing at the Pi (step 1 of B6):** all name lookups at home stop. Open the router by its IP and set DNS back to automatic.

The containers restart on their own after a reboot or power cut.

### Update
```bash
cd ~/NPMPlus && git pull && docker compose pull && docker compose up -d
```

### Backups
`step-ca-data/` holds your CA's keys. Anyone who has it can issue valid certs. Back it up encrypted and off the Pi, and never commit it. Also back up `data/` (NPMplus's database) and `client-certs/`. `.gitignore` already keeps all three out of git.

---

## Questions and answers

**Do the certificates renew themselves?**
- **Server certs** (`npm.matrix.internal` and every other host): yes. NPMplus checks every few hours and renews each one at half its 7-day life, so about every 3–4 days.
- **Device certs** (`.p12`): no, on purpose. They last 1 year. Run `./client-cert.sh renew <device>` before they expire and import the new `.p12`.
- **Root CA:** valid for 10 years.

**Do I have to redo the CA setup for a new service?**
No. The root CA on your devices and the `Matrix client CA` entry in NPMplus are one-time and cover every future service. A new service is only a proxy host with *Request a new certificate* (plus the mTLS settings if you want it locked). Devices trust its cert right away.

**Do all proxy hosts have to move to `matrix.internal`?**
Yes. NPMplus sends every certificate, renewals included, to the CA in `ACME_SERVER`, which is your own CA. A Let's Encrypt cert can't renew any more and expires on the date shown under Certificates. Moving everything also means no DuckDNS and no public names. mTLS stays a choice per service.

One thing to check first: **Android apps** (not Chrome) ignore CAs you install yourself, so they won't trust these certs unless the app trusts the CA itself. For your own apps that's one config file. See `TODO.md`.

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
3. Put `DNS = 10.8.0.1` in each phone's WireGuard config. On computers, change the B6 rule from the LAN IP to `10.8.0.1`. From then on, the internal sites only work with the VPN on, even at home.
4. On the router, forward only UDP 51820 to the Pi.
