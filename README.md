# Ubuntu VLESS

Run sing-box as a VLESS TUN client on an Ubuntu server. The SSH menu has four actions and keeps command output on screen.

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

1. **Install sing-box** installs the official package and checks its download digest. An existing compatible installation is reused.
2. **Import VLESS link** saves a link from your VLESS provider. Input stays hidden.
3. **Start TUN** activates the imported profile and checks connectivity. The same option becomes **Stop TUN** while it runs. Stop also cancels a pending activation.
4. **Update toolbox** fetches the latest script from this repository’s `main` branch with Git. The menu closes after a successful update. Reopen `ubuntu-vless` to load it.

The [example VLESS link](examples/client.vless) contains dummy values. TUN needs a working upstream, `/dev/net/tun`, systemd-resolved with the standard Ubuntu stub, and a live SSH connection. If the server has public IPv6 routes, the upstream must support IPv6 egress.

## Confirm TUN after starting

Keep the first SSH session open and wait for the health checks to pass. From the same client IP, open a **new** SSH connection with ControlMaster disabled and run:

```bash
ubuntu-vless confirm
```

If the command is unavailable in the second shell, use the exact confirmation command shown by **Start TUN**. Without confirmation within five minutes, the watchdog restores the prior configuration. TUN is scoped to the current boot. After a reboot, choose **Start TUN** again.

## Recovery and automation

Run `ubuntu-vless --help` for command-line options. Use `ubuntu-vless rollback` from an available SSH session or the VPS console to cancel a pending activation. Use `ubuntu-vless status` or `ubuntu-vless logs` to diagnose problems. The console can also start the watchdog directly.

```bash
sudo systemctl start singbox-toolbox-rollback.service
sudo journalctl -u singbox-toolbox-rollback.service -n 40 --no-pager
```

Root-only snapshots are under `/var/lib/singbox-toolbox/transactions/`. If recovery remains pending, the ID in `/var/lib/singbox-toolbox/pending` identifies the snapshot.

## Tests

Run `bash tests/smoke.sh` and `python3 tests/tui-pty.py`. Set `SINGBOX_TEST_BIN` to a sing-box 1.14+ executable to include configuration checks. Follow the [staging acceptance tests](tests/STAGING.md) to verify live SSH, DNS, and TUN on a VPS with your upstream.
