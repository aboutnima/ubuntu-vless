#!/bin/bash
# singbox-toolbox.sh — sing-box client management for Ubuntu with systemd.
# The installed copy in STATE_DIR is also the timer's recovery program.
set -Eeuo pipefail
set +x
umask 077

STATE_DIR=/var/lib/singbox-toolbox
CONFIG_DIR=/etc/sing-box
CONFIG_FILE=$CONFIG_DIR/config.json
UNIT_DIR=/etc/systemd/system
UNIT=sing-box.service
DROP_IN=$UNIT_DIR/$UNIT.d/99-singbox-toolbox.conf
ROLLBACK_TIMER=singbox-toolbox-rollback.timer
ROLLBACK_SERVICE=singbox-toolbox-rollback.service
TUN_PERMIT=/run/singbox-toolbox.tun
ROLLBACK_SECONDS=300
MAX_CONFIG_BYTES=4194304
LOCK_FD=
SCRATCH=
TXN=
BIN=
CLR_RED='' CLR_GREEN='' CLR_YELLOW='' CLR_RESET=''
if [[ -t 2 && ${TERM:-dumb} != dumb && ! ${NO_COLOR+x} ]]; then
    CLR_RED=$'\e[31m' CLR_GREEN=$'\e[32m' CLR_YELLOW=$'\e[33m' CLR_RESET=$'\e[0m'
fi

log_info() { printf '%s%s%s\n' "$CLR_GREEN" "$*" "$CLR_RESET" >&2; }
log_warn() { printf '%s%s%s\n' "$CLR_YELLOW" "$*" "$CLR_RESET" >&2; }
log_error() { printf '%s%s%s\n' "$CLR_RED" "$*" "$CLR_RESET" >&2; }
fail() { log_error "$*"; return 1; }

require_commands() {
    local cmd missing=()
    for cmd in "$@"; do
        command -v "$cmd" >/dev/null || missing+=("$cmd")
    done
    if ((${#missing[@]})); then
        fail "Missing commands: ${missing[*]}. Run the install action to install runtime dependencies."
        return 1
    fi
}

ubuntu_release() {
    local ID='' VERSION_ID=''
    [[ -r /etc/os-release ]] || return 1
    # shellcheck source=/dev/null
    . /etc/os-release
    [[ $ID == ubuntu && $VERSION_ID =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "$VERSION_ID"
}

runtime_init() {
    local action=$1
    ((EUID == 0)) || { fail 'Run the toolbox as root (sudo).'; return 1; }
    ((BASH_VERSINFO[0] > 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] >= 3))) ||
        { fail 'Bash 4.3 or newer is required.'; return 1; }
    require_commands systemctl flock install mktemp stat sync mv rm date timeout realpath grep || return 1
    [[ -d /run/systemd/system ]] || { fail 'An active systemd system manager is required.'; return 1; }
    if [[ $action != _rollback ]] && ! ubuntu_release >/dev/null; then
        fail 'This toolbox requires Ubuntu.'
        return 1
    fi
    if [[ -L $STATE_DIR || ( -e $STATE_DIR && ! -d $STATE_DIR ) ]]; then
        fail 'The toolbox state path is unsafe.'
        return 1
    fi
    install -d -m 0700 -- "$STATE_DIR" "$STATE_DIR/transactions" || return 1
}

open_lock() {
    local wait_seconds=${1:-0}
    exec {LOCK_FD}>"$STATE_DIR/lock" || return 1
    if ! flock -w "$wait_seconds" "$LOCK_FD"; then
        close_lock
        fail 'Another toolbox operation holds the lock. Try again shortly.'
        return 1
    fi
}

close_lock() {
    if [[ -n $LOCK_FD ]]; then
        exec {LOCK_FD}>&-
        LOCK_FD=
    fi
}

scratch_open() {
    SCRATCH=$(mktemp -d "$STATE_DIR/work.XXXXXXXX") || return 1
}

scratch_close() {
    if [[ -n $SCRATCH ]]; then
        rm -rf -- "$SCRATCH"
        SCRATCH=
    fi
}

# Stage on the destination filesystem and rename. install also replaces the
# source's permissions with the requested mode.
atomic_copy() {
    local source=$1 target=$2 mode=${3:-0600} stage
    stage=$(mktemp "${target%/*}/.sbtoolbox.XXXXXXXX") || return 1
    if ! install -m "$mode" -- "$source" "$stage" || ! mv -Tf -- "$stage" "$target"; then
        rm -f -- "$stage"
        return 1
    fi
}

atomic_text() {
    local target=$1 value=$2 stage
    stage=$(mktemp "${target%/*}/.sbtoolbox.XXXXXXXX") || return 1
    if ! printf '%s\n' "$value" >"$stage" || ! mv -Tf -- "$stage" "$target"; then
        rm -f -- "$stage"
        return 1
    fi
}

safe_config_paths() {
    local path
    for path in "$CONFIG_DIR" "${DROP_IN%/*}" "$CONFIG_FILE" "$DROP_IN"; do
        if [[ -L $path ]]; then
            fail 'A configuration or systemd drop-in path is a symlink. Resolve it before using the toolbox.'
            return 1
        fi
    done
    for path in "$CONFIG_FILE" "$DROP_IN"; do
        if [[ -e $path && ! -f $path ]]; then
            fail 'A configuration or drop-in path is not a regular file.'
            return 1
        fi
    done
}

htget() {
    curl -q --fail --silent --show-error --proto '=https' --proto-redir '=https' \
        --connect-timeout 8 --max-time 120 --tlsv1.2 "$@"
}

locate_box() {
    BIN=$(type -P sing-box) || { fail 'sing-box is missing. Run the install action first.'; return 1; }
    [[ $BIN =~ ^/[a-zA-Z0-9_./-]+$ ]] || { fail 'The sing-box binary path is unsupported.'; return 1; }
}

show_version() {
    local output version
    output=$("$BIN" version 2>/dev/null) || return 1
    if [[ $output =~ ^sing-box[[:space:]]version[[:space:]]([0-9]+\.[0-9]+\.[0-9]+([A-Za-z0-9.+~-]*)) ]]; then
        version=${BASH_REMATCH[1]}
        printf '%s\n' "$version"
        return 0
    fi
    fail 'The installed sing-box version could not be determined.'
}

require_box() {
    local version major minor
    locate_box || return 1
    version=$(show_version) || return 1
    IFS=. read -r major minor _ <<<"$version"
    if ((major < 1 || (major == 1 && minor < 14))); then
        fail "sing-box $version is installed. Upgrade it to stable 1.14 or later using its original package source."
        return 1
    fi
}

install_dependencies() {
    local package cmd
    local -a packages=()
    for package in curl jq python3 iproute2 coreutils util-linux; do
        case $package in
            iproute2) cmd=ip ;;
            coreutils) cmd=timeout ;;
            util-linux) cmd=flock ;;
            *) cmd=$package ;;
        esac
        command -v "$cmd" >/dev/null || packages+=("$package")
    done
    [[ -s /etc/ssl/certs/ca-certificates.crt ]] || packages+=(ca-certificates)
    if ((${#packages[@]})); then
        log_info "Installing runtime dependencies: ${packages[*]}"
        apt-get -q update && DEBIAN_FRONTEND=noninteractive apt-get -qy install --no-install-recommends "${packages[@]}"
    fi
}

install_box() {
    local arch release version tag asset digest url actual old_dir='' install_rc=0
    reject_pending || return 1
    require_commands apt-get dpkg dpkg-query uname sha256sum || return 1
    release=$(ubuntu_release) || return 1
    arch=$(dpkg --print-architecture) || return 1
    case $arch in
        amd64|arm64|armhf|i386|s390x) ;;
        *) fail "Unsupported Ubuntu package architecture: $arch"; return 1 ;;
    esac
    log_info "Ubuntu $release, $arch ($(uname -m))."
    install_dependencies || { fail 'Dependency installation failed.'; return 1; }
    if type -P sing-box >/dev/null; then
        require_box || return 1
        version=$(show_version) || return 1
        log_info "sing-box $version is already installed."
        return 0
    fi
    if dpkg-query -W -f='${db:Status-Status}\n' sing-box 2>/dev/null | grep -qx installed; then
        fail 'The sing-box package is installed but the executable is missing. Repair the package with APT.'
        return 1
    fi
    if systemctl is-active --quiet "$UNIT"; then
        fail 'An existing sing-box service is active. Resolve the existing installation before installing.'
        return 1
    fi
    require_commands curl jq cmp || return 1
    log_info 'Downloading the latest stable SagerNet release and verifying its SHA-256 digest.'
    htget --max-filesize 8388608 --output "$SCRATCH/release.json" \
        'https://api.github.com/repos/SagerNet/sing-box/releases/latest' 2>/dev/null ||
        { fail 'The official release metadata could not be downloaded.'; return 1; }
    tag=$(jq -er 'select(.draft == false and .prerelease == false) | .tag_name |
        select(test("^v[0-9]+\\.[0-9]+\\.[0-9]+$"))' "$SCRATCH/release.json" 2>/dev/null) ||
        { fail 'The official stable release response was invalid.'; return 1; }
    version=${tag#v}
    # Upstream names its 32-bit x86 and ARMv7 assets by GOARCH.
    case $arch in i386) arch=386 ;; armhf) arch=armv7 ;; esac
    asset=sing-box_${version}_linux_${arch}.deb
    url="https://github.com/SagerNet/sing-box/releases/download/$tag/$asset"
    digest=$(jq -er --arg name "$asset" --arg url "$url" '
        [.assets[] | select(.name == $name and .browser_download_url == $url)] |
        select(length == 1) | .[0].digest | select(test("^sha256:[a-f0-9]{64}$"))' \
        "$SCRATCH/release.json" 2>/dev/null) ||
        { fail 'The release has no matching official package with a SHA-256 digest.'; return 1; }
    htget --location --max-redirs 4 --max-filesize 67108864 --output "$SCRATCH/$asset" "$url" 2>/dev/null ||
        { fail 'The official sing-box package could not be downloaded.'; return 1; }
    actual=$(sha256sum -- "$SCRATCH/$asset") || return 1
    [[ ${actual%% *} == "${digest#sha256:}" ]] || { fail 'Package digest mismatch. Installation aborted.'; return 1; }
    safe_config_paths || return 1
    if [[ -f $CONFIG_FILE ]]; then
        old_dir=$(mktemp -d "$STATE_DIR/pre-install.XXXXXXXX") || return 1
        atomic_copy "$CONFIG_FILE" "$old_dir/config.json" || return 1
        stat -c '%u %g %a' -- "$CONFIG_FILE" >"$old_dir/config.stat" || return 1
        sync -f "$STATE_DIR" || return 1
    fi
    # The upstream package ships a conffile and only reloads systemd in postinst.
    DEBIAN_FRONTEND=noninteractive dpkg --force-confold -i "$SCRATCH/$asset" || install_rc=$?
    if [[ -n $old_dir ]] && ! cmp -s "$CONFIG_FILE" "$old_dir/config.json"; then
        restore_config "$old_dir" || { fail "Restore the pre-install backup at $old_dir."; return 1; }
    fi
    if ((install_rc)); then
        fail 'Package installation failed. Inspect the dpkg output before retrying.'
        return 1
    fi
    require_box || return 1
    version=$(show_version) || return 1
    log_info "Installed sing-box $version. Import a client profile to activate a connection."
}

reject_pending() {
    if [[ -e $STATE_DIR/pending ]]; then
        fail 'A rollback is pending. Confirm from a second SSH session or run rollback first.'
        return 1
    fi
}

require_network_tools() {
    require_commands jq python3 curl ip ss timeout getent
}

safe_https_url() {
    python3 -I -c '
import re
import sys
from urllib.parse import urlsplit

raw = sys.stdin.buffer.read(8193).rstrip(b"\r\n")
if not raw or len(raw) > 8192 or not re.fullmatch(rb"[\x21-\x7e]+", raw):
    sys.exit(1)
url = raw.decode("ascii")
if not url.startswith("https://") or any(c in url for c in ("\"", "\\", "#", "{", "}", "[", "]")):
    sys.exit(1)
try:
    u = urlsplit(url)
    if (u.username is not None or u.password is not None or not u.hostname
        or not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?", u.hostname)
        or "%" in u.netloc or (u.port is not None and not 1 <= u.port <= 65535)):
        sys.exit(1)
except ValueError:
    sys.exit(1)
sys.stdout.write(url)
'
}

read_source() {
    local source=$1 target=$2 bytes
    if [[ $source == - ]]; then
        head -c "$((MAX_CONFIG_BYTES + 1))" >"$target" || return 1
    else
        [[ -f $source && -r $source ]] || { fail 'The input must be a readable regular file.'; return 1; }
        head -c "$((MAX_CONFIG_BYTES + 1))" <"$source" >"$target" || return 1
    fi
    bytes=$(wc -c <"$target") || return 1
    if ((bytes == 0 || bytes > MAX_CONFIG_BYTES)); then
        fail 'Input is empty or exceeds 4 MiB.'
        return 1
    fi
}

download_json() {
    local url bytes
    url=$(safe_https_url) || { fail 'Enter a valid HTTPS URL without userinfo or a fragment.'; return 1; }
    # Keep the URL off argv and bound streamed responses even with older curl.
    if ! printf 'url = "%s"\n' "$url" | htget --config - --globoff --proxy '' --noproxy '*' \
        --max-time 30 --max-filesize "$MAX_CONFIG_BYTES" --write-out '%{stderr}%{http_code}' \
        2>"$SCRATCH/http-code" | head -c "$((MAX_CONFIG_BYTES + 1))" >"$SCRATCH/input"; then
        fail 'The HTTPS configuration download failed or exceeded the size limit.'
        return 1
    fi
    [[ $(<"$SCRATCH/http-code") == 200 ]] ||
        { fail 'The download must return HTTP 200. Redirects are refused.'; return 1; }
    bytes=$(wc -c <"$SCRATCH/input") || return 1
    if ((bytes == 0 || bytes > MAX_CONFIG_BYTES)); then
        fail 'Downloaded input is empty or exceeds 4 MiB.'
        return 1
    fi
}

import_profile() {
    local kind=$1 source=$2
    reject_pending || return 1
    require_commands jq python3 || return 1
    if [[ $kind == json && $source == --url-stdin ]]; then
        require_commands curl || return 1
        download_json || return 1
    else
        read_source "$source" "$SCRATCH/input" || return 1
    fi
    case $kind in
        vless) vless_profile "$SCRATCH/input" "$SCRATCH/profile.json" || return 1 ;;
        json) import_json_profile "$SCRATCH/input" "$SCRATCH/profile.json" || return 1 ;;
    esac
    atomic_copy "$SCRATCH/profile.json" "$STATE_DIR/profile.json" || return 1
    log_info 'Client profile staged. The running service is unchanged.'
}

# Credentials enter the parser through private files, never through command arguments.
config_tool() {
    python3 -I - "$@" <<'PYTHON'
import ipaddress
import json
import os
import re
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit


class ConfigError(ValueError):
    pass


def require(condition, message):
    if not condition:
        raise ConfigError(message)


def read_input(path, limit):
    with Path(path).open("rb") as stream:
        data = stream.read(limit + 1)
    require(len(data) <= limit, "Configuration input exceeds the size limit.")
    return data.decode("utf-8")


def unique_pairs(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "JSON contains a duplicate object key.")
        result[key] = value
    return result


def reject_constant(_value):
    raise ConfigError("JSON contains a non-finite number.")


def read_json(path):
    return json.loads(
        read_input(path, 4 * 1024 * 1024),
        object_pairs_hook=unique_pairs,
        parse_constant=reject_constant,
    )


def write_json(path, data):
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW
    with os.fdopen(os.open(path, flags, 0o600), "w", encoding="utf-8") as stream:
        os.fchmod(stream.fileno(), 0o600)
        json.dump(data, stream, indent=2, allow_nan=False)
        stream.write("\n")


def parse_ip(value):
    if not isinstance(value, str) or "%" in value:
        return None
    try:
        return ipaddress.ip_address(value)
    except ValueError:
        return None


def endpoint_host(value):
    require(isinstance(value, str) and bool(value), "Invalid or missing outbound server.")
    address = parse_ip(value)
    if address:
        require(not (address.is_unspecified or address.is_multicast),
                "An outbound server must be a unicast IP or hostname.")
        require(not getattr(address, "ipv4_mapped", None), "Use plain IPv4 for a mapped IPv4 endpoint.")
        return str(address)
    host = value.lower()
    if host.endswith("."):
        host = host[:-1]
    require(len(host) <= 253 and all(
        re.fullmatch(r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?", label)
        for label in host.split(".")
    ) and not re.fullmatch(r"[0-9.]+", host), "Invalid outbound server or TLS server name.")
    return host


def decode_url_field(value):
    require(not re.search(r"%(?![0-9a-fA-F]{2})", value), "Invalid VLESS percent encoding.")
    decoded = unquote(value, errors="strict")
    require(not re.search(r"[\x00-\x1f\x7f]", decoded), "A VLESS field contains a control character.")
    return decoded


def vless_query(raw):
    params = {}
    for item in raw.split("&") if raw else []:
        key, separator, value = item.partition("=")
        require(bool(separator), "VLESS URL has a malformed query parameter.")
        key = decode_url_field(key).lower()
        require(re.fullmatch(r"[a-z0-9_]+", key) and key not in params,
                "VLESS URL has a malformed or repeated query parameter.")
        params[key] = decode_url_field(value)
    return params


def alias(params, *keys):
    values = [params[key] for key in keys if key in params]
    require(len(set(values)) <= 1, "VLESS URL contains conflicting aliases.")
    return values[0] if values else ""


def link_transport(params):
    kind = params.get("type", "tcp").lower() or "tcp"
    kind = {"raw": "tcp", "websocket": "ws"}.get(kind, kind)
    require(kind in {"tcp", "ws", "grpc"}, "Supported VLESS transports are TCP, WebSocket and gRPC.")
    require(params.get("headertype", "none").lower() in {"", "none"},
            "VLESS header camouflage is unsupported.")
    service_name = alias(params, "servicename", "service_name")
    path = params.get("path", "")
    host = params.get("host", "")
    mode = params.get("mode", "").lower()
    early_data = params.get("ed", "")
    early_header = params.get("eh", "")
    require(not params.get("authority"), "Custom gRPC authority requires a compatible JSON profile.")

    if kind == "ws":
        require(not (service_name or mode), "WebSocket does not support gRPC parameters.")
        require(not path or path.startswith("/"), "A WebSocket path must begin with a slash.")
        transport = {"type": "ws", "path": path or "/"}
        if host:
            require(bool(re.fullmatch(r"[A-Za-z0-9.\[\]:-]+", host)),
                    "Invalid WebSocket Host header.")
            transport["headers"] = {"Host": host}
        if early_data:
            require(bool(re.fullmatch(r"[0-9]{1,5}", early_data)) and int(early_data) <= 65535,
                    "Invalid WebSocket early-data length.")
            transport["max_early_data"] = int(early_data)
        if early_header:
            require(bool(re.fullmatch(r"[A-Za-z0-9-]+", early_header)) and transport.get("max_early_data", 0),
                    "A WebSocket early-data header requires a positive early-data length.")
            transport["early_data_header_name"] = early_header
        return transport

    require(not (path or host or early_data or early_header),
            "WebSocket parameters require the WebSocket transport.")
    if kind == "grpc":
        require(mode in {"", "gun"}, "Only single-stream gRPC is supported for VLESS URLs.")
        return {"type": "grpc", "service_name": service_name}
    require(not (service_name or mode), "gRPC parameters require the gRPC transport.")
    return None


def link_tls(params):
    security = params.get("security", "none").lower() or "none"
    require(security in {"none", "tls", "reality"}, "Unsupported VLESS security mode.")
    require(alias(params, "allowinsecure", "insecure").lower() in {"", "0", "false"},
            "Disabling TLS certificate verification is unsupported.")
    sni = alias(params, "sni", "servername", "server_name")
    fingerprint = params.get("fp", "").lower()
    public_key = alias(params, "pbk", "publickey")
    short_id = alias(params, "sid", "shortid")
    alpn = params.get("alpn", "")
    if security == "none":
        require(not any((sni, fingerprint, public_key, short_id, alpn)),
                "TLS parameters require TLS or Reality security.")
        return None
    require(security == "reality" or not (public_key or short_id),
            "Reality credentials require Reality security.")
    tls = {"enabled": True}
    if sni:
        tls["server_name"] = endpoint_host(sni)
    if alpn:
        protocols = [protocol.strip() for protocol in alpn.split(",")]
        require(all(re.fullmatch(r"[!-~]{1,255}", protocol) for protocol in protocols),
                "Invalid ALPN list.")
        tls["alpn"] = protocols
    if fingerprint or security == "reality":
        require(fingerprint in {
            "", "chrome", "firefox", "edge", "safari", "360", "qq", "ios", "android", "random", "randomized",
        }, "Unsupported uTLS fingerprint.")
        tls["utls"] = {"enabled": True, "fingerprint": fingerprint or "chrome"}
    if security == "reality":
        require(bool(sni) and bool(re.fullmatch(r"[A-Za-z0-9_-]{43}", public_key)),
                "Reality requires an SNI and a URL-safe X25519 public key.")
        require(bool(re.fullmatch(r"(?:[a-fA-F0-9]{2}){0,8}", short_id)),
                "Reality short ID must contain zero to eight hexadecimal bytes.")
        tls["reality"] = {"enabled": True, "public_key": public_key, "short_id": short_id}
    return tls


def parse_vless(path):
    raw = read_input(path, 16 * 1024)
    if raw.endswith("\n"):
        raw = raw[:-1]
        if raw.endswith("\r"):
            raw = raw[:-1]
    require(not re.search(r"[\x00-\x20\x7f]", raw), "Enter exactly one VLESS URL without unescaped whitespace.")
    parsed = urlsplit(raw)
    require(parsed.scheme == "vless" and parsed.hostname and parsed.path in {"", "/"}
            and parsed.password is None and parsed.netloc.count("@") == 1
            and ":" not in (parsed.username or ""), "Invalid VLESS URL authority.")
    user_id = decode_url_field(parsed.username or "")
    require(bool(re.fullmatch(r"[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}", user_id)),
            "VLESS URL requires a canonical UUID.")
    port = parsed.port
    require(port is not None and port > 0, "VLESS URL requires a server port between 1 and 65535.")
    params = vless_query(parsed.query)
    require(not (params.keys() - {
        "type", "headertype", "servicename", "service_name", "path", "host", "mode", "authority",
        "ed", "eh", "security", "allowinsecure", "insecure", "sni", "servername", "server_name",
        "fp", "pbk", "publickey", "sid", "shortid", "alpn", "flow", "packetenconding",
        "packetencoding", "packet_encoding", "encryption", "spx",
    }), "VLESS URL contains an unsupported query parameter.")
    require(params.get("encryption", "none").lower() in {"", "none"},
            "VLESS URL requests an unsupported encryption extension.")
    tls = link_tls(params)
    transport = link_transport(params)
    flow = params.get("flow", "")
    require(not flow or (flow == "xtls-rprx-vision" and tls and not transport),
            "Vision requires TCP with TLS or Reality.")
    encoding = alias(params, "packetencoding", "packet_encoding", "packetenconding")
    require(encoding in {"", "none", "xudp", "packetaddr"}, "Unsupported VLESS UDP packet encoding.")
    outbound = {
        "type": "vless", "tag": "toolbox-vpn",
        "server": endpoint_host(parsed.hostname), "server_port": port, "uuid": user_id.lower(),
    }
    if tls:
        outbound["tls"] = tls
    if transport:
        outbound["transport"] = transport
    if flow:
        outbound["flow"] = flow
    if any(key in params for key in ("packetencoding", "packet_encoding", "packetenconding")):
        outbound["packet_encoding"] = "" if encoding == "none" else encoding
    return {"outbounds": [outbound], "route": {"final": "toolbox-vpn"}}


PROXY_TYPES = {
    "vless", "vmess", "trojan", "shadowsocks", "shadowtls", "hysteria", "hysteria2",
    "tuic", "anytls", "http", "socks",
}
GROUP_TYPES = {"selector", "urltest"}
UNSAFE_OPTIONS = {
    "bind_interface", "inet4_bind_address", "inet6_bind_address", "routing_mark", "netns", "netns_path",
    "network_strategy", "network_type", "fallback_network_type", "override_address", "override_port",
    "spoof", "spoof_method", "certificate_path", "client_certificate_path", "client_key_path",
    "key_path", "config_path", "private_key_path", "certificate_provider", "query_server_name",
    "realm",
}


def check_outbound_fields(data):
    if isinstance(data, list):
        for value in data:
            check_outbound_fields(value)
    if isinstance(data, dict):
        require(not any(key in UNSAFE_OPTIONS and value for key, value in data.items()),
                "An outbound requests an unsupported file, network or bootstrap option.")
        require(data.get("insecure") in (None, False),
                "Disabling TLS certificate verification is unsupported.")
        for value in data.values():
            check_outbound_fields(value)


def normalize_profile(config):
    require(isinstance(config, dict), "The JSON configuration must be an object.")
    standard_sections = {"$schema", "outbounds", "route", "inbounds", "dns", "log"}
    require(not any(key not in standard_sections and value not in (None, [], {}, False)
                    for key, value in config.items()), "JSON has unsupported top-level capabilities.")
    outbounds = config.get("outbounds")
    require(isinstance(outbounds, list) and 0 < len(outbounds) <= 64,
            "JSON must contain between 1 and 64 client outbounds.")
    route = config.get("route", {})
    require(isinstance(route, dict) and not any(
        key not in {"final", "auto_detect_interface", "default_domain_resolver"} and value not in (None, [], {}, False)
        for key, value in route.items()), "Custom routing policy or rule sets cannot be imported.")
    tags = {}
    for outbound in outbounds:
        require(isinstance(outbound, dict), "Each outbound must be a JSON object.")
        kind = outbound.get("type")
        require(isinstance(kind, str) and kind in PROXY_TYPES | GROUP_TYPES | {"direct"},
                "JSON contains an unsupported outbound type.")
        tag = outbound.get("tag")
        if not tag and len(outbounds) == 1:
            tag = outbound["tag"] = "toolbox-vpn"
        require(isinstance(tag, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,63}", tag))
                and tag not in tags, "Outbound tags must be unique and contain only safe tag characters.")
        tags[tag] = outbound
        check_outbound_fields(outbound)
        if kind in PROXY_TYPES:
            outbound["server"] = endpoint_host(outbound.get("server"))
            port = outbound.get("server_port")
            if kind == "hysteria2" and not port and outbound.get("server_ports"):
                require(type(outbound["server_ports"]) is list,
                        "Hysteria2 alternate ports must be an array.")
            else:
                require(type(port) is int and 1 <= port <= 65535,
                        "An outbound requires a valid server port.")
        # Use managed bootstrap settings for all outbound dials.
        outbound.pop("domain_resolver", None)
        outbound.pop("domain_strategy", None)

    selected = route.get("final", "")
    require(isinstance(selected, str), "The final outbound tag must be a string.")
    final = selected or outbounds[0]["tag"]
    require(isinstance(final, str) and final in tags, "The final routing tag must refer to an outbound.")

    # A group may select only proxies. A direct outbound can still provide a socket detour.
    validated = set()

    def validate_graph(tag, stack):
        if tag in validated:
            return
        require(tag not in stack, "The outbound graph contains a dependency cycle.")
        entry = tags[tag]
        if entry["type"] in GROUP_TYPES:
            choices = entry.get("outbounds")
            require(isinstance(choices, list) and bool(choices) and all(
                isinstance(item, str) and item in tags and tags[item]["type"] != "direct" for item in choices
            ), "A selector or URLTest must use defined proxy candidates.")
            default = entry.get("default", "")
            require(not default or (isinstance(default, str) and default in choices),
                    "A selector default must refer to one of its candidates.")
            for item in choices:
                validate_graph(item, stack | {tag})
        detour = entry.get("detour", "")
        if detour:
            require(isinstance(detour, str) and detour in tags,
                    "An outbound detour must refer to a defined outbound.")
            validate_graph(detour, stack | {tag})
        validated.add(tag)

    require(tags[final]["type"] != "direct", "The final outbound must use a proxy.")
    for tag in tags:
        validate_graph(tag, set())
    return {"outbounds": outbounds, "route": {"final": final}}


def profile_hosts(profile):
    return sorted({outbound["server"] for outbound in profile["outbounds"] if outbound["type"] in PROXY_TYPES})


def generate(profile_path, mode, ipv6, exclusions_path, output_path, pins_path=""):
    require(mode in {"proxy", "tun"} and ipv6 in {"yes", "no"}, "Invalid managed routing mode.")
    profile = normalize_profile(read_json(profile_path))
    final = profile["route"]["final"]
    bootstrap = {"type": "local", "tag": "toolbox-bootstrap"}
    dns_final = {
        "type": "https", "tag": "toolbox-dns", "server": "1.1.1.1", "detour": final,
        "path": "/dns-query", "tls": {"enabled": True, "server_name": "cloudflare-dns.com"},
    }
    inbounds = [{"type": "mixed", "tag": "toolbox-proxy", "listen": "127.0.0.1", "listen_port": 1080}]
    route = {
        "auto_detect_interface": mode == "tun", "default_domain_resolver": "toolbox-bootstrap",
        "final": final,
    }
    if mode == "tun":
        pins = read_json(pins_path) if pins_path else {}
        exclusions = read_json(exclusions_path)
        require(isinstance(pins, dict) and isinstance(exclusions, list)
                and all(isinstance(item, str) for item in exclusions), "Invalid TUN bootstrap or exclusion data.")
        networks = [ipaddress.ip_network(item, strict=True) for item in exclusions]
        enabled_networks = {network for network in networks if network.version == 4 or ipv6 == "yes"}
        require(all(network.prefixlen > 0 for network in enabled_networks), "A TUN exclusion would cover an entire address family.")
        pinned_hosts = {}
        for host in profile_hosts(profile):
            address = parse_ip(host)
            values = pins.get(host, [])
            require(isinstance(values, list), "TUN bootstrap address entries must be arrays.")
            addresses = [address] if address else [parse_ip(value) for value in values]
            require(bool(addresses) and all(item and not (item.is_unspecified or item.is_multicast
                    or getattr(item, "ipv4_mapped", None)) for item in addresses),
                    "The TUN needs valid bootstrap addresses for every outbound server.")
            require(all((item.version == 6 and ipv6 == "no") or
                        ipaddress.ip_network(item) in enabled_networks for item in addresses),
                    "Every outbound address carried by the TUN needs a host-route exclusion.")
            if not address:
                pinned_hosts[host] = list(dict.fromkeys(str(item) for item in addresses))
        bootstrap = {"type": "hosts", "tag": "toolbox-bootstrap", "predefined": pinned_hosts}
        tun_addresses = ["198.18.0.1/30"]
        if ipv6 == "yes":
            tun_addresses.append("fd4e:1d57:89a4::1/126")
        inbounds.append({
            "type": "tun", "tag": "toolbox-tun", "interface_name": "sbtoolbox0",
            "address": tun_addresses, "mtu": 1500, "dns_mode": "hijack",
            "auto_route": True, "auto_redirect": False,
            "iproute2_table_index": 20220, "iproute2_rule_index": 9200,
            "route_exclude_address": [str(network) for network in sorted(
                enabled_networks, key=lambda value: (value.version, int(value.network_address), value.prefixlen)
            )],
        })
        route["rules"] = [{"inbound": ["toolbox-tun"], "port": 53, "action": "hijack-dns"}]

    result = {
        "log": {"disabled": True},
        "dns": {"servers": [bootstrap, dns_final], "final": "toolbox-dns"},
        "inbounds": inbounds, "outbounds": profile["outbounds"], "route": route,
    }
    write_json(output_path, result)


def main(operation, *args):
    if operation == "vless":
        write_json(args[1], parse_vless(args[0]))
    elif operation == "import":
        write_json(args[1], normalize_profile(read_json(args[0])))
    elif operation == "endpoints":
        for host in profile_hosts(normalize_profile(read_json(args[0]))):
            print(host)
    elif operation == "generate":
        generate(*args)
    else:
        raise ConfigError("Unknown configuration operation.")


try:
    main(*sys.argv[1:])
except ConfigError as error:
    # ConfigError messages are fixed strings. Raw parser errors may contain secrets.
    print(str(error), file=sys.stderr)
    raise SystemExit(1)
except (OSError, ValueError, TypeError, RecursionError, OverflowError):
    print("Malformed or unreadable configuration input. Source content was withheld.", file=sys.stderr)
    raise SystemExit(1)
PYTHON
}

vless_profile() {
    config_tool vless "$@"
}

import_json_profile() {
    config_tool import "$@"
}

profile_endpoints() {
    config_tool endpoints "$@"
}

generate_config() {
    config_tool generate "$@"
}
# Network inspection and checks. TUN routing belongs to sing-box.
NETWORK_TUN=sbtoolbox0
NETWORK_TABLE=20220
NETWORK_RULE_FIRST=9200
NETWORK_RULE_LAST=9210
NETWORK_SERVICE=sing-box.service
SSH_SESSION=
SSH_CLIENT_IP=
SSH_CLIENT_CIDR=
SSH_BASELINE=
PROXY_PUBLIC_IP=
PROXY_PUBLIC_IPV6=

network_ssh_tuple() {
    python3 - "${1:-}" 2>/dev/null <<'PY'
import ipaddress
import re
import sys

try:
    peer, peer_port, local, local_port = sys.argv[1].split()
    addresses = [ipaddress.ip_address(value) for value in (peer, local)]
    addresses = [getattr(ip, "ipv4_mapped", None) or ip for ip in addresses]
    if addresses[0].version != addresses[1].version:
        raise ValueError
    if any(ip.is_unspecified or ip.is_multicast or ip.is_loopback or ip.is_link_local
           or getattr(ip, "scope_id", None) for ip in addresses):
        raise ValueError
    ports = [peer_port, local_port]
    if any(not re.fullmatch(r"[0-9]{1,5}", port) or not 1 <= int(port) <= 65535
           for port in ports):
        raise ValueError
    print(addresses[0], int(peer_port), addresses[1], int(local_port))
except ValueError:
    sys.exit(1)
PY
}

network_ssh_established() {
    local peer peer_port server server_port socket
    IFS=' ' read -r peer peer_port server server_port <<< "$1"
    if [[ $peer == *:* ]]; then
        peer="[$peer]"
        server="[$server]"
    fi
    socket=$(ss -H -tn state established "( src $server and sport = :$server_port and dst $peer and dport = :$peer_port )" 2>/dev/null) || return 1
    [[ -n $socket ]]
}

network_ssh_peer_ports() {
    local peer peer_port server server_port sockets socket remote port found=0
    local -a columns
    IFS=' ' read -r peer peer_port server server_port <<< "$1"
    if [[ $peer == *:* ]]; then
        peer="[$peer]"
        server="[$server]"
    fi
    sockets=$(ss -H -tn state established "( src $server and sport = :$server_port and dst $peer )" 2>/dev/null) || return 1
    while IFS= read -r socket; do
        [[ -n $socket ]] || continue
        IFS=$' \t' read -ra columns <<< "$socket"
        remote=${columns[-1]}
        port=${remote##*:}
        [[ $port =~ ^[0-9]{1,5}$ ]] || return 1
        printf '%s\n' "$port"
        if [[ $port == "$peer_port" ]]; then
            found=1
        fi
    done <<< "$sockets"
    (( found ))
}

network_route_fingerprint() {
    local destination=$1 family=4
    shift
    [[ $destination != *:* ]] || family=6
    ip "-$family" -N -j route get "$destination" "$@" 2>/dev/null |
        jq -ce '.[0] | select(.dev != null) | {dev, gateway, via, type, table, prefsrc, src}'
}

network_ssh_route() {
    local peer peer_port server server_port
    IFS=' ' read -r peer peer_port server server_port <<< "$1"
    network_route_fingerprint "$peer" from "$server" ipproto tcp sport "$server_port" dport "$peer_port"
}

network_confirm_ssh() {
    local original=$1 preexisting=${2:-} current original_peer original_port original_local original_local_port
    local current_peer current_port current_local current_local_port port original_found=0
    current=$(network_ssh_tuple "${SSH_CONNECTION:-}") || {
        log_error 'Confirmation requires SSH_CONNECTION from a live SSH shell.'
        return 1
    }
    IFS=' ' read -r original_peer original_port original_local original_local_port <<< "$original"
    IFS=' ' read -r current_peer current_port current_local current_local_port <<< "$current"
    if [[ $current_peer != "$original_peer" || $current_port == "$original_port" ||
          $current_local != "$original_local" || $current_local_port != "$original_local_port" ]]; then
        log_error 'Open a separate TCP SSH connection from the same client IP and disable SSH multiplexing.'
        return 1
    fi
    if [[ -n $preexisting ]]; then
        if [[ ! -s $preexisting || ! -r $preexisting ]]; then
            log_error 'The saved SSH socket inventory is unavailable.'
            return 1
        fi
        while IFS= read -r port; do
            if [[ $port == "$current_port" ]]; then
                log_error 'This SSH connection was already established. Open a new TCP SSH connection now.'
                return 1
            fi
            if [[ $port == "$original_port" ]]; then
                original_found=1
            fi
        done < "$preexisting"
        if (( ! original_found )); then
            log_error 'The original SSH connection was absent from the saved socket inventory.'
            return 1
        fi
    fi
    if ! network_ssh_established "$current"; then
        log_error 'The second SSH connection is missing from the kernel socket table.'
        return 1
    fi
}

network_verify_ssh() {
    local current
    if [[ -z $SSH_SESSION || -z $SSH_BASELINE ]] ||
       ! network_ssh_established "$SSH_SESSION" ||
       ! current=$(network_ssh_route "$SSH_SESSION") ||
       [[ $current != "$SSH_BASELINE" ]]; then
        log_error 'The original SSH connection or its return route changed.'
        return 1
    fi
}

network_resolve_endpoint() {
    timeout 8s python3 - "$1" 2>/dev/null <<'PY'
import ipaddress
import re
import socket
import sys

host = sys.argv[1]
try:
    if "%" in host:
        raise ValueError
    try:
        addresses = [ipaddress.ip_address(host)]
    except ValueError:
        labels = host.rstrip(".").split(".")
        if not (1 <= len(host) <= 254) or any(
            not re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?", label)
            for label in labels
        ):
            raise ValueError
        entries = socket.getaddrinfo(host, None, type=socket.SOCK_STREAM,
                                     proto=socket.IPPROTO_TCP)
        addresses = list(dict.fromkeys(ipaddress.ip_address(entry[4][0])
                                       for entry in entries if "%" not in entry[4][0]))
    if not 1 <= len(addresses) <= 32:
        raise ValueError
    if any(ip.is_unspecified or ip.is_multicast or ip.is_link_local
           or getattr(ip, "ipv4_mapped", None) or getattr(ip, "scope_id", None)
           for ip in addresses):
        raise ValueError
    for ip in addresses:
        print(ip)
except (ValueError, OSError):
    sys.exit(1)
PY
}

network_capture_endpoint_routes() {
    local endpoints=$1 destination=$2 address path reachable=0
    : > "$destination" || return 1
    while IFS= read -r address; do
        if path=$(network_route_fingerprint "$address"); then
            jq -e --arg tun "$NETWORK_TUN" '.dev != $tun' <<< "$path" >/dev/null || return 1
            reachable=1
        else
            path=UNREACHABLE
        fi
        printf '%s\t%s\n' "$address" "$path" >> "$destination" || return 1
    done < "$endpoints"
    if (( ! reachable )); then
        log_error 'The host has no direct route to any configured upstream endpoint.'
        return 1
    fi
}

network_verify_endpoint_routes() {
    local address baseline current
    [[ -s $1 ]] || return 1
    while IFS=$'\t' read -r address baseline; do
        current=$(network_route_fingerprint "$address") || current=UNREACHABLE
        if [[ -z $baseline || $current != "$baseline" ]]; then
            log_error 'An upstream endpoint no longer follows its original direct route.'
            return 1
        fi
    done < "$1"
}

network_active_service_pid() {
    local pid
    systemctl is-active --quiet "$NETWORK_SERVICE" || return 1
    pid=$(systemctl show -p MainPID --value "$NETWORK_SERVICE") || return 1
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 1
    printf '%s\n' "$pid"
}

network_proxy_preflight() {
    local sockets socket service_pid owners
    sockets=$(ss -H -ltnp 'sport = :1080' 2>/dev/null) || {
        log_error 'Could not check ownership of TCP port 1080.'
        return 1
    }
    [[ -n $sockets ]] || return 0
    service_pid=$(network_active_service_pid) || service_pid=
    while IFS= read -r socket; do
        if [[ -z $service_pid || $socket != *"pid=$service_pid,"* ||
              ! $socket =~ (^|[[:space:]])127\.0\.0\.1:1080([[:space:]]|$) ]]; then
            log_error 'TCP port 1080 has a listener outside the expected sing-box loopback listener.'
            return 1
        fi
        owners=$socket
        while [[ $owners =~ pid=([0-9]+), ]]; do
            if [[ ${BASH_REMATCH[1]} != "$service_pid" ]]; then
                log_error 'Another process shares the existing TCP port 1080 listener.'
                return 1
            fi
            owners=${owners#*"${BASH_REMATCH[0]}"}
        done
    done <<< "$sockets"
}

network_firewall_preflight() {
    local rules command
    if command -v nft >/dev/null; then
        rules=$(nft -j list ruleset 2>/dev/null) || {
            log_error 'Could not inspect nftables rules for routing conflicts.'
            return 1
        }
        if jq -e 'any(.nftables[].rule.expr[]?; has("tproxy") or has("redirect") or has("mangle"))' <<< "$rules" >/dev/null; then
            log_error 'nftables already contains transparent redirection or packet mangling rules.'
            return 1
        fi
        if jq -e 'any(.nftables[]; has("rule"))' <<< "$rules" >/dev/null; then
            log_warn 'Existing nftables filters may affect TUN traffic. Connectivity checks must pass.'
        fi
    else
        log_warn 'nft is unavailable. The toolbox cannot inspect nftables filters.'
    fi
    for command in iptables-legacy-save ip6tables-legacy-save; do
        if command -v "$command" >/dev/null; then
            rules=$("$command" 2>/dev/null) || {
                log_error 'Could not inspect legacy iptables rules for routing conflicts.'
                return 1
            }
            if [[ $rules =~ [[:space:]]-j[[:space:]](MARK|CONNMARK|TPROXY|REDIRECT)([[:space:]]|$) ]]; then
                log_error 'Legacy iptables already contains transparent redirection or packet marking rules.'
                return 1
            fi
            if [[ $rules == *'-A '* ]]; then
                log_warn 'Existing legacy iptables filters may affect TUN traffic. Connectivity checks must pass.'
            fi
        fi
    done
}

network_dns_preflight() {
    local output line domain has_local_domains=0
    local -a domains
    output=$(timeout 5s resolvectl --no-pager domain 2>/dev/null) || {
        log_error 'Could not inspect systemd-resolved DNS routing domains.'
        return 1
    }
    while IFS= read -r line; do
        IFS=$' \t' read -ra domains <<< "${line#*:}"
        for domain in "${domains[@]}"; do
            domain=${domain%.}
            case ${domain,,} in
                local|*.local|internal|*.internal|localdomain|*.localdomain|lan|*.lan|home.arpa|*.home.arpa)
                    has_local_domains=1 ;;
                *)
                    log_error 'An existing DNS routing or public search domain could bypass the TUN DNS link.'
                    return 1 ;;
            esac
        done
    done <<< "$output"
    if (( has_local_domains )); then
        log_warn 'Local search domains may continue to use their existing DNS link.'
    fi
}

network_tun_preflight() {
    local family links rules routes addresses global_v6
    if [[ ! -c /dev/net/tun ]] || ! ( exec 3<>/dev/net/tun ) 2>/dev/null; then
        log_error 'The kernel TUN device /dev/net/tun is unavailable.'
        return 1
    fi
    if ! command -v resolvectl >/dev/null ||
       ! systemctl is-active --quiet systemd-resolved.service ||
       [[ $(readlink -f /etc/resolv.conf 2>/dev/null) != /run/systemd/resolve/stub-resolv.conf ]]; then
        log_error 'TUN requires systemd-resolved and the standard Ubuntu stub resolv.conf symlink.'
        return 1
    fi
    network_dns_preflight || return 1
    if [[ $(</proc/sys/net/ipv4/ip_forward) != 0 ||
          ( -r /proc/sys/net/ipv6/conf/all/forwarding && $(</proc/sys/net/ipv6/conf/all/forwarding) != 0 ) ]]; then
        log_error 'Packet forwarding is enabled. Use proxy mode on routers and container forwarding hosts.'
        return 1
    fi
    links=$(ip -j -d link show 2>/dev/null) || {
        log_error 'Could not inspect existing network interfaces.'
        return 1
    }
    if jq -e --arg tun "$NETWORK_TUN" '
        any(.[]; .ifname == $tun or
            (((.flags // []) | index("UP")) != null and
             (((.linkinfo.info_kind // "") | IN("tun","wireguard","xfrm","gre","gretap","ipip","sit","vti","vti6","bridge")) or
              ((.ifname // "") | test("^(tun[0-9]|tap[0-9]|wg[0-9]|ppp[0-9]|tailscale|zt[a-z0-9]|docker|podman|cni|flannel|virbr|lxcbr|br-[a-f0-9])")))))
        ' <<< "$links" >/dev/null; then
        log_error 'An active tunnel or bridge, or the reserved toolbox interface, conflicts with TUN.'
        return 1
    fi
    for family in 4 6; do
        rules=$(ip "-$family" -N -j rule show 2>/dev/null) || {
            log_error 'Could not inspect policy-routing rules.'
            return 1
        }
        if ! jq -e 'all(.[]; (.table | tostring) as $table |
            ((.priority == 0 and ($table == "255" or $table == "local")) or
             (.priority == 32766 and ($table == "254" or $table == "main")) or
             (.priority == 32767 and ($table == "253" or $table == "default"))) and
             (.src == "all" or .src == null) and
             ((keys - ["priority","src","table","protocol","family","flags"]) | length == 0))' <<< "$rules" >/dev/null; then
            log_error 'Custom policy-routing rules are present. Use proxy mode with this routing policy.'
            return 1
        fi
        routes=$(ip "-$family" -N -j route show table all 2>/dev/null) || {
            log_error 'Could not inspect existing route tables.'
            return 1
        }
        if jq -e --arg table "$NETWORK_TABLE" 'any(.[]; (.table | tostring) == $table)' <<< "$routes" >/dev/null; then
            log_error 'The route table reserved by the toolbox is already in use.'
            return 1
        fi
        addresses=$(ip "-$family" -j address show 2>/dev/null) || return 1
        if ! python3 - "$family" <(printf '%s' "$addresses") <(printf '%s' "$routes") 2>/dev/null <<'PY'
import ipaddress
import json
import sys

family, link_path, route_path = sys.argv[1:]
with open(link_path, encoding="utf-8") as link_file, open(route_path, encoding="utf-8") as route_file:
    links = json.load(link_file)
    routes = json.load(route_file)
reserved = ipaddress.ip_network("198.18.0.0/30" if family == "4" else "fd4e:1d57:89a4::/126")
for link in links:
    for address in link.get("addr_info", []):
        prefix = ipaddress.ip_network(f'{address["local"]}/{address["prefixlen"]}', strict=False)
        if prefix.overlaps(reserved):
            sys.exit(1)
for route in routes:
    destination = route.get("dst", "default")
    if destination not in ("default", "0.0.0.0/0", "::/0"):
        if ipaddress.ip_network(destination, strict=False).overlaps(reserved):
            sys.exit(1)
PY
        then
            log_error 'An existing address or route overlaps a TUN address range.'
            return 1
        fi
    done
    global_v6=$(ip -6 -N -j route show table main 2>/dev/null) || return 1
    if [[ $1 != yes ]] && ! python3 -c '
import ipaddress
import json
import sys

public_range = ipaddress.ip_network("2000::/3")
for route in json.load(sys.stdin):
    if route.get("type", "unicast") != "unicast":
        continue
    target = route.get("dst", "default")
    if target == "default" or ipaddress.ip_network(target, strict=False).overlaps(public_range):
        sys.exit(1)
' <<< "$global_v6"; then
        log_error 'Public IPv6 routing is available. Enable verified IPv6 TUN routing or use proxy mode.'
        return 1
    fi
    network_firewall_preflight
}

network_preflight() {
    local mode=$1 ipv6=${2:-no} prefix
    network_proxy_preflight || return 1
    [[ $mode == tun ]] || return 0
    SSH_SESSION=$(network_ssh_tuple "${SSH_CONNECTION:-}") || {
        log_error 'TUN activation requires SSH_CONNECTION from a live SSH session. Preserve it with sudo.'
        return 1
    }
    if ! network_ssh_established "$SSH_SESSION" || ! SSH_BASELINE=$(network_ssh_route "$SSH_SESSION"); then
        log_error 'Could not verify the current SSH connection and its original return route.'
        return 1
    fi
    SSH_CLIENT_IP=${SSH_SESSION%% *}
    prefix=32
    [[ $SSH_CLIENT_IP != *:* ]] || prefix=128
    SSH_CLIENT_CIDR="$SSH_CLIENT_IP/$prefix"
    network_tun_preflight "$ipv6"
}

network_cleanup_tun() {
    local family rules routes priorities priority failed=0
    if systemctl is-active --quiet "$NETWORK_SERVICE"; then
        log_error 'TUN cleanup requires sing-box to be stopped.'
        return 1
    fi
    if ip link show dev "$NETWORK_TUN" >/dev/null 2>&1; then
        if command -v resolvectl >/dev/null; then
            timeout 5s resolvectl revert "$NETWORK_TUN" >/dev/null 2>&1 || true
        fi
        ip link delete dev "$NETWORK_TUN" >/dev/null 2>&1 || failed=1
    fi
    for family in 4 6; do
        if ! rules=$(ip "-$family" -j rule show 2>/dev/null) ||
           ! priorities=$(jq -r --argjson first "$NETWORK_RULE_FIRST" --argjson last "$NETWORK_RULE_LAST" '
                .[] | .priority | select(. >= $first and . <= $last)
            ' <<< "$rules"); then
            failed=1
            continue
        fi
        while IFS= read -r priority; do
            [[ -n $priority ]] || continue
            ip "-$family" rule delete priority "$priority" >/dev/null 2>&1 || failed=1
        done <<< "$priorities"
        if ! routes=$(ip "-$family" -N -j route show table all 2>/dev/null); then
            failed=1
        elif jq -e --arg table "$NETWORK_TABLE" 'any(.[]; (.table | tostring) == $table)' <<< "$routes" >/dev/null; then
            ip "-$family" route flush table "$NETWORK_TABLE" >/dev/null 2>&1 || failed=1
        fi
    done
    if (( failed )); then
        log_error 'Could not remove every routing object reserved by the toolbox.'
        return 1
    fi
}

network_probe_ip() {
    local mode=$1 family=$2 url=$3 body
    local -a options
    case $mode in
        direct|routed) options=("--ipv$family" --proxy '' --noproxy '*') ;;
        proxy) options=(--proxy socks5h://127.0.0.1:1080 --noproxy '') ;;
        http) options=(--proxy http://127.0.0.1:1080 --noproxy '') ;;
        *) return 1 ;;
    esac
    body=$(curl --disable --silent --fail --proto '=https' --connect-timeout 4 --max-time 7 \
        --max-filesize 1024 "${options[@]}" -- "$url" 2>/dev/null) || return 1
    python3 -c '
import ipaddress
import sys

try:
    ip = ipaddress.ip_address(sys.stdin.read().strip())
    if (ip.version != int(sys.argv[1]) or not ip.is_global
            or ip.is_multicast or getattr(ip, "scope_id", None)):
        raise ValueError
    print(ip)
except ValueError:
    sys.exit(1)
' "$family" <<< "$body"
}

network_public_ip() {
    local mode=$1 family=${2:-4} url ip
    local -a endpoints
    local -A seen=()
    case $family in
        4) endpoints=(https://api.ipify.org https://ipv4.icanhazip.com https://v4.ident.me) ;;
        6) endpoints=(https://api6.ipify.org https://ipv6.icanhazip.com https://v6.ident.me) ;;
        *) return 1 ;;
    esac
    for url in "${endpoints[@]}"; do
        if ip=$(network_probe_ip "$mode" "$family" "$url"); then
            if [[ -n ${seen[$ip]:-} ]]; then
                printf '%s\n' "$ip"
                return 0
            fi
            seen[$ip]=1
        fi
    done
    return 1
}

network_verify_default_tun() {
    local family=$1 address count=0 path
    local -a destinations
    case $family in
        4) destinations=(1.0.0.1 8.8.4.4 149.112.112.112) ;;
        6) destinations=(2606:4700:4700::1001 2001:4860:4860::8844 2620:fe::9) ;;
        *) return 1 ;;
    esac
    for address in "${destinations[@]}"; do
        if path=$(network_route_fingerprint "$address") &&
           jq -e --arg tun "$NETWORK_TUN" '.dev == $tun' <<< "$path" >/dev/null; then
            count=$((count + 1))
        fi
    done
    if (( count < 2 )); then
        log_error "Public IPv$family destinations do not route through the TUN interface."
        return 1
    fi
}

network_tun_dns_ready() {
    local ipv6=$1 servers domains
    servers=$(timeout 5s resolvectl dns "$NETWORK_TUN" 2>/dev/null) || return 1
    domains=$(timeout 5s resolvectl domain "$NETWORK_TUN" 2>/dev/null) || return 1
    [[ $servers =~ (^|[[:space:]])198\.18\.0\.2([[:space:]]|$) ]] &&
        [[ $domains =~ (^|[[:space:]])~\.([[:space:]]|$) ]] || return 1
    if [[ $ipv6 == yes && ! $servers =~ (^|[[:space:]])fd4e:1d57:89a4::2([[:space:]]|$) ]]; then
        return 1
    fi
}

network_verify_tun_dns() {
    local ipv6=$1 host answer
    if ! network_tun_dns_ready "$ipv6"; then
        log_error 'systemd-resolved lacks the expected TUN DNS server or catch-all DNS domain.'
        return 1
    fi
    for host in api.ipify.org. ipv4.icanhazip.com. v4.ident.me.; do
        if answer=$(LC_ALL=C SYSTEMD_COLORS=0 timeout 7s resolvectl -4 --protocol=dns --cache=no --synthesize=no query "$host" 2>/dev/null) &&
           [[ $answer =~ --[[:space:]]link:[[:space:]]$NETWORK_TUN([[:space:]]|$) ]] &&
           timeout 5s getent ahostsv4 "$host" >/dev/null 2>&1; then
            return 0
        fi
    done
    log_error 'A fresh system DNS query could not be verified on the TUN DNS link.'
    return 1
}

network_health() {
    local mode=$1 baseline4=${2:-} ipv6=${3:-no} baseline6=${4:-}
    local attempt initial_pid='' pid sockets ordinary_ip http_ip
    PROXY_PUBLIC_IP=
    PROXY_PUBLIC_IPV6=
    for attempt in {1..8}; do
        if initial_pid=$(network_active_service_pid) &&
           sockets=$(ss -H -ltnp 'src 127.0.0.1 and sport = :1080' 2>/dev/null) &&
           [[ $sockets == *"pid=$initial_pid,"* ]] &&
           { [[ $mode != tun ]] || network_tun_dns_ready "$ipv6"; }; then
            break
        fi
        initial_pid=
        if (( attempt < 8 )); then
            sleep 1
        fi
    done
    if [[ -z $initial_pid ]]; then
        log_error 'sing-box did not reach the expected service, loopback listener, or TUN DNS state.'
        return 1
    fi
    if [[ $mode == tun ]]; then
        network_verify_ssh || return 1
        network_verify_default_tun 4 || return 1
        if [[ $ipv6 == yes ]]; then
            network_verify_default_tun 6 || return 1
        fi
        network_verify_tun_dns "$ipv6" || return 1
        log_info 'TUN routes and an uncached DNS lookup passed.'
    fi
    if ! PROXY_PUBLIC_IP=$(network_public_ip proxy 4); then
        log_error 'Independent HTTPS probes did not agree on an IPv4 address through SOCKS5.'
        return 1
    fi
    if [[ $mode == tun ]]; then
        if ! ordinary_ip=$(network_public_ip routed 4) || [[ $ordinary_ip != "$PROXY_PUBLIC_IP" ]]; then
            log_error 'Ordinary IPv4 traffic does not share the verified SOCKS5 egress.'
            return 1
        fi
        if [[ -z $baseline4 || $ordinary_ip == "$baseline4" ]]; then
            log_error 'The TUN IPv4 address cannot be distinguished from the original direct IPv4 address.'
            return 1
        fi
        if [[ $ipv6 == yes ]]; then
            if ! PROXY_PUBLIC_IPV6=$(network_public_ip proxy 6) ||
               ! ordinary_ip=$(network_public_ip routed 6) ||
               [[ $ordinary_ip != "$PROXY_PUBLIC_IPV6" || $ordinary_ip == "$baseline6" ]]; then
                log_error 'Independent HTTPS probes could not verify matching SOCKS5 and TUN IPv6 egress.'
                return 1
            fi
        fi
        network_verify_ssh || return 1
    else
        if ! http_ip=$(network_public_ip http 4) || [[ $http_ip != "$PROXY_PUBLIC_IP" ]]; then
            log_error 'The loopback HTTP proxy did not match the verified SOCKS5 egress.'
            return 1
        fi
        if [[ -n $baseline4 && $baseline4 == "$PROXY_PUBLIC_IP" ]]; then
            log_warn 'Direct and proxy IPv4 egress agree. HTTPS succeeded through both local proxy protocols.'
        fi
    fi
    sleep 2
    if ! pid=$(network_active_service_pid) || [[ $pid != "$initial_pid" ]]; then
        log_error 'The sing-box process stopped or restarted during connectivity tests.'
        return 1
    fi
}

managed_mode() {
    if [[ -f $DROP_IN ]]; then
        local marker
        IFS= read -r marker <"$DROP_IN" || return 1
        case $marker in
            '# singbox-toolbox mode=proxy') printf '%s\n' proxy ;;
            '# singbox-toolbox mode=tun') printf '%s\n' tun ;;
            *) return 1 ;;
        esac
    else
        printf '%s\n' external
    fi
}

service_compatible() {
    local fragment user drop_ins state extra
    fragment=$(systemctl show "$UNIT" --property=FragmentPath --value) || return 1
    user=$(systemctl show "$UNIT" --property=User --value) || return 1
    drop_ins=$(systemctl show "$UNIT" --property=DropInPaths --value) || return 1
    state=$(systemctl show "$UNIT" --property=ActiveState --value) || return 1
    if [[ $fragment != /usr/lib/systemd/system/sing-box.service && $fragment != /lib/systemd/system/sing-box.service ]] ||
        [[ $user != "" && $user != root ]] ||
        [[ -n $drop_ins && $drop_ins != "$DROP_IN" ]] ||
        [[ $state != active && $state != inactive && $state != failed ]]; then
        fail 'This service has an unsupported unit, custom overrides, or a pending state transition.'
        return 1
    fi
    managed_mode >/dev/null || { fail 'The toolbox drop-in name is occupied.'; return 1; }
    if [[ $state == active && ! -f $DROP_IN ]]; then
        # The vendor unit normally loads its entire configuration directory.
        for extra in "$CONFIG_DIR"/*.json; do
            [[ -e $extra && $extra != "$CONFIG_FILE" ]] || continue
            fail 'The active vendor service loads additional JSON files. Keep its configuration under separate management.'
            return 1
        done
        if [[ ! -f $CONFIG_FILE ]] || ! jq -e '
            ([.inbounds[]? | .type] - ["mixed","socks","http"] | length) == 0
            and ([.endpoints[]?,.services[]?] | length) == 0
        ' "$CONFIG_FILE" >/dev/null 2>&1; then
            fail 'The active service has a TUN or another unmanaged network role. Keep it under separate management.'
            return 1
        fi
    fi
}

read_pointer() {
    local name=$1 id
    IFS= read -r id <"$STATE_DIR/$name" || return 1
    [[ $id =~ ^txn\.[A-Za-z0-9]{12}$ && -d $STATE_DIR/transactions/$id ]] || return 1
    printf '%s\n' "$STATE_DIR/transactions/$id"
}

stop_timer() {
    systemctl disable --now "$ROLLBACK_TIMER" >/dev/null 2>&1 ||
        log_warn 'The rollback timer may still be listed. It has no work without a pending transaction.'
}

arm_timer() {
    local deadline=$1 calendar source
    calendar=$(date -u -d "@$deadline" '+%Y-%m-%d %H:%M:%S UTC') || return 1
    source=$(realpath -- "${BASH_SOURCE[0]}") || return 1
    if [[ ! $source -ef $STATE_DIR/runner ]]; then
        atomic_copy "$source" "$STATE_DIR/runner" 0700 || return 1
    fi
    cat >"$SCRATCH/rollback.service" <<EOF || return 1
[Unit]
Description=Restore the sing-box toolbox transaction
StartLimitIntervalSec=0

[Service]
Type=oneshot
ExecStart=/bin/bash $STATE_DIR/runner _rollback
Restart=on-failure
RestartSec=10s
TimeoutStartSec=150s
EOF
    cat >"$SCRATCH/rollback.timer" <<EOF || return 1
[Unit]
Description=Deadline for restoring the sing-box toolbox transaction

[Timer]
OnCalendar=$calendar
AccuracySec=1s
Persistent=true
Unit=$ROLLBACK_SERVICE

[Install]
WantedBy=timers.target
EOF
    atomic_copy "$SCRATCH/rollback.service" "$UNIT_DIR/$ROLLBACK_SERVICE" 0644 || return 1
    atomic_copy "$SCRATCH/rollback.timer" "$UNIT_DIR/$ROLLBACK_TIMER" 0644 || return 1
    systemctl daemon-reload &&
        systemctl enable "$ROLLBACK_TIMER" >/dev/null &&
        systemctl restart "$ROLLBACK_TIMER" &&
        systemctl is-enabled --quiet "$ROLLBACK_TIMER" &&
        systemctl is-active --quiet "$ROLLBACK_TIMER"
}

boot_id() {
    cat /proc/sys/kernel/random/boot_id
}

snapshot_current() {
    local snapshot=$1 mode
    mode=$(managed_mode) || return 1
    atomic_text "$snapshot/mode" "$mode" || return 1
    if [[ -f $CONFIG_FILE ]]; then
        atomic_copy "$CONFIG_FILE" "$snapshot/config.json" || return 1
        stat -c '%u %g %a' -- "$CONFIG_FILE" >"$snapshot/config.stat" || return 1
    fi
    if [[ -f $DROP_IN ]]; then
        atomic_copy "$DROP_IN" "$snapshot/drop-in.conf" || return 1
    fi
    if [[ -f $STATE_DIR/active-profile.json ]]; then
        atomic_copy "$STATE_DIR/active-profile.json" "$snapshot/profile.json" || return 1
    fi
    if [[ -f $STATE_DIR/active-ipv6 ]]; then
        atomic_copy "$STATE_DIR/active-ipv6" "$snapshot/ipv6" || return 1
    fi
    if [[ -e $TUN_PERMIT ]]; then
        boot_id >"$snapshot/permit.boot" || return 1
    fi
    if systemctl is-active --quiet "$UNIT"; then
        atomic_text "$snapshot/active" yes || return 1
    else
        atomic_text "$snapshot/active" no || return 1
    fi
    if [[ -f $STATE_DIR/previous ]]; then
        atomic_copy "$STATE_DIR/previous" "$snapshot/previous" || return 1
    fi
}

begin_transaction() {
    local now deadline
    reject_pending || return 1
    safe_config_paths || return 1
    now=$(date +%s) || return 1
    deadline=$((now + ROLLBACK_SECONDS))
    TXN=$(mktemp -d "$STATE_DIR/transactions/txn.XXXXXXXXXXXX") || return 1
    snapshot_current "$TXN" || return 1
    atomic_text "$TXN/deadline" "$deadline" || return 1
    if ! arm_timer "$deadline"; then
        stop_timer
        fail 'The persistent systemd rollback could not be armed. No configuration was applied.'
        return 1
    fi
    if ! sync -f "$UNIT_DIR" || ! atomic_text "$STATE_DIR/pending" "${TXN##*/}" || ! sync -f "$STATE_DIR"; then
        fail 'The transaction could not be saved durably.'
        return 1
    fi
    log_info 'Rollback armed for five minutes.'
}

restore_optional() {
    local source=$1 destination=$2 mode=${3:-0600}
    if [[ -f $source ]]; then
        atomic_copy "$source" "$destination" "$mode"
    else
        rm -f -- "$destination"
    fi
}

restore_config() {
    local snapshot=$1 uid gid mode stage
    if [[ ! -f $snapshot/config.json ]]; then
        rm -f -- "$CONFIG_FILE"
        return
    fi
    read -r uid gid mode <"$snapshot/config.stat" || return 1
    [[ $uid =~ ^[0-9]+$ && $gid =~ ^[0-9]+$ && $mode =~ ^[0-7]{3,4}$ ]] || return 1
    install -d -- "$CONFIG_DIR" || return 1
    stage=$(mktemp "$CONFIG_DIR/.sbtoolbox.XXXXXXXX") || return 1
    if ! install -o "$uid" -g "$gid" -m "$mode" -- "$snapshot/config.json" "$stage" ||
        ! mv -Tf -- "$stage" "$CONFIG_FILE"; then
        rm -f -- "$stage"
        return 1
    fi
}

stop_service() {
    timeout 55s systemctl stop "$UNIT" >/dev/null 2>&1 || return 1
    local state
    state=$(systemctl show "$UNIT" --property=ActiveState --value) || return 1
    [[ $state == inactive || $state == failed ]]
}

start_service() {
    timeout 55s systemctl start "$UNIT" >/dev/null 2>&1 ||
        { fail 'The service could not be started. Use the logs menu for a redacted event summary.'; return 1; }
}

restore_snapshot() {
    local snapshot=$1 cleanup=${2:-yes} current_boot
    safe_config_paths || return 1
    stop_service || { fail 'Could not stop sing-box to restore the snapshot.'; return 1; }
    if [[ $cleanup == yes && -e $snapshot/owns-tun ]]; then
        network_cleanup_tun || return 1
    fi
    restore_config "$snapshot" || return 1
    if [[ -f $snapshot/drop-in.conf ]]; then
        install -d -- "${DROP_IN%/*}" || return 1
    fi
    restore_optional "$snapshot/drop-in.conf" "$DROP_IN" 0644 || return 1
    restore_optional "$snapshot/profile.json" "$STATE_DIR/active-profile.json" || return 1
    restore_optional "$snapshot/ipv6" "$STATE_DIR/active-ipv6" || return 1
    rm -f -- "$TUN_PERMIT" || return 1
    current_boot=$(boot_id) || return 1
    if [[ -f $snapshot/permit.boot && $(<"$snapshot/permit.boot") == "$current_boot" ]]; then
        atomic_text "$TUN_PERMIT" "$current_boot" || return 1
    fi
    systemctl daemon-reload || return 1
    if [[ $(<"$snapshot/active") == yes ]]; then
        if [[ $(<"$snapshot/mode") == tun && ! -e $TUN_PERMIT ]]; then
            log_warn 'The earlier TUN configuration was restored. Its service requires a fresh activation after reboot.'
            return 0
        fi
        start_service && systemctl is-active --quiet "$UNIT" || return 1
    fi
}

rollback_pending() {
    local snapshot
    if [[ ! -e $STATE_DIR/pending ]]; then
        log_info 'There is no pending transaction.'
        return 0
    fi
    snapshot=$(read_pointer pending) || { fail 'The pending backup pointer is invalid. Use the recovery procedure.'; return 1; }
    if [[ -e $snapshot/touched ]]; then
        log_warn 'Restoring the pre-activation configuration and service state.'
        if ! restore_snapshot "$snapshot"; then
            fail 'Rollback is incomplete. The pending snapshot was retained for another attempt.'
            return 1
        fi
    fi
    restore_optional "$snapshot/previous" "$STATE_DIR/previous" || return 1
    sync -f "$CONFIG_DIR" 2>/dev/null || { [[ ! -e $CONFIG_DIR ]] || return 1; }
    sync -f "$UNIT_DIR" || return 1
    sync -f "$STATE_DIR" || return 1
    rm -f -- "$STATE_DIR/pending" || return 1
    sync -f "$STATE_DIR" || return 1
    stop_timer
    TXN=
    log_info 'Rollback completed.'
}

commit_transaction() {
    local snapshot=$1
    sync -f "$CONFIG_DIR" && sync -f "$UNIT_DIR" && sync -f "$STATE_DIR" || return 1
    atomic_text "$STATE_DIR/previous" "${snapshot##*/}" && sync -f "$STATE_DIR" || return 1
    rm -f -- "$STATE_DIR/pending" || return 1
    # Unlink is the commit point. Preserve success if flushing the unlink fails,
    # so the operator knows it may still be recovered after an abrupt reboot.
    if ! sync -f "$STATE_DIR"; then
        log_warn 'The commit could not be flushed to disk. An abrupt reboot may still restore the snapshot.'
    fi
    stop_timer
    TXN=
}

check_config() {
    local candidate=$1
    if ! jq -e -s 'length == 1 and (.[0] | type == "object")' "$candidate" >/dev/null 2>&1; then
        fail 'The configuration is not one valid JSON object.'
        return 1
    fi
    if ! timeout 15s "$BIN" check -D "$SCRATCH" -c "$candidate" >/dev/null 2>&1; then
        fail 'sing-box check rejected the configuration. Review the imported profile for version and transport compatibility.'
        return 1
    fi
}

apply_config() {
    local mode=$1 ipv6=$2 profile=$3 candidate=$4 service_file="$SCRATCH/sing-box.conf"
    {
        printf '# singbox-toolbox mode=%s\n[Service]\n' "$mode"
        printf 'ExecStart=\nExecStart=%s -D /var/lib/sing-box -c %s run\n' "$BIN" "$CONFIG_FILE"
        printf 'TimeoutStopSec=25s\n'
        if [[ $mode == tun ]]; then
            printf 'ExecCondition=/usr/bin/test -f %s\n' "$TUN_PERMIT"
        fi
    } >"$service_file" || return 1
    if [[ ! -d $CONFIG_DIR ]]; then
        install -d -m 0755 -- "$CONFIG_DIR" || return 1
    fi
    if [[ ! -d ${DROP_IN%/*} ]]; then
        install -d -m 0755 -- "${DROP_IN%/*}" || return 1
    fi
    atomic_text "$TXN/touched" yes || return 1
    sync -f "$STATE_DIR" || return 1
    stop_service || return 1
    atomic_copy "$candidate" "$CONFIG_FILE" || return 1
    atomic_copy "$service_file" "$DROP_IN" 0644 || return 1
    atomic_copy "$profile" "$STATE_DIR/active-profile.json" || return 1
    atomic_text "$STATE_DIR/active-ipv6" "$ipv6" || return 1
    if [[ $mode == tun ]]; then
        atomic_text "$TXN/owns-tun" yes || return 1
        sync -f "$STATE_DIR" || return 1
        atomic_text "$TUN_PERMIT" "$(boot_id)" || return 1
    else
        rm -f -- "$TUN_PERMIT" || return 1
    fi
    systemctl daemon-reload && start_service
}

managed_network_inputs() {
    local profile=$1 host
    local endpoint_file="$SCRATCH/endpoints" pins="$SCRATCH/pins.json"
    : >"$endpoint_file" || return 1
    printf '{}\n' >"$pins" || return 1
    profile_endpoints "$profile" >"$SCRATCH/hosts" || return 1
    while IFS= read -r host; do
        if ! network_resolve_endpoint "$host" >"$SCRATCH/addresses" || [[ ! -s $SCRATCH/addresses ]]; then
            fail 'Could not resolve a configured upstream endpoint before enabling TUN.'
            return 1
        fi
        cat "$SCRATCH/addresses" >>"$endpoint_file" || return 1
        jq -e --arg host "$host" --rawfile ips "$SCRATCH/addresses" \
            '.[$host] = ($ips | split("\n") | map(select(length > 0)))' "$pins" \
            >"$SCRATCH/pins-next.json" || return 1
        mv -Tf -- "$SCRATCH/pins-next.json" "$pins" || return 1
    done <"$SCRATCH/hosts"
    [[ -s $endpoint_file ]] || return 1
    sort -u -o "$endpoint_file" "$endpoint_file" || return 1
    jq -Rn --arg ssh "$SSH_CLIENT_CIDR" '[inputs | . + (if contains(":") then "/128" else "/32" end)] + [$ssh] | unique' \
        <"$endpoint_file" >"$SCRATCH/excludes.json" || return 1
    network_capture_endpoint_routes "$endpoint_file" "$SCRATCH/endpoint-routes" || return 1
}

deadline_open() {
    local snapshot=$1 now deadline
    IFS= read -r deadline <"$snapshot/deadline" || return 1
    [[ $deadline =~ ^[1-9][0-9]{8,}$ ]] || return 1
    now=$(date +%s) || return 1
    if ((now >= deadline)); then
        fail 'The rollback deadline has passed.'
        return 1
    fi
}

ensure_watchdog() {
    if ! deadline_open "$1" || ! systemctl is-active --quiet "$ROLLBACK_TIMER"; then
        fail 'The rollback watchdog is no longer active.'
        return 1
    fi
}

quiesce_managed_tun() {
    atomic_text "$TXN/touched" yes && atomic_text "$TXN/owns-tun" yes && sync -f "$STATE_DIR" || return 1
    stop_service && network_cleanup_tun && rm -f -- "$TUN_PERMIT"
}

stage_activation() {
    local mode=$1 ipv6=$2 profile=$3 direct4='' direct6=''
    local candidate="$SCRATCH/config.json"
    network_preflight "$mode" "$ipv6" || return 1
    log_info 'Checking direct public IPv4 egress.'
    if ! direct4=$(network_public_ip direct 4); then
        if [[ $mode == tun ]]; then
            fail 'Independent sources could not verify the original IPv4 address. TUN activation aborted.'
            return 1
        fi
        log_warn 'The direct public IPv4 address could not be verified.'
    fi
    if [[ $mode == tun ]]; then
        if [[ $ipv6 == yes ]]; then
            direct6=$(network_public_ip direct 6) || direct6=
        fi
        managed_network_inputs "$profile" || return 1
    fi
    generate_config "$profile" "$mode" "$ipv6" "$SCRATCH/excludes.json" "$candidate" "$SCRATCH/pins.json" || return 1
    check_config "$candidate" || return 1
    if [[ -z $TXN ]]; then
        begin_transaction || return 1
    fi
    ensure_watchdog "$TXN" || return 1
    if [[ $mode == tun ]]; then
        atomic_text "$TXN/ssh-session" "$SSH_SESSION" &&
            atomic_text "$TXN/ssh-route" "$SSH_BASELINE" &&
            atomic_text "$TXN/direct4" "$direct4" &&
            atomic_text "$TXN/direct6" "$direct6" &&
            atomic_text "$TXN/new-ipv6" "$ipv6" &&
            atomic_copy "$SCRATCH/endpoint-routes" "$TXN/endpoint-routes" || return 1
    fi
    log_info 'Starting sing-box and checking live connectivity.'
    apply_config "$mode" "$ipv6" "$profile" "$candidate" || return 1
    if [[ $mode == tun ]]; then
        network_verify_endpoint_routes "$TXN/endpoint-routes" || return 1
    fi
    network_health "$mode" "$direct4" "$ipv6" "$direct6" || return 1
    ensure_watchdog "$TXN" || return 1
    if [[ $mode == tun ]]; then
        network_verify_endpoint_routes "$TXN/endpoint-routes" || return 1
        if ! network_ssh_peer_ports "$SSH_SESSION" >"$TXN/ssh-peer-ports"; then
            fail 'Could not record existing SSH connections before confirmation.'
            return 1
        fi
        atomic_text "$TXN/ready" yes && sync -f "$STATE_DIR" || return 1
        report_connection "$direct4"
        log_warn 'TUN passed health checks. Rollback is still armed.'
        printf '%s\n' 'Keep this SSH shell open. Open a new SSH connection from the same client with ControlMaster disabled.' \
            "In that second shell run: sudo --preserve-env=SSH_CONNECTION $STATE_DIR/runner confirm" \
            "Rollback deadline: $(date -u -d "@$(<"$TXN/deadline")" '+%Y-%m-%d %H:%M:%S UTC')"
        TXN=
    else
        commit_transaction "$TXN" || return 1
        log_info 'The loopback SOCKS5 and HTTP proxy is working at 127.0.0.1:1080.'
        report_connection "$direct4"
        management_commands
    fi
}

activate_profile() {
    local mode=$1 ipv6=$2 profile=${3:-$STATE_DIR/profile.json} current
    reject_pending || return 1
    require_network_tools && require_box && safe_config_paths && service_compatible || return 1
    [[ -f $profile ]] || { fail 'Import a VLESS link or JSON client profile first.'; return 1; }
    current=$(managed_mode) || return 1
    TXN=
    if [[ $current == tun && -e $TUN_PERMIT ]]; then
        # Refuse an invalid caller before touching a working tunnel.
        if [[ $mode == tun ]]; then
            local tuple
            if ! tuple=$(network_ssh_tuple "${SSH_CONNECTION:-}") || ! network_ssh_established "$tuple"; then
                fail 'Use a live SSH connection and preserve SSH_CONNECTION with sudo.'
                return 1
            fi
        fi
        if ! begin_transaction || ! quiesce_managed_tun; then
            fail_activation
            return 1
        fi
    fi
    if ! stage_activation "$mode" "$ipv6" "$profile"; then
        fail_activation
        return 1
    fi
}

fail_activation() {
    log_error 'Activation did not pass all checks.'
    if [[ -e $STATE_DIR/pending ]]; then
        rollback_pending || log_error 'The watchdog remains responsible for retrying recovery.'
    fi
}

confirm_tun() {
    local snapshot ipv6 direct4 direct6
    require_network_tools || return 1
    [[ -e $STATE_DIR/pending ]] || { fail 'There is no pending TUN activation to confirm.'; return 1; }
    snapshot=$(read_pointer pending) || return 1
    [[ -f $snapshot/ready && $(managed_mode) == tun ]] ||
        { fail 'Activation did not reach the confirmation stage. Run rollback or let the timer recover it.'; return 1; }
    SSH_SESSION=$(<"$snapshot/ssh-session")
    SSH_BASELINE=$(<"$snapshot/ssh-route")
    network_confirm_ssh "$SSH_SESSION" "$snapshot/ssh-peer-ports" || return 1
    ipv6=$(<"$snapshot/new-ipv6")
    direct4=$(<"$snapshot/direct4")
    direct6=$(<"$snapshot/direct6")
    if ! ensure_watchdog "$snapshot" ||
        ! network_verify_endpoint_routes "$snapshot/endpoint-routes" ||
        ! network_health tun "$direct4" "$ipv6" "$direct6" ||
        ! network_confirm_ssh "$SSH_SESSION" "$snapshot/ssh-peer-ports" ||
        ! network_verify_endpoint_routes "$snapshot/endpoint-routes" ||
        ! ensure_watchdog "$snapshot" ||
        ! commit_transaction "$snapshot"; then
        fail_activation
        return 1
    fi
    log_info 'TUN is working and the second SSH connection was verified. Rollback cancelled.'
    report_connection "$direct4"
    management_commands
}

report_connection() {
    if [[ -n ${1:-} ]]; then
        printf 'Direct IPv4: %s\n' "$1"
    fi
    printf 'Proxy egress IPv4: %s\n' "$PROXY_PUBLIC_IP"
    if [[ -n $PROXY_PUBLIC_IPV6 ]]; then
        printf 'Proxy egress IPv6: %s\n' "$PROXY_PUBLIC_IPV6"
    fi
}

management_commands() {
    printf '%s\n' "Service state: sudo $STATE_DIR/runner status" \
        "Managed restart: sudo --preserve-env=SSH_CONNECTION $STATE_DIR/runner restart" \
        "Managed stop: sudo $STATE_DIR/runner stop"
}

test_connection() {
    local direct=
    require_network_tools || return 1
    if [[ $(managed_mode) != tun ]]; then
        direct=$(network_public_ip direct 4) || direct=
        network_health proxy "$direct" || return 1
    else
        PROXY_PUBLIC_IP=$(network_public_ip proxy 4) ||
            { fail 'The running SOCKS5 proxy did not pass the public-IP probes.'; return 1; }
        PROXY_PUBLIC_IPV6=
    fi
    report_connection "$direct"
}

show_public_ip() {
    local observed
    require_commands curl python3 || return 1
    observed=$(network_public_ip routed 4) ||
        { fail 'Public IPv4 could not be verified by multiple services.'; return 1; }
    printf 'Current server egress IPv4: %s\n' "$observed"
}

status_box() {
    local mode version
    if locate_box && version=$(show_version); then
        printf 'sing-box version: %s\n' "$version"
    fi
    mode=$(managed_mode) || mode=unknown
    printf 'Configuration mode: %s\n' "$mode"
    if [[ -e $STATE_DIR/pending ]]; then
        printf '%s\n' 'A rollback is pending.'
        systemctl list-timers --all --no-pager "$ROLLBACK_TIMER" || return 1
    fi
    systemctl show "$UNIT" -p LoadState -p ActiveState -p SubState -p Result -p MainPID -p UnitFileState
}

logs_box() {
    require_commands journalctl jq || return 1
    printf '%s\n' 'Recent systemd events (message contents withheld to protect credentials).'
    # Only fixed state labels are emitted, even for an older external config.
    journalctl --no-pager -u "$UNIT" -n 100 -o json _PID=1 2>/dev/null |
        jq -r '
          select(.__REALTIME_TIMESTAMP? | type == "string") |
          ((.MESSAGE // "") | tostring | ascii_downcase) as $m |
          (if ($m | test("fail|error|timed out")) then "failure"
            elif ($m | test("restart")) then "restart scheduled"
            elif ($m | test("^started")) then "started"
            elif ($m | test("^starting")) then "starting"
            elif ($m | test("^stopped|deactivated")) then "stopped"
            elif ($m | test("^stopping")) then "stopping"
            else "state change" end) as $event |
          ((.__REALTIME_TIMESTAMP | tonumber) / 1000000 | floor | todateiso8601) + " " + $event
        '
}

restart_box() {
    local mode ipv6=no
    reject_pending && safe_config_paths || return 1
    mode=$(managed_mode) || return 1
    if [[ $mode == external ]]; then
        fail 'Use the original service configuration management or activate a toolbox profile first.'
        return 1
    fi
    if [[ -f $STATE_DIR/active-ipv6 ]]; then
        ipv6=$(<"$STATE_DIR/active-ipv6")
    fi
    activate_profile "$mode" "$ipv6" "$STATE_DIR/active-profile.json"
}

stop_box() {
    local mode
    reject_pending && safe_config_paths || return 1
    mode=$(managed_mode) || return 1
    if [[ $mode == tun && -e $TUN_PERMIT ]]; then
        require_commands jq ip || return 1
    fi
    stop_service || { fail 'sing-box did not stop cleanly.'; return 1; }
    if [[ $mode == tun && -e $TUN_PERMIT ]]; then
        network_cleanup_tun && rm -f -- "$TUN_PERMIT" || return 1
    fi
    log_info 'sing-box is stopped.'
}

restore_previous() {
    local snapshot previous_mode current_mode ipv6=no direct='' after=''
    reject_pending && require_network_tools && require_box && safe_config_paths && service_compatible || return 1
    [[ -e $STATE_DIR/previous ]] || { fail 'No previous configuration is available.'; return 1; }
    snapshot=$(read_pointer previous) || return 1
    previous_mode=$(<"$snapshot/mode")
    current_mode=$(managed_mode) || return 1
    if [[ $previous_mode != external && $(<"$snapshot/active") == yes ]]; then
        [[ ! -f $snapshot/ipv6 ]] || ipv6=$(<"$snapshot/ipv6")
        activate_profile "$previous_mode" "$ipv6" "$snapshot/profile.json"
        return
    fi
    if [[ -f $snapshot/config.json ]]; then
        check_config "$snapshot/config.json" || return 1
    fi
    TXN=
    if ! begin_transaction ||
        { [[ $current_mode == tun && -e $TUN_PERMIT ]] && ! quiesce_managed_tun; } ||
        ! direct=$(network_public_ip direct 4) ||
        ! atomic_text "$TXN/touched" yes ||
        ! sync -f "$STATE_DIR" ||
        ! restore_snapshot "$snapshot" no ||
        ! after=$(network_public_ip direct 4) || [[ $direct != "$after" ]] ||
        ! ensure_watchdog "$TXN" || ! commit_transaction "$TXN"; then
        fail_activation
        return 1
    fi
    log_info 'Previous configuration and service activity restored. Direct IPv4 was verified.'
}

uninstall_box() {
    local snapshot
    reject_pending && safe_config_paths || return 1
    require_commands dpkg dpkg-query || return 1
    if ! dpkg-query -W -f='${db:Status-Status}\n' sing-box 2>/dev/null | grep -qx installed; then
        fail 'No Debian sing-box package is installed. Use its original installer for a manually installed copy.'
        return 1
    fi
    snapshot=$(mktemp -d "$STATE_DIR/pre-uninstall.XXXXXXXX") || return 1
    snapshot_current "$snapshot" && sync -f "$STATE_DIR" || return 1
    stop_box || return 1
    DEBIAN_FRONTEND=noninteractive dpkg -r sing-box ||
        { fail 'Package removal failed. Your configuration snapshot was retained.'; return 1; }
    rm -f -- "$DROP_IN" || return 1
    systemctl daemon-reload || return 1
    log_info "Package removed. Configuration and protected backups remain in $CONFIG_DIR and $STATE_DIR."
}

usage() {
    cat <<'EOF'
Usage: sudo bash singbox-toolbox.sh [COMMAND]

  install                  Install sing-box and missing runtime dependencies
  import-vless FILE|-      Stage a VLESS link from a private file or stdin
  import-json FILE|-       Stage a JSON client profile
  import-json --url-stdin  Read an HTTPS configuration URL from stdin
  enable-proxy             Start SOCKS5 and HTTP on 127.0.0.1:1080
  enable-tun [--ipv6]      Enable TUN with automatic rollback pending confirmation
  confirm                  Confirm a pending TUN activation from a second SSH connection
  test                     Test loopback SOCKS5 connectivity
  ip                       Report the server's current public IPv4
  status | logs            Show service state or redacted systemd events
  restart | stop           Manage the service
  restore | rollback       Restore the previous config or undo a pending activation
  uninstall --yes          Remove the Debian package and retain config and backups
  help                     Show this help

Run without a command for the keyboard-driven terminal interface.
Use menu --plain for a numbered menu. Use sudo
--preserve-env=SSH_CONNECTION for enable-tun, confirm, and TUN restart/restore.
EOF
}

run_action() {
    local action=$1 result=0 wait_seconds=0
    shift
    if [[ $action == _rollback ]]; then
        wait_seconds=20
    fi
    open_lock "$wait_seconds" || return 1
    if [[ $action != rollback && $action != _rollback ]] && ! scratch_open; then
        close_lock
        return 1
    fi
    case $action in
        install) install_box || result=$? ;;
        import-vless) import_profile vless "$1" || result=$? ;;
        import-json) import_profile json "$1" || result=$? ;;
        enable-proxy) activate_profile proxy no || result=$? ;;
        enable-tun)
            if [[ ${1:-} == --ipv6 ]]; then
                activate_profile tun yes || result=$?
            else
                activate_profile tun no || result=$?
            fi ;;
        confirm) confirm_tun || result=$? ;;
        test) test_connection || result=$? ;;
        ip) show_public_ip || result=$? ;;
        status) status_box || result=$? ;;
        logs) logs_box || result=$? ;;
        restart) restart_box || result=$? ;;
        stop) stop_box || result=$? ;;
        restore) restore_previous || result=$? ;;
        rollback|_rollback) rollback_pending || result=$? ;;
        uninstall) uninstall_box || result=$? ;;
    esac
    scratch_close
    close_lock
    return "$result"
}

TUI_ACTIVE=no
TUI_RESIZED=no
TUI_CHOICE=0
TUI_STATE=
TUI_MODE=
TUI_PROFILE=
TUI_PENDING=no
TUI_DEADLINE=
TUI_WIDTH=76
TUI_HEIGHT=24
TUI_ACCENT=
TUI_MUTED=
TUI_FOCUS=$'\033[7m'
TUI_OUTPUT=
TUI_PROGRESS_PID=

tui_cleanup() {
    tui_stop_progress
    tui_remove_output
    if [[ $TUI_ACTIVE == yes ]]; then
        TUI_ACTIVE=no
        printf '\033[0m\033[?25h\033[?1049l' || true
    fi
}

tui_open() {
    if [[ $TUI_ACTIVE != yes ]]; then
        TUI_ACTIVE=yes
        printf '\033[?1049h'
    fi
    printf '\033[?25l'
}

tui_measure() {
    local dimensions rows cols
    dimensions=$(stty size 2>/dev/null) || dimensions=
    IFS=' ' read -r rows cols <<<"$dimensions"
    [[ $rows =~ ^[1-9][0-9]{0,3}$ ]] || rows=24
    [[ $cols =~ ^[1-9][0-9]{0,3}$ ]] || cols=80
    TUI_HEIGHT=$rows
    TUI_WIDTH=$((cols > 4 ? cols - 4 : 1))
    if ((TUI_WIDTH > 88)); then
        TUI_WIDTH=88
    fi
}

tui_line() {
    local row=$1 content=$2 style=${3:-}
    printf '\033[%d;1H\033[2K  %s%-*.*s\033[0m' \
        "$row" "$style" "$TUI_WIDTH" "$TUI_WIDTH" "$content"
}

tui_refresh() {
    local service_state='' snapshot
    TUI_STATE='Not installed'
    if type -P sing-box >/dev/null; then
        service_state=$(timeout 2s systemctl show "$UNIT" --property=ActiveState --value 2>/dev/null) || service_state=
        case $service_state in
            active) TUI_STATE=Running ;;
            inactive) TUI_STATE=Stopped ;;
            failed) TUI_STATE=Failed ;;
            activating|deactivating|reloading) TUI_STATE='Changing state' ;;
            *) TUI_STATE=Unknown ;;
        esac
    fi
    TUI_MODE=$(managed_mode 2>/dev/null) || TUI_MODE=unknown
    case $TUI_MODE in
        proxy) TUI_MODE=Proxy ;;
        tun) TUI_MODE=TUN ;;
        external) TUI_MODE='Unmanaged' ;;
        *) TUI_MODE='Unknown' ;;
    esac
    TUI_PROFILE=None
    if [[ -s $STATE_DIR/profile.json ]]; then
        TUI_PROFILE=Staged
    fi
    TUI_PENDING=no
    TUI_DEADLINE=
    if [[ -e $STATE_DIR/pending ]]; then
        TUI_PENDING=yes
        if snapshot=$(read_pointer pending 2>/dev/null) && [[ -r $snapshot/deadline ]]; then
            IFS= read -r TUI_DEADLINE <"$snapshot/deadline" || TUI_DEADLINE=
        fi
    fi
}

tui_status_line() {
    local remaining now
    if [[ $TUI_PENDING != yes ]]; then
        printf 'Profile  %s' "$TUI_PROFILE"
        return
    fi
    if [[ $TUI_DEADLINE =~ ^[1-9][0-9]{8,9}$ ]]; then
        printf -v now '%(%s)T' -1
        remaining=$((TUI_DEADLINE - now))
        if ((remaining > 0)); then
            printf 'Rollback in %02d:%02d  |  Confirm from a fresh SSH session' "$((remaining / 60))" "$((remaining % 60))"
            return
        fi
    fi
    printf '%s' 'Rollback pending  |  Check service status'
}

tui_render() {
    local title=$1 focus=$2 subtitle=$3
    local -n render_labels=$4 render_details=$5
    local count=${#render_labels[@]} first visible index row footer rule prefix
    tui_measure
    printf '\033[H\033[J'
    tui_line 1 'UBUNTU VLESS' "$TUI_ACCENT"
    if ((TUI_HEIGHT < 10)); then
        if ((TUI_HEIGHT >= 2)); then
            tui_line 2 "> ${render_labels[focus]}" "$TUI_FOCUS"
        fi
        if ((TUI_HEIGHT >= 3)); then
            tui_line 3 'Up/Down  Enter  Esc' "$TUI_MUTED"
        fi
        return
    fi
    if [[ -n $subtitle ]]; then
        tui_line 2 "$subtitle" "$TUI_MUTED"
    else
        tui_line 2 "Service  $TUI_STATE  |  Route  $TUI_MODE"
    fi
    if [[ -z $subtitle || $TUI_PENDING == yes ]]; then
        tui_line 3 "$(tui_status_line)" "$TUI_ACCENT"
    fi
    printf -v rule '%*s' "$TUI_WIDTH" ''
    tui_line 4 "${rule// /-}" "$TUI_MUTED"
    visible=$((TUI_HEIGHT - 8))
    first=$((focus / visible * visible))
    tui_line 5 "$title" "$TUI_ACCENT"
    for ((index = first; index < first + visible && index < count; index++)); do
        row=$((6 + index - first))
        if ((index == focus)); then
            prefix=' > '
            tui_line "$row" "$prefix${render_labels[index]}" "$TUI_FOCUS"
        else
            tui_line "$row" "   ${render_labels[index]}"
        fi
    done
    tui_line "$((TUI_HEIGHT - 2))" "${render_details[focus]}" "$TUI_MUTED"
    if ((TUI_WIDTH >= 55)); then
        footer='Up/Down Move   Enter Select   R Refresh   Esc Back'
        if ((count > visible)); then
            footer+="   $((focus + 1))/$count"
        fi
    else
        footer='Up/Down  Enter  Esc'
    fi
    tui_line "$((TUI_HEIGHT - 1))" "$footer" "$TUI_MUTED"
}

tui_key() {
    local input='' escaped='' ending='' result=0
    IFS= read -rsn1 -t 1 input || result=$?
    if ((result > 128)); then
        TUI_KEY=idle
        return
    elif ((result != 0)); then
        TUI_KEY=eof
        return
    fi
    case $input in
        '')
            TUI_KEY=enter ;;
        k|K)
            TUI_KEY=up ;;
        j|J|$'\t')
            TUI_KEY=down ;;
        q|Q)
            TUI_KEY=back ;;
        r|R)
            TUI_KEY=refresh ;;
        $'\033')
            if ! IFS= read -rsn1 -t .18 escaped; then
                TUI_KEY=back
                return
            fi
            TUI_KEY=ignore
            if [[ $escaped == '[' || $escaped == O ]] && IFS= read -rsn1 -t .18 ending; then
                case $ending in
                    A) TUI_KEY=up ;;
                    B) TUI_KEY=down ;;
                    H) TUI_KEY=first ;;
                    F) TUI_KEY=last ;;
                    5|6)
                        if IFS= read -rsn1 -t .18 escaped && [[ $escaped == '~' ]]; then
                            if [[ $ending == 5 ]]; then TUI_KEY=page-up; else TUI_KEY=page-down; fi
                        fi ;;
                esac
            fi ;;
        *)
            TUI_KEY=ignore ;;
    esac
}

tui_select() {
    local title=$1 subtitle=$2 list_name=$3 details_name=$4 focus=${5:-0} dirty=yes
    local -n choices=$list_name
    local count=${#choices[@]}
    tui_open
    while true; do
        if [[ $dirty == yes || $TUI_RESIZED == yes ]]; then
            TUI_RESIZED=no
            tui_render "$title" "$focus" "$subtitle" "$list_name" "$details_name"
        fi
        dirty=yes
        tui_key
        case $TUI_KEY in
            up) focus=$(((focus + count - 1) % count)) ;;
            down) focus=$(((focus + 1) % count)) ;;
            first) focus=0 ;;
            last) focus=$((count - 1)) ;;
            enter) TUI_CHOICE=$focus; return 0 ;;
            back|eof) return 1 ;;
            refresh) tui_refresh ;;
            idle)
                if [[ $TUI_PENDING == yes && ! -e $STATE_DIR/pending ]] ||
                   [[ $TUI_PENDING == no && -e $STATE_DIR/pending ]]; then
                    tui_refresh
                elif [[ $TUI_PENDING == no ]]; then
                    dirty=no
                fi ;;
            *) dirty=no ;;
        esac
    done
}

tui_prompt() {
    local title=$1 instructions=$2
    printf '\033[H\033[J\033[?25h'
    tui_measure
    tui_line 1 'UBUNTU VLESS' "$TUI_ACCENT"
    tui_line 3 "$title" "$TUI_ACCENT"
    tui_line 4 "$instructions"
    printf '\033[6;1H  '
}

tui_stop_progress() {
    if [[ -n $TUI_PROGRESS_PID ]]; then
        kill "$TUI_PROGRESS_PID" 2>/dev/null || true
        wait "$TUI_PROGRESS_PID" 2>/dev/null || true
        TUI_PROGRESS_PID=
    fi
}

tui_remove_output() {
    if [[ -n $TUI_OUTPUT ]]; then
        rm -f -- "$TUI_OUTPUT"
        TUI_OUTPUT=
    fi
}

tui_render_output() {
    local title=$1 status=$2 top=$3 first=5 last index count style
    local -a lines
    tui_measure
    # Command output is data. Strip terminal controls before displaying it.
    mapfile -t lines < <(
        LC_ALL=C sed -E $'s/\033\\[[0-?]*[ -/]*[@-~]//g' "$TUI_OUTPUT" |
            LC_ALL=C tr -cd '\11\12\40-\176' |
            expand -t 4 | fold -sw "$TUI_WIDTH"
    )
    if ((${#lines[@]} == 0)); then
        if [[ $status == running ]]; then
            lines=('Waiting for output...')
        else
            lines=('No output.')
        fi
    fi

    printf '\033[H\033[J'
    style=$TUI_ACCENT
    case $status in
        running) status='Running...' ;;
        success) status='Completed' ;;
        *) status="Failed (exit $status)"; style=$CLR_RED ;;
    esac
    if ((TUI_HEIGHT >= 8)); then
        tui_line 1 'UBUNTU VLESS' "$TUI_ACCENT"
        tui_line 2 "$title"
        tui_line 3 "$status" "$style"
    else
        first=2
        tui_line 1 "$title  |  $status" "$style"
    fi

    TUI_OUTPUT_ROWS=$((TUI_HEIGHT > first ? TUI_HEIGHT - first : 0))
    count=${#lines[@]}
    TUI_OUTPUT_LIMIT=$((count > TUI_OUTPUT_ROWS ? count - TUI_OUTPUT_ROWS : 0))
    if ((top < 0 || top > TUI_OUTPUT_LIMIT)); then
        top=$TUI_OUTPUT_LIMIT
    fi
    TUI_OUTPUT_TOP=$top
    last=$((top + TUI_OUTPUT_ROWS < count ? top + TUI_OUTPUT_ROWS : count))
    for ((index = top; index < last; index++)); do
        tui_line "$((first + index - top))" "${lines[index]}"
    done
    if [[ $status != 'Running...' ]] && ((TUI_HEIGHT >= 2)); then
        if ((TUI_OUTPUT_LIMIT > 0 && TUI_WIDTH >= 42)); then
            tui_line "$TUI_HEIGHT" "Enter/Esc Back   Up/Down Scroll   $((top + 1))-$last/$count" "$TUI_MUTED"
        elif ((TUI_OUTPUT_LIMIT > 0)); then
            tui_line "$TUI_HEIGHT" 'Enter/Esc Back   Up/Down Scroll' "$TUI_MUTED"
        else
            tui_line "$TUI_HEIGHT" 'Enter/Esc Back' "$TUI_MUTED"
        fi
    fi
}

tui_watch_output() {
    local previous_size=0 size
    trap - EXIT
    trap 'exit 0' TERM HUP
    trap 'TUI_RESIZED=yes' WINCH
    while true; do
        sleep 0.5
        size=$(wc -c <"$TUI_OUTPUT") || return
        if ((size != previous_size)) || [[ $TUI_RESIZED == yes ]]; then
            previous_size=$size
            TUI_RESIZED=no
            tui_render_output "$1" running -1
        fi
    done
}

tui_review_output() {
    local title=$1 status=$2 top=-1 dirty=yes step
    while true; do
        if [[ $dirty == yes || $TUI_RESIZED == yes ]]; then
            TUI_RESIZED=no
            tui_render_output "$title" "$status" "$top"
        fi
        tui_key
        dirty=yes
        case $TUI_KEY in
            enter|back) return 0 ;;
            eof) return 1 ;;
            up|page-up)
                step=1
                if [[ $TUI_KEY == page-up ]]; then step=$TUI_OUTPUT_ROWS; fi
                top=$((TUI_OUTPUT_TOP > step ? TUI_OUTPUT_TOP - step : 0))
                ;;
            down) top=$((TUI_OUTPUT_TOP + 1)) ;;
            page-down) top=$((TUI_OUTPUT_TOP + TUI_OUTPUT_ROWS)) ;;
            first) top=0 ;;
            last) top=-1 ;;
            *) dirty=no ;;
        esac
    done
}

menu_dispatch() {
    local action=$1
    shift
    if [[ $action == import-vless || ( $action == import-json && ${1:-} == --url-stdin ) ]]; then
        run_action "$action" "$@" <&3 3<&-
    else
        run_action "$action" "$@"
    fi
}

menu_run() {
    local ui=$1 title=$2 status=success result
    shift 2
    if [[ $ui != terminal ]]; then
        menu_dispatch "$@" || true
        return 0
    fi

    tui_open
    if ! TUI_OUTPUT=$(mktemp "$STATE_DIR/ui-output.XXXXXXXX"); then
        tui_prompt "$title" 'Could not open a private output view. Press Enter to go back.'
        IFS= read -r
        return
    fi
    tui_render_output "$title" running -1
    # Keep the action in the foreground with its existing signal and rollback handling.
    tui_watch_output "$title" <&0 3<&- &
    TUI_PROGRESS_PID=$!
    menu_dispatch "$@" >"$TUI_OUTPUT" 2>&1 || status=$?
    tui_stop_progress
    result=0
    tui_review_output "$title" "$status" || result=$?
    tui_remove_output
    return "$result"
}

menu_action() {
    local ui=$1 action=$2 title=$3 input source
    local -a dialog_labels dialog_details
    # The dialog arrays are used through tui_select/tui_render namerefs.
    # shellcheck disable=SC2034
    case $action in
        import-vless)
            if [[ $ui == terminal ]]; then
                tui_prompt "$title" 'Paste one VLESS link. Empty input goes back.'
            fi
            IFS= read -rs -p 'VLESS URL (hidden): ' input || return 1
            printf '\n'
            if [[ -n $input ]]; then
                # Only the action gets the here-string. The return prompt still reads the SSH terminal.
                menu_run "$ui" "$title" import-vless - 3<<<"$input" || return 1
            fi ;;
        import-json)
            if [[ $ui == terminal ]]; then
                dialog_labels=('Local JSON file' 'HTTPS URL' 'Back')
                dialog_details=('Read a file already on this Ubuntu server.' 'Paste the final HTTPS URL with input hidden.' 'Return to the action list.')
                tui_select "$title" 'Choose a source for the client profile.' dialog_labels dialog_details || return 0
                case $TUI_CHOICE in 0) source=f ;; 1) source=u ;; *) return 0 ;; esac
            else
                IFS= read -r -p 'Import [f]ile or [u]rl? ' source || return 1
            fi
            case $source in
                f)
                    if [[ $ui == terminal ]]; then
                        tui_prompt "$title" 'Enter a path on this server. Empty input goes back.'
                    fi
                    IFS= read -r -p 'Local JSON path: ' input || return 1
                    if [[ -n $input ]]; then
                        menu_run "$ui" "$title" import-json "$input" || return 1
                    fi ;;
                u)
                    if [[ $ui == terminal ]]; then
                        tui_prompt "$title" 'Paste the full HTTPS URL. Empty input goes back.'
                    fi
                    IFS= read -rs -p 'HTTPS URL (hidden): ' input || return 1
                    printf '\n'
                    if [[ -n $input ]]; then
                        menu_run "$ui" "$title" import-json --url-stdin 3<<<"$input" || return 1
                    fi ;;
                *) log_warn 'Enter f or u.' ;;
            esac ;;
        enable-tun)
            if [[ $ui == terminal ]]; then
                dialog_labels=('IPv4' 'IPv4 and IPv6' 'Back')
                dialog_details=('Use on a server without a public IPv6 route.' 'Tunnel both families through a dual-stack upstream.' 'Return without changing routing.')
                tui_select "$title" 'Keep this SSH session open. Rollback stays armed for five minutes.' dialog_labels dialog_details 2 || return 0
                case $TUI_CHOICE in 0) input=n ;; 1) input=y ;; *) return 0 ;; esac
            else
                IFS= read -r -p 'Tunnel IPv6 as well? [y/N] ' input || return 1
            fi
            if [[ $input == [yY] ]]; then
                menu_run "$ui" "$title" enable-tun --ipv6 || return 1
            else
                menu_run "$ui" "$title" enable-tun || return 1
            fi ;;
        restore)
            if [[ -e $STATE_DIR/pending ]]; then
                menu_run "$ui" 'Roll back pending change' rollback || return 1
            else
                menu_run "$ui" "$title" restore || return 1
            fi ;;
        uninstall)
            if [[ $ui == terminal ]]; then
                tui_prompt "$title" 'The package is removed. Configuration and backups stay on disk.'
            fi
            IFS= read -r -p 'Type UNINSTALL to continue: ' input || return 1
            if [[ $input == UNINSTALL ]]; then
                menu_run "$ui" "$title" uninstall --yes || return 1
            fi ;;
        *)
            menu_run "$ui" "$title" "$action" || return 1 ;;
    esac
}

menu() {
    local ui=terminal focus=0 selection index title
    local -a actions=(install import-vless import-json enable-proxy enable-tun test ip status logs restart stop restore uninstall confirm exit)
    local -a labels=(
        'Install sing-box' 'Import VLESS link' 'Import JSON profile'
        'Enable loopback proxy' 'Enable full-server TUN' 'Test proxy connection' 'Show public IP'
        'Service status' 'View logs' 'Restart sing-box' 'Stop sing-box'
        'Restore previous configuration' 'Uninstall sing-box' 'Confirm TUN' 'Exit'
    )
    # Read by tui_render through a nameref.
    # shellcheck disable=SC2034
    local -a details=(
        'Install the stable package or check the version already installed.'
        'Stage a VLESS link without echoing it to the terminal.'
        'Stage a profile from a local file or HTTPS.'
        'Start SOCKS5 and HTTP on 127.0.0.1:1080 and test the connection.'
        'Route server traffic through sing-box with an SSH rollback timer.'
        'Check the running proxy and display its public egress.'
        'Check the public IPv4 address used by this server.'
        'Show the daemon state and any pending rollback deadline.'
        'Read recent systemd events with credentials withheld.'
        'Restart the managed service and rerun its connection checks.'
        'Stop sing-box and remove its managed TUN routes.'
        'Restore the last snapshot or roll back a pending change now.'
        'Remove the Debian package while retaining your configuration.'
        'Confirm from the new SSH session after TUN health checks pass.'
        'Close this terminal interface.'
    )
    if [[ ${1:-} == --plain || ! -t 1 || ${TERM:-dumb} == dumb || ${TERM:-} == unknown || ${TERM:-} == linux ]]; then
        ui=plain
    fi
    if [[ $ui == terminal ]]; then
        if [[ ! ${NO_COLOR+x} ]]; then
            TUI_ACCENT=$'\033[1;36m'
            TUI_MUTED=$'\033[2m'
        fi
        trap 'TUI_RESIZED=yes' WINCH
        tui_refresh
    fi
    while true; do
        if [[ $ui == terminal ]]; then
            if [[ $TUI_PENDING == yes ]]; then
                labels[11]='Roll back pending change'
            else
                labels[11]='Restore previous configuration'
            fi
            if ! tui_select 'ACTIONS' '' labels details "$focus"; then
                break
            fi
            focus=$TUI_CHOICE
        else
            printf '\n%s\n' 'Ubuntu VLESS'
            for ((index = 0; index < ${#actions[@]} - 1; index++)); do
                printf '%2d. %s\n' "$((index + 1))" "${labels[index]}"
            done
            printf '%s\n' ' 0. Exit'
            IFS= read -r -p '> ' selection || break
            case $selection in
                0) break ;;
                [1-9]|1[0-4]) focus=$((selection - 1)) ;;
                *) log_warn 'Choose a number from the menu.'; continue ;;
            esac
        fi
        [[ ${actions[focus]} != exit ]] || break
        title=${labels[focus]}
        menu_action "$ui" "${actions[focus]}" "$title" || break
        if [[ $ui == terminal ]]; then
            tui_refresh
        fi
    done
    tui_cleanup
}

main() {
    local action=${1:-menu}
    case $action in
        help|-h|--help) usage; return 0 ;;
        menu) [[ $# -le 1 || ( $# == 2 && $2 == --plain ) ]] || { usage >&2; return 2; } ;;
        install|enable-proxy|confirm|test|ip|status|logs|restart|stop|restore|rollback|_rollback)
            (($# <= 1)) || { usage >&2; return 2; } ;;
        import-vless|import-json) (($# == 2)) || { usage >&2; return 2; } ;;
        enable-tun) [[ $# == 1 || ( $# == 2 && $2 == --ipv6 ) ]] || { usage >&2; return 2; } ;;
        uninstall) [[ $# == 2 && $2 == --yes ]] || { usage >&2; return 2; } ;;
        *) usage >&2; return 2 ;;
    esac
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export LC_ALL=C SYSTEMD_COLORS=0 SYSTEMD_PAGER=cat
    trap 'log_error "Unexpected toolbox failure near line $LINENO."' ERR
    trap 'tui_cleanup; scratch_close' EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM
    runtime_init "$action" || return 1
    if [[ $action == menu ]]; then
        [[ -t 0 ]] || { usage >&2; return 2; }
        menu "${2:-}"
    else
        shift
        run_action "$action" "$@"
    fi
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
