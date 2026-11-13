# Just CMFA Slim

An unofficial slim build of [Clash Meta for Android](https://github.com/MetaCubeX/ClashMetaForAndroid)
with patches from [JustClash Core Slim](https://github.com/SaltyMonkey/justclash-core-slim).
This repository contains build scripts and patches; the app and embedded mihomo
sources are downloaded during preparation. This project is not affiliated with
MetaCubeX and is not an official CMFA release.

## Differences from JustClash Core Slim

- **TUN patches are excluded.** Android VPN, upstream TUN stack selection,
  gVisor, and the `foss,with_gvisor,cmfa` tags are preserved in both Android flavors.
- **Patch `0012` is excluded:** the additional `/connections/count` API is absent.
- The core comes from the submodule pinned by the selected CMFA revision.
  The builder does not independently update mihomo's `Alpha` branch; tracking two
  moving upstreams independently would make JNI compatibility unnecessarily exciting.
- Router CI patches `0001` and `0015` are replaced with Android build workflows.
  Temporary branches, source mirroring, and `BUILDER_TOKEN` are unnecessary.
- The JNI bridge reads the saved core SHA, so CMake does not require Git history
  when building from an extracted source archive.

## Differences from upstream CMFA

EasyTier, Tailscale, ZeroTier, TrustTunnel, Hysteria 1, ShadowQUIC, OpenVPN,
ShadowsocksR, HTTP `/debug`, core self-updates through the API, and extraction of
`BundleMRS.7z` are disabled. The bundle archive is also excluded from APK downloads.
Regular rule providers, including individual MRS files, remain supported.
Hysteria 2, Shadowsocks, and Snell are retained. Android VPN and its native code
are unchanged.

Providers skip nodes using disabled protocols and log a warning. An update with
no usable nodes fails and preserves the previous list. An explicitly configured
unsupported outbound remains a configuration error.

Other changes, including patches from [JustClash Core Slim](https://github.com/SaltyMonkey/justclash-core-slim):

- SOCKS5 supports `resolve-destination: true` for local TCP destination resolution.
- `load-balance` groups support `strategy: least-connections`.
- Atomic fake IP persistence and fixes for URL-test and XHTTP.
- Fallback groups select the first alive proxy when the saved selection is absent,
  while preserving that selection for when its provider returns.
- The correct `custom-certificates` configuration key.
- HTTP controller limits, a correct initial `/memory` response, and cancellation
  of delay checks when their API requests are cancelled.
- Cleanup of idle TPROXY UDP sockets and termination of retries when local socket
  resources are exhausted.
- A 32 KiB limit on temporary HTTP/2 send buffers in both HTTP client implementations.
  The dependency replacement is applied to all three CMFA Go modules.
- Closed HTTP/2 connections stop their idle and health-check timers so those timers
  do not retain connection buffers.
- Fewer temporary allocations when decoding MRS domain/IP rules and
  single-threaded zstd decoding.

Patch numbering is preserved for comparison with the reference project.
Its `patches/unfinished` directory and benchmarks are excluded; patch `0026`
retains the benchmarks from its pinned upstream PR.
Application and core versions receive a Slim suffix.

As in upstream CMFA, the core is a pinned revision from mihomo's `Alpha` branch.
Both app flavors use that submodule. Stable builds select a stable CMFA release
and its pinned core; they do not switch to a separate stable mihomo release.
The core revision can therefore differ between the latest Alpha app and an older
Stable app.

### Installation alongside official CMFA

The application IDs are `com.github.just.clash.alpha` for Alpha and
`com.github.just.clash.meta` for Stable. Launcher names are `Just CMFA Slim Alpha`
and `Just CMFA Slim`; full application names are
`Just Clash Meta for Android Slim Alpha` and `Just Clash Meta for Android Slim`.
Both variants can be installed alongside official CMFA. Each installation has
separate profiles and settings; use export/import to transfer configuration.
Sign all updates to your build with the same permanent key.

Providers, internal permissions, and control commands use the new `applicationId`.
The Alpha start action is `com.github.just.clash.alpha.action.START_CLASH`;
the Stable action is `com.github.just.clash.meta.action.START_CLASH`.
Stop and toggle actions use the same full names with `STOP_CLASH` and
`TOGGLE_CLASH` endings. Actions are written explicitly in each flavor's manifest,
without substitutions. The activity class remains
`com.github.kr328.clash.ExternalControlActivity`.
Import links using `clash://` and `clashmeta://` are preserved; Android may offer
an app chooser when several clients are installed. Only one Android VPN can be
active per user profile at a time.

### Versioning

The displayed version follows upstream and includes a Slim suffix.
The separate `versionCode` is the number of seconds since
`2020-01-01 00:00:00 UTC` when source preparation starts. Later builds therefore
receive higher codes, including reruns against unchanged upstream sources.
Renaming workflows or resetting run numbers does not reset this code.
CI runs for each channel are serialized; Alpha and Stable have separate app IDs.
The value is recorded in `downstream-version-code.txt`, `DOWNSTREAM.json`, and
release notes. Recompiling an already prepared source tree preserves its code.

## GitHub Actions builds

1. Push this repository to your own GitHub repository with `main` as its primary branch.
2. Add four Actions secrets for **your own permanent signing key**:

   | Secret | Purpose |
   | --- | --- |
   | `CMFA_KEYSTORE_BASE64` | Base64-encoded keystore |
   | `CMFA_STORE_PASSWORD` | Keystore password |
   | `CMFA_KEY_ALIAS` | Key alias |
   | `CMFA_KEY_PASSWORD` | Key password |

3. Run **Sync upstream builds** and select `both`, `alpha`, or `stable`.
   Enable `force` to rebuild unchanged revisions.

Do not send secrets in chat or commit them to Git. The upstream keystore is not
used. Signing material is written after source archiving, is not printed to logs,
and is removed after the build. Publishing requires all four secrets.
Keep a backup of your signing key and reuse it for APK updates.

Upstream is checked daily at 01:00 UTC (04:00 Moscow time):

- Alpha follows CMFA's `Prerelease-alpha` tag and is published under `Prerelease-alpha`.
  Changes to `main` alone do not trigger an Alpha rebuild; the tracked upstream
  revision changes when that tag moves.
- Stable follows the latest stable CMFA release and is published as `<upstream-tag>-slim`.
- Application, pinned core, and builder revisions are compared. Patch changes also
  trigger a rebuild at the next check.
- Expected SHAs are checked before patches are applied. If an upstream ref moves
  between detection and cloning, the build stops.
- Tests for core packages affected by patches run first. Gradle then builds and
  signs APKs using CMFA's standard process. Publishing follows a successful build.

The workflow uses Java 21 and Go 1.26 from MetaCubeX's Android-compatible fork,
with CMFA's upstream Go runtime patches. Gradle Wrapper, AGP, Kotlin, Android SDK,
NDK, Build Tools, and CMake follow the selected upstream CMFA configuration.
The currently tracked configuration uses Gradle 8.10.2, AGP 8.8.0, Kotlin 2.1.0,
SDK 35, and NDK `29.0.14206865`. Builds use the standard Android environment on
`ubuntu-latest`, as upstream does; Gradle obtains missing SDK components.
There are no separate `setup-android`/`sdkmanager` steps, Build Tools/CMake
overrides, or calls to a separately pinned `apksigner`.
Go dependencies are resolved through modules, as in upstream. APK compilation
and our core tests use no vendoring or `GOFLAGS` override. Dependencies follow
`go.mod` and `go.sum` through the module cache; missing dependencies require
network access.
The Go runtime patches come from upstream CMFA and do not restrict TUN.
An upstream change incompatible with the patches or tools fails CI instead of
silently skipping changes.

The original `constant.TestPath` runs separately without the `cmfa` tag:
Android mode deliberately bypasses the path restriction that this test expects.
All tests in the 19 patched packages of the main core module run with the full
Android/Slim tag set, including both upstream tests and tests added by patches.
The package list is `TEST_PACKAGES` in `scripts/common.sh`; update it when adding
a patch affecting another package. The HTTP/2 patch has a separate test command.
As in [JustClash Core Slim](https://github.com/SaltyMonkey/justclash-core-slim),
tests use `SKIP_CONCURRENT_TEST=1`, `SKIP_INTEROP_TEST=1`, and `-count=1`.

Each release contains APKs for `arm64-v8a`, `armeabi-v7a`, `x86`, `x86_64`, and
universal, plus `checksums.txt`, `build-info.json`, licenses, and
`custom-cmfa-source.tar.gz`. The source archive includes the modified app,
embedded core, patched HTTP dependency, Go module manifests, and a builder copy
in `.downstream-builder`. Other Go dependencies are downloaded during preparation
and are not bundled in the archive. CA certificates are updated before archiving.
GEO data is downloaded by CMFA's original Gradle task.
Workflows inside the downloaded CMFA source do not run automatically.

## Local preparation and checks

Patch checks require Bash 4+, Git, `jq`, and standard GNU utilities
(`find`, `realpath`, `sha256sum`, `tar`). Python is not used.
These tools are available on Ubuntu GitHub Actions runners. On Windows, use
Git Bash with `jq` installed in `PATH`.
Release operations also require `gh`; signing requires `base64` and `iconv`.

```sh
bash scripts/prepare.sh --upstream-ref Prerelease-alpha --patches-only
```

Prepare sources, resolve dependencies, and run core tests:

```sh
bash scripts/prepare.sh --upstream-ref v2.11.36 --source-dir output/stable --test
```

To reproduce a particular build's version code, pass `--version-code <number>`
using the value in its `build-info.json`. The allowed range is `1`–`2100000000`.
Keep automatic versioning for ordinary new releases; manually assigning a higher
code may prevent subsequent updates from installing.

The destination directory must be empty. Prepared sources remain available for
inspection; the script does not overwrite existing work or publish anything.
The builder does not search for or read local `.env` files, authentication
configuration, or keys. Patch application can be checked on Windows; full APK
builds are configured for Linux GitHub Actions. See `.github/workflows/build.yml`
for the SDK, Go runtime patching, archiving, and compilation sequence.

## License and attribution

CMFA, mihomo, and this modification are distributed under [GPL-3.0](LICENSE).
Original licenses and notices are preserved. Modifications are documented in
`DOWNSTREAM.md` and `DOWNSTREAM.json` inside the source archive.
Third-party components retain their own licenses and attribution.
Patches from [JustClash Core Slim](https://github.com/SaltyMonkey/justclash-core-slim)
include work by mihomo contributors, [Citrus](https://github.com/getmikan/Citrus),
and [prizrak-http](https://github.com/legiz-ru/prizrak-http); source references are
preserved in the corresponding patches. No exclusive authorship is claimed.
