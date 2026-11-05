#!/usr/bin/env bash
# Signing values belong in files with restricted access, not in a helpful shell trace.
set +x
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

escape_property() {
    # Java Properties expects UTF-16 escapes; this also preserves whitespace/surrogates.
    iconv -f UTF-8 -t UTF-16BE | od -An -v -tx1 | tr -d '[:space:]' | sed 's/..../\\u&/g'
}

main() {
    local source_dir='' clean=false key properties marker
    while (($#)); do
        case "$1" in
            --source-dir)
                (($# >= 2)) && [[ -n "$2" ]] || fail '--source-dir requires a value'
                source_dir="$2"; shift 2 ;;
            --clean) clean=true; shift ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
    [[ -n "$source_dir" ]] || fail '--source-dir is required'
    key="$source_dir/release.keystore"
    properties="$source_dir/signing.properties"
    marker="$source_dir/.downstream-signing-created"
    if [[ "$clean" == true ]]; then
        # Only remove files created by this script, even on a failed CI run.
        if [[ -f "$marker" ]]; then rm -f -- "$key" "$properties" "$marker"; fi
        return
    fi
    require_commands iconv od base64
    [[ -n "${CMFA_KEYSTORE_BASE64:-}" && -n "${CMFA_STORE_PASSWORD:-}" &&
        -n "${CMFA_KEY_ALIAS:-}" && -n "${CMFA_KEY_PASSWORD:-}" ]] ||
        fail 'Configure all four CMFA signing secrets; no credentials were printed'
    [[ -d "$source_dir" ]] || fail 'Source directory is missing'
    [[ ! -e "$key" && ! -L "$key" && ! -e "$properties" && ! -L "$properties" &&
        ! -e "$marker" && ! -L "$marker" ]] || fail 'Refusing to overwrite existing signing material'
    umask 077
    (set -o noclobber; : > "$marker")
    printf '%s' "$CMFA_KEYSTORE_BASE64" | tr -d '[:space:]' | base64 --decode > "$key" || fail 'Invalid keystore encoding'
    [[ -s "$key" ]] || fail 'Empty keystore'
    {
        printf 'keystore.password='; printf '%s' "$CMFA_STORE_PASSWORD" | escape_property; printf '\n'
        printf 'key.alias='; printf '%s' "$CMFA_KEY_ALIAS" | escape_property; printf '\n'
        printf 'key.password='; printf '%s' "$CMFA_KEY_PASSWORD" | escape_property; printf '\n'
    } > "$properties"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
