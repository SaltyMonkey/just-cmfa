#!/usr/bin/env bash
set -euo pipefail

source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

detect() {
    local selected="${CHANNEL:-both}" force="${FORCE:-false}" builder_sha stable=''
    local channel ref tag sha core_sha body matrix='[]' release_json
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}" "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
    [[ "$selected" == both || "$selected" == alpha || "$selected" == stable ]] || fail 'Invalid detection channel'
    builder_sha="$(git -C "$ROOT" rev-parse HEAD)"
    if [[ "$selected" != alpha ]]; then
        stable="$(gh api "repos/$UPSTREAM_REPO/releases/latest" --jq '.tag_name')"
    fi
    for channel in alpha stable; do
        [[ "$selected" == both || "$selected" == "$channel" ]] || continue
        ref=Prerelease-alpha tag=Prerelease-alpha
        if [[ "$channel" == stable ]]; then ref="$stable"; tag="$stable-slim"; fi
        sha="$(gh api "repos/$UPSTREAM_REPO/commits/$ref" --jq '.sha')"
        core_sha="$(gh api "repos/$UPSTREAM_REPO/contents/$CORE_PATH?ref=$sha" --jq '.sha')"
        body=''
        if release_json="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json body 2>/dev/null)"; then
            body="$(jq -r '.body' <<< "$release_json")"
        else
            # A failed connection is not proof that a release does not exist.
            gh api "repos/$GITHUB_REPOSITORY/releases?per_page=1" >/dev/null
        fi
        if [[ "$force" == true ]] ||
            ! grep -Fxq -- "- Upstream commit: $sha" <<< "$body" ||
            ! grep -Fxq -- "- Core commit: $core_sha" <<< "$body" ||
            ! grep -Fxq -- "- Builder commit: $builder_sha" <<< "$body"; then
            matrix="$(jq -cn --argjson entries "$matrix" --arg channel "$channel" --arg ref "$ref" \
                --arg sha "$sha" --arg core_sha "$core_sha" --arg tag "$tag" \
                '$entries + [{channel:$channel,ref:$ref,sha:$sha,core_sha:$core_sha,tag:$tag}]')"
        fi
    done
    printf 'matrix=%s\nchanged=%s\n' "$(jq -cn --argjson entries "$matrix" '{include:$entries}')" \
        "$(jq -r 'length > 0' <<< "$matrix")" >> "$GITHUB_OUTPUT"
    printf 'Build channels: %s\n' "$(jq -r 'if length == 0 then "up to date" else map(.channel) | join(", ") end' <<< "$matrix")"
}

source_entries() {
    find . \( -name .git -o -name .gradle -o -name .cxx -o -name __pycache__ \
        -o -name '.env*' -o -name '*.keystore' -o -name '*.jks' -o -name '*.log' -o -name '*.pyc' \
        -o -name signing.properties -o -name local.properties -o -name key.properties \
        -o -name .downstream-signing-created \
        -o \( -name build ! -path '*/vendor/*' ! -path '*/.downstream-deps/*' \) \) \
        -prune -o "$@"
}

archive_source() (
    local source_dir output_dir list
    source_dir="$(realpath "$1")"
    output_dir="$(realpath -m "$2")"
    case "$output_dir/" in "$source_dir/"*) fail 'Release output must be outside the source tree' ;; esac
    jq -e '.dependencies_vendored == true' "$source_dir/DOWNSTREAM.json" >/dev/null ||
        fail 'Source archives require vendored dependencies'
    mkdir -p "$output_dir"
    cd "$source_dir"
    [[ -z "$(source_entries -type l -print -quit)" ]] || fail 'Unexpected link in source archive'
    list="$(mktemp "$output_dir/.source-files.XXXXXX")"
    trap 'rm -f -- "$list"' EXIT
    source_entries -print0 | sort -z > "$list"
    tar --create --gzip --file="$output_dir/custom-cmfa-source.tar.gz" \
        --no-recursion --transform='s,^\.,source,' --null --files-from="$list"
    cp DOWNSTREAM.json "$output_dir/build-info.json"
    cp LICENSE "$output_dir/LICENSE"
    if [[ -f NOTICE ]]; then cp NOTICE "$output_dir/NOTICE"; fi
)

collect() {
    local source_dir="$1" output_dir="$2" channel="$3" flavor abi path sha
    local -a apks matches
    validate_channel "$channel"
    [[ -f "$output_dir/custom-cmfa-source.tar.gz" ]] || fail 'Corresponding source archive is missing'
    flavor=alpha
    [[ "$channel" != stable ]] || flavor=meta
    shopt -s nullglob
    apks=("$source_dir/app/build/outputs/apk/$flavor/release/"*.apk)
    ((${#apks[@]} == ${#ABIS[@]})) || fail 'Expected four ABI APKs and one universal APK'
    sha="$(jq -er '.upstream_commit' "$source_dir/DOWNSTREAM.json")"
    for abi in "${ABIS[@]}"; do
        matches=()
        for path in "${apks[@]}"; do
            [[ "$(basename "$path")" != *"-$abi-"* ]] || matches+=("$path")
        done
        ((${#matches[@]} == 1)) || fail "Missing or ambiguous APK for $abi"
        cp "${matches[0]}" "$output_dir/just-cmfa-$channel-${sha:0:7}-$abi.apk"
    done
    # checksums.txt is explicitly excluded from the input list.
    (cd "$output_dir" && find . -maxdepth 1 -type f ! -name checksums.txt -printf '%P\0' |
        sort -z | xargs -0 sha256sum > checksums.txt)
}

publish() {
    local source_dir="$1" output_dir="$2" channel="$3" tag="$4"
    local builder_sha notes asset name asset_names
    local -a assets options=()
    validate_channel "$channel"
    : "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"
    builder_sha="$(git -C "$ROOT" rev-parse HEAD)"
    notes="$(dirname "$output_dir")/release-notes.md"
    {
        printf 'Unofficial Just CMFA Slim build.\n\n'
        jq -r '"- Upstream ref: " + .upstream_ref,
            "- Upstream commit: " + .upstream_commit, "- Core commit: " + .core_commit,
            "- Android versionCode: " + (.version_code | tostring)' "$source_dir/DOWNSTREAM.json"
        printf '%s\n\n' "- Builder commit: $builder_sha"
        cat <<'EOF'
Android TUN and gVisor are preserved. TUN restrictions and patch 0012
(connections-count API) are excluded.

Optional protocols, HTTP debug, rule-bundle extraction and core self-update
are disabled. SOCKS5 destination resolution, least-connections balancing and
fixes from JustClash Core Slim are included. See the builder README and
build-info.json for the complete profile.

APKs: four ABIs and universal. custom-cmfa-source.tar.gz contains the patched
app, embedded core, vendored Go dependencies and builder. Original licenses
and attribution are retained.
EOF
    } > "$notes"
    [[ "$channel" != alpha ]] || options=(--prerelease --latest=false)
    shopt -s nullglob
    assets=("$output_dir/"*)
    ((${#assets[@]})) || fail 'No release assets'
    if gh release view "$tag" --repo "$GITHUB_REPOSITORY" >/dev/null 2>&1; then
        gh release upload "$tag" "${assets[@]}" --repo "$GITHUB_REPOSITORY" --clobber
        asset_names="$(gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets --jq '.assets[].name')"
        while IFS= read -r name; do
            [[ -n "$name" && ! -f "$output_dir/$name" ]] || continue
            gh release delete-asset "$tag" "$name" --repo "$GITHUB_REPOSITORY" --yes
        done <<< "$asset_names"
        gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/tags/$tag" \
            -f "sha=$builder_sha" -F force=true >/dev/null
        gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --title "$tag" --notes-file "$notes" "${options[@]}"
    else
        # Verify connectivity before deciding to create a new release.
        gh api "repos/$GITHUB_REPOSITORY/releases?per_page=1" >/dev/null
        for asset in "${assets[@]}"; do [[ -f "$asset" ]] || fail 'Unexpected release directory'; done
        gh release create "$tag" "${assets[@]}" --repo "$GITHUB_REPOSITORY" \
            --target "$builder_sha" --title "$tag" --notes-file "$notes" "${options[@]}"
    fi
}

main() {
    local command_name="${1:-}" source_dir="$ROOT/output/source" output_dir="$ROOT/output/release"
    local channel=alpha tag=''
    [[ -n "$command_name" ]] || fail 'Usage: bash scripts/ci.sh detect|archive|collect|publish [options]'
    shift
    while (($#)); do
        (($# >= 2)) && [[ -n "$2" ]] || fail "$1 requires a value"
        case "$1" in
            --source-dir) source_dir="$2" ;;
            --output-dir) output_dir="$2" ;;
            --channel) channel="$2" ;;
            --tag) tag="$2" ;;
            *) fail "Unknown argument: $1" ;;
        esac
        shift 2
    done
    require_commands jq
    case "$command_name" in
        detect) require_commands gh git; detect ;;
        archive) require_commands tar realpath; archive_source "$source_dir" "$output_dir" ;;
        collect) collect "$source_dir" "$output_dir" "$channel" ;;
        publish)
            require_commands gh git
            [[ -n "$tag" ]] || fail 'publish requires --tag'
            publish "$source_dir" "$output_dir" "$channel" "$tag" ;;
        *) fail 'Command must be detect, archive, collect or publish' ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
