#!/usr/bin/env bash
# Mocks and shared variables are called or read by the dynamically sourced toolbox.
# shellcheck disable=SC2034,SC2329
# Run without sudo. Source the toolbox to test isolated helpers in a scratch directory.
set -Eeuo pipefail
umask 077

if (( EUID == 0 )); then
    printf 'Run the offline test suite as an unprivileged user.\n' >&2
    exit 2
fi
if (( BASH_VERSINFO[0] < 4 )); then
    printf 'Run this suite with Bash 4 or later.\n' >&2
    exit 2
fi
command -v jq >/dev/null || { printf 'jq is required.\n' >&2; exit 2; }

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
toolbox=${1:-$script_dir/../singbox-toolbox.sh}
[[ -r $toolbox ]] || { printf 'Toolbox script is missing.\n' >&2; exit 2; }
TOOLBOX_TEST_BINARY=${SINGBOX_TEST_BIN:-}
if [[ -n $TOOLBOX_TEST_BINARY && ! -x $TOOLBOX_TEST_BINARY ]]; then
    printf 'SINGBOX_TEST_BIN must be the path to an executable sing-box 1.14+ binary.\n' >&2
    exit 2
fi

# shellcheck disable=SC1090
source "$toolbox"

suite_dir=$(mktemp -d "${TMPDIR:-/tmp}/singbox-toolbox-tests.XXXXXXXX")
trap 'rm -rf -- "$suite_dir"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DUMMY_UUID=00000000-0000-4000-8000-000000000001

test_fail() {
    printf 'FAIL %s\n' "$*" >&2
    exit 1
}

expect_failure() {
    local output_file=$1/rejection.log
    shift
    if "$@" >"$output_file" 2>&1; then
        test_fail "expected ${1} to reject the input"
    fi
    if grep -Fq -- "$DUMMY_UUID" "$output_file"; then
        test_fail "${1} exposed a test credential"
    fi
}

check_real_binary() {
    local generated=$1
    if [[ -n $TOOLBOX_TEST_BINARY ]]; then
        "$TOOLBOX_TEST_BINARY" check -c "$generated" >"$generated.check.log" 2>&1 ||
            test_fail 'official sing-box rejected a generated configuration'
    fi
}

run_case() {
    local label=$1 case_dir
    shift
    case_dir=$(mktemp -d "$suite_dir/case.XXXXXXXX")
    (
        trap 'printf "FAIL %s (line %s)\n" "$label" "$LINENO" >&2' ERR
        "$@" "$case_dir"
    )
    printf 'PASS %s\n' "$label"
}

vless_transports() {
    local case_dir=$1
    local source_uri=$case_dir/link.txt profile=$case_dir/profile.json
    local empty_excludes=$case_dir/no-excludes.json generated=$case_dir/generated.json
    local reality_key=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
    printf '[]\n' >"$empty_excludes"

    printf 'vless://%s@192.0.2.10:443?type=tcp&security=tls&sni=vpn.example.test&fp=chrome&alpn=h2%%2Chttp%%2F1.1\n' \
        "$DUMMY_UUID" >"$source_uri"
    vless_profile "$source_uri" "$profile"
    generate_config "$profile" proxy no "$empty_excludes" "$generated"
    jq -e 'any(.inbounds[]; .type == "mixed" and .listen == "127.0.0.1" and .listen_port == 1080) and
        any(.outbounds[]; .type == "vless" and .tls.server_name == "vpn.example.test" and
          .tls.utls.fingerprint == "chrome" and .tls.alpn == ["h2", "http/1.1"])' "$generated" >/dev/null
    check_real_binary "$generated"

    printf 'vless://%s@192.0.2.10:443?type=tcp&security=reality&sni=vpn.example.test&fp=chrome&pbk=%s&sid=1234&flow=xtls-rprx-vision\n' \
        "$DUMMY_UUID" "$reality_key" >"$source_uri"
    vless_profile "$source_uri" "$profile"
    generate_config "$profile" proxy no "$empty_excludes" "$generated"
    jq -e --arg key "$reality_key" 'any(.outbounds[]; .type == "vless" and .flow == "xtls-rprx-vision" and
        .tls.reality.enabled and .tls.reality.public_key == $key and .tls.reality.short_id == "1234")' \
        "$generated" >/dev/null
    check_real_binary "$generated"

    printf 'vless://%s@192.0.2.10:443?type=ws&security=tls&sni=vpn.example.test&host=ws.example.test&path=%%2Fvpn%%3Fed%%3D1024\n' \
        "$DUMMY_UUID" >"$source_uri"
    vless_profile "$source_uri" "$profile"
    generate_config "$profile" proxy no "$empty_excludes" "$generated"
    jq -e 'any(.outbounds[]; .type == "vless" and .transport.type == "ws" and
        (.transport.path | startswith("/vpn")) and .transport.headers.Host == "ws.example.test")' "$generated" >/dev/null
    check_real_binary "$generated"

    printf 'vless://%s@192.0.2.10:443?type=grpc&security=tls&sni=vpn.example.test&serviceName=vpn-service\n' \
        "$DUMMY_UUID" >"$source_uri"
    vless_profile "$source_uri" "$profile"
    generate_config "$profile" proxy no "$empty_excludes" "$generated"
    jq -e 'any(.outbounds[]; .type == "vless" and .transport.type == "grpc" and .transport.service_name == "vpn-service")' \
        "$generated" >/dev/null
    check_real_binary "$generated"
}

invalid_configuration() {
    local case_dir=$1
    local source_uri=$case_dir/link.txt source_json=$case_dir/input.json profile=$case_dir/profile.json
    printf '{"outbounds": [invalid]}\n' >"$source_json"
    expect_failure "$case_dir" import_json_profile "$source_json" "$profile"
    [[ ! -s $profile ]] || test_fail 'invalid JSON wrote a usable profile'

    printf 'vless://%s@192.0.2.10:99999?security=tls\n' "$DUMMY_UUID" >"$source_uri"
    expect_failure "$case_dir" vless_profile "$source_uri" "$profile"
    printf 'vless://%s@192.0.2.10:443?type=unsupported&security=tls\n' "$DUMMY_UUID" >"$source_uri"
    expect_failure "$case_dir" vless_profile "$source_uri" "$profile"
    printf 'vless://%s@192.0.2.10:443?type=ws&security=tls&path=%%00\n' "$DUMMY_UUID" >"$source_uri"
    expect_failure "$case_dir" vless_profile "$source_uri" "$profile"
    [[ ! -s $profile ]] || test_fail 'invalid VLESS input wrote a usable profile'
}

tun_configuration() {
    local case_dir=$1
    local source_json=$case_dir/input.json profile=$case_dir/profile.json
    local exclusions=$case_dir/exclusions.json pins=$case_dir/pins.json generated=$case_dir/generated.json
    jq -n --arg id "$DUMMY_UUID" '{
        inbounds: [{type:"mixed",tag:"imported-listener",listen:"0.0.0.0",listen_port:9080}],
        outbounds: [{type:"vless",tag:"vpn",server:"192.0.2.10",server_port:443,uuid:$id,
                     tls:{enabled:true,server_name:"vpn.example.test"}}],
        route:{final:"vpn"}
    }' >"$source_json"
    printf '["192.0.2.10/32", "198.51.100.25/32", "2001:db8:25::1/128"]\n' >"$exclusions"
    printf '{}\n' >"$pins"
    import_json_profile "$source_json" "$profile"
    generate_config "$profile" tun yes "$exclusions" "$generated" "$pins"
    jq -e 'any(.inbounds[]; .type == "tun" and .auto_route and .dns_mode == "hijack" and
        (.route_exclude_address | index("192.0.2.10/32")) and
        (.route_exclude_address | index("198.51.100.25/32")) and
        (.route_exclude_address | index("2001:db8:25::1/128"))) and
        any(.inbounds[]; .type == "mixed" and .listen == "127.0.0.1" and .listen_port == 1080) and
        all(.inbounds[]; .listen_port != 9080 and .listen != "0.0.0.0")' "$generated" >/dev/null
    check_real_binary "$generated"
}

# The installer and transaction cases redirect every writable path into the
# case directory and mock systemd, package management, downloads and clocks.
use_case_paths() {
    TEST_CASE=$1
    STATE_DIR=$TEST_CASE/state
    CONFIG_DIR=$TEST_CASE/config
    CONFIG_FILE=$CONFIG_DIR/config.json
    UNIT_DIR=$TEST_CASE/systemd
    DROP_IN=$UNIT_DIR/$UNIT.d/99-singbox-toolbox.conf
    TUN_PERMIT=$TEST_CASE/tun-permit
    SCRATCH=$TEST_CASE/scratch
    mkdir -p -- "$STATE_DIR/transactions" "$CONFIG_DIR" "$UNIT_DIR" "$SCRATCH" "$TEST_CASE/bin"
    : >"$TEST_CASE/events"
}

# BSD mv has no -T. These fixtures only rename private regular files.
if [[ $(uname -s) == Darwin ]]; then
    stat() {
        [[ $* == '-c %u %g %a -- '* ]] || test_fail 'unexpected stat arguments'
        command stat -f '%u %g %Lp' "$4"
    }
    mv() {
        [[ ${1:-} != -Tf ]] || shift
        command mv -f "$@"
    }
fi

install_fixture() {
    local case_dir=$1
    use_case_paths "$case_dir"
    local mock_tool executable
    for executable in cat chmod cmp curl grep install jq mktemp mv rm sha256sum stat uname; do
        mock_tool=$(type -P "$executable") || test_fail "missing test tool $executable"
        ln -s -- "$mock_tool" "$case_dir/bin/$executable"
    done
    PATH=$case_dir/bin
    printf 'old config sentinel\n' >"$CONFIG_FILE"
    printf 'fixture package\n' >"$case_dir/package"
    FIXTURE_DIGEST=$(sha256sum -- "$case_dir/package")
    FIXTURE_DIGEST=${FIXTURE_DIGEST%% *}
    FAIL_PACKAGE=no

    ubuntu_release() { printf '24.04\n'; }
    install_dependencies() { printf 'dependencies\n' >>"$TEST_CASE/events"; }
    apt-get() { test_fail 'real package management would have been unsafe'; }
    dpkg-query() { return 1; }
    sync() { return 0; }
    systemctl() { [[ $* == 'is-active --quiet sing-box.service' ]] || test_fail "unexpected systemd action $*"; return 1; }
    dpkg() {
        if [[ $* == --print-architecture ]]; then
            printf 'arm64\n'
            return 0
        fi
        [[ $# == 3 && $1 == --force-confold && $2 == -i ]] || test_fail "unexpected package action $*"
        printf 'dpkg install\n' >>"$TEST_CASE/events"
        if [[ $FAIL_PACKAGE == yes ]]; then
            printf 'package modified conffile\n' >"$CONFIG_FILE"
            return 1
        fi
        cat >"$TEST_CASE/bin/sing-box" <<'BIN'
#!/bin/sh
[ "$1" = version ] || exit 2
printf 'sing-box version 1.14.4\n'
BIN
        chmod 700 "$TEST_CASE/bin/sing-box"
    }
    htget() {
        local target='' url=${*: -1}
        while (( $# )); do
            if [[ $1 == --output ]]; then
                target=$2
                break
            fi
            shift
        done
        [[ -n $target ]] || test_fail 'download requested without an output file'
        case $url in
            https://api.github.com/repos/SagerNet/sing-box/releases/latest)
                printf 'release metadata\n' >>"$TEST_CASE/events"
                jq -n --arg digest "$FIXTURE_DIGEST" '{draft:false,prerelease:false,tag_name:"v1.14.4",
                    assets:[{name:"sing-box_1.14.4_linux_arm64.deb",
                    browser_download_url:"https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box_1.14.4_linux_arm64.deb",
                    digest:("sha256:" + $digest)}]}' >"$target"
                ;;
            https://github.com/SagerNet/sing-box/releases/download/v1.14.4/sing-box_1.14.4_linux_arm64.deb)
                printf 'package download\n' >>"$TEST_CASE/events"
                cat -- "$TEST_CASE/package" >"$target"
                ;;
            *) test_fail 'unexpected package download';;
        esac
    }
}

installer_idempotence() {
    local case_dir=$1
    install_fixture "$case_dir"
    install_box >"$case_dir/install.log" 2>&1
    install_box >>"$case_dir/install.log" 2>&1
    [[ $(grep -c '^dpkg install$' "$case_dir/events") == 1 ]] || test_fail 'installer ran dpkg twice'
    [[ $(grep -c '^package download$' "$case_dir/events") == 1 ]] || test_fail 'installer fetched the package twice'
    local backups=("$STATE_DIR"/pre-install.*/config.json)
    [[ ${#backups[@]} == 1 ]] || test_fail 'installer failed to keep one pre-install backup'
    cmp -s "$CONFIG_FILE" "${backups[0]}" || test_fail 'pre-install backup differs from the original'
}

installer_bad_digest() {
    local case_dir=$1
    install_fixture "$case_dir"
    printf 'tampered bytes\n' >"$case_dir/package"
    expect_failure "$case_dir" install_box
    if grep -Fq 'dpkg install' "$case_dir/events"; then
        test_fail 'package installation ran after a digest mismatch'
    fi
    [[ $(cat -- "$CONFIG_FILE") == 'old config sentinel' ]] || test_fail 'digest failure changed the current configuration'
}

installer_failed_package() {
    local case_dir=$1
    install_fixture "$case_dir"
    FAIL_PACKAGE=yes
    expect_failure "$case_dir" install_box
    grep -Fxq 'dpkg install' "$case_dir/events" || test_fail 'failed package fixture did not reach dpkg'
    [[ $(cat -- "$CONFIG_FILE") == 'old config sentinel' ]] || test_fail 'failed package installation did not restore the prior config'
}

test_ssh_socket_table() {
    local port expression=${*: -1}
    for port in 52001 52002 52003; do
        [[ $port != 52003 || $MOCK_FRESH_SSH == yes ]] || continue
        if [[ $expression != *'dport = :'* || $expression == *"dport = :$port )" ]]; then
            printf '0 0 192.0.2.5:22 198.51.100.25:%s\n' "$port"
        fi
    done
    return 0
}

ssh_protection() {
    local case_dir=$1 changed=no
    local original='198.51.100.25 52001 192.0.2.5 22'
    MOCK_FRESH_SSH=no
    ss() { test_ssh_socket_table "$@"; }
    ip() {
        if [[ $changed == yes ]]; then
            printf '[{"dev":"sbtoolbox0","table":20220,"prefsrc":"198.18.0.1"}]\n'
        else
            printf '[{"dev":"eth0","gateway":"192.0.2.1","prefsrc":"192.0.2.5"}]\n'
        fi
    }
    SSH_SESSION=$original
    SSH_BASELINE=$(network_ssh_route "$SSH_SESSION")
    network_verify_ssh
    SSH_CONNECTION=$original expect_failure "$case_dir" network_confirm_ssh "$original"
    SSH_CONNECTION='203.0.113.25 52002 192.0.2.5 22' expect_failure "$case_dir" network_confirm_ssh "$original"
    network_ssh_peer_ports "$original" >"$case_dir/prior-ports"
    SSH_CONNECTION='198.51.100.25 52002 192.0.2.5 22' expect_failure "$case_dir" network_confirm_ssh "$original" "$case_dir/prior-ports"
    SSH_CONNECTION='198.51.100.25 52003 192.0.2.5 22' expect_failure "$case_dir" network_confirm_ssh "$original" "$case_dir/prior-ports"
    MOCK_FRESH_SSH=yes
    SSH_CONNECTION='198.51.100.25 52003 192.0.2.5 22' network_confirm_ssh "$original" "$case_dir/prior-ports"
    changed=yes
    expect_failure "$case_dir" network_verify_ssh
    expect_failure "$case_dir" network_ssh_tuple '198.51.100.25 52001 2001:db8::5 22'
}

transaction_fixture() {
    use_case_paths "$1"
    printf 'active\n' >"$TEST_CASE/service-state"
    printf 'inactive\n' >"$TEST_CASE/timer-state"
    printf '{"inbounds":[]}\n' >"$CONFIG_FILE"
    chmod 0640 "$CONFIG_FILE"
    cp -- "$CONFIG_FILE" "$TEST_CASE/original.json"
    mkdir -p -- "${DROP_IN%/*}"
    printf '# singbox-toolbox mode=proxy\n[Service]\n' >"$DROP_IN"
    cp -- "$DROP_IN" "$TEST_CASE/original.conf"
    printf '{"outbounds":[]}\n' >"$TEST_CASE/candidate.json"
    printf '{"outbounds":[]}\n' >"$TEST_CASE/profile.json"
    BIN=/test/sing-box
    FAIL_TIMER=no
    FAIL_CLEANUP=no
    MOCK_UNIT_FRAGMENT=/usr/lib/systemd/system/sing-box.service
    MOCK_UNIT_USER=sing-box
    MOCK_UNIT_DROPINS=$DROP_IN

    boot_id() { printf 'test-boot\n'; }
    sync() { return 0; }
    timeout() { shift; "$@"; }
    network_cleanup_tun() {
        printf 'cleanup-tun\n' >>"$TEST_CASE/events"
        [[ $FAIL_CLEANUP == no ]]
    }
    systemctl() {
        printf '%s\n' "$*" >>"$TEST_CASE/events"
        case $* in
            'daemon-reload'|"enable $ROLLBACK_TIMER"|"is-enabled --quiet $ROLLBACK_TIMER") return 0 ;;
            "restart $ROLLBACK_TIMER")
                [[ $FAIL_TIMER == no ]] || return 1
                printf 'active\n' >"$TEST_CASE/timer-state"
                ;;
            "is-active --quiet $ROLLBACK_TIMER") [[ $(<"$TEST_CASE/timer-state") == active ]] ;;
            "disable --now $ROLLBACK_TIMER") printf 'inactive\n' >"$TEST_CASE/timer-state" ;;
            "stop $UNIT") printf 'inactive\n' >"$TEST_CASE/service-state" ;;
            "start $UNIT") printf 'active\n' >"$TEST_CASE/service-state" ;;
            "show $UNIT --property=ActiveState --value") cat -- "$TEST_CASE/service-state" ;;
            "show $UNIT --property=FragmentPath --value") printf '%s\n' "$MOCK_UNIT_FRAGMENT" ;;
            "show $UNIT --property=User --value") printf '%s\n' "$MOCK_UNIT_USER" ;;
            "show $UNIT --property=DropInPaths --value") printf '%s\n' "$MOCK_UNIT_DROPINS" ;;
            "is-active --quiet $UNIT") [[ $(<"$TEST_CASE/service-state") == active ]] ;;
            *) test_fail "unexpected systemd action $*" ;;
        esac
    }
    if [[ $(uname -s) == Darwin ]]; then
        date() {
            if [[ $* == '-u -d @'* ]]; then
                command date -u -r "${3#@}" "$4"
            else
                command date "$@"
            fi
        }
    fi
}

vendor_service_compatibility() {
    local case_dir=$1
    transaction_fixture "$case_dir"
    rm -f -- "$DROP_IN"
    MOCK_UNIT_DROPINS=''
    service_compatible || test_fail 'official sing-box service account was rejected'
    MOCK_UNIT_FRAGMENT=/lib/systemd/system/sing-box.service
    service_compatible || test_fail 'official service under /lib was rejected'
    MOCK_UNIT_FRAGMENT=/etc/systemd/system/sing-box.service
    expect_failure "$case_dir" service_compatible
    grep -Fq 'Unsupported sing-box unit path' "$case_dir/rejection.log" || test_fail 'unit path error was unclear'
    MOCK_UNIT_FRAGMENT=/usr/lib/systemd/system/sing-box.service
    MOCK_UNIT_DROPINS=/etc/systemd/system/sing-box.service.d/local.conf
    expect_failure "$case_dir" service_compatible
    grep -Fq "$MOCK_UNIT_DROPINS" "$case_dir/rejection.log" || test_fail 'drop-in error did not name the file'
    MOCK_UNIT_DROPINS=''
    MOCK_UNIT_USER=other-service
    expect_failure "$case_dir" service_compatible
    grep -Fq 'Unsupported sing-box service account' "$case_dir/rejection.log" || test_fail 'service account error was unclear'
    MOCK_UNIT_USER=root
    service_compatible || test_fail 'previously supported root service account was rejected'
    printf 'activating\n' >"$case_dir/service-state"
    expect_failure "$case_dir" service_compatible
    grep -Fq "'activating' state" "$case_dir/rejection.log" || test_fail 'transition error did not name the state'
}

transaction_rollback() {
    local case_dir=$1 restore_output snapshot
    transaction_fixture "$case_dir"
    begin_transaction >"$case_dir/begin.log" 2>&1
    snapshot=$TXN
    [[ $(read_pointer pending) == "$snapshot" ]] || test_fail 'pending transaction did not identify its snapshot'
    grep -Fxq 'Persistent=true' "$UNIT_DIR/$ROLLBACK_TIMER" || test_fail 'timer is not persistent'
    grep -Fxq "ExecStart=/bin/bash $STATE_DIR/runner _rollback" "$UNIT_DIR/$ROLLBACK_SERVICE" ||
        test_fail 'rollback unit is missing a self-contained runner'
    cmp -s "$STATE_DIR/runner" "$toolbox" || test_fail 'rollback runner does not match the toolbox'
    [[ $(<"$TEST_CASE/timer-state") == active ]] || test_fail 'timer was not armed'
    apply_config tun no "$case_dir/profile.json" "$case_dir/candidate.json"
    [[ -f $TUN_PERMIT && $(managed_mode) == tun ]] || test_fail 'TUN candidate was not applied'
    cmp -s "$CONFIG_FILE" "$case_dir/candidate.json" || test_fail 'TUN activation did not install the candidate'

    # Drop in-memory transaction state to simulate independent recovery.
    TXN='' SCRATCH=''
    FAIL_CLEANUP=yes
    expect_failure "$case_dir" rollback_pending
    [[ -f $STATE_DIR/pending && $(<"$case_dir/timer-state") == active ]] ||
        test_fail 'failed restoration discarded the snapshot or disabled the timer'
    FAIL_CLEANUP=no
    restore_output=$(rollback_pending 2>&1) || test_fail "restoration did not retry: $restore_output"
    [[ ! -e $STATE_DIR/pending && ! -e $TUN_PERMIT ]] || test_fail 'successful rollback left pending state or a TUN permit'
    cmp -s "$CONFIG_FILE" "$case_dir/original.json" || test_fail 'previous config was not restored'
    cmp -s "$DROP_IN" "$case_dir/original.conf" || test_fail 'previous drop-in was not restored'
    [[ $(stat -c '%u %g %a' -- "$CONFIG_FILE") == "$(<"$snapshot/config.stat")" ]] ||
        test_fail 'rollback did not preserve original ownership and permissions'
    [[ $(<"$case_dir/service-state") == active ]] || test_fail 'rollback did not restore the previous active service'
    [[ $(<"$case_dir/timer-state") == inactive ]] || test_fail 'rollback timer stayed active after restoration'
    rollback_pending >"$case_dir/repeated-rollback.log" 2>&1
    [[ $(grep -c '^cleanup-tun$' "$case_dir/events") == 2 ]] || test_fail 'rollback was not idempotent'
}

transaction_timer_failure() {
    local case_dir=$1
    transaction_fixture "$case_dir"
    FAIL_TIMER=yes
    expect_failure "$case_dir" begin_transaction
    [[ ! -e $STATE_DIR/pending ]] || test_fail 'a failed timer start left an armed transaction'
    cmp -s "$CONFIG_FILE" "$case_dir/original.json" || test_fail 'timer failure changed the working configuration'
    [[ $(<"$case_dir/service-state") == active ]] || test_fail 'timer failure changed service state'
    if grep -Fxq "stop $UNIT" "$case_dir/events"; then
        test_fail 'failed timer start stopped the working service'
    fi
}

activation_fixture() {
    transaction_fixture "$1"
    printf 'vless://%s@192.0.2.10:443?security=tls&sni=example.test\n' "$DUMMY_UUID" >"$TEST_CASE/input.vless"
    vless_profile "$TEST_CASE/input.vless" "$STATE_DIR/profile.json"
    MOCK_HEALTH=healthy
    SSH_CONNECTION='198.51.100.25 52001 192.0.2.5 22'
    require_network_tools() { return 0; }
    require_box() { return 0; }
    check_config() {
        jq -e 'any(.inbounds[]; .type == "mixed")' "$1" >/dev/null || return 1
        printf 'config validated\n' >>"$TEST_CASE/events"
    }
    MOCK_FRESH_SSH=no
    ss() { test_ssh_socket_table "$@"; }
    ip() { printf '[{"dev":"eth0","gateway":"192.0.2.1","prefsrc":"192.0.2.5"}]\n'; }
    network_preflight() {
        if [[ $1 == tun ]]; then
            SSH_SESSION=$(network_ssh_tuple "$SSH_CONNECTION") || return 1
            SSH_CLIENT_CIDR=198.51.100.25/32
            SSH_BASELINE=$(network_ssh_route "$SSH_SESSION") || return 1
        fi
    }
    network_public_ip() {
        [[ $* == 'direct 4' ]] || test_fail 'unexpected public-IP probe'
        printf '192.0.2.5\n'
    }
    network_health() {
        [[ $(<"$TEST_CASE/service-state") == active && $(<"$TEST_CASE/timer-state") == active ]] ||
            test_fail 'health checks ran without an active service and watchdog'
        printf 'health probe %s %s\n' "$1" "$MOCK_HEALTH" >>"$TEST_CASE/events"
        [[ $MOCK_HEALTH == healthy ]] || return 1
        PROXY_PUBLIC_IP=198.51.100.35
    }
}

failed_live_connection() {
    local case_dir=$1
    activation_fixture "$case_dir"
    MOCK_HEALTH=unreachable
    expect_failure "$case_dir" activate_profile proxy no
    grep -Fxq 'config validated' "$case_dir/events" || test_fail 'failed activation skipped preflight validation'
    grep -Fxq 'health probe proxy unreachable' "$case_dir/events" || test_fail 'failed activation skipped connectivity validation'
    cmp -s "$CONFIG_FILE" "$case_dir/original.json" || test_fail 'failed connectivity did not restore the previous config'
    cmp -s "$DROP_IN" "$case_dir/original.conf" || test_fail 'failed connectivity did not restore the previous drop-in'
    [[ $(<"$case_dir/service-state") == active ]] || test_fail 'failed activation did not restore the active service'
    [[ $(<"$case_dir/timer-state") == inactive && ! -e $STATE_DIR/pending ]] ||
        test_fail 'clean recovery did not clear pending rollback state'
}

successful_tun_confirmation() {
    local case_dir=$1 snapshot
    activation_fixture "$case_dir"
    activate_profile tun no >"$case_dir/activation.log" 2>&1
    snapshot=$(read_pointer pending)
    [[ -f $snapshot/ready && $(<"$case_dir/timer-state") == active ]] ||
        test_fail 'successful health probes cancelled the timer before confirmation'
    jq -e 'any(.inbounds[]; .type == "tun" and
        (.route_exclude_address | index("192.0.2.10/32")) and
        (.route_exclude_address | index("198.51.100.25/32")))' "$CONFIG_FILE" >/dev/null
    expect_failure "$case_dir" confirm_tun
    [[ -f $STATE_DIR/pending && $(<"$case_dir/timer-state") == active ]] ||
        test_fail 'first SSH session cancelled the timer'
    SSH_CONNECTION='198.51.100.25 52002 192.0.2.5 22' expect_failure "$case_dir" confirm_tun
    [[ -f $STATE_DIR/pending && $(<"$case_dir/timer-state") == active ]] ||
        test_fail 'an already-open second session cancelled rollback'
    MOCK_FRESH_SSH=yes
    SSH_CONNECTION='198.51.100.25 52003 192.0.2.5 22'
    confirm_tun >"$case_dir/confirmation.log" 2>&1
    [[ $(read_pointer previous) == "$snapshot" ]] || test_fail 'confirmation did not retain the previous config snapshot'
    [[ ! -e $STATE_DIR/pending && $(<"$case_dir/timer-state") == inactive ]] || test_fail 'confirmed activation left the watchdog armed'
    [[ -f $TUN_PERMIT && $(managed_mode) == tun && $(<"$case_dir/service-state") == active ]] ||
        test_fail 'confirmed TUN application did not preserve the active tunnel'
    [[ $(grep -c '^health probe tun healthy$' "$case_dir/events") == 2 ]] ||
        test_fail 'confirmation did not recheck TUN health'
}

stop_preserves_external_service() {
    local case_dir=$1
    transaction_fixture "$case_dir"
    rm -f -- "$DROP_IN"
    MOCK_UNIT_DROPINS=''
    stop_tun >"$case_dir/stop.log" 2>&1 || true
    begin_transaction >"$case_dir/begin.log" 2>&1
    stop_tun >>"$case_dir/stop.log" 2>&1 || true
    [[ -e $STATE_DIR/pending && $(<"$case_dir/timer-state") == active ]] ||
        test_fail 'Stop cleared an unrelated pending transaction'
    atomic_text "$TXN/new-ipv6" no
    stop_tun >>"$case_dir/stop.log" 2>&1 || test_fail 'Stop failed to cancel a TUN before configuration was applied'
    [[ ! -e $STATE_DIR/pending && $(<"$case_dir/timer-state") == inactive ]] ||
        test_fail 'Stop left the un-applied TUN watchdog armed'
    [[ $(<"$case_dir/service-state") == active ]] || test_fail 'Stop interrupted an external sing-box service'
    if grep -Fxq "stop $UNIT" "$case_dir/events"; then
        test_fail 'Stop attempted to stop an external service'
    fi
}

stop_pending_tun() {
    local case_dir=$1
    transaction_fixture "$case_dir"
    printf '# singbox-toolbox mode=tun\n[Service]\n' >"$DROP_IN"
    printf 'test-boot\n' >"$TUN_PERMIT"
    begin_transaction >"$case_dir/begin.log" 2>&1
    apply_config tun no "$case_dir/profile.json" "$case_dir/candidate.json"
    : >"$case_dir/events"
    require_commands() { return 0; }
    stop_tun >"$case_dir/stop.log" 2>&1 || test_fail 'Stop failed with a pending managed TUN'
    [[ ! -e $STATE_DIR/pending && ! -e $TUN_PERMIT ]] || test_fail 'Stop left a pending transaction or TUN permit'
    [[ $(<"$case_dir/timer-state") == inactive && $(<"$case_dir/service-state") == inactive ]] ||
        test_fail 'Stop left the watchdog or restored TUN running'
    cmp -s "$CONFIG_FILE" "$case_dir/original.json" || test_fail 'Stop skipped restoring the prior configuration'
    [[ $(grep -Fxc "stop $UNIT" "$case_dir/events") == 2 && $(grep -Fxc 'cleanup-tun' "$case_dir/events") == 2 ]] ||
        test_fail 'Stop did not clean up both the pending and restored tunnels'
}

dns_routing_domains() {
    local case_dir=$1
    local fixture='Global:
Link 2 (eth0): openstacklocal. ~Corp.Internal.
Link 3 (eth1): home.arpa'
    timeout() { shift; "$@"; }
    resolvectl() { printf '%s\n' "$fixture"; }
    network_dns_preflight >"$case_dir/allowed.log" 2>&1
    grep -Fq 'Local DNS domains may continue' "$case_dir/allowed.log"

    fixture+=$'\nLink 7 (sbtoolbox0): ~.'
    network_dns_preflight "$NETWORK_TUN"
    expect_failure "$case_dir" network_dns_preflight
    grep -Fq "DNS domain '~.' on Link 7 (sbtoolbox0)" "$case_dir/rejection.log"

    fixture+=$'\nLink 8 (another-vpn): ~.'
    expect_failure "$case_dir" network_dns_preflight "$NETWORK_TUN"
    grep -Fq "DNS domain '~.' on Link 8 (another-vpn)" "$case_dir/rejection.log"

    fixture='Global: example.com'
    expect_failure "$case_dir" network_dns_preflight "$NETWORK_TUN"
    grep -Fq "DNS domain 'example.com' on Global" "$case_dir/rejection.log"
}

forwarding_preflight() {
    local case_dir=$1 output
    output=$(network_forwarding_warning 0 0 2>&1) || test_fail 'disabled forwarding failed preflight'
    [[ -z $output ]] || test_fail 'disabled forwarding produced a warning'
    output=$(network_forwarding_warning 1 0 2>&1) || test_fail 'IPv4 forwarding incorrectly blocked TUN'
    grep -Fq 'TUN covers server-local traffic' <<< "$output" ||
        test_fail 'IPv4 forwarding did not explain the TUN scope'
    output=$(network_forwarding_warning 0 1 2>&1) || test_fail 'IPv6 forwarding incorrectly blocked TUN'
    grep -Fq 'TUN covers server-local traffic' <<< "$output" ||
        test_fail 'IPv6 forwarding did not explain the TUN scope'
    : >"$case_dir/forwarding-preflight.log"
}

tun_link_preflight() {
    local case_dir=$1
    local sample fixture master
    sample='[
      {"ifindex": 1, "ifname": "lo", "flags": ["UP", "LOWER_UP"], "operstate": "UNKNOWN"},
      {"ifindex": 2, "ifname": "eth0", "flags": ["UP", "LOWER_UP"], "operstate": "UP"},
      {"ifindex": 3, "ifname": "docker0", "flags": ["UP"], "operstate": "DOWN", "linkinfo": {"info_kind": "bridge"}}
    ]'
    ip() { printf '%s\n' "$fixture"; }

    fixture=$sample
    network_tun_link_preflight

    fixture=$(jq '.[2].flags += ["LOWER_UP"]' <<< "$sample")
    expect_failure "$case_dir" network_tun_link_preflight
    grep -Fq 'docker0 (bridge, DOWN)' "$case_dir/rejection.log"

    for master in '"docker0"' '3'; do
        fixture=$(jq --argjson master "$master" '. + [{"ifname":"veth0","master":$master,"flags":[]}]' <<< "$sample")
        expect_failure "$case_dir" network_tun_link_preflight
        grep -Fq 'docker0 (bridge, DOWN)' "$case_dir/rejection.log"
    done

    fixture=$(jq '.[2].ifname = "br-test"' <<< "$sample")
    expect_failure "$case_dir" network_tun_link_preflight
    grep -Fq 'br-test (bridge, DOWN)' "$case_dir/rejection.log"

    fixture=$(jq '. + [{"ifname":"sbtoolbox0","flags":[],"operstate":"DOWN","linkinfo":{"info_kind":"tun"}}]' <<< "$sample")
    expect_failure "$case_dir" network_tun_link_preflight
    grep -Fq 'sbtoolbox0 (tun, DOWN)' "$case_dir/rejection.log"
    network_tun_link_preflight "$NETWORK_TUN"

    fixture='{"unexpected":true}'
    expect_failure "$case_dir" network_tun_link_preflight
}

run_case 'VLESS TCP/TLS, Reality, WebSocket and gRPC conversion' vless_transports
run_case 'malformed input rejected without credential disclosure' invalid_configuration
run_case 'TUN exclusions and loopback-only proxy listener' tun_configuration
run_case 'official package metadata, digest, backup and repeat install' installer_idempotence
run_case 'digest mismatch rejects the package without changing active config' installer_bad_digest
run_case 'failed package installation restores the original conffile' installer_failed_package
run_case 'official sing-box unit accepted and unsupported unit settings rejected' vendor_service_compatibility
run_case 'enabled packet forwarding warns but does not block host TUN' forwarding_preflight
run_case 'private search and split DNS suffixes accepted while competing DNS routes are blocked' dns_routing_domains
run_case 'idle docker0 without ports is accepted; bridged traffic and other TUN conflicts are blocked' tun_link_preflight
run_case 'SSH route verification and second-session enforcement' ssh_protection
run_case 'persistent rollback snapshot, failed restoration, retry and idempotence' transaction_rollback
run_case 'failed timer arming leaves the prior configuration and service running' transaction_timer_failure
run_case 'failed live connectivity automatically restores the working proxy' failed_live_connection
run_case 'healthy TUN stays pending until health is rechecked from a second session' successful_tun_confirmation
run_case 'TUN Stop preserves an external sing-box service' stop_preserves_external_service
run_case 'TUN Stop rolls back pending activation and stops a restored managed tunnel' stop_pending_tun
if [[ -n $TOOLBOX_TEST_BINARY ]]; then
    printf 'Generated configs also passed the real sing-box configuration checker.\n'
else
    printf 'Set SINGBOX_TEST_BIN to also run the official configuration checker.\n'
fi
