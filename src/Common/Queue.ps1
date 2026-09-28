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
