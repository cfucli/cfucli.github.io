#!/usr/bin/env bash
# cfucli installer for macOS. Install and update are the same command:
#
#     curl -fsSL https://cfucli.github.io/install.sh | bash
#
# No administrator rights (no sudo), and nothing needs to be installed first - a private Java
# runtime is fetched into the cfucli folder if one is not already there. Everything lives under
# ~/cfucli:
#     versions/<version>/   cfucli.jar and cfucli-app.jar for that release
#     runtime/              the Java runtime cfucli runs on
#     bin/                  the cfucli and cfucliapp launchers, added to your PATH
# Each release goes into its own versions folder and the launchers are repointed, so a jar that is
# in use is never overwritten. Your settings.toml (the relay credentials) is never touched.
#
# The whole script is one function called on the last line, so a download cut off half way runs
# nothing at all rather than half an installer.
#
# CFUCLI_HOME overrides the folder, which is how this script is tested without touching a real
# install. CFUCLI_NO_PATH=1 leaves your shell profile alone. CFUCLI_RELEASE points at a different
# release folder (a local test server) instead of the latest GitHub release.

main() {
    set -euo pipefail

    local release="${CFUCLI_RELEASE:-https://github.com/cfucli/cfucli/releases/latest/download}"
    local home_="${CFUCLI_HOME:-$HOME/cfucli}"
    local bin="$home_/bin" runtime="$home_/runtime" versions="$home_/versions"

    say() { printf 'cfucli: %s\n' "$*"; }
    die() { printf 'cfucli: %s\n' "$*" >&2; exit 1; }

    # A flaky connection should cost a retry, not a half-installed tool.
    fetch() { curl -fsSL --retry 4 --retry-delay 2 --retry-all-errors -o "$2" "$1" || die "download failed: $1"; }

    sha256() { if command -v shasum >/dev/null; then shasum -a 256 "$1" | cut -d' ' -f1; else sha256sum "$1" | cut -d' ' -f1; fi; }

    local os arch appjar jre
    os="$(uname -s)"
    case "$os" in
        Darwin)
            # Ask the hardware, not the shell: a Terminal running under Rosetta reports x86_64 on
            # Apple Silicon, and would get the Intel build.
            if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = "1" ]; then arch=aarch64; appjar=cfucli-app-mac-aarch64.jar
            else arch=x64; appjar=cfucli-app-mac.jar; fi
            jre="https://api.adoptium.net/v3/binary/latest/25/ga/mac/$arch/jre/hotspot/normal/eclipse" ;;
        Linux) die "Linux is not packaged yet - build from https://github.com/cfucli/cfucli with: mvn -Plinux package" ;;
        *) die "unsupported system '$os' - on Windows use: irm https://cfucli.github.io/install.ps1 | iex" ;;
    esac

    mkdir -p "$bin" "$versions"
    local tmp; tmp="$(mktemp -d "$home_/.download-XXXXXX")"
    trap 'rm -rf "$tmp"' EXIT

    fetch "$release/version.txt" "$tmp/version.txt"
    local version; version="$(tr -d '[:space:]' < "$tmp/version.txt")"
    [[ "$version" =~ ^[0-9A-Za-z._-]+$ ]] || die "unexpected version string '$version'"
    local target="$versions/$version"

    if [ -f "$target/cfucli.jar" ]; then
        say "version $version is already installed - repointing the launchers only"
    else
        say "downloading version $version"
        fetch "$release/SHA256SUMS" "$tmp/SHA256SUMS"
        fetch "$release/cfucli.jar" "$tmp/cfucli.jar"
        fetch "$release/$appjar" "$tmp/cfucli-app.jar"
        local name local_name want got
        for pair in "cfucli.jar:cfucli.jar" "$appjar:cfucli-app.jar"; do
            name="${pair%%:*}"; local_name="${pair##*:}"
            want="$(awk -v f="$name" '{ n = $2; sub(/^\*/, "", n); if (n == f) print tolower($1) }' "$tmp/SHA256SUMS")"
            [ -n "$want" ] || die "SHA256SUMS has no entry for $name"
            got="$(sha256 "$tmp/$local_name")"
            [ "$want" = "$got" ] || die "$name failed its checksum - nothing was installed"
        done
        mkdir -p "$target"
        mv "$tmp/cfucli.jar" "$tmp/cfucli-app.jar" "$tmp/version.txt" "$target/"
        say "verified and unpacked into $target"
    fi

    local java
    java="$(find "$runtime" -path '*/bin/java' -type f 2>/dev/null | head -1 || true)"
    if [ -z "$java" ]; then
        say "downloading a Java 25 runtime (once; about 50 MB)"
        fetch "$jre" "$tmp/jre.tar.gz"
        mkdir -p "$tmp/jre"
        tar -xzf "$tmp/jre.tar.gz" -C "$tmp/jre"
        rm -rf "$runtime"
        mv "$tmp/jre/"* "$runtime"
        java="$(find "$runtime" -path '*/bin/java' -type f | head -1)"
        [ -n "$java" ] || die "the Java runtime archive did not contain bin/java"
    fi

    # Nodes still running the previous version would keep answering with the old code - a jar
    # replaced under a running node fails later with NoSuchMethodError, not at once.
    # Nodes keep their state under ~/cfucli whatever folder the jars went into - that is where
    # cfucli itself looks (user.home), not CFUCLI_HOME.
    local cli="$target/cfucli.jar" f node pid state="${CFUCLI_STATE:-$HOME/cfucli}"
    if [ -d "$state/run" ]; then
        for f in "$state"/run/node-*.json; do
            [ -e "$f" ] || continue
            node="$(basename "$f" .json)"; node="${node#node-}"
            pid="$(sed -n 's/.*"pid" *: *\([0-9][0-9]*\).*/\1/p' "$f")"
            # A port file outlives a node that was killed outright; only a live process is stopped.
            if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
                "$java" -jar "$cli" node stop --node "$node" >/dev/null 2>&1 || true
                say "stopped node '$node' so it restarts on the new version"
            fi
        done
    fi

    local vm="--enable-native-access=ALL-UNNAMED -Xlog:aot*=off -XX:+DisplayVMOutputToStderr"
    printf '#!/bin/sh\nexec "%s" %s -jar "%s" "$@"\n' "$java" "$vm" "$cli" > "$bin/cfucli"
    printf '#!/bin/sh\nexec "%s" --enable-native-access=ALL-UNNAMED -jar "%s" "$@"\n' "$java" "$target/cfucli-app.jar" > "$bin/cfucliapp"
    chmod +x "$bin/cfucli" "$bin/cfucliapp"

    # A real app bundle, so the window is in Spotlight and Launchpad and can be kept in the Dock,
    # plus a link to it on the Desktop. Rebuilt on every run, so it always opens the version just
    # installed. Made here rather than downloaded, so it carries no quarantine flag and Gatekeeper
    # has nothing to ask about. The icon is built from the site's PNG with sips and iconutil, which
    # ship with macOS; without it the app still works, with a generic icon.
    local apps="$HOME/Applications" desk="$HOME/Desktop"
    if [ "${CFUCLI_NO_PATH:-}" = "1" ]; then apps="$home_/shortcuts"; desk="$home_/shortcuts"; fi   # tests leave the real ones alone
    local app="$apps/cfucli.app"
    rm -rf "$app"; mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
    cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>cfucli</string>
  <key>CFBundleDisplayName</key><string>cfucli</string>
  <key>CFBundleIdentifier</key><string>io.github.cfucli.app</string>
  <key>CFBundleVersion</key><string>$version</string>
  <key>CFBundleShortVersionString</key><string>$version</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>cfucli</string>
  <key>CFBundleIconFile</key><string>cfucli</string>
  <key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
    local icns="$app/Contents/Resources/cfucli.icns" dockicon=""
    if command -v sips >/dev/null && command -v iconutil >/dev/null; then
        local set="$tmp/cfucli.iconset" s
        mkdir -p "$set"
        if curl -fsSL --retry 3 -o "$tmp/icon.png" "https://cfucli.github.io/assets/cfucli-512.png" 2>/dev/null; then
            for s in 16 32 128 256 512; do
                sips -z $s $s "$tmp/icon.png" --out "$set/icon_${s}x${s}.png" >/dev/null 2>&1 || true
                sips -z $((s*2)) $((s*2)) "$tmp/icon.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null 2>&1 || true
            done
            if iconutil -c icns "$set" -o "$icns" 2>/dev/null; then
                # A copy outside the bundle, where cfucli itself looks when it starts the window
                # (cfucli console), so the Dock shows the logo however the window was opened.
                cp "$icns" "$home_/cfucli.icns"
                dockicon="-Xdock:icon=$home_/cfucli.icns"
            fi
        fi
    fi
    printf '#!/bin/sh\nexec "%s" --enable-native-access=ALL-UNNAMED -Xdock:name=cfucli %s -jar "%s" "$@"\n' \
        "$java" "$dockicon" "$target/cfucli-app.jar" > "$bin/cfucliapp"
    printf '#!/bin/sh\nexec "%s" --enable-native-access=ALL-UNNAMED -Xdock:name=cfucli %s -jar "%s" "$@"\n' \
        "$java" "$dockicon" "$target/cfucli-app.jar" > "$app/Contents/MacOS/cfucli"
    chmod +x "$app/Contents/MacOS/cfucli"
    touch "$app"   # Finder caches bundle icons; a new mtime makes it look again
    mkdir -p "$desk"; ln -sfn "$app" "$desk/cfucli"
    say "cfucli.app in $apps, and on the Desktop"

    if [ "${CFUCLI_NO_PATH:-}" != "1" ]; then
        # FIRST on the PATH, so this install wins over any older copy without deleting anything -
        # nothing this script did not create is ever removed or edited.
        local line="export PATH=\"$bin:\$PATH\"" rc
        case "${SHELL:-}" in */bash) rc="$HOME/.bash_profile" ;; *) rc="$HOME/.zprofile" ;; esac
        if ! grep -qsF "$bin" "$rc"; then
            printf '\n# cfucli\n%s\n' "$line" >> "$rc"
            say "added $bin to your PATH in $rc - open a new terminal, or run:  $line"
        fi
        # Other copies that are now shadowed: named, never deleted.
        local others; others="$(PATH="$bin:$PATH" which -a cfucli 2>/dev/null | grep -vF "$bin/" | sort -u || true)"
        if [ -n "$others" ]; then
            echo
            echo "  Other copies of cfucli on your PATH, now shadowed by this one (safe to delete if they are old installs):"
            echo "$others" | sed 's/^/    /'
        fi
    fi

    # Keep the current version and the one before it.
    ls -1t "$versions" | tail -n +3 | while read -r old; do rm -rf "${versions:?}/$old"; done

    say "installed $version"
    echo
    echo "  First time on this machine? Two things, once:"
    echo "    cfucli relay set --from <the relay file you were sent>"
    echo "    cfucli available on --as <your name>"
    echo
    echo "  To update later, run the same install line again, or:  cfucli update"
}

main "$@"
