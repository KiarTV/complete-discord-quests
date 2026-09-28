# =============================================================================
# GENERATED FILE - do not edit directly.
# Source lives in src/ - run .\build.ps1 to regenerate this file, then
# commit both. See CLAUDE.md for the module layout.
# =============================================================================
# --- src/Main.Params.ps1 ---------------------------------------------------
# Discord Quest Game Mirror
# Interactive: irm https://raw.githubusercontent.com/KiarTV/Discord-Quest/master/mirror.ps1 | iex
# Non-interactive (scripting/testing): .\mirror.ps1 -GameName "Roblox" -ExeChoice 2
#
# Resolves a raw game name to the exact executable name Discord's Quest
# detection looks for, then launches a renamed copy of a harmless stub
# process so a process with that image name is running. Only affects your
# own local Discord client's Quest progress detection - no network/account
# tampering.
#
# Runs on Windows (PowerShell 5.1+) and macOS (PowerShell 7+/pwsh - see
# README for the macOS caveats before relying on this).

param(
    [string]$GameName,
    [int]$ExeChoice = 0
)

$ErrorActionPreference = 'Stop'

$MirrorDurationSeconds = [int](17.5 * 60)
$CacheMaxAgeHours = 24
$Version = '2.1.0'

# FIFO of games waiting for the currently running mirror to finish - only one
# mirror runs at a time, so anything requested while one is active gets
# queued here instead of launching immediately.
$script:MirrorQueue = New-Object System.Collections.Generic.Queue[object]

# exeName -> game display name, recorded whenever a mirror launches, so
# /stop and /status can work in terms of the game's name instead of its
# renamed stub filename.
$script:MirrorNameMap = @{}

# --- src/Common/UI.ps1 -----------------------------------------------------
# ---------------------------------------------------------------------------
# UI kit - console output helpers, banner, spinner, and the cross-platform
# VT/ANSI enable step everything below (InputLoop.ps1's completion menu)
# depends on.
# ---------------------------------------------------------------------------

$script:Glyph = @{ Ok = [char]0x2713; Warn = [char]0x26A0; Err = [char]0x2717; Step = [char]0x25B8 }

$script:HRule = [char]0x2500
$script:Esc = [char]27

function Write-Divider { Write-Host (([string]$script:HRule) * 46) -ForegroundColor DarkGray }

# Block letters built from [char] codepoints (not literal Unicode text) so the
# art can't be corrupted by Windows PowerShell 5.1 misreading the file's
# encoding. Each letter is a 6-row array; widths verified to line up.
function J { param([int[]]$Codes) -join ($Codes | ForEach-Object { [char]$_ }) }

$FBc = 0x2588  # â–ˆ
$V   = 0x2551  # â•‘
$UR  = 0x2557  # â•—  (down+left)
$UL  = 0x2554  # â•”  (down+right)
$LR  = 0x255D  # â•  (up+left)
$LL  = 0x255A  # â•š  (up+right)
$H   = 0x2550  # â•
$SP  = 0x0020

$script:BigLetters = @{
    M = @(
        (J @($FBc,$FBc,$FBc,$UR,$SP,$SP,$SP,$FBc,$FBc,$FBc,$UR)),
        (J @($FBc,$FBc,$FBc,$FBc,$UR,$SP,$FBc,$FBc,$FBc,$FBc,$V)),
        (J @($FBc,$FBc,$UL,$FBc,$FBc,$FBc,$FBc,$UL,$FBc,$FBc,$V)),
        (J @($FBc,$FBc,$V,$LL,$FBc,$FBc,$UL,$LR,$FBc,$FBc,$V)),
        (J @($FBc,$FBc,$V,$SP,$LL,$H,$LR,$SP,$FBc,$FBc,$V)),
        (J @($LL,$H,$LR,$SP,$SP,$SP,$SP,$SP,$LL,$H,$LR))
    )
    I = @(
        (J @($FBc,$FBc,$UR)),
        (J @($FBc,$FBc,$V)),
        (J @($FBc,$FBc,$V)),
        (J @($FBc,$FBc,$V)),
        (J @($FBc,$FBc,$V)),
        (J @($LL,$H,$LR))
    )
    R = @(
        (J @($FBc,$FBc,$FBc,$FBc,$FBc,$FBc,$UR,$SP)),
        (J @($FBc,$FBc,$UL,$H,$H,$FBc,$FBc,$UR)),
        (J @($FBc,$FBc,$FBc,$FBc,$FBc,$FBc,$UL,$LR)),
        (J @($FBc,$FBc,$UL,$H,$H,$FBc,$FBc,$UR)),
        (J @($FBc,$FBc,$V,$SP,$SP,$FBc,$FBc,$V)),
        (J @($LL,$H,$LR,$SP,$SP,$LL,$H,$LR))
    )
    O = @(
        (J @($SP,$FBc,$FBc,$FBc,$FBc,$FBc,$FBc,$UR,$SP)),
        (J @($FBc,$FBc,$UL,$H,$H,$H,$FBc,$FBc,$UR)),
        (J @($FBc,$FBc,$V,$SP,$SP,$SP,$FBc,$FBc,$V)),
        (J @($FBc,$FBc,$V,$SP,$SP,$SP,$FBc,$FBc,$V)),
        (J @($LL,$FBc,$FBc,$FBc,$FBc,$FBc,$FBc,$UL,$LR)),
        (J @($SP,$LL,$H,$H,$H,$H,$H,$LR,$SP))
    )
}

function Write-BigBanner {
    $word = 'M', 'I', 'R', 'R', 'O', 'R'
    Write-Host ""
    for ($row = 0; $row -lt 6; $row++) {
        $line = '  ' + (($word | ForEach-Object { $script:BigLetters[$_][$row] }) -join '')
        Write-Host $line -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host '  Discord Quest Mirror ' -ForegroundColor White -NoNewline
    Write-Host "v$Version" -ForegroundColor DarkGray
    Write-Host '  Make Discord see a game that is not there' -ForegroundColor DarkGray
    Write-Host ""
}

function Write-Step  { param([string]$Text) Write-Host "$($script:Glyph.Step) $Text" -ForegroundColor White }
function Write-Ok    { param([string]$Text) Write-Host "  $($script:Glyph.Ok) $Text" -ForegroundColor Green }
function Write-Warn2 { param([string]$Text) Write-Host "  $($script:Glyph.Warn) $Text" -ForegroundColor Yellow }
function Write-Err2  { param([string]$Text) Write-Host "  $($script:Glyph.Err) $Text" -ForegroundColor Red }
function Write-Meta  { param([string]$Text) Write-Host "  $Text" -ForegroundColor DarkGray }

function Format-TimeAgo {
    param([datetime]$Since)
    $span = (Get-Date) - $Since
    if ($span.TotalMinutes -lt 1) { return "just now" }
    if ($span.TotalHours -lt 1) { return "$([int]$span.TotalMinutes)m ago" }
    return "$([int]$span.TotalHours)h ago"
}

function Invoke-WithSpinner {
    param([scriptblock]$Action, [string]$Message)

    $frames = [char[]]@(0x280B, 0x2819, 0x2839, 0x2838, 0x283C, 0x2834, 0x2826, 0x2827, 0x2807, 0x280F)
    $job = Start-Job -ScriptBlock $Action
    $i = 0
    try {
        while ($job.State -eq 'Running') {
            Write-Host -NoNewline ("`r{0} {1}" -f $frames[$i % $frames.Count], $Message) -ForegroundColor Cyan
            Start-Sleep -Milliseconds 80
            $i++
        }
        $result = Receive-Job -Job $job -ErrorAction Stop
    } finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        Write-Host ("`r" + (' ' * ($Message.Length + 4)) + "`r") -NoNewline
    }
    return $result
}

# Cached tri-state ($null = not probed yet). Enabling VT lets the /stop
# completion menu draw real rows below the prompt using only *relative*
# ANSI cursor moves (save/restore, next-line, line-clear) - unlike
# [Console]::CursorTop/SetCursorPosition, those aren't the ones that desync
# from the real cursor under Windows Terminal's ConPTY translation layer
# (see the comment on Read-MirrorCommand in InputLoop.ps1 for why that
# matters here). Any failure leaves $script:UseMenu false for the whole
# session and the original single-line ghost-text path runs unchanged.
$script:VtEnabled = $null

function Enable-VirtualTerminal {
    if ($null -ne $script:VtEnabled) { return $script:VtEnabled }
    if ([Console]::IsOutputRedirected) { $script:VtEnabled = $false; return $false }

    if ($script:PlatformOS -eq 'win32') {
        # Windows consoles need ENABLE_VIRTUAL_TERMINAL_PROCESSING flipped on
        # explicitly - see Platform/Windows.ps1.
        $script:VtEnabled = Enable-VirtualTerminal-Windows
    } else {
        # Unix terminals (Terminal.app, iTerm2, and effectively everything
        # else macOS/Linux users run) interpret ANSI/VT sequences natively -
        # there's no console-mode flag to flip the way Windows needs one.
        $script:VtEnabled = $true
    }
    return $script:VtEnabled
}

# --- src/Common/PlatformDispatch.ps1 ---------------------------------------
# ---------------------------------------------------------------------------
# Platform detection & dispatch - the only place that decides whether
# Platform/Windows.ps1 or Platform/MacOS.ps1 handles a given call. Both
# platform files are always loaded (this ships as one bundled script), so
# every platform-specific function is suffixed -Windows / -MacOS and is
# never called directly outside this dispatch layer.
# ---------------------------------------------------------------------------

function Get-PlatformOS {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        if ($IsMacOS) { return 'darwin' }
        if ($IsWindows) { return 'win32' }
        return 'linux'
    }
    # Windows PowerShell 5.1 (no $IsWindows/$IsMacOS) only ever runs on Windows.
    return 'win32'
}

# Sets $script:CacheDir, $script:CacheFile, $script:MirrorsDir,
# $script:StubSource and $script:AppOsKey (the "os" value Discord's
# detectable-apps executables list uses for this platform - 'win32' or
# 'darwin') by delegating to the matching Initialize-Platform-* function.
function Initialize-Platform {
    $script:PlatformOS = Get-PlatformOS

    switch ($script:PlatformOS) {
        'win32'  { Initialize-Platform-Windows }
        'darwin' { Initialize-Platform-MacOS }
        default {
            Write-Host "quest-mirror only supports Windows and macOS right now (detected: $script:PlatformOS)." -ForegroundColor Red
            exit 1
        }
    }

    if (-not (Test-Path $script:CacheDir)) {
        New-Item -ItemType Directory -Path $script:CacheDir -Force | Out-Null
    }
}

function Deploy-Stub {
    param([string]$ExeName)
    if ($script:PlatformOS -eq 'win32') { return Deploy-Stub-Windows -ExeName $ExeName }
    return Deploy-Stub-MacOS -ExeName $ExeName
}

function Start-Mirror {
    param([string]$ExePath)
    if ($script:PlatformOS -eq 'win32') { return Start-Mirror-Windows -ExePath $ExePath }
    return Start-Mirror-MacOS -ExePath $ExePath
}

function Stop-MirrorProcess {
    param([int]$ProcessId)
    if ($script:PlatformOS -eq 'win32') { Stop-MirrorProcess-Windows -ProcessId $ProcessId; return }
    Stop-MirrorProcess-MacOS -ProcessId $ProcessId
}

# --- src/Platform/Windows.ps1 ----------------------------------------------
# ---------------------------------------------------------------------------
# Windows implementation - stub is a renamed copy of cmd.exe, kept alive via
# `timeout`, moved off-screen (not minimized) so Discord's window-owning
# process scan still counts it as running.
# ---------------------------------------------------------------------------

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class QuestMirrorNative {
    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
}
"@

Add-Type @"
using System;
using System.Runtime.InteropServices;
public class QuestMirrorConsole {
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int nStdHandle);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleHandle, out uint lpMode);
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleHandle, uint dwMode);
}
"@

function Enable-VirtualTerminal-Windows {
    try {
        $STD_OUTPUT_HANDLE = -11
        $ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
        $h = [QuestMirrorConsole]::GetStdHandle($STD_OUTPUT_HANDLE)
        if ($h -eq [IntPtr]::Zero) { return $false }
        $mode = 0
        if (-not [QuestMirrorConsole]::GetConsoleMode($h, [ref]$mode)) { return $false }
        if (($mode -band $ENABLE_VIRTUAL_TERMINAL_PROCESSING) -eq 0) {
            if (-not [QuestMirrorConsole]::SetConsoleMode($h, ($mode -bor $ENABLE_VIRTUAL_TERMINAL_PROCESSING))) { return $false }
        }
        return $true
    } catch {
        return $false
    }
}

function Find-MirrorWindowHandle {
    param([int]$ProcessId, [string]$ExeName)

    # The renamed process itself, a classic conhost.exe child, or - on
    # machines where Windows Terminal is the default terminal app - a
    # WindowsTerminal.exe window can each end up owning the actual HWND,
    # so all three have to be checked (confirmed via live testing).
    $deadline = (Get-Date).AddSeconds(6)
    while ((Get-Date) -lt $deadline) {
        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($proc -and $proc.MainWindowHandle -ne [IntPtr]::Zero) { return $proc.MainWindowHandle }

        $conhosts = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId AND Name='conhost.exe'" -ErrorAction SilentlyContinue
        foreach ($c in $conhosts) {
            $chProc = Get-Process -Id $c.ProcessId -ErrorAction SilentlyContinue
            if ($chProc -and $chProc.MainWindowHandle -ne [IntPtr]::Zero) { return $chProc.MainWindowHandle }
        }

        $wt = Get-Process WindowsTerminal -ErrorAction SilentlyContinue |
            Where-Object { $_.MainWindowTitle -like "*$ExeName*" -and $_.MainWindowHandle -ne [IntPtr]::Zero } |
            Select-Object -First 1
        if ($wt) { return $wt.MainWindowHandle }

        Start-Sleep -Milliseconds 300
    }
    return [IntPtr]::Zero
}

function Hide-MirrorWindow {
    param([int]$ProcessId, [string]$ExeName)

    $hwnd = Find-MirrorWindowHandle -ProcessId $ProcessId -ExeName $ExeName
    if ($hwnd -eq [IntPtr]::Zero) {
        Write-Warn2 "Couldn't locate the mirror's window to hide it - it may briefly flash on screen"
        return
    }
    # SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE. The window stays in its
    # normal (restored) state - Discord only counts the mirror as running
    # while it's not minimized - just relocated off every monitor.
    [QuestMirrorNative]::SetWindowPos($hwnd, [IntPtr]::Zero, -32000, -32000, 0, 0, 0x15) | Out-Null
}

function Test-IsElevated {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Start-DeElevated {
    param([string]$FilePath, [string]$Arguments)

    # A standard-integrity Discord process can't properly see into a
    # higher-integrity (elevated) one - UIPI blocks it. If this script is
    # running elevated, the stub must still launch at standard integrity, so
    # hand the launch to a Limited-rights scheduled task instead of spawning
    # it directly (which would inherit our elevated token).
    $escapedPath = $FilePath.Replace("'", "''")
    $escapedArgs = $Arguments.Replace("'", "''")
    $inner = "Start-Process -FilePath '$escapedPath' -ArgumentList '$escapedArgs' -WindowStyle Normal"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($inner))

    $taskName = "QuestMirror_$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -WindowStyle Hidden -EncodedCommand $encoded"
    $principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Limited
    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
    try {
        Start-ScheduledTask -TaskName $taskName
        $deadline = (Get-Date).AddSeconds(5)
        $proc = $null
        while ((Get-Date) -lt $deadline -and -not $proc) {
            Start-Sleep -Milliseconds 300
            # .Path can throw for processes that exit mid-scan (see the
            # matching comment on Get-ActiveMirrorProcesses in Queue.ps1) -
            # this scans every system process on each retry, so it needs
            # the same guard to keep retrying instead of crashing out.
            $proc = Get-Process | Where-Object {
                try { $_.Path -eq $FilePath } catch { $false }
            } | Select-Object -First 1
        }
        return $proc
    } finally {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Initialize-Platform-Windows {
    $script:CacheDir = Join-Path $env:LOCALAPPDATA 'quest-mirror'
    $script:CacheFile = Join-Path $script:CacheDir 'detectable_apps.json'
    $script:MirrorsDir = Join-Path $script:CacheDir 'mirrors'
    $script:StubSource = Join-Path $env:WINDIR 'System32\cmd.exe'
    $script:AppOsKey = 'win32'
}

function Deploy-Stub-Windows {
    param([string]$ExeName)

    if (-not (Test-Path $script:MirrorsDir)) {
        New-Item -ItemType Directory -Path $script:MirrorsDir -Force | Out-Null
    }
    if (-not (Test-Path $script:StubSource)) {
        throw "Stub source not found: $script:StubSource"
    }

    $target = Join-Path $script:MirrorsDir $ExeName
    Copy-Item -Path $script:StubSource -Destination $target -Force
    return $target
}

function Start-Mirror-Windows {
    param([string]$ExePath)

    # Discord only counts the mirror as running while its window is in a
    # normal (restored) state - Minimized reads as not-running (confirmed
    # via live testing). So launch visibly, then move the window off every
    # monitor instead of minimizing it.
    $seconds = [int]$MirrorDurationSeconds
    $mirrorArgs = "/c timeout /t $seconds /nobreak >nul"
    $exeName = Split-Path $ExePath -Leaf

    if (Test-IsElevated) {
        Write-Meta "Running elevated - launching mirror at standard integrity so Discord can see it"
        $proc = Start-DeElevated -FilePath $ExePath -Arguments $mirrorArgs
        if (-not $proc) {
            Write-Err2 "De-elevated launch didn't produce a matching process in time"
            return [PSCustomObject]@{ Id = $null; Alive = $false }
        }
    } else {
        $proc = Start-Process -FilePath $ExePath -ArgumentList $mirrorArgs -WindowStyle Normal -PassThru
    }

    Hide-MirrorWindow -ProcessId $proc.Id -ExeName $exeName

    Start-Sleep -Milliseconds 1200
    $alive = $false
    try { $alive = -not (Get-Process -Id $proc.Id -ErrorAction Stop).HasExited } catch { $alive = $false }

    if (-not $alive) {
        Write-Err2 "Process exited immediately after launch (PID $($proc.Id) is gone)"
        Write-Meta "Likely cause: antivirus killing a renamed system exe on sight"
        Write-Meta "Check Windows Security -> Protection history, then exclude: $script:MirrorsDir"
    }

    return [PSCustomObject]@{ Id = $proc.Id; Alive = $alive }
}

function Stop-MirrorProcess-Windows {
    param([int]$ProcessId)

    # The mirror stub is a renamed cmd.exe running `/c timeout ...` -
    # timeout.exe runs as a CHILD of that process, sharing its console.
    # Stop-Process on just the tracked PID doesn't cascade to children, so
    # timeout.exe (and the console/window it's still attached to) keeps
    # running for whatever's left of its ~17.5 minutes - and it's invisible
    # to /status the whole time, since its own Path is
    # System32\timeout.exe, not under $script:MirrorsDir. Confirmed via a
    # live report of exactly this: /stop reported success, but the process
    # was still running afterward.
    $children = Get-CimInstance Win32_Process -Filter "ParentProcessId=$ProcessId" -ErrorAction SilentlyContinue
    foreach ($child in $children) {
        Stop-Process -Id $child.ProcessId -Force -ErrorAction SilentlyContinue
    }
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

# --- src/Platform/MacOS.ps1 ------------------------------------------------
# ---------------------------------------------------------------------------
# macOS implementation - UNVERIFIED against Discord's real Quest detection.
#
# The Windows half of this script works because Discord's Windows detector
# enumerates top-level windows and matches the owning process' image name -
# confirmed by live testing against real Quests. Discord's macOS detector is
# a different, closed-source code path, and nobody involved in this repo has
# confirmed exactly what it keys on (running process name via ps/libproc?
# the app bundle's CFBundleIdentifier from Info.plist? something else?).
#
# This implementation takes the most likely guess given how the Windows side
# behaves: a running process whose name matches the executable name from
# Discord's detectable-apps list. It deliberately does NOT try to fake a
# window - a bare CLI process has no window at all, and unlike Windows,
# nothing suggests Discord's Mac client requires one.
#
# If a mirror doesn't get picked up as a running game on your machine,
# that's useful signal either way - please open an issue with what you
# tried and whether Quest progress moved.
# ---------------------------------------------------------------------------

function Initialize-Platform-MacOS {
    $script:CacheDir = Join-Path $HOME 'Library/Caches/quest-mirror'
    $script:CacheFile = Join-Path $script:CacheDir 'detectable_apps.json'
    $script:MirrorsDir = Join-Path $script:CacheDir 'mirrors'
    # /bin/sleep IS the mirror - it already accepts a duration and exits on
    # its own, so (unlike Windows' cmd.exe) no wrapper arguments are needed.
    $script:StubSource = '/bin/sleep'
    $script:AppOsKey = 'darwin'
}

function Deploy-Stub-MacOS {
    param([string]$ExeName)

    if (-not (Test-Path $script:MirrorsDir)) {
        New-Item -ItemType Directory -Path $script:MirrorsDir -Force | Out-Null
    }
    if (-not (Test-Path $script:StubSource)) {
        throw "Stub source not found: $script:StubSource"
    }

    $target = Join-Path $script:MirrorsDir $ExeName
    Copy-Item -Path $script:StubSource -Destination $target -Force
    # Copy-Item doesn't reliably preserve the executable bit across
    # filesystems/pwsh versions - set it explicitly rather than assume.
    & chmod 755 $target
    return $target
}

function Start-Mirror-MacOS {
    param([string]$ExePath)

    $seconds = [int]$MirrorDurationSeconds
    $proc = Start-Process -FilePath $ExePath -ArgumentList "$seconds" -PassThru

    Start-Sleep -Milliseconds 1200
    $alive = $false
    try { $alive = -not (Get-Process -Id $proc.Id -ErrorAction Stop).HasExited } catch { $alive = $false }

    if (-not $alive) {
        Write-Err2 "Process exited immediately after launch (PID $($proc.Id) is gone)"
        Write-Meta "Check Gatekeeper isn't blocking the renamed binary in: $script:MirrorsDir"
    }

    return [PSCustomObject]@{ Id = $proc.Id; Alive = $alive }
}

function Stop-MirrorProcess-MacOS {
    param([int]$ProcessId)
    # Unlike Windows' cmd.exe-wrapped stub, /bin/sleep never spawns a child
    # process, so there's nothing else to clean up here.
    Stop-Process -Id $ProcessId -Force -ErrorAction SilentlyContinue
}

# --- src/Common/Discovery.ps1 ----------------------------------------------
# ---------------------------------------------------------------------------
# Game resolution - fetching/caching Discord's detectable-apps list, scoring
# a typed name against it, falling back to Steam's search for a canonical
# name, and picking which platform-appropriate executable to impersonate.
# Entirely cross-platform: the only platform-specific bit is which "os" key
# ($script:AppOsKey, set by Initialize-Platform) to filter executables by.
# ---------------------------------------------------------------------------

function Get-DetectableApps {
    if ((Test-Path $script:CacheFile) -and
        ((Get-Item $script:CacheFile).LastWriteTime -gt (Get-Date).AddHours(-$CacheMaxAgeHours))) {
        $age = Format-TimeAgo (Get-Item $script:CacheFile).LastWriteTime
        Write-Meta "Using cached game list (refreshed $age)"
        return Read-DetectableAppsCache
    }

    try {
        $apps = Invoke-WithSpinner -Message "Fetching Discord's detectable game list..." -Action {
            Invoke-RestMethod "https://discord.com/api/v10/applications/detectable"
        }
    } catch {
        # An expired list is still far better than nothing - game executable
        # names rarely change, so only give up if there's no cache at all.
        if (-not (Test-Path $script:CacheFile)) { throw }
        Write-Warn2 "Couldn't refresh Discord's game list ($($_.Exception.Message)) - using the older cached copy"
        return Read-DetectableAppsCache
    }
    # Explicit BOM-less UTF-8 via .NET: Set-Content/Get-Content in Windows
    # PowerShell 5.1 default to the ANSI codepage, which turned every
    # CJK/Korean game name in the cache into "????" (confirmed - 68 of them),
    # making those games impossible to match.
    [System.IO.File]::WriteAllText($script:CacheFile, ($apps | ConvertTo-Json -Depth 10), (New-Object System.Text.UTF8Encoding($false)))
    Write-Meta "Cached $($apps.Count) known games"
    return $apps
}

function Read-DetectableAppsCache {
    return [System.IO.File]::ReadAllText($script:CacheFile, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
}

function Resolve-SteamCanonicalName {
    param([string]$RawName)

    try {
        $encoded = [uri]::EscapeDataString($RawName)
        $url = "https://store.steampowered.com/api/storesearch/?term=$encoded&cc=us&l=en"
        $result = Invoke-WithSpinner -Message "Checking Steam for a closer match..." -Action {
            Invoke-RestMethod $using:url -TimeoutSec 5
        }
        if ($result.items -and $result.items.Count -gt 0) {
            return $result.items[0].name
        }
    } catch {
        Write-Meta "Steam lookup skipped ($($_.Exception.Message))"
    }
    return $null
}

function Get-MatchScore {
    param([string]$Query, [string]$Candidate)

    $q = $Query.ToLowerInvariant().Trim()
    $c = $Candidate.ToLowerInvariant().Trim()

    if ($c -eq $q) { return 100 }
    if ($c.StartsWith($q)) { return 90 }
    if ($c.Contains($q)) { return 75 }

    $qWords = $q -split '\s+'
    if ($qWords.Count -eq 0) { return 0 }
    $matched = 0
    foreach ($w in $qWords) { if ($c.Contains($w)) { $matched++ } }
    return [math]::Round(60 * $matched / $qWords.Count)
}

function Test-HasPlatformExecutable {
    param($App)
    return [bool](@($App.executables) | Where-Object { $_.os -eq $script:AppOsKey })
}

function Get-StorefrontLinkCount {
    param($App)
    return @($App.third_party_skus).Count
}

function Find-GameMatch {
    param($Apps, [string]$Query)

    # Plain foreach loops, not ForEach-Object/Measure-Object pipelines - this
    # runs over the whole ~25k-entry list, and per-app pipeline setup made a
    # single lookup take ~8s on Windows PowerShell 5.1 (twice that when the
    # Steam retry runs).
    $scored = foreach ($app in $Apps) {
        $best = 0
        foreach ($name in @($app.name) + @($app.aliases)) {
            $s = Get-MatchScore -Query $Query -Candidate $name
            if ($s -gt $best) { $best = $s }
        }
        if ($best -gt 0) {
            [PSCustomObject]@{ App = $app; Score = $best }
        }
    }

    # Discord's detectable-apps list is self-registered by any developer with
    # a Discord application, not curated by popularity - a query like "apex"
    # ties in text score between "Apex Legends" and an obscure "Apex Rush"
    # that has no executable at all. Break ties (never override a clearly
    # better text match - this only runs within a single Score value) using
    # signals from the data that do correlate with "this is a real, known
    # release": whether it even has an executable for this platform, and how
    # many storefronts (Steam/Xbox/Epic/...) it's linked to, since obscure or
    # test entries are rarely linked to any.
    return $scored | Sort-Object -Property @(
        @{ Expression = 'Score'; Descending = $true }
        @{ Expression = { Test-HasPlatformExecutable $_.App }; Descending = $true }
        @{ Expression = { Get-StorefrontLinkCount $_.App }; Descending = $true }
    ) | Select-Object -First 8
}

function Select-BestExecutable {
    param($Executables, [int]$PresetChoice = 0, [bool]$ForcePrompt = $false)

    $osExes = @($Executables | Where-Object { $_.os -eq $script:AppOsKey -and -not $_.is_launcher })
    if ($osExes.Count -eq 0) {
        $osExes = @($Executables | Where-Object { $_.os -eq $script:AppOsKey })
    }
    if ($osExes.Count -eq 0) { return $null }
    if ($osExes.Count -eq 1) { return $osExes[0] }

    # Prefer a top-level exe (no subfolder) as the most likely main game binary.
    $topLevel = @($osExes | Where-Object { $_.name -notmatch '/' })
    $ordered = if ($topLevel.Count -gt 0) { $topLevel + ($osExes | Where-Object { $_.name -match '/' }) } else { $osExes }

    if ($PresetChoice -ge 1 -and $PresetChoice -le $ordered.Count) {
        Write-Meta "Multiple executables found - using [$PresetChoice] $($ordered[$PresetChoice - 1].name) (preset)"
        return $ordered[$PresetChoice - 1]
    }

    # Discord's detection just checks the process name against its list, so
    # any of these is equally "correct" - no need to ask, always take the
    # first, unless the user explicitly wants to pick (e.g. the first one
    # didn't get detected for some reason) via a trailing --pick flag.
    if (-not $ForcePrompt) {
        Write-Meta "Multiple executables found - using $($ordered[0].name) (add --pick to choose one)"
        return $ordered[0]
    }

    Write-Warn2 "Multiple executables found for this game:"
    $picked = Read-MenuSelection -Items @($ordered | ForEach-Object { $_.name }) -DefaultIndex 0
    if ($null -eq $picked) {
        # Arrow-key menu can't be rendered here (no VT support, or the
        # window's too short) - fall back to the plain numbered prompt.
        for ($i = 0; $i -lt $ordered.Count; $i++) {
            Write-Host ("      [{0}] {1}" -f ($i + 1), $ordered[$i].name) -ForegroundColor Gray
        }
        Write-Host -NoNewline "    Pick one (Enter for [1]): " -ForegroundColor DarkGray
        $pick = Read-Host
        $picked = 0
        $valid = $pick -and [int]::TryParse($pick, [ref]$picked) -and $picked -ge 1 -and $picked -le $ordered.Count
        if ($valid) {
            $picked -= 1
        } else {
            if ($pick) { Write-Meta "'$pick' isn't valid (1-$($ordered.Count)), defaulting to [1]" }
            $picked = 0
        }
    }
    Write-Ok "Using [$($picked + 1)] $($ordered[$picked].name)"
    return $ordered[$picked]
}

# --- src/Common/Queue.ps1 --------------------------------------------------
# ---------------------------------------------------------------------------
# Mirror queue - only one mirror runs at a time; anything requested while
# one is active goes into $script:MirrorQueue and auto-starts once the
# active mirror exits. Cross-platform: relies only on Get-Process/Path and
# the Deploy-Stub/Start-Mirror dispatchers from PlatformDispatch.ps1.
# ---------------------------------------------------------------------------

function Get-ActiveMirrorProcesses {
    # $_.Path re-queries live OS process info on every access rather than
    # returning a cached value, and this runs on every idle poll tick over
    # the *entire* system process list - if a process exits between two
    # separate $_.Path accesses (e.g. right after a /stop, or just normal
    # system churn), the first access can return a valid path while a
    # second one moments later returns null or throws. Capture it once, and
    # never let one uncooperative process take down the whole polling loop -
    # confirmed live: this exact race crashed the interactive prompt.
    return Get-Process | Where-Object {
        try {
            $path = $_.Path
            $path -and $path.StartsWith($script:MirrorsDir, [StringComparison]::OrdinalIgnoreCase)
        } catch {
            $false
        }
    }
}

function Get-ActiveMirrorInfo {
    Get-ActiveMirrorProcesses | ForEach-Object {
        # Same live-query race as Get-ActiveMirrorProcesses above: $_.Path
        # already succeeded once when this process passed that filter, but
        # it's queried again here in a separate pipeline stage moments
        # later, and the process can have exited in between. Skip it rather
        # than crash - if it's still actually running, the next poll picks
        # it back up.
        try {
            $exeName = Split-Path $_.Path -Leaf
            $displayName = $script:MirrorNameMap[$exeName]
            if (-not $displayName) { $displayName = $exeName }
            [PSCustomObject]@{ Process = $_; ExeName = $exeName; DisplayName = $displayName }
        } catch {
        }
    }
}

function Test-MirrorActive {
    return [bool](Get-ActiveMirrorProcesses)
}

function Remove-QueuedMirror {
    param([string]$ExeName)
    $kept = New-Object System.Collections.Generic.Queue[object]
    foreach ($item in $script:MirrorQueue.ToArray()) {
        if ($item.ExeName -ne $ExeName) { $kept.Enqueue($item) }
    }
    $script:MirrorQueue = $kept
}

# Only one mirror is ever actually running, but /stop needs to reach a
# queued-and-not-yet-started game too - "queued" is a real, user-visible
# state (shown in /status), not an implementation detail, so a queued game
# should be cancelable by name just like a running one.
function Stop-Mirror {
    param([string]$Query)

    $active = @(Get-ActiveMirrorInfo | ForEach-Object {
        [PSCustomObject]@{ Kind = 'Active'; DisplayName = $_.DisplayName; ExeName = $_.ExeName; Process = $_.Process }
    })
    $queued = @($script:MirrorQueue.ToArray() | ForEach-Object {
        [PSCustomObject]@{ Kind = 'Queued'; DisplayName = $_.DisplayName; ExeName = $_.ExeName }
    })
    $all = $active + $queued

    $matched = @($all | Where-Object { $_.DisplayName -eq $Query -or $_.ExeName -eq $Query })
    if ($matched.Count -eq 0) {
        # Escaped so a typed "[" etc. is literal instead of a malformed wildcard.
        $pattern = "*$([WildcardPattern]::Escape($Query))*"
        $matched = @($all | Where-Object { $_.DisplayName -like $pattern -or $_.ExeName -like $pattern })
    }

    if ($matched.Count -eq 0) {
        Write-Warn2 "No running or queued mirror matching '$Query' found"
        return
    }
    foreach ($m in $matched) {
        if ($m.Kind -eq 'Active') {
            Stop-MirrorProcess -ProcessId $m.Process.Id
            Write-Ok "Stopped $($m.DisplayName) (PID $($m.Process.Id))"
        } else {
            Remove-QueuedMirror -ExeName $m.ExeName
            Write-Ok "Removed `"$($m.DisplayName)`" from the queue"
        }
    }
}

function Stop-AllMirrors {
    $active = @(Get-ActiveMirrorInfo)
    $queuedCount = $script:MirrorQueue.Count

    if ($active.Count -eq 0 -and $queuedCount -eq 0) {
        Write-Warn2 "No active or queued mirrors to stop"
        return
    }

    foreach ($m in $active) {
        Stop-MirrorProcess -ProcessId $m.Process.Id
        Write-Ok "Stopped $($m.DisplayName) (PID $($m.Process.Id))"
    }

    if ($queuedCount -gt 0) {
        $script:MirrorQueue.Clear()
        Write-Ok "Cleared $queuedCount queued mirror$(if ($queuedCount -ne 1) { 's' })"
    }
}

function Show-ActiveMirrors {
    $active = @(Get-ActiveMirrorInfo)
    if ($active.Count -eq 0) {
        Write-Meta "No active mirrors."
    } else {
        Write-Host ""
        Write-Host ("  {0,-28} {1,-8} {2}" -f 'GAME', 'PID', 'EXPIRES') -ForegroundColor DarkGray
        foreach ($m in $active) {
            $expires = $m.Process.StartTime.AddSeconds($MirrorDurationSeconds).ToString('HH:mm:ss')
            Write-Host ("  {0,-28} {1,-8} {2}" -f $m.DisplayName, $m.Process.Id, $expires) -ForegroundColor White
        }
        Write-Host ""
    }

    if ($script:MirrorQueue.Count -gt 0) {
        Write-Host "  Queued:" -ForegroundColor DarkGray
        $i = 1
        foreach ($item in $script:MirrorQueue.ToArray()) {
            Write-Host ("      [{0}] {1}" -f $i, $item.DisplayName) -ForegroundColor Gray
            $i++
        }
        Write-Host ""
    }
}

function Invoke-QueuePump {
    if ($script:MirrorQueue.Count -eq 0 -or (Test-MirrorActive)) { return }

    $next = $script:MirrorQueue.Dequeue()
    Write-Host ""
    Write-Step "Starting queued mirror: $($next.DisplayName)"
    Start-MirrorForGame -ExeName $next.ExeName -DisplayName $next.DisplayName
}

function Get-StopCandidates {
    param([string]$Typed)

    # Each side must be forced to an array (@(...)) at assignment, not just
    # around the combined expression - a pipeline that yields exactly one
    # item collapses to a plain scalar string, and string + string is
    # concatenation ("Apex Legends" + "all" -> "Apex Legendsall"), not the
    # array-append this needs.
    $activeNames = @(Get-ActiveMirrorInfo | ForEach-Object { $_.DisplayName })
    $queuedNames = @($script:MirrorQueue.ToArray() | ForEach-Object { $_.DisplayName })
    $names = @($activeNames + $queuedNames + 'all') | Select-Object -Unique
    return @($names | Where-Object { $_.ToLowerInvariant().StartsWith($Typed.ToLowerInvariant()) })
}

function Start-MirrorForGame {
    param([string]$ExeName, [string]$DisplayName)

    $script:MirrorNameMap[$ExeName] = $DisplayName

    $target = Deploy-Stub -ExeName $ExeName
    $proc = Start-Mirror -ExePath $target

    if ($proc.Alive) {
        $expires = (Get-Date).AddSeconds($MirrorDurationSeconds).ToString('HH:mm:ss')
        Write-Ok "Mirror running - PID $($proc.Id), expires ~$expires"
        Write-Meta "Stop early with: /stop $DisplayName"
    }
}

# --- src/Common/InputLoop.ps1 ----------------------------------------------
# ---------------------------------------------------------------------------
# Dropdown completion menu - draws below the current input line using only
# relative ANSI/VT moves (save/restore cursor, cursor-next-line, line-clear),
# never [Console]::CursorTop/SetCursorPosition. Takes only plain strings and
# indices - no /stop-specific knowledge lives here - so it's general enough
# to reuse for other pickers (e.g. Select-BestExecutable's ambiguous-match
# prompt in Discovery.ps1) even though /stop is the primary user.
#
# Everything here is cross-platform: it only touches [Console] and the
# Enable-VirtualTerminal abstraction from UI.ps1, both of which work the
# same way (from this code's perspective) on Windows and macOS terminals.
# ---------------------------------------------------------------------------

function Clear-InlineOverlay {
    param([int]$Length)
    if ($Length -le 0) { return }
    Write-Host -NoNewline (' ' * $Length)
    [Console]::CursorLeft = [Console]::CursorLeft - $Length
}

function Write-InlineOverlay {
    param([string]$Text)
    if (-not $Text) { return 0 }
    Write-Host -NoNewline $Text -ForegroundColor DarkGray
    [Console]::CursorLeft = [Console]::CursorLeft - $Text.Length
    return $Text.Length
}

function Invoke-BelowCursor {
    param([int]$RowCount, [scriptblock]$RowRenderer)
    if ($RowCount -le 0) { return }
    Write-Host -NoNewline "$($script:Esc)[?25l$($script:Esc)[s"
    for ($i = 0; $i -lt $RowCount; $i++) {
        Write-Host -NoNewline "$($script:Esc)[1E$($script:Esc)[2K"
        & $RowRenderer $i
    }
    Write-Host -NoNewline "$($script:Esc)[u$($script:Esc)[?25h"
}

# Always emits exactly (MaxVisibleRows + 2) rows - a divider, the candidate
# rows, and a hint row - clearing every row on every call. That constant
# row-count is what guarantees a shorter/longer redraw never leaves stray
# characters behind, which is the failure mode this whole menu replaces.
function Show-CompletionMenu {
    param(
        [string[]]$Candidates,
        [string]$Filter,
        [int]$SelectedIndex,
        [int]$MaxVisibleRows = 5
    )
    $width = [Math]::Max(20, [Console]::WindowWidth - 1)
    Invoke-BelowCursor -RowCount ($MaxVisibleRows + 2) -RowRenderer {
        param($i)
        if ($i -eq 0) {
            Write-Host -NoNewline (([string]$script:HRule) * [Math]::Min(46, $width)) -ForegroundColor DarkGray
        } elseif ($i -le $MaxVisibleRows) {
            $idx = $i - 1
            if ($idx -lt $Candidates.Count) {
                $c = $Candidates[$idx]
                $maxLen = [Math]::Max(1, $width - 6)
                if ($c.Length -gt $maxLen) { $c = $c.Substring(0, [Math]::Max(1, $maxLen - 1)) + [char]0x2026 }
                $matchLen = [Math]::Min($Filter.Length, $c.Length)
                $matched = $c.Substring(0, $matchLen)
                $rest = $c.Substring($matchLen)
                if ($idx -eq $SelectedIndex) {
                    Write-Host -NoNewline "  $($script:Glyph.Step) " -ForegroundColor Cyan
                    Write-Host -NoNewline $matched -ForegroundColor Cyan
                    Write-Host -NoNewline $rest -ForegroundColor White
                } else {
                    Write-Host -NoNewline "    "
                    Write-Host -NoNewline $matched -ForegroundColor DarkCyan
                    Write-Host -NoNewline $rest -ForegroundColor DarkGray
                }
            }
        } else {
            $hint = "  Up/Dn move   Tab cycle   Enter select   Esc cancel"
            if ($Candidates.Count -gt $MaxVisibleRows) {
                $hint += "   (+$($Candidates.Count - $MaxVisibleRows) more)"
            }
            if ($hint.Length -gt $width) { $hint = $hint.Substring(0, $width) }
            Write-Host -NoNewline $hint -ForegroundColor DarkGray
        }
    }
}

function Hide-CompletionMenu {
    param([int]$TotalRows)
    Invoke-BelowCursor -RowCount $TotalRows -RowRenderer { param($i) }
}

# One-shot arrow-key list picker built on the same Show-CompletionMenu
# rendering as /stop - Up/Down (or Tab) move the highlight, Enter accepts,
# Escape accepts $DefaultIndex (same as pressing Enter with nothing typed in
# the old numbered prompts). Returns the chosen 0-based index, or $null if
# the menu can't be rendered here (no VT support, or the window's too short)
# - callers should fall back to their own plain prompt in that case, same as
# before this existed.
function Read-MenuSelection {
    param(
        [string[]]$Items,
        [int]$DefaultIndex = 0,
        [int]$MaxVisibleRows = 8
    )

    if ($Items.Count -eq 0) { return $null }
    $vtOk = Enable-VirtualTerminal
    $maxVisible = [Math]::Min($MaxVisibleRows, $Items.Count)
    $totalRows = $maxVisible + 2
    if (-not $vtOk -or (([Console]::WindowHeight - 3) -lt $totalRows)) { return $null }

    1..$totalRows | ForEach-Object { Write-Host "" }
    Write-Host -NoNewline ("$($script:Esc)[{0}A" -f $totalRows)

    $selected = $DefaultIndex
    Show-CompletionMenu -Candidates $Items -Filter '' -SelectedIndex $selected -MaxVisibleRows $maxVisible

    while ($true) {
        $key = [Console]::ReadKey($true)
        if ($key.Key -eq 'Enter') { break }
        if ($key.Key -eq 'Escape') { $selected = $DefaultIndex; break }
        if ($key.Key -eq 'UpArrow') {
            $selected = ($selected - 1 + $Items.Count) % $Items.Count
        } elseif ($key.Key -eq 'DownArrow' -or $key.Key -eq 'Tab') {
            $selected = ($selected + 1) % $Items.Count
        } else {
            continue
        }
        Show-CompletionMenu -Candidates $Items -Filter '' -SelectedIndex $selected -MaxVisibleRows $maxVisible
    }

    Hide-CompletionMenu -TotalRows $totalRows
    return $selected
}

# Draws the "quest-mirror > " prompt (optionally re-echoing already-typed
# text, for the queue-pump mid-typing redraw). When a completion menu may be
# used this turn, it first prints $script:MenuTotalRows blank lines and
# moves back up over them with a *relative* cursor-up - this is what
# guarantees room exists below the prompt before anything ever tries to
# save/restore into that space, so the menu's own rendering never has to
# provoke a fresh scroll mid-render.
function Show-Prompt {
    param([string]$CurrentText = '')
    if ($script:UseMenu) {
        1..$script:MenuTotalRows | ForEach-Object { Write-Host "" }
        Write-Host -NoNewline ("$($script:Esc)[{0}A" -f $script:MenuTotalRows)
    }
    Write-Host -NoNewline "quest-mirror " -ForegroundColor DarkCyan
    Write-Host -NoNewline "> " -ForegroundColor DarkGray
    if ($CurrentText) { Write-Host -NoNewline $CurrentText }
}

function Read-MirrorCommand {
    # A plain Read-Host blocks the thread, and .NET timer/event callbacks
    # don't get pumped reliably while it's blocked (confirmed via live
    # testing - a queued mirror never auto-started while sitting idle at a
    # Read-Host prompt). Polling for keystrokes here instead lets the queue
    # advance itself while the prompt sits idle with nothing typed.
    #
    # /stop completion prefers a real dropdown menu (Show-CompletionMenu)
    # drawn below the prompt via Invoke-BelowCursor, which only ever uses
    # *relative* ANSI/VT cursor moves (save/restore, next-line). An earlier
    # version tried a second line using Console.CursorTop directly and hit
    # Windows Terminal's long-standing ConPTY bugs where CursorTop/
    # SetCursorPosition desyncs from the real cursor across rows - that's a
    # different, buggier code path than relative VT sequences, which the
    # terminal itself interprets natively. If VT mode can't be enabled (or
    # the window's too short to fit the menu), $script:UseMenu stays false
    # and this falls all the way back to the original single-row-only ghost
    # text + Tab-cycle counter, unchanged.
    $vtOk = Enable-VirtualTerminal
    $maxVisible = 5
    $script:MenuTotalRows = $maxVisible + 2
    $script:UseMenu = $false
    if ($vtOk) {
        $script:UseMenu = ([Console]::WindowHeight - 3) -ge $script:MenuTotalRows
        if (-not $script:UseMenu) {
            $maxVisible = [Console]::WindowHeight - 5
            $script:MenuTotalRows = $maxVisible + 2
            $script:UseMenu = $maxVisible -ge 1
        }
    }

    Show-Prompt
    $buffer = New-Object System.Text.StringBuilder
    $tabState = $null
    $overlayLen = 0
    $menuState = $null
    $menuSuppressed = $false
    $menuSuppressedFilter = ''
    $lastPump = Get-Date

    while ($true) {
        if ([Console]::KeyAvailable) {
            $key = [Console]::ReadKey($true)
            if (-not $script:UseMenu -and $key.Key -ne 'Tab') { $tabState = $null }

            Clear-InlineOverlay -Length $overlayLen
            $overlayLen = 0

            if ($key.Key -eq 'Enter') {
                if ($script:UseMenu -and $menuState -and $menuState.Candidates.Count -gt 0) {
                    $newText = "/stop " + $menuState.Candidates[$menuState.SelectedIndex]
                    if ($newText -ne $buffer.ToString()) {
                        $clear = ("`b" * $buffer.Length) + (' ' * $buffer.Length) + ("`b" * $buffer.Length)
                        Write-Host -NoNewline $clear
                        $buffer.Length = 0
                        [void]$buffer.Append($newText)
                        Write-Host -NoNewline $newText
                    }
                }
                if ($script:UseMenu) { Hide-CompletionMenu -TotalRows $script:MenuTotalRows }
                Write-Host ""
                return $buffer.ToString()
            } elseif ($key.Key -eq 'Backspace') {
                if ($buffer.Length -gt 0) {
                    $buffer.Length -= 1
                    Write-Host -NoNewline "`b `b"
                }
            } elseif ($key.Key -eq 'Tab') {
                if ($script:UseMenu) {
                    if ($buffer.ToString() -match '^/stop\s+(.*)$' -and $menuState -and $menuState.Candidates.Count -gt 0) {
                        $menuState.SelectedIndex = ($menuState.SelectedIndex + 1) % $menuState.Candidates.Count
                        $newText = "/stop " + $menuState.Candidates[$menuState.SelectedIndex]
                        $clear = ("`b" * $buffer.Length) + (' ' * $buffer.Length) + ("`b" * $buffer.Length)
                        Write-Host -NoNewline $clear
                        $buffer.Length = 0
                        [void]$buffer.Append($newText)
                        Write-Host -NoNewline $newText
                        Show-CompletionMenu -Candidates $menuState.Candidates -Filter $menuState.Filter -SelectedIndex $menuState.SelectedIndex -MaxVisibleRows $maxVisible
                    }
                } elseif ($buffer.ToString() -match '^/stop\s+(.*)$') {
                    if (-not $tabState) {
                        $candidates = Get-StopCandidates -Typed $Matches[1]
                        if ($candidates.Count -gt 0) {
                            $tabState = [PSCustomObject]@{ Candidates = $candidates; Index = 0 }
                        }
                    } else {
                        $tabState.Index = ($tabState.Index + 1) % $tabState.Candidates.Count
                    }
                    if ($tabState) {
                        $newText = "/stop " + $tabState.Candidates[$tabState.Index]
                        $clear = ("`b" * $buffer.Length) + (' ' * $buffer.Length) + ("`b" * $buffer.Length)
                        Write-Host -NoNewline $clear
                        $buffer.Length = 0
                        [void]$buffer.Append($newText)
                        Write-Host -NoNewline $newText
                    }
                }
            } elseif ($key.Key -eq 'UpArrow') {
                if ($script:UseMenu -and $menuState -and $menuState.Candidates.Count -gt 0) {
                    $menuState.SelectedIndex = ($menuState.SelectedIndex - 1 + $menuState.Candidates.Count) % $menuState.Candidates.Count
                    Show-CompletionMenu -Candidates $menuState.Candidates -Filter $menuState.Filter -SelectedIndex $menuState.SelectedIndex -MaxVisibleRows $maxVisible
                }
            } elseif ($key.Key -eq 'DownArrow') {
                if ($script:UseMenu -and $menuState -and $menuState.Candidates.Count -gt 0) {
                    $menuState.SelectedIndex = ($menuState.SelectedIndex + 1) % $menuState.Candidates.Count
                    Show-CompletionMenu -Candidates $menuState.Candidates -Filter $menuState.Filter -SelectedIndex $menuState.SelectedIndex -MaxVisibleRows $maxVisible
                }
            } elseif ($key.Key -eq 'Escape') {
                if ($script:UseMenu -and $menuState) {
                    Hide-CompletionMenu -TotalRows $script:MenuTotalRows
                    $menuSuppressed = $true
                    $menuSuppressedFilter = if ($buffer.ToString() -match '^/stop\s+(.*)$') { $Matches[1] } else { '' }
                    $menuState = $null
                }
            } elseif (-not [char]::IsControl($key.KeyChar)) {
                [void]$buffer.Append($key.KeyChar)
                Write-Host -NoNewline $key.KeyChar
            }

            # Skip the shared recompute below for the keys that already fully
            # handled their own redraw above - re-running it for those would
            # immediately recompute a fresh $menuState (Index reset to 0) and
            # stomp on the Up/Down/Tab selection that was just made.
            $skipRecompute = ($key.Key -in @('UpArrow', 'DownArrow', 'Escape')) -or ($script:UseMenu -and $key.Key -eq 'Tab')

            if (-not $skipRecompute) {
                if ($buffer.ToString() -match '^/stop\s+(.*)$') {
                    $typed = $Matches[1]
                    if ($script:UseMenu) {
                        if ($menuSuppressed -and $typed -eq $menuSuppressedFilter) {
                            # Escape was just pressed for this exact fragment -
                            # stay hidden until the user actually changes it.
                        } else {
                            $menuSuppressed = $false
                            $candidates = Get-StopCandidates -Typed $typed
                            if ($candidates.Count -eq 0) {
                                if ($menuState) { Hide-CompletionMenu -TotalRows $script:MenuTotalRows }
                                $menuState = $null
                            } else {
                                $menuState = [PSCustomObject]@{ Candidates = $candidates; Filter = $typed; SelectedIndex = 0 }
                                Show-CompletionMenu -Candidates $candidates -Filter $typed -SelectedIndex 0 -MaxVisibleRows $maxVisible
                            }
                        }
                    } elseif ($tabState) {
                        if ($tabState.Candidates.Count -gt 1) {
                            $overlayLen = Write-InlineOverlay -Text (" ({0}/{1})" -f ($tabState.Index + 1), $tabState.Candidates.Count)
                        }
                    } elseif ($typed) {
                        $candidates = Get-StopCandidates -Typed $typed
                        if ($candidates.Count -gt 0 -and $candidates[0].Length -gt $typed.Length) {
                            $overlayLen = Write-InlineOverlay -Text $candidates[0].Substring($typed.Length)
                        }
                    }
                } elseif ($script:UseMenu -and $menuState) {
                    Hide-CompletionMenu -TotalRows $script:MenuTotalRows
                    $menuState = $null
                    $menuSuppressed = $false
                }
            }
            continue
        }

        # Keep this sleep short so typing stays responsive - a 150ms poll
        # here made every keystroke feel laggy. The queue pump itself (which
        # enumerates all processes) only needs to run every couple seconds,
        # not on every idle tick, so it's throttled separately below.
        Start-Sleep -Milliseconds 25
        if (((Get-Date) - $lastPump).TotalMilliseconds -lt 2000) { continue }
        $lastPump = Get-Date

        # Mirrors Invoke-QueuePump's own guard so the menu is only hidden
        # when a queued mirror is actually about to print output through it -
        # avoids a needless hide/reshow flicker on every idle poll tick.
        $queuePumpWillRun = $script:MirrorQueue.Count -gt 0 -and -not (Test-MirrorActive)
        if ($queuePumpWillRun -and $script:UseMenu -and $menuState) {
            Hide-CompletionMenu -TotalRows $script:MenuTotalRows
        }

        $before = $script:MirrorQueue.Count
        Invoke-QueuePump
        if ($script:MirrorQueue.Count -lt $before) {
            # A queued mirror just started - redraw the prompt line so the
            # user's partially-typed input isn't lost underneath the output.
            Clear-InlineOverlay -Length $overlayLen
            Write-Host ""
            Show-Prompt -CurrentText $buffer.ToString()
            $overlayLen = 0
        }

        if ($queuePumpWillRun -and $script:UseMenu -and $menuState) {
            Show-CompletionMenu -Candidates $menuState.Candidates -Filter $menuState.Filter -SelectedIndex $menuState.SelectedIndex -MaxVisibleRows $maxVisible
        }
    }
}

# --- src/Main.Driver.ps1 ---------------------------------------------------
# ---------------------------------------------------------------------------
# Driver - REPL/non-interactive entry point. Everything above this has only
# defined functions; this is the first place anything actually runs.
# ---------------------------------------------------------------------------

function Show-Help {
    Write-Host ""
    Write-Host "  Commands" -ForegroundColor DarkCyan
    Write-Host "    <game name>       start a mirror, or queue it if one's already running" -ForegroundColor Gray
    Write-Host "    <game name> --pick   choose which executable to use, if the first didn't work" -ForegroundColor Gray
    Write-Host "    /status           show the running mirror and the queue" -ForegroundColor Gray
    Write-Host "    /stop <game name> stop it if running, or cancel it if queued (Tab to autocomplete)" -ForegroundColor Gray
    Write-Host "    /stop all         stop the running mirror and clear the queue" -ForegroundColor Gray
    Write-Host "    /help             show this list" -ForegroundColor Gray
    Write-Host "    /exit             quit (or just press Enter)" -ForegroundColor Gray
    Write-Host ""
}

function Invoke-QuestMirror {
    param([string]$RawName, [int]$PresetExeChoice = 0, [bool]$Interactive = $true)

    $forcePick = $false
    if ($RawName -match '^(.*?)\s+--?pick$') {
        $RawName = $Matches[1].Trim()
        $forcePick = $true
    }

    Write-Step "Resolving `"$RawName`""

    $apps = Get-DetectableApps

    # Not named $matches - that's PowerShell's automatic -match variable
    # (names are case-insensitive), so any -match in between would clobber it.
    # @() so zero results is an empty array rather than $null, which throws
    # "Cannot index into a null array" on the [0] below.
    $gameMatches = @(Find-GameMatch -Apps $apps -Query $RawName)
    if ($gameMatches.Count -eq 0 -or $gameMatches[0].Score -lt 75) {
        $canonical = Resolve-SteamCanonicalName -RawName $RawName
        if ($canonical -and $canonical -ne $RawName) {
            Write-Meta "Steam suggests `"$canonical`" - retrying..."
            $retry = @(Find-GameMatch -Apps $apps -Query $canonical)
            if ($retry.Count -gt 0 -and ($gameMatches.Count -eq 0 -or $retry[0].Score -gt $gameMatches[0].Score)) {
                $gameMatches = $retry
            }
        }
    }

    if ($gameMatches.Count -eq 0) {
        Write-Err2 "No matching game found for `"$RawName`""
        return
    }

    $chosen = $gameMatches[0].App
    if ($gameMatches.Count -gt 1 -and $gameMatches[0].Score -lt 90) {
        Write-Warn2 "Multiple possible matches:"
        for ($i = 0; $i -lt $gameMatches.Count; $i++) {
            Write-Host ("      [{0}] {1}" -f ($i + 1), $gameMatches[$i].App.name) -ForegroundColor Gray
        }
        if ($Interactive) {
            Write-Host -NoNewline "    Pick one (Enter for [1]): " -ForegroundColor DarkGray
            $pick = Read-Host
            $index = 0
            $valid = $pick -and [int]::TryParse($pick, [ref]$index) -and $index -ge 1 -and $index -le $gameMatches.Count
            if ($valid) {
                $chosen = $gameMatches[$index - 1].App
                Write-Ok "Using [$index] $($chosen.name)"
            } elseif ($pick) {
                Write-Meta "'$pick' isn't valid (1-$($gameMatches.Count)), defaulting to [1]"
            }
        } else {
            Write-Meta "Non-interactive, defaulting to [1] $($chosen.name)"
        }
    } else {
        Write-Ok "Matched $($chosen.name)"
    }

    $exe = Select-BestExecutable -Executables $chosen.executables -PresetChoice $PresetExeChoice -ForcePrompt $forcePick
    if (-not $exe) {
        $platformLabel = if ($script:PlatformOS -eq 'darwin') { 'macOS' } else { 'Windows' }
        Write-Err2 "`"$($chosen.name)`" has no known $platformLabel executable in Discord's list"
        return
    }

    $exeName = Split-Path $exe.name -Leaf
    Write-Ok "Target exe: $exeName"

    if ($Interactive -and (Test-MirrorActive)) {
        $script:MirrorQueue.Enqueue([PSCustomObject]@{ ExeName = $exeName; DisplayName = $chosen.name })
        Write-Ok "Queued `"$($chosen.name)`" - starts automatically once the current mirror finishes (position $($script:MirrorQueue.Count))"
        return
    }

    Start-MirrorForGame -ExeName $exeName -DisplayName $chosen.name
}

Initialize-Platform

if ($GameName) {
    try {
        Invoke-QuestMirror -RawName $GameName -PresetExeChoice $ExeChoice -Interactive $false
    } catch {
        Write-Err2 "Unexpected error: $($_.Exception.Message)"
        exit 1
    }
} else {
    Write-BigBanner
    $platformLabel = if ($script:PlatformOS -eq 'darwin') { 'macOS' } else { 'Windows' }
    Write-Meta "Platform: $platformLabel"
    Write-Meta "Each mirror runs ~17.5 min. Type /help for commands."

    while ($true) {
        Write-Host ""
        $gameInput = Read-MirrorCommand

        if ([string]::IsNullOrWhiteSpace($gameInput) -or $gameInput.Trim() -eq '/exit') {
            break
        }

        switch -Regex ($gameInput.Trim()) {
            '^/help$' { Show-Help; continue }
            '^/status$' { Show-ActiveMirrors; continue }
            '^/stop\s+all$' { Stop-AllMirrors; continue }
            '^/stop\s+(.+)$' { Stop-Mirror -Query $Matches[1].Trim(); continue }
            default {
                Write-Divider
                try {
                    Invoke-QuestMirror -RawName $gameInput -Interactive $true
                } catch {
                    Write-Err2 "Unexpected error: $($_.Exception.Message)"
                }
                continue
            }
        }
    }

    Write-Host ""
    if ($script:MirrorQueue.Count -gt 0) {
        Write-Warn2 "$($script:MirrorQueue.Count) queued game(s) will NOT start - the queue only advances while this window is open"
    }
    Write-Meta "Bye - a running mirror keeps going until it expires or you /stop it."
}
