#!/usr/bin/env python3
"""Exercise the toolbox keyboard interface in an isolated pseudoterminal."""

import argparse
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time


MOCKS = r'''
source "$1"
STATE_DIR=$2
managed_mode() { printf '%s\n' proxy; }
locate_box() { return 1; }
runtime_init() { return 0; }
tui_has_running_tun() { [[ -e $STATE_DIR/mock-tunnel ]]; }
systemctl() {
    case "$1" in
        is-active) return 1 ;;
        show) printf '%s\n' inactive ;;
        *) return 1 ;;
    esac
}
run_action() {
    local value
    printf '%s\n' "$*" >>"$STATE_DIR/actions"
    case "$1" in
        import-vless)
            IFS= read -r value
            if [[ $value == vless://dummy-keyboard-test@vpn.example.test:443 ]]; then
                printf '%s\n' vless-input-ok >>"$STATE_DIR/actions"
            else
                printf '%s\n' vless-input-bad >>"$STATE_DIR/actions"
                return 1
            fi
            ;;
        install)
            printf '%s\n' 'First installer line'
            sleep 1.2
            for value in {2..20}; do
                printf 'Installer line %s\n' "$value"
            done
            printf '\033[?1049l%s\n' 'Last installer line'
            ;;
        enable-tun)
            if [[ -e $STATE_DIR/allow-start ]]; then
                : >"$STATE_DIR/mock-tunnel"
            else
                printf '%s\n' 'Fixture connectivity failed.' >&2
                return 42
            fi
            ;;
        stop-tun)
            rm -f "$STATE_DIR/mock-tunnel"
            ;;
    esac
    printf '%s\n' 'Fixture action finished.'
}
tty_modes() {
    "$3" -c '
import termios
modes = termios.tcgetattr(0)
# PENDIN is temporary kernel state after toggling canonical input on macOS.
modes[3] &= ~getattr(termios, "PENDIN", 0)
print(modes)
'
}
if [[ -t 0 ]]; then
    tty_modes "$@" >"$STATE_DIR/terminal-before"
    main
    tty_modes "$@" >"$STATE_DIR/terminal-after"
else
    main status
fi
'''


def tty_modes(fd):
    modes = termios.tcgetattr(fd)
    modes[3] &= ~getattr(termios, "PENDIN", 0)
    return modes


def acquire_terminal():
    os.setsid()
    fcntl.ioctl(0, termios.TIOCSCTTY, 0)


class Terminal:
    def __init__(self, toolbox, bash, state, rows=24, cols=80, term="xterm-256color"):
        self.master, self.slave = pty.openpty()
        self.state = state
        self.transcript = bytearray()
        self.baseline = tty_modes(self.slave)
        self.resize(rows, cols)
        env = dict(os.environ, TERM=term, LC_ALL="C")
        env.pop("NO_COLOR", None)
        self.child = subprocess.Popen(
            [bash, "-c", MOCKS, "toolbox-pty-test", os.fspath(toolbox), os.fspath(state), sys.executable],
            stdin=self.slave,
            stdout=self.slave,
            stderr=self.slave,
            env=env,
            preexec_fn=acquire_terminal,
        )

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        try:
            if self.child.poll() is None:
                self.child.terminate()
                try:
                    self.child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    self.child.kill()
                    self.child.wait()
        finally:
            os.close(self.master)
            os.close(self.slave)

    def collect(self, wait):
        if not select.select([self.master], [], [], wait)[0]:
            return
        try:
            self.transcript.extend(os.read(self.master, 65536))
        except OSError as error:
            if error.errno != errno.EIO:
                raise

    def expect(self, needle, start=0, timeout=5):
        deadline = time.monotonic() + timeout
        while True:
            idx = self.transcript.find(needle, start)
            if idx >= 0:
                return idx + len(needle)
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError(f"Expected {needle!r}; received {bytes(self.transcript[-2500:])!r}")
            self.collect(min(remaining, 0.1))

    def send(self, data):
        os.write(self.master, data)

    def expect_echo_disabled(self):
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if not termios.tcgetattr(self.slave)[3] & termios.ECHO:
                return
            self.collect(0.02)
        raise AssertionError("Terminal did not suppress echo for credentials")

    def resize(self, rows, cols):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))

    def expect_actions(self, *actions):
        path = self.state / "actions"
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if path.exists() and path.read_text().splitlines() == list(actions):
                return
            self.collect(0.05)
        output = path.read_text() if path.exists() else ""
        raise AssertionError(f"Expected actions {actions!r}; got {output!r}")

    def assert_exit(self, code=0):
        deadline = time.monotonic() + 5
        while self.child.poll() is None and time.monotonic() < deadline:
            self.collect(0.05)
        assert self.child.poll() == code, f"Expected exit {code}; got {self.child.poll()}"
        self.collect(0.05)
        # macOS detaches the controlling TTY when the session leader exits.
        if code == 0:
            assert (self.state / "terminal-before").read_bytes() == (self.state / "terminal-after").read_bytes(), (
                "PTY modes were left modified"
            )
        else:
            try:
                assert tty_modes(self.slave) == self.baseline, "PTY modes were left modified"
            except termios.error as error:
                if error.args[0] not in (errno.EIO, errno.ENOTTY):
                    raise
        for hide, show in ((b"\x1b[?25l", b"\x1b[?25h"), (b"\x1b[?1049h", b"\x1b[?1049l")):
            if hide in self.transcript:
                assert self.transcript.rfind(show) > self.transcript.rfind(hide), "Terminal display was not restored"


TITLE = b"UBUNTU VLESS"
VLESS_LABEL = b"Import VLESS link"
VLESS_PROMPT = b"VLESS URL (hidden): "
VLESS_TOKEN = b"vless://dummy-keyboard-test@vpn.example.test:443"
RETURN_PROMPT = b"Enter/Esc Back"
ALT_SCREEN_EXIT = b"\x1b[?1049l"
START_TUN = b"Start TUN"
STOP_TUN = b"Stop TUN"


def credential_case(toolbox, bash, tmp):
    with Terminal(toolbox, bash, tmp) as tty:
        tty.expect(VLESS_LABEL)
        tty.send(b"\x1b[B\r")
        begin = tty.expect(VLESS_PROMPT)
        tty.expect_echo_disabled()
        tty.send(VLESS_TOKEN + b"\r")
        progress = tty.expect(b"Fixture action finished.", start=begin)
        prompt = tty.expect(RETURN_PROMPT, start=progress)
        tty.expect_actions("import-vless -", "vless-input-ok")
        assert ALT_SCREEN_EXIT not in tty.transcript, "The action left the dashboard"
        assert VLESS_TOKEN not in tty.transcript, "The credential was echoed to the terminal"
        tty.send(b"\r")
        tty.expect(TITLE, start=prompt)
        tty.send(b"\x1b")
        tty.assert_exit()


def toggle_case(toolbox, bash, tmp):
    (tmp / "allow-start").touch()
    with Terminal(toolbox, bash, tmp) as tty:
        tty.expect(START_TUN)
        dashboard = tty.expect(b"Update toolbox")
        for removed in (b"Import JSON profile", b"View logs", b"Service status", b"Enable loopback proxy"):
            assert removed not in tty.transcript
        tty.send(b"jj\r")
        review = tty.expect(RETURN_PROMPT, start=dashboard)
        tty.expect_actions("enable-tun --auto")
        tty.send(b"\r")
        dashboard = tty.expect(STOP_TUN, start=review)
        tty.send(b"\r")
        review = tty.expect(RETURN_PROMPT, start=dashboard)
        tty.expect_actions("enable-tun --auto", "stop-tun")
        tty.send(b"\r")
        dashboard = tty.expect(START_TUN, start=review)
        tty.send(b"j\r")
        tty.expect(RETURN_PROMPT, start=dashboard)
        tty.expect_actions("enable-tun --auto", "stop-tun", "update")
        tty.send(b"\r")
        tty.assert_exit()


def resize_case(toolbox, bash, tmp):
    with Terminal(toolbox, bash, tmp, rows=24, cols=80) as tty:
        tty.expect(VLESS_LABEL)
        before_resize = len(tty.transcript)
        tty.resize(10, 40)
        after_resize = tty.expect(TITLE, start=before_resize)
        # The third item moves the selection onto the next page.
        tty.send(b"j\x1bOB")
        tty.expect(START_TUN, start=after_resize)
        tty.send(b"\r")
        result = tty.expect(RETURN_PROMPT, start=after_resize)
        tty.expect_actions("enable-tun --auto")
        tty.send(b"\r")
        tty.expect(TITLE, start=result)
        tty.send(b"q")
        tty.assert_exit()


def output_case(toolbox, bash, tmp):
    with Terminal(toolbox, bash, tmp, rows=18, cols=88) as tty:
        tty.expect(START_TUN)
        tty.send(b"\r")
        running = tty.expect(b"Running...")
        tty.expect(b"First installer line", start=running)
        review = tty.expect(RETURN_PROMPT, start=running)
        assert b"Last installer line" in tty.transcript[running:review]
        assert ALT_SCREEN_EXIT not in tty.transcript, "Command output escaped the alternate screen"
        tty.send(b"\x1b[5~")
        scrolled = tty.expect(b"First installer line", start=review)
        tty.send(b"\r")
        dashboard = tty.expect(START_TUN, start=scrolled)
        tty.send(b"jj\r")
        failed = tty.expect(b"Failed (exit 42)", start=dashboard)
        review = tty.expect(RETURN_PROMPT, start=failed)
        assert b"Fixture connectivity failed." in tty.transcript[failed:review]
        assert b"installer line" not in tty.transcript[failed:review].lower()
        tty.expect_actions("install", "enable-tun --auto")
        tty.send(b"\x1b")
        tty.expect(START_TUN, start=review)
        assert not list(tmp.glob("ui-output.*")), "An action output file was left behind"
        tty.send(b"q")
        tty.assert_exit()


def term_case(toolbox, bash, tmp):
    with Terminal(toolbox, bash, tmp) as tty:
        tty.expect(VLESS_LABEL)
        assert b"\x1b[?1049h" in tty.transcript, "Dashboard did not open the alternate screen"
        tty.child.send_signal(signal.SIGTERM)
        tty.assert_exit(143)


def plain_case(toolbox, bash, tmp):
    (tmp / "allow-start").touch()
    with Terminal(toolbox, bash, tmp, term="dumb") as tty:
        tty.expect(b" 1. Install sing-box")
        tty.expect(b" 2. Import VLESS link")
        tty.expect(b" 3. Start TUN")
        tty.expect(b" 4. Update toolbox")
        menu = tty.expect(b" 0. Exit")
        assert b" 5. " not in tty.transcript
        tty.send(b"3\r")
        menu = tty.expect(b" 3. Stop TUN", start=menu)
        tty.send(b"3\r")
        tty.expect(b" 3. Start TUN", start=menu)
        tty.expect_actions("enable-tun --auto", "stop-tun")
        tty.send(b"0\r")
        tty.assert_exit()
        assert b"\x1b[?1049h" not in tty.transcript, "Plain fallback used the alternate screen"


def cli_case(toolbox, bash, tmp):
    result = subprocess.run(
        [bash, "-c", MOCKS, "toolbox-cli-test", os.fspath(toolbox), os.fspath(tmp), sys.executable],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=True,
    )
    assert (tmp / "actions").read_text().splitlines() == ["status"]
    assert result.stdout == b"Fixture action finished.\n", result.stdout
    assert not result.stderr, result.stderr


def run_cases(toolbox, bash):
    for test, label in (
        (credential_case, "arrow navigation, hidden credential, and Escape exit"),
        (toggle_case, "simplified menu, Start/Stop TUN toggle, and updater dispatch"),
        (resize_case, "resize, short-window scrolling, and Start TUN dispatch"),
        (output_case, "live output, scrolling, fresh action results, and safe terminal rendering"),
        (term_case, "terminal restoration after SIGTERM"),
        (plain_case, "plain menu fallback on a dumb terminal"),
        (cli_case, "non-interactive status bypasses the dashboard"),
    ):
        with tempfile.TemporaryDirectory(prefix="ubuntu-vless-tui.") as state:
            test(toolbox, bash, Path(state))
        print(f"PASS {label}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("toolbox", nargs="?", type=Path, default=Path(__file__).resolve().parent.parent / "singbox-toolbox.sh")
    parser.add_argument("--bash", default=shutil.which("bash"))
    args = parser.parse_args()
    toolbox = args.toolbox.resolve(strict=True)
    result = subprocess.run([args.bash, "-c", 'test "${BASH_VERSINFO[0]}" -ge 4'], check=False)
    if result.returncode:
        parser.error("choose Bash 4+ with --bash")
    run_cases(toolbox, args.bash)


if __name__ == "__main__":
    main()
