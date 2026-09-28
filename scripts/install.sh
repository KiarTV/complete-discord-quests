#!/usr/bin/env bash
# Discord Quest Game Mirror - macOS installer/launcher.
#
#   curl -fsSL https://raw.githubusercontent.com/KiarTV/Discord-Quest/master/scripts/install.sh | bash
#
# Fully self-contained - no Homebrew, no sudo, nothing installed
# system-wide. If `pwsh` isn't already on PATH, this downloads Microsoft's
# official portable PowerShell build straight from its GitHub releases
# (verified against the release's published SHA-256 checksum) into
# ~/Library/Caches/quest-mirror/pwsh/<version>/ and runs it from there.
# That download only ever happens once - later runs reuse the cached pwsh
# (delete the pwsh/ subfolder to force a fresh version) and just
# re-download mirror.ps1 itself, so this also acts as an update command
# for the tool.
#
# Arguments pass through to mirror.ps1 via `bash -s -- <args>`, e.g.:
#   curl -fsSL .../install.sh | bash -s -- -GameName "Roblox"
#
# All status/log output below goes to stderr, on purpose: this script is
# meant to be piped straight into `bash`, but if someone instead pastes it
# wrapped in backticks or $(...) (easy to do by accident), stdout gets
# captured and re-run as a command. Keeping stdout empty until the final
# `exec pwsh` means that mistake fails quietly instead of surfacing a
# second, misleading "command not found" error on top of the real one.

set -euo pipefail

MIRROR_URL="https://raw.githubusercontent.com/KiarTV/Discord-Quest/master/mirror.ps1"
CACHE_DIR="$HOME/Library/Caches/quest-mirror"
MIRROR_SCRIPT="$CACHE_DIR/mirror.ps1"

# Known-good pwsh release to fall back to if resolving "latest" below fails
# for any reason (network hiccup, GitHub format change, etc.) - bump this
# occasionally, but it doesn't need to track every release.
PWSH_FALLBACK_VERSION="7.6.4"

if [[ "$(uname -s)" != "Darwin" ]]; then
    echo "This installer is for macOS. On Windows, run mirror.ps1 directly - see the README." >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Locate pwsh: already on PATH, already downloaded by a previous run, or
# needs fetching now.
# ---------------------------------------------------------------------------

PWSH_BIN=""
if command -v pwsh >/dev/null 2>&1; then
    PWSH_BIN="$(command -v pwsh)"
elif [[ -d "$CACHE_DIR/pwsh" ]]; then
    # `|| true` on every lookup pipeline below: under `set -e -o pipefail`,
    # a pipeline stage that merely finds nothing (grep exit 1) or a sort
    # without -V support on an older macOS would abort the whole script
    # silently instead of taking the fallback path.
    candidate=$(find "$CACHE_DIR/pwsh" -maxdepth 2 -type f -name pwsh 2>/dev/null | sort -V | tail -1 || true)
    if [[ -n "$candidate" ]]; then
        chmod +x "$candidate" 2>/dev/null || true
        PWSH_BIN="$candidate"
    fi
fi

if [[ -z "$PWSH_BIN" ]]; then
    case "$(uname -m)" in
        arm64)  PWSH_ARCH="osx-arm64" ;;
        x86_64) PWSH_ARCH="osx-x64" ;;
        *)
            echo "Unsupported Mac architecture: $(uname -m)" >&2
            exit 1
            ;;
    esac

    # Resolve the newest release tag via GitHub's redirect for /releases/latest
    # (a plain redirect, not the rate-limited API) - fall back to the pinned
    # version above if this fails for any reason.
    PWSH_VERSION="$PWSH_FALLBACK_VERSION"
    resolved_url=$(curl -fsSLI --max-time 10 -o /dev/null -w '%{url_effective}' \
        "https://github.com/PowerShell/PowerShell/releases/latest" 2>/dev/null || true)
    resolved_tag=$(echo "$resolved_url" | grep -oE 'tag/v[0-9]+\.[0-9]+\.[0-9]+' | sed 's#tag/v##' || true)
    if [[ -n "$resolved_tag" ]]; then
        PWSH_VERSION="$resolved_tag"
    fi

    RELEASE_BASE="https://github.com/PowerShell/PowerShell/releases/download/v$PWSH_VERSION"
    ASSET="powershell-$PWSH_VERSION-$PWSH_ARCH.tar.gz"
    PWSH_DIR="$CACHE_DIR/pwsh/$PWSH_VERSION"
    WORK_DIR=$(mktemp -d)
    trap 'rm -rf "$WORK_DIR"' EXIT

    echo "PowerShell not found - downloading the portable pwsh $PWSH_VERSION build for macOS ($PWSH_ARCH, ~70MB, one-time)..." >&2
    curl -fL --connect-timeout 10 --progress-bar -o "$WORK_DIR/$ASSET" "$RELEASE_BASE/$ASSET"

    echo "Verifying checksum..." >&2
    curl -fsSL --max-time 15 -o "$WORK_DIR/hashes.sha256" "$RELEASE_BASE/hashes.sha256"
    # Microsoft publishes this file as UTF-16LE (Windows default) - convert
    # before grepping it, or every line just looks empty to grep/awk.
    expected=$(iconv -f UTF-16LE -t UTF-8 "$WORK_DIR/hashes.sha256" 2>/dev/null |
        grep -F "$ASSET" | awk '{print $1}' | tr -d '\r' || true)
    actual=$(shasum -a 256 "$WORK_DIR/$ASSET" | awk '{print $1}')
    if [[ -z "$expected" || "$expected" != "$actual" ]]; then
        echo "Checksum verification failed for $ASSET (expected '$expected', got '$actual') - aborting." >&2
        exit 1
    fi

    mkdir -p "$PWSH_DIR"
    tar -xzf "$WORK_DIR/$ASSET" -C "$PWSH_DIR"
    chmod +x "$PWSH_DIR/pwsh"
    rm -rf "$WORK_DIR"
    trap - EXIT

    PWSH_BIN="$PWSH_DIR/pwsh"
fi

# ---------------------------------------------------------------------------
# Fetch and run mirror.ps1
# ---------------------------------------------------------------------------

mkdir -p "$CACHE_DIR"
echo "Fetching mirror.ps1..." >&2
curl -fsSL --max-time 15 "$MIRROR_URL" -o "$MIRROR_SCRIPT"

exec "$PWSH_BIN" -NoProfile -File "$MIRROR_SCRIPT" "$@"
