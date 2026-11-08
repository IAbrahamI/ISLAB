# To do

Open points for later. Remove each one when it's done.

## Make my Android app trust the private CA
Android apps ignore CAs installed on the phone, so the app can't reach its API under `*.matrix.internal`. iOS apps are fine once the root CA is installed and trusted.

Fix in the app (native Android or React Native):
1. Copy `step-ca-data/certs/root_ca.crt` into the app as `res/raw/matrix_root.crt`. The root is public, so it's safe to bundle.
2. Create `res/xml/network_security_config.xml`:
   ```xml
   <network-security-config>
     <domain-config>
       <domain includeSubdomains="true">matrix.internal</domain>
       <trust-anchors>
         <certificates src="@raw/matrix_root" />
       </trust-anchors>
     </domain-config>
   </network-security-config>
   ```
3. In `AndroidManifest.xml`, add `android:networkSecurityConfig="@xml/network_security_config"` to `<application>`.

Notes:
- With Flutter this doesn't apply. Load the root in the app's HTTP client (`SecurityContext`) instead.
- Keep the API's proxy host **without** mTLS and use the API's own login/token. With mTLS the app would also need its own device cert.

## Other open points
- Move the remaining proxy hosts to `*.matrix.internal` before the DuckDNS Let's Encrypt cert expires (date under NPMplus → Certificates). Then do B9 (clean up).
- Add the split DNS rule (DEPLOY.md B6, step 2) and the device cert on CachyOS and other computers.
- WireGuard (DEPLOY.md part D).
