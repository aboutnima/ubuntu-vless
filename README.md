# sing-box toolbox

`singbox-toolbox.sh` manages a sing-box 1.14+ client on Ubuntu with systemd. Use proxy mode for a loopback SOCKS5/HTTP listener. Use TUN when you need the server’s own TCP and UDP internet traffic routed through the configured upstream.

## Install

Download the toolbox on your VPS and open it from an SSH terminal. Use Ubuntu 22.04 or newer for the TUN resolver checks. TUN requires a provider that exposes `/dev/net/tun`, a working systemd-resolved stub, and a live SSH connection. Keep the provider console available when first testing TUN.

```bash
sudo --preserve-env=SSH_CONNECTION bash ./singbox-toolbox.sh
```

Choose **Install sing-box** to install missing dependencies through Ubuntu APT and download the latest stable SagerNet release for your architecture. It verifies the downloaded Debian package against the SHA-256 digest in the official GitHub release metadata. It keeps a compatible installed version and preserves a preexisting configuration. Activation supports the standard root-run sing-box service. [Upstream package documentation](https://sing-box.sagernet.org/installation/package-manager/)

This one-line installer downloads the current script from GitHub and opens the terminal UI.

```bash
toolbox=$(mktemp /tmp/singbox-toolbox.XXXXXXXX) && curl -qfsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/aboutnima/ubuntu-vless/main/singbox-toolbox.sh -o "$toolbox" && sudo --preserve-env=SSH_CONNECTION bash "$toolbox"
```

Use the arrow keys to move, Enter to select, `R` to refresh service status, and Esc to go back. The dashboard shows the service, routing mode, and staged profile. During a pending TUN activation it shows the time remaining before rollback. Use `menu --plain` for the numbered fallback.

To keep a short command on the server after downloading `singbox-toolbox.sh`:

```bash
sudo install -m 0755 ./singbox-toolbox.sh /usr/local/bin/ubuntu-vless
sudo --preserve-env=SSH_CONNECTION ubuntu-vless
```

## Use a profile

Choose **Import VLESS link** or **Import JSON profile** to stage a profile. **Enable loopback proxy** applies it and runs connectivity checks. The examples use a dummy endpoint and UUID. Replace them in a private file before testing connectivity.

- [Example VLESS link](examples/client.vless) supports the TLS/TCP form. The importer also supports TCP Reality, WebSocket, and gRPC, along with SNI, uTLS, ALPN, and Vision where compatible. TLS certificate verification remains enabled.
- [Example JSON profile](examples/client.json) supplies client outbounds and the optional final outbound tag. The toolbox builds the inbounds, DNS, and routing policy. Use the profile format for client outbounds and supported selector/URLTest groups. Custom routing rules, rule sets, server roles, endpoints, experimental features, and local file-backed TLS settings require a separately managed sing-box service.
- For local files, use mode `0600`. For a URL, the menu reads it without echo. HTTPS downloads are limited to 4 MiB and must return HTTP 200. Use the final URL when a service publishes a redirect.

### Non-interactive installation and proxy activation

```bash
sudo bash ./singbox-toolbox.sh install
sudo bash ./singbox-toolbox.sh import-vless - < ./private-client.vless
sudo bash ./singbox-toolbox.sh enable-proxy
sudo bash ./singbox-toolbox.sh test
sudo bash ./singbox-toolbox.sh status
```

Alternatives for importing JSON:

```bash
sudo bash ./singbox-toolbox.sh import-json ./private-client.json
sudo bash ./singbox-toolbox.sh import-json --url-stdin < ./private-config-url.txt
```

Both proxy protocols share `127.0.0.1:1080`. The listener is unauthenticated and available to local users. For client-side DNS through SOCKS, use `socks5h`.

```bash
curl -qfsS --noproxy '' --proxy socks5h://127.0.0.1:1080 https://api.ipify.org
```

## Enable TUN over SSH

In SSH session A, choose **Enable full-server TUN** and keep the session open. You can also use the command directly.

```bash
sudo --preserve-env=SSH_CONNECTION bash ./singbox-toolbox.sh enable-tun
```

Use `enable-tun --ipv6` if the host has a public IPv6 route or you want IPv6 egress and the upstream supports it. On success the script prints the deadline and the egress IP. A five-minute systemd rollback timer remains armed.

Open session B **after** the health checks, using the same client IP and server address and a separate SSH TCP connection. On your client:

```bash
ssh -o ControlMaster=no -o ControlPath=none user@your-vps
```

From session B, choose **Confirm TUN** in the terminal UI or use this command.

```bash
sudo --preserve-env=SSH_CONNECTION /var/lib/singbox-toolbox/runner confirm
```

The command checks both SSH connections, rechecks live connectivity, and commits. Without a valid confirmation by the deadline, systemd restores the earlier configuration. There is no automatic confirmation flag.

TUN behavior and preflight requirements:

- The toolbox protects the initiating SSH client IP and pins the upstream’s resolved endpoint IPs outside TUN. Use the same protected SSH source IP to reconnect. If the upstream changes addresses, use the toolbox restart to refresh the pins and confirm again.
- Activation compares the original public egress with matching SOCKS5 and ordinary TUN egress. It needs access to multiple public IP services and requires different direct and tunneled IPv4 addresses. It also verifies an uncached DNS lookup on the TUN link. Public DNS goes through tunnelled HTTPS. Local search domains and network-local traffic can still use the local network, as can ICMP.
- TUN preflight declines existing VPNs, active bridges, forwarding hosts, custom policy-routing rules, and incompatible DNS routing. Use proxy mode on those hosts. The toolbox leaves Docker settings and the system `resolv.conf` symlink alone.
- TUN is scoped to the current boot. After a reboot, run activation again from SSH to refresh the exceptions and repeat validation. Use the toolbox `restart` command for a managed TUN restart.

## Rollback and recovery

If activation tests fail, the toolbox tries to recover immediately. The systemd watchdog handles session loss, script termination, and missed confirmation. It retries incomplete recovery. Service boot enablement is preserved. The watchdog restores the earlier running or stopped state, with a fresh activation required to bring back a managed TUN after reboot.

1. Use a usable SSH session or the VPS console to request immediate rollback.

   ```bash
   sudo /var/lib/singbox-toolbox/runner rollback
   sudo /var/lib/singbox-toolbox/runner status
   ```

2. If recovery is still pending, start or inspect the watchdog from the console.

   ```bash
   sudo systemctl start singbox-toolbox-rollback.service
   sudo journalctl -u singbox-toolbox-rollback.service -n 40 --no-pager
   sudo systemctl list-timers --all singbox-toolbox-rollback.timer
   ```

3. After a confirmed change, use `sudo --preserve-env=SSH_CONNECTION /var/lib/singbox-toolbox/runner restore` for the previous configuration. Restoring a previously active managed TUN runs a fresh activation and requires SSH confirmation again. Root-only transaction snapshots are under `/var/lib/singbox-toolbox/transactions/`. If the runner cannot recover, use the ID in `/var/lib/singbox-toolbox/pending` to find the exact snapshot. From the console, stop sing-box, restore its saved `config.json` and `drop-in.conf` or remove the corresponding managed file if it was absent, run `systemctl daemon-reload`, and start sing-box only if the saved `active` value was `yes`. Keep the pending snapshot available while diagnosing recovery.

Managed configurations and backups use root-only permissions. The status and logs commands show safe service metadata and redacted systemd events. `uninstall --yes` removes the Debian package while retaining the configuration and backups.

## Tests

Run `bash tests/smoke.sh` for local regression tests. Set `SINGBOX_TEST_BIN` to a sing-box 1.14+ executable to include real configuration checks. Use the [Ubuntu staging acceptance tests](tests/STAGING.md) for live SSH, systemd, DNS, and TUN verification against your upstream.
