# Ubuntu VLESS

Run sing-box as a VLESS client on an Ubuntu server in TUN or local proxy mode. The SSH menu keeps command output on screen.

## Install once

Run this on Ubuntu 22.04 or newer to install the `ubuntu-vless` command.

```bash
toolbox=$(mktemp /tmp/ubuntu-vless.XXXXXXXX) &&
curl -qfsSL --proto '=https' --proto-redir '=https' https://raw.githubusercontent.com/aboutnima/ubuntu-vless/main/singbox-toolbox.sh -o "$toolbox" &&
sudo bash "$toolbox" setup
```

Afterwards, open the menu by typing:

```bash
ubuntu-vless
```

The command uses sudo when needed and preserves the SSH connection details. Use the arrow keys and Enter to select an action, or Esc to leave. For longer output, use the arrow keys or Page Up and Page Down to scroll.

## Menu

| Menu action | Command-line equivalent | What it does |
| --- | --- | --- |
| **Install sing-box** | `ubuntu-vless install` | Installs the official package and checks the download digest. Reuses an existing compatible installation. |
| **Import VLESS link** | `ubuntu-vless import-vless FILE` | Saves your provider link. The menu hides the input. The CLI also accepts `-` to read from standard input. |
| **Start TUN** | `ubuntu-vless enable-tun --auto` | Starts TUN and checks connectivity. Confirm from a fresh SSH session. |
| **Stop TUN** | `ubuntu-vless stop-tun` | Stops TUN or cancels a pending activation. Appears in place of **Start TUN** while the tunnel is running or awaiting confirmation. |
| **Enable proxy** | `ubuntu-vless enable-proxy` | Activates the imported profile as a local SOCKS5/HTTP proxy on `127.0.0.1:1080`. |
| **Update toolbox** | `ubuntu-vless update` | Fetches the latest script from this repository’s `main` branch with Git. The menu closes after a successful update. Reopen `ubuntu-vless` to load it. |

## Proxy mode

Import a VLESS link and select **Enable proxy** to switch the managed service to proxy mode. Programs on Ubuntu can send their requests through `socks5h://127.0.0.1:1080` or `http://127.0.0.1:1080`. Proxy mode applies to programs configured to use that address. Use `ubuntu-vless test` to check the proxy and `ubuntu-vless stop` to stop it.

In a bridged Docker container, `127.0.0.1` is the container's own loopback. For outbound HTTP(S) calls from selected containers, use a VLESS proxy service on a private Docker network and configure those applications to reach it. Scope proxy settings to those services and include internal service names in `NO_PROXY` where supported. [Docker networking](https://docs.docker.com/engine/network/) · [Proxy settings for containers](https://docs.docker.com/engine/cli/proxy/)

## TUN mode

The [example VLESS link](examples/client.vless) contains dummy values. TUN needs a working upstream, `/dev/net/tun`, systemd-resolved with the standard Ubuntu stub, and a live SSH connection. If the server has public IPv6 routes, the upstream must support IPv6 egress.

The menu uses `--auto` to pick IPv4 or dual stack. From the CLI, `ubuntu-vless enable-tun` requests IPv4 and `ubuntu-vless enable-tun --ipv6` requests dual stack.

If Start TUN reports a DNS conflict, run `resolvectl domain` and `resolvectl dns` to locate the rule and its resolver. Private search domains such as `openstacklocal` and `*.internal` can keep using local DNS. A competing `~.` or public suffix on another link can divert DNS outside TUN and blocks activation.

An idle Docker default bridge is accepted when it has no attached ports or carrier. Start TUN reports the name of any conflicting bridge or tunnel. The TUN checks cover traffic from the Ubuntu server itself; forwarded traffic can take a different route.

## Confirm TUN after starting

Keep the first SSH session open and wait for the health checks to pass. From the same client IP, open a **new** SSH connection with ControlMaster disabled and run:

```bash
ubuntu-vless confirm
```

If the command is unavailable in the second shell, use the exact confirmation command shown by **Start TUN**. Without confirmation within five minutes, the watchdog restores the prior configuration. TUN is scoped to the current boot. After a reboot, choose **Start TUN** again.

## CLI-only commands

| Command | What it does |
| --- | --- |
| `ubuntu-vless setup` | Installs or refreshes the `ubuntu-vless` launcher from the running script. |
| `ubuntu-vless import-json FILE` | Stages a sing-box JSON profile. Use `-` for standard input. |
| `ubuntu-vless import-json --url-stdin` | Reads a single HTTPS configuration URL from standard input. |
| `ubuntu-vless confirm` | Confirms a pending TUN on a fresh SSH connection. |
| `ubuntu-vless test` | Checks the running SOCKS5 proxy and reports the observed egress IP. |
| `ubuntu-vless ip` | Shows the server’s current public IPv4 address. |
| `ubuntu-vless status` | Shows the sing-box state, configured mode and any pending rollback timer. |
| `ubuntu-vless logs` | Shows a redacted summary of recent sing-box service events. |
| `ubuntu-vless restart` | Restarts the managed service from its active profile. TUN restarts require SSH confirmation. |
| `ubuntu-vless stop` | Stops the sing-box service, including proxy mode. |
| `ubuntu-vless restore` | Restores the previous sing-box configuration saved by the toolbox, if available. |
| `ubuntu-vless rollback` | Immediately cancels a pending activation and restores its saved state. |
| `ubuntu-vless uninstall --yes` | Removes the Debian sing-box package and keeps configuration and backups. |
| `ubuntu-vless menu --plain` | Opens the numbered menu. |
| `ubuntu-vless --help` | Lists the available commands. |

## Recovery

Run `ubuntu-vless rollback` from an available SSH session or the VPS console to cancel a pending activation. The console can also start the watchdog directly.

```bash
sudo systemctl start singbox-toolbox-rollback.service
sudo journalctl -u singbox-toolbox-rollback.service -n 40 --no-pager
```

Root-only snapshots are under `/var/lib/singbox-toolbox/transactions/`. If recovery remains pending, the ID in `/var/lib/singbox-toolbox/pending` identifies the snapshot.

## Tests

Run `bash tests/smoke.sh` and `python3 tests/tui-pty.py`. Set `SINGBOX_TEST_BIN` to a sing-box 1.14+ executable to include configuration checks. Follow the [staging acceptance tests](tests/STAGING.md) to verify live SSH, DNS, and TUN on a VPS with your upstream.
