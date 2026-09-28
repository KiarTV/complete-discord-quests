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
