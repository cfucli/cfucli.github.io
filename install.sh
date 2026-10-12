#!/usr/bin/env bash
# cfucli installer for macOS, kept for the copies that still call it. Since 0.5 cfucli installs
# itself, and the line to give people is the one on https://cfucli.github.io:
#
#     curl -fLo /tmp/cfucli https://github.com/cfucli/cfucli/releases/latest/download/cfucli-macos-$(uname -m) && chmod +x /tmp/cfucli && /tmp/cfucli install
#
# This script stays because `cfucli update` in 0.4.x runs `curl -fsSL https://cfucli.github.io/install.sh | bash`.
# It does what the line above does: it downloads the cfucli binary for this Mac, checks it against
# the release's SHA256SUMS, and runs its own `install`. That puts cfucli.app in ~/Applications and
# the cfucli command in ~/.local/bin, and takes away what 0.4 left (its launcher script and app,
# ~/cfucli/versions and ~/cfucli/runtime). From then on `cfucli update` replaces the binary itself.
# Your settings.toml (the relay credentials) is never touched.
#
# Until 0.4 this script built the install itself: a jar per version under ~/cfucli/versions, a
# private Java runtime, a launcher script. That copy ran the jar with plain java, where 0.5's
# `cfucli update` cannot work, so it is gone.
#
# The whole script is one function called on the last line, so a download cut off half way runs
# nothing at all rather than half an installer. CFUCLI_RELEASE points at a different release
# folder (a test) instead of the latest GitHub release.

main() {
    set -euo pipefail

    local release="${CFUCLI_RELEASE:-https://github.com/cfucli/cfucli/releases/latest/download}"

    say() { printf 'cfucli: %s\n' "$*"; }
    die() { printf 'cfucli: %s\n' "$*" >&2; exit 1; }

    # A flaky connection should cost a retry, not a half-installed tool.
    fetch() { curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors -o "$2" "$1" || die "download failed: $1"; }

    local os arch name
    os="$(uname -s)"
    case "$os" in
        Darwin)
            # Ask the hardware, not the shell: a Terminal running under Rosetta reports x86_64 on
            # Apple silicon, and would get the Intel build.
            if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then arch=arm64; else arch=x86_64; fi
            name="cfucli-macos-$arch" ;;
        Linux) die "Linux is not packaged yet - build from https://github.com/cfucli/cfucli with: mvn -Plinux package" ;;
        *) die "unsupported system '$os' - on Windows see https://cfucli.github.io" ;;
    esac

    local tmp; tmp="$(mktemp -d "${TMPDIR:-/tmp}/cfucli-install-XXXXXX")"
    # The path is put into the trap now, not looked up at exit: tmp is local to main, which has
    # returned by then, and under set -u reading it fails and leaves the download folder behind.
    trap "rm -rf '$tmp'" EXIT

    fetch "$release/version.txt" "$tmp/version.txt"
    local version; version="$(tr -d '[:space:]' < "$tmp/version.txt")"
    [[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || die "unexpected version string '$version'"
    say "downloading version $version for $arch"
    fetch "$release/SHA256SUMS" "$tmp/SHA256SUMS"
    fetch "$release/$name" "$tmp/cfucli"
    local want got
    want="$(awk -v f="$name" '{ n = $2; sub(/^\*/, "", n); if (n == f) print tolower($1) }' "$tmp/SHA256SUMS")"
    [ -n "$want" ] || die "SHA256SUMS has no entry for $name"
    got="$(shasum -a 256 "$tmp/cfucli" | cut -d' ' -f1)"
    [ "$want" = "$got" ] || die "$name failed its checksum - nothing was installed"
    chmod +x "$tmp/cfucli"

    # -Xjr:yes: jr fetches the jar (and a Java runtime if there is none) without stopping to ask.
    # stdin from /dev/null: this script is often itself read from a pipe, which nothing may consume.
    say "verified - installing (the first run fetches the cfucli jar, and Java if needed)"
    "$tmp/cfucli" -Xjr:yes install < /dev/null
}

main "$@"
