# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A PowerShell tool that tricks Discord's local Quest detection into seeing a
game as "running." Discord Quests only check whether a process with a
specific executable filename exists — this script copies a harmless system
binary to a working folder, renames it to match that filename, and runs it
for ~17.5 minutes. It only affects what the local Discord client detects; no
network/account tampering, no actual game files downloaded. Runs on both
Windows and macOS (`pwsh` required on macOS — see README).

There is no package manifest or test suite. `build.ps1` is the only
"tooling" — a source bundler, not a build system in the compiled-language
sense. GitHub Actions wraps it: `.github/workflows/ci.yml` fails any push
where the committed `mirror.ps1` doesn't match a fresh `build.ps1` run, and
`.github/workflows/release.yml` publishes a GitHub Release when a `v*` tag
is pushed. The tag must equal `v` + `$Version` from `Main.Params.ps1`, so
bump that first. The release attaches `QuestMirror-windows.zip` (`mirror.ps1`
+ `scripts/QuestMirror.cmd`, a double-click launcher) plus the raw
`mirror.ps1`/`install.sh`. `docs/demo.svg` is the README's animated terminal
demo. It's a hand-generated CSS-animated SVG replaying real tool output, so
regenerate it if the tool's output format changes noticeably.

## Repository layout — source vs. generated

**`mirror.ps1` at the repo root is a generated file.** It's what the
README's `irm | iex` one-liners fetch and run, and it must stay a single
file for that zero-install workflow to work. The real source lives under
`src/`, split by concern. **Never hand-edit `mirror.ps1` directly** — edit
the matching file under `src/` and run `.\build.ps1` to regenerate it, then
commit both.

```
scripts/install.sh            # macOS entrypoint (curl | bash) - hand-maintained, not build.ps1 output
scripts/QuestMirror.cmd       # Windows double-click launcher shipped in the release zip
src/
├── Main.Params.ps1          # param() block + top-level constants (must stay first — see build.ps1)
├── Main.Driver.ps1          # Show-Help, Invoke-QuestMirror, REPL/non-interactive driver (must stay last — calls everything else)
├── Common/
│   ├── UI.ps1                # banner, Write-Ok/Err2/Meta/etc., spinner, Enable-VirtualTerminal dispatch
│   ├── PlatformDispatch.ps1   # OS detection + Initialize-Platform/Deploy-Stub/Start-Mirror dispatchers
│   ├── Discovery.ps1          # Get-DetectableApps, matching/scoring, Steam fallback, exe selection
│   ├── Queue.ps1              # mirror queue, /stop, /status, Start-MirrorForGame
│   └── InputLoop.ps1          # completion-menu rendering + the custom Read-MirrorCommand key loop
└── Platform/
    ├── Windows.ps1            # Windows-only mechanics (see below)
    └── MacOS.ps1               # macOS-only mechanics (see below)
```

`scripts/install.sh` is the macOS entrypoint referenced in the README's
`curl -fsSL <raw-url>/scripts/install.sh | bash` line. It's plain bash,
hand-maintained (not something `build.ps1` produces). It's fully
self-contained — **no Homebrew, no sudo, nothing system-wide**: if `pwsh`
isn't already on PATH (and wasn't already downloaded by a previous run), it
resolves the latest PowerShell release tag via GitHub's `/releases/latest`
redirect (falling back to a pinned `PWSH_FALLBACK_VERSION` if that lookup
fails), downloads the matching portable `osx-arm64`/`osx-x64` tarball from
PowerShell's GitHub releases, verifies it against the release's published
`hashes.sha256` (note: that file ships **UTF-16LE encoded** — pipe it through
`iconv -f UTF-16LE -t UTF-8` before grepping/awk'ing it, or every line looks
empty), and unpacks it into `~/Library/Caches/quest-mirror/pwsh/<version>/`.
That download happens at most once — later runs find the cached binary via
`find .../pwsh -maxdepth 2 -name pwsh` and skip straight to running
`mirror.ps1`, so a pwsh point-release doesn't force a ~70MB re-download on
every invocation. All of the script's own status messages go to stderr on
purpose (see the comment at the top of the file) — never add a plain
`echo` there without `>&2`, or piping/backtick-wrapping this script can
misfire in confusing ways. Keep its `MIRROR_URL`/cache-path constants in
sync with `Platform/MacOS.ps1`'s `Initialize-Platform-MacOS` if either
changes.

`build.ps1` concatenates the `src/` files **in a fixed order** (defined in its
`$files` array) into `mirror.ps1`. Order matters for two reasons: PowerShell
requires a script's `param()` block to be the first executable statement
(only comments may precede it), so `Main.Params.ps1` must be emitted first;
and `Main.Driver.ps1`'s bottom section is executable driver code (not just
function definitions), so it must be emitted last, after every function it
calls has been defined earlier in the file.

## Running / testing changes

```powershell
# After editing anything under src/:
.\build.ps1

# Interactive REPL (banner + `quest-mirror >` prompt)
.\mirror.ps1

# Non-interactive, for iterating on matching/exe-selection logic without
# typing into the prompt each time:
.\mirror.ps1 -GameName "Roblox"
.\mirror.ps1 -GameName "Roblox" -ExeChoice 2   # force a specific exe from the candidate list
```

There are no automated tests. Verify changes by rebuilding and running the
generated `mirror.ps1` directly, exercising the REPL commands (`/status`,
`/stop <name>`, `/stop all`, `/help`) plus the non-interactive `-GameName`
path. A quick syntax-only check without actually running it (useful after
touching `build.ps1`'s concatenation order):

```powershell
$errors = $null; $tokens = $null
[System.Management.Automation.Language.Parser]::ParseFile("mirror.ps1", [ref]$tokens, [ref]$errors)
$errors  # empty = no syntax errors
```

When touching window handling (`Hide-MirrorWindow`, `Start-DeElevated` in
`Platform/Windows.ps1`) or the completion menu (`Read-MirrorCommand` in
`Common/InputLoop.ps1`), test live in a real console — behavior here depends
on ConPTY/Windows Terminal quirks that don't show up from reading the code.
**macOS support has not been tested against a real Discord Quest** (see
below) — treat any change there as unverified until confirmed live.

Caches live in `%LOCALAPPDATA%\quest-mirror\` on Windows /
`~/Library/Caches/quest-mirror/` on macOS (`detectable_apps.json`, 24h TTL,
and a `mirrors\` folder holding the renamed stub executables) — delete that
directory to force a fresh fetch of Discord's detectable-apps list.

## Architecture

**`Common/UI.ps1`** — banner art, `Write-Ok`/`Write-Err2`/`Write-Meta`/etc.
console helpers, `Invoke-WithSpinner` (runs a scriptblock as a background job
while animating a spinner, used for the two HTTP calls), and
`Enable-VirtualTerminal` — a thin dispatcher that calls the Windows-only
console-mode P/Invoke helper on Windows, or just returns `$true` on
macOS/Linux (Unix terminals interpret ANSI/VT sequences natively; there's no
console-mode flag to flip the way Windows needs one).

**`Common/PlatformDispatch.ps1`** — the *only* place that decides which
platform implementation handles a call. `Get-PlatformOS` detects
`'win32'`/`'darwin'`/`'linux'` (exits with an error on Linux — not
supported). `Initialize-Platform` calls `Initialize-Platform-Windows` or
`-MacOS`, which each set `$script:CacheDir`, `$script:MirrorsDir`,
`$script:StubSource`, and `$script:AppOsKey` (the `"os"` value Discord's
detectable-apps executables list uses for this platform). `Deploy-Stub`,
`Start-Mirror`, and `Stop-MirrorProcess` are dispatchers with the same
pattern.

**`Platform/Windows.ps1`** and **`Platform/MacOS.ps1`** hold the concrete,
platform-specific mechanics. Because this all ends up concatenated into one
bundled file where both platforms' code is always defined, **every
platform-specific function is suffixed `-Windows` or `-MacOS`** (e.g.
`Deploy-Stub-Windows`, `Start-Mirror-MacOS`) and is never called directly
outside `PlatformDispatch.ps1` — using the unsuffixed name for both would
mean whichever file is concatenated last silently overwrites the other
platform's implementation.

- *Windows*: stub is a renamed copy of `cmd.exe`, launched via
  `timeout /t <seconds>`, then moved off-screen with a `SetWindowPos`
  P/Invoke call rather than minimized — Discord's Windows scanner only
  counts a window as "running" while it's in the normal (restored) state
  (confirmed via live testing). `Start-DeElevated` handles the case where
  the script itself runs elevated: UIPI blocks a standard-integrity Discord
  process from seeing an elevated one, so the launch is handed to a
  temporary Limited-rights scheduled task instead of being spawned directly.
  `Stop-MirrorProcess-Windows` kills the tracked PID's children (found via
  `Win32_Process -Filter "ParentProcessId=..."`) before the PID itself —
  `cmd.exe /c timeout ...` runs `timeout.exe` as a *child* process sharing
  the same console, and `Stop-Process` doesn't cascade to children, so
  killing only the tracked PID left `timeout.exe` (and the console it was
  attached to) running for whatever was left of its ~17.5 minutes,
  invisible to `/status` the whole time since its own `Path` is
  `System32\timeout.exe`, not under `$script:MirrorsDir`. Confirmed via a
  live report of exactly this symptom (`/stop` reported success, process
  kept running) before this was added — verify any future change here by
  actually launching a mirror, checking `Win32_Process` for its children,
  stopping it, and confirming zero PIDs survive, not just that the script
  parses.
- *macOS*: stub is a renamed copy of `/bin/sleep` (which already accepts a
  duration and exits on its own, so unlike Windows there's no wrapper
  command needed), run as a plain background process with no window-hiding
  step at all. **This is a guess, not a confirmed mechanism** — Discord's
  macOS Quest detection is closed-source, and nobody involved in this repo
  has confirmed what it actually keys on (process name? bundle identifier?
  something else?). See the comment block at the top of `Platform/MacOS.ps1`
  before changing this.

**`Common/Discovery.ps1`** — the resolution pipeline, cross-platform except
for filtering executables by `$script:AppOsKey`:
1. `Get-DetectableApps` — fetches/caches Discord's public
   `applications/detectable` list.
2. `Find-GameMatch` / `Get-MatchScore` — scores the typed name against known
   app names + aliases (exact/prefix/substring/word-overlap).
3. `Resolve-SteamCanonicalName` — if the match is weak (score < 75), queries
   Steam's store search to canonicalize the name (e.g. "gta 5" → "Grand Theft
   Auto V") and retries the match.
4. `Select-BestExecutable` — picks which executable to impersonate when a
   game lists several for the current platform (prefers top-level,
   non-launcher exes; `--pick` forces the interactive menu instead of
   auto-picking the first).

**`Common/Queue.ps1`** — only one mirror runs at a time; anything requested
while one is active goes into `$script:MirrorQueue` (a FIFO) and auto-starts
via `Invoke-QueuePump` once the active mirror exits. `Stop-Mirror` (`/stop
<name>`) matches against both the running process *and* the queue - a
queued-but-not-yet-started game is a real, user-visible state (shown in
`/status`), so it needs to be cancelable by name too, not just the one
currently running. `Stop-AllMirrors` (`/stop all`) stops the running mirror
and clears the whole queue via `.Clear()`; don't let it drift back to only
handling the active process, since with the queue that's no longer "all."

**`Common/InputLoop.ps1`** — `Read-MirrorCommand` is a custom key-by-key
input loop (not `Read-Host`) — this is deliberate, because `Read-Host` blocks
the thread and the queue can't advance while blocked. It also drives the
`/stop` autocomplete dropdown (`Show-CompletionMenu`, `Invoke-BelowCursor`)
built from *relative* ANSI/VT cursor moves only (save/restore, next-line,
line-clear) — never `[Console]::CursorTop`/`SetCursorPosition`, which desync
from the real cursor under Windows Terminal's ConPTY. If VT mode can't be
enabled or the window is too short, everything falls back to a plain
single-line ghost-text/Tab-cycle completion, unchanged.

**`Main.Driver.ps1`** — `Show-Help`, `Invoke-QuestMirror` (the top-level
resolve → match → select-exe → deploy → start pipeline), and the bottom
driver block that calls `Initialize-Platform` and then either runs the
non-interactive `-GameName` path or the REPL loop.

### Key invariants worth knowing before editing

- **A single bundled output file, always containing both platforms' code** —
  see the `-Windows`/`-MacOS` function-suffix rule above. Don't add a new
  platform-specific function without suffixing it and wiring it through
  `PlatformDispatch.ps1`.
- **`build.ps1`'s file order is load-bearing**, not cosmetic — `param()`
  must lead the output, and `Main.Driver.ps1`'s driver code must trail it.
- **Windows: window must stay in "normal" (restored) state, just relocated
  off-screen** — Discord's scanner treats a minimized window as not-running.
  Don't "simplify" `Hide-MirrorWindow` into a minimize call.
- **The dropdown menu always redraws a fixed row count**
  (`MaxVisibleRows + 2` rows: divider + candidates + hint), clearing every row
  every call — this is what prevents stray characters being left behind on a
  shorter redraw. Keep that invariant if you touch `Show-CompletionMenu`.
- **Windows: elevated runs must de-elevate the launch**, not just the
  display — spawning directly from an elevated script would inherit the
  elevated token and become invisible to Discord's (standard-integrity)
  detection.
- Block-letter banner art (`$script:BigLetters` in `Common/UI.ps1`) is built
  from `[char]` codepoints rather than literal Unicode text, specifically to
  survive Windows PowerShell 5.1 misreading the file's encoding.
- **macOS's entire mechanism is unverified** — don't present it in commit
  messages, docs, or user-facing text as confirmed behavior the way the
  Windows path can be.
