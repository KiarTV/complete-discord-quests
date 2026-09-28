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
