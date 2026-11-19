# Ubuntu staging acceptance tests

Run the offline suite as an unprivileged user from the directory containing the toolbox. It uses a private temporary directory and mocks systemd, package installation, downloads, and route inspection. An optional sing-box binary adds real configuration checks.

```bash
bash -n singbox-toolbox.sh
shellcheck singbox-toolbox.sh tests/smoke.sh
bash tests/smoke.sh
SINGBOX_TEST_BIN=/usr/bin/sing-box bash tests/smoke.sh
```

Run the loopback integration with sing-box 1.14+, Python 3, curl, and OpenSSL. It opens temporary listeners on `127.0.0.1`, fetches a separate HTTP origin through real SOCKS5 and HTTP over VLESS TCP/TLS, and verifies that a wrong UUID fails connectivity after passing `sing-box check`.

```bash
SINGBOX_TEST_BIN=/usr/bin/sing-box python3 tests/loopback.py
```

Run the following live tests only on a disposable Ubuntu VM or VPS with systemd, `/dev/net/tun`, a provider console, the systemd-resolved stub symlink at `/etc/resolv.conf`, and a working upstream VLESS instance with a public egress address different from the VPS. Keep the provider console available and leave the first SSH terminal open during confirmation. Place a valid VLESS link and a second copy with a different valid UUID in private files named `working.vless` and `wrong-uuid.vless`. Use a separate TCP connection for each SSH session from the same client IP. Use an IPv4-only staging VM for the commands shown, or append `--ipv6` to every `enable-tun` invocation if the VM has public IPv6 routing and the upstream supports IPv6 egress.

```bash
chmod 600 working.vless wrong-uuid.vless
```

## Install and repeat

```bash
sudo ./singbox-toolbox.sh install
sing-box version
sudo ./singbox-toolbox.sh install
```

Expect the supported stable version on the first run and an already-installed result on the second. On a separate fresh VM, make the official release source temporarily unreachable with the staging provider's egress controls. Expect a nonzero exit and an installation error. Remove the block and rerun the command.

## Reject invalid data

```bash
printf '%s\n' '{"outbounds": [' | sudo ./singbox-toolbox.sh import-json -
sudo ./singbox-toolbox.sh import-vless working.vless
sudo ./singbox-toolbox.sh enable-proxy
sudo ./singbox-toolbox.sh test
```

The malformed input must be rejected before changing the active service or configuration. With the working link, expect successful SOCKS5 connectivity, DNS resolution, and the upstream public IP. Independently test the local SOCKS5 and HTTP interfaces.

```bash
curl -q -fsS --noproxy '' --socks5-hostname 127.0.0.1:1080 https://api.ipify.org
curl -q -fsS --noproxy '' --proxy http://127.0.0.1:1080 https://api.ipify.org
```

## Roll back a failed connection

```bash
before=$(sudo sha256sum /etc/sing-box/config.json)
sudo ./singbox-toolbox.sh import-vless wrong-uuid.vless
sudo ./singbox-toolbox.sh enable-proxy
test "$before" = "$(sudo sha256sum /etc/sing-box/config.json)"
sudo ./singbox-toolbox.sh test
```

The wrong UUID must pass configuration parsing and fail the connectivity test. The wrapper must exit nonzero, restore the identical configuration, restart the earlier working proxy, and keep the credential out of command output. Repeat with `enable-tun` over SSH to cover failed TUN connectivity. Reload `working.vless` before continuing.

## Verify timeout and SSH recovery

Optionally open a second TCP SSH connection before enabling TUN. Its later `confirm` attempt should fail because its socket was already open. From SSH session A, record the existing return route, arm TUN, and inspect the timer.

```bash
read -r peer peer_port local_addr local_port <<< "$SSH_CONNECTION"
ip route get "$peer" from "$local_addr"
sudo ./singbox-toolbox.sh import-vless working.vless
sudo env "SSH_CONNECTION=$SSH_CONNECTION" ./singbox-toolbox.sh enable-tun
sudo systemctl list-timers --all singbox-toolbox-rollback.timer
ip route get "$peer" from "$local_addr"
sudo env "SSH_CONNECTION=$SSH_CONNECTION" ./singbox-toolbox.sh confirm
```

The SSH route should stay on the original interface. The confirmation in session A must fail and leave the timer armed. Close session A without confirming, let the displayed deadline pass, then reconnect. The old configuration hash, proxy test result, and sing-box service state should match their recorded values. Confirm the toolbox TUN interface is gone and a repeated rollback request is harmless.

```bash
sudo journalctl -u singbox-toolbox-rollback.service -n 30 --no-pager
ip link show sbtoolbox0
sudo ./singbox-toolbox.sh rollback
```

Repeat the timeout exercise with a staging reboot before the deadline to verify the persistent timer and the TUN boot guard. Check console and SSH recovery, then verify the baseline configuration and service once the timer has run.

## Confirm and verify successful TUN activation

From SSH session A, repeat `enable-tun`. Open session B with a new TCP connection. Run the following SSH command from your client machine with your staging VM hostname or IP.

```bash
ssh -o ControlMaster=no -o ControlPath=none user@your-staging-vps
```

From session B in the script directory, check public egress with proxy environment variables ignored, resolve a domain, and confirm the change.

```bash
curl -q -4fsS --noproxy '*' https://api.ipify.org
getent ahostsv4 example.com
sudo env "SSH_CONNECTION=$SSH_CONNECTION" ./singbox-toolbox.sh confirm
sudo systemctl is-active sing-box.service
sudo systemctl is-active singbox-toolbox-rollback.timer
sudo ./singbox-toolbox.sh test
```

Expect the public IP to match the earlier SOCKS5 result and differ from the direct VPS IP. Session A and session B should both remain usable. The sing-box service should be active and the rollback timer should be inactive after confirmation. For a dual-stack VPS and upstream, repeat with `enable-tun --ipv6` and compare `curl -q -6fsS --noproxy '*' https://api64.ipify.org` to the IPv6 proxy egress. Restore the baseline at the end of the staging run.

```bash
sudo ./singbox-toolbox.sh restore
```
