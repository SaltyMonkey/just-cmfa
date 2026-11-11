#!/usr/bin/env bash
# Shared build settings. Android gets to keep its VPN stack during this diet.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE_PATH=core/src/foss/golang/clash
UPSTREAM_REPO=MetaCubeX/ClashMetaForAndroid
BUILD_TAGS=(
    foss with_gvisor cmfa
    no_easytier no_tailscale no_zerotier no_trusttunnel no_hysteria1
    no_shadowquic no_openvpn no_shadowsocksr no_debug_http no_rule_bundle
)
TEST_PACKAGES=(
    ./adapter/outbound ./adapter/outboundgroup ./adapter/provider ./common/convert
    ./component/fakeip ./component/profile/cachefile ./component/resource
    ./component/nat ./component/cidr ./component/trie ./config ./constant
    ./hub/route ./listener/inbound ./listener/tproxy ./rules/bundle
    ./rules/provider ./transport/xhttp ./tunnel
)
ABIS=(arm64-v8a armeabi-v7a x86_64 x86 universal)

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

require_commands() {
    local command_name
    for command_name in "$@"; do
        type -P "$command_name" >/dev/null || fail "Required command: $command_name"
    done
}

# Git Bash can prepare/check sources; complete APK builds run on Linux.
case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
        git() { command git -c http.sslBackend=openssl "$@"; }
        jq() { command jq --binary "$@"; }
        native_path() { cygpath -u "$1"; }
        ;;
    *) native_path() { printf '%s\n' "$1"; } ;;
esac

validate_channel() {
    [[ "$1" == alpha || "$1" == stable ]] || fail 'Channel must be alpha or stable'
}

