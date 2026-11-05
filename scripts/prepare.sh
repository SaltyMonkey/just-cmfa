#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

apply_patches() {
    local source_dir="$1" group target patch
    local -a patches
    shopt -s nullglob
    for group in cmfa mihomo; do
        target="$source_dir"
        [[ "$group" != mihomo ]] || target="$source_dir/$CORE_PATH"
        patches=("$ROOT/patches/$group/"*.patch)
        for patch in "${patches[@]}"; do
            printf 'Applying %s/%s\n' "$group" "$(basename "$patch")"
            git -C "$target" apply --check -- "$patch"
            git -C "$target" apply -- "$patch"
        done
    done
    # One upstream diff forgot its last newline. Strict git apply did not forget.
    for patch in "$source_dir/.github/patch/"*.patch; do
        [[ -f "$patch" ]] || continue
        [[ "$(tail -c 1 "$patch" | od -An -tu1 | tr -d '[:space:]')" == 10 ]] || printf '\n' >> "$patch"
    done
}

resolve_dependencies() {
    local source_dir="$1" core="$1/$CORE_PATH" utls directory dependency original local_dir
    local module relative patch
    local -a modules=("$core" "$source_dir/core/src/main/golang" "$source_dir/core/src/foss/golang")
    local -a dependency_patches
    require_commands go
    utls="$(cd "$core" && go mod edit -json | jq -er '.Require[] | select(.Path == "github.com/metacubex/utls") | .Version')"
    for module in "${modules[@]:1}"; do
        # A dependency's replace directives do not propagate. Go enjoys paperwork.
        (cd "$module" && go mod edit "-require=github.com/metacubex/utls@$utls")
    done
    for directory in "$ROOT/patches/"*/; do
        [[ -f "$directory/module" ]] || continue
        dependency_patches=("$directory"*.patch)
        ((${#dependency_patches[@]})) || fail 'Dependency has no patches'
        dependency="$(tr -d '\r\n' < "$directory/module")"
        [[ "$dependency" =~ ^[a-zA-Z0-9][a-zA-Z0-9._~/-]*$ ]] || fail 'Invalid dependency module'
        (cd "$core" && go mod download "$dependency")
        original="$(cd "$core" && go list -m -f '{{.Dir}}' "$dependency")"
        original="$(native_path "${original%$'\r'}")"
        local_dir="$core/.downstream-deps/$(basename "$directory")"
        [[ ! -e "$local_dir" ]] || fail 'Patched dependency directory already exists'
        mkdir -p "$core/.downstream-deps"
        cp -R "$original" "$local_dir"
        chmod -R u+w "$local_dir"
        relative="${local_dir#"$core/"}"
        for patch in "${dependency_patches[@]}"; do
            git -C "$core" apply --directory="$relative" --check "$patch"
            git -C "$core" apply --directory="$relative" "$patch"
        done
        for module in "${modules[@]}"; do
            relative="$(realpath --relative-to="$module" "$local_dir")"
            (cd "$module" && go mod edit "-replace=$dependency=./$relative")
        done
    done
    for module in "${modules[@]}"; do
        (cd "$module" && go mod tidy && go mod vendor)
    done
}

test_core() (
    local source_dir="$1" tags generic_tags
    tags="$(IFS=,; printf '%s' "${BUILD_TAGS[*]}")"
    generic_tags="${tags/,cmfa/}"
    cd "$source_dir/$CORE_PATH"
    export SKIP_CONCURRENT_TEST=1 SKIP_INTEROP_TEST=1
    go test -mod=mod github.com/metacubex/http/downstreamtests -count=1
    # CMFA bypasses IsSafePath. Testing that it also enforces it is rather optimistic.
    go test -mod=vendor -tags="$generic_tags" '-run=^TestPath$' -count=1 ./constant
    go test -mod=vendor -tags="$tags" '-skip=^TestPath$' -count=1 "${TEST_PACKAGES[@]}"
)

write_notice() {
    local source_dir="$1" ref="$2" app_sha="$3" core_sha="$4" dependencies="$5"
    local version_code="$6"
    local patch hashes='[]' hash path builder="$1/.downstream-builder" name
    printf '%s\n' "$core_sha" > "$source_dir/core/src/main/cpp/downstream-core-sha.txt"
    printf '%s\n' "$version_code" > "$source_dir/downstream-version-code.txt"
    while IFS= read -r -d '' patch; do
        hash="$(sha256sum "$patch")"
        hash="${hash%% *}"
        path="${patch#"$ROOT/"}"
        hashes="$(jq -cn --argjson entries "$hashes" --arg path "$path" --arg digest "$hash" \
            '$entries + [{key:$path,value:$digest}]')"
    done < <(find "$ROOT/patches" -type f -name '*.patch' -print0 | sort -z)
    jq -n --arg ref "$ref" --arg app_sha "$app_sha" --arg core_sha "$core_sha" \
        --argjson version_code "$version_code" \
        --arg modified_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" \
        --argjson dependencies "$dependencies" --argjson hashes "$hashes" \
        --args '{upstream_ref:$ref, upstream_commit:$app_sha, core_commit:$core_sha,
            version_code:$version_code,
            modified_at:$modified_at, build_tags:$ARGS.positional,
            dependencies_vendored:$dependencies, patches:($hashes | from_entries)}' \
        "${BUILD_TAGS[@]}" > "$source_dir/DOWNSTREAM.json"
    cat > "$source_dir/DOWNSTREAM.md" <<'EOF'
# Just CMFA Slim modification notice

Unofficial modified MetaCubeX/ClashMetaForAndroid and MetaCubeX/mihomo.
See DOWNSTREAM.json for exact revisions, date, build tags and patch checksums.

Optional protocols, debug HTTP, rule-bundle extraction and core self-update are
excluded. SOCKS5 destination resolution, least-connections balancing and the
fixes listed in the builder README are included.

Android TUN code and with_gvisor/cmfa tags are preserved. Router patch 0011 and
connections-count API patch 0012 are excluded. App/runtime versions carry a Slim
suffix. BundleMRS.7z is not downloaded. CMake reads the pinned core SHA without
Git history. Runtime patch files receive a terminal newline when missing.

Separate Just CMFA application IDs allow installation alongside official CMFA.
Launcher names and external-control actions use the downstream identity.
downstream-version-code.txt records the Android versionCode used by Gradle;
automatic codes count seconds since 2020-01-01 UTC, independently of upstream.

The patched HTTP dependency retains its license under .downstream-deps/http.
Each Go main module includes vendor in full builds. The corresponding builder,
patches and instructions are in .downstream-builder.
Original copyright, GPL-3.0 and third-party license notices remain in effect.
EOF
    mkdir "$builder"
    for name in scripts patches .github README.md LICENSE; do
        cp -R "$ROOT/$name" "$builder/$name"
    done
}

main() {
    local upstream_ref=Prerelease-alpha expected_sha='' expected_core_sha='' source_dir="$ROOT/output/source"
    local patches_only=false run_tests=false app_sha core_sha
    local version_code=''
    while (($#)); do
        case "$1" in
            --upstream-ref|--expected-sha|--expected-core-sha|--source-dir|--version-code)
                (($# >= 2)) && [[ -n "$2" ]] || fail "$1 requires a value"
                case "$1" in
                    --upstream-ref) upstream_ref="$2" ;;
                    --expected-sha) expected_sha="$2" ;;
                    --expected-core-sha) expected_core_sha="$2" ;;
                    --source-dir) source_dir="$2" ;;
                    --version-code) version_code="$2" ;;
                esac
                shift 2 ;;
            --patches-only) patches_only=true; shift ;;
            --test) run_tests=true; shift ;;
            -h|--help)
                printf '%s\n' 'Usage: bash scripts/prepare.sh [--upstream-ref REF] [--source-dir DIR]' \
                    '       [--expected-sha SHA] [--expected-core-sha SHA] [--patches-only | --test]' \
                    '       [--version-code CODE] (default: seconds since 2020-01-01 UTC)'
                return ;;
            *) fail "Unknown argument: $1" ;;
        esac
    done
    [[ "$patches_only:$run_tests" != true:true ]] || fail '--test requires dependency preparation'
    require_commands git jq realpath sha256sum
    if [[ -z "$version_code" ]]; then version_code="$(( $(date -u +%s) - 1577836800 ))"; fi
    [[ "$version_code" =~ ^[1-9][0-9]{0,9}$ ]] ||
        fail 'versionCode must be an integer between 1 and 2100000000'
    ((version_code <= 2100000000)) ||
        fail 'versionCode must be an integer between 1 and 2100000000'
    source_dir="$(realpath -m "$source_dir")"
    if [[ -e "$source_dir" ]]; then
        [[ -d "$source_dir" && -z "$(find "$source_dir" -mindepth 1 -maxdepth 1 -print -quit)" ]] ||
            fail 'Source directory must be empty; existing work is never overwritten'
    fi
    git clone --depth=1 --filter=blob:none --no-checkout --branch "$upstream_ref" \
        "https://github.com/$UPSTREAM_REPO.git" "$source_dir"
    git -C "$source_dir" sparse-checkout init --no-cone
    # Upstream's signing material is not an input to our build.
    printf '%s\n' '/*' '!*.keystore' '!*.jks' '!**/.env*' '!**/signing.properties' \
        '!**/local.properties' > "$source_dir/.git/info/sparse-checkout"
    git -C "$source_dir" checkout
    app_sha="$(git -C "$source_dir" rev-parse HEAD)"
    [[ -z "$expected_sha" || "$app_sha" == "$expected_sha" ]] || fail 'Upstream app ref moved; rerun detection'
    git -C "$source_dir" submodule update --init --depth=1 "$CORE_PATH"
    core_sha="$(git -C "$source_dir/$CORE_PATH" rev-parse HEAD)"
    [[ -z "$expected_core_sha" || "$core_sha" == "$expected_core_sha" ]] || fail 'Pinned core differs from detection'
    apply_patches "$source_dir"
    if [[ "$patches_only" == false ]]; then
        resolve_dependencies "$source_dir"
    fi
    write_notice "$source_dir" "$upstream_ref" "$app_sha" "$core_sha" \
        "$([[ "$patches_only" == false ]] && echo true || echo false)" "$version_code"
    if [[ "$run_tests" == true ]]; then test_core "$source_dir"; fi
    printf 'Prepared source: %s\n' "$source_dir"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
