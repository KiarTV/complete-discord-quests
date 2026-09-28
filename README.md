# Discord Quest Completer - complete Discord Quests without playing the game

**Finish Discord "play" Quests and collect the Orbs and rewards without downloading, installing, or playing the game.** Type the game's name and Discord sees it as running.

<p align="center">
  <img src="docs/demo.svg" alt="Typing roblox into quest-mirror starts a process that Discord detects as Roblox running" width="760">
</p>

<p align="center">
  <a href="https://github.com/KiarTV/complete-discord-quests/releases/latest"><img src="https://img.shields.io/github/v/release/KiarTV/complete-discord-quests?label=download" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/Windows-supported-2ea44f" alt="Windows supported">
  <img src="https://img.shields.io/badge/macOS-experimental-yellow" alt="macOS experimental">
  <img src="https://img.shields.io/badge/install-none%20needed-blue" alt="No install needed">
</p>

## Quick start (Windows, 3 steps)

1. **Accept the Quest in Discord** on Discord's Quests page, and keep Discord
   open.
2. **Open PowerShell** (press <kbd>Win</kbd>, type `powershell`, press Enter) and
   paste:
   ```powershell
   irm https://raw.githubusercontent.com/KiarTV/complete-discord-quests/master/mirror.ps1 | iex
   ```
3. **Type the game's name** from the Quest (for example `roblox` or `apex legends`)
   and press Enter. Leave it running for about 15 minutes, then claim your
   reward in Discord.

Prefer to download something? Grab **[QuestMirror-windows.zip](https://github.com/KiarTV/complete-discord-quests/releases/latest/download/QuestMirror-windows.zip)**,
extract it, and double-click `QuestMirror.cmd`.

### macOS (experimental)

Paste into Terminal:

```bash
curl -fsSL https://raw.githubusercontent.com/KiarTV/complete-discord-quests/master/scripts/install.sh | bash
```

You don't need Homebrew or an admin password. If PowerShell isn't installed, the
script downloads a portable copy once and reuses it after that. macOS support
**hasn't been confirmed against a real Discord Quest yet**. If you try it,
please [open an issue](https://github.com/KiarTV/complete-discord-quests/issues) and say
whether your Quest progress moved.

## How to complete a Discord Quest without playing the game

Discord "play" Quests (the "Play *Game* for 15 minutes" kind) only check that
a program with the game's executable name is running on your PC. They don't
check that the game is installed or that you're playing it. This tool:

1. Looks the game up in **Discord's own public list of detectable games** to
   find the exact executable name Discord watches for (e.g. `roblox.exe`).
2. If your spelling doesn't match well, asks Steam's store search for the
   official name (e.g. "gta 5" → "Grand Theft Auto V") and tries again.
3. Copies a harmless built-in system program (`cmd.exe` on Windows,
   `/bin/sleep` on macOS), renames the copy to that executable name, and runs
   it for about 17.5 minutes. Most Quests need 15.

Nothing is downloaded from the game, and the tool doesn't touch your Discord
account, network traffic, or other users. It only changes what your own
Discord client sees running.

## Commands

The prompt (`quest-mirror >`) runs one mirror at a time. If you type another
game while one is running, it's queued and starts automatically when the
current one finishes.

| Command               | What it does                                     |
| --------------------- | ------------------------------------------------ |
| `<game name>`         | start a mirror, or queue it if one's running     |
| `<game name> --pick`  | choose which executable to use (if the first one didn't register) |
| `/status`             | show the running mirror and the queue            |
| `/stop <game name>`   | stop it if running, or cancel it if queued       |
| `/stop all`           | stop the running mirror and clear the queue      |
| `/help`               | show the command list                            |
| `/exit` (or blank)    | quit (the running mirror keeps going)            |

## FAQ

### Does this download or install the game?
No. Nothing from the game is ever downloaded. The "game" is a renamed copy of
a program that's already on your computer.

### Which Quests does it work for?
Quests that ask you to **play** a game for a number of minutes. Video Quests
are a different mechanism, and this tool doesn't do them.

### Can I get banned for this?
Use it at your own risk. It doesn't modify Discord or talk to Discord's
servers, but faking game activity to earn Quest rewards is against the spirit
of Quests and may break Discord's Terms of Service.

### Discord isn't detecting the game. What now?
- Make sure you **accepted the Quest first** and Discord is running.
- Try `<game name> --pick` and choose a different executable. Some games list
  several.
- If you see *"Process exited immediately after launch,"* your antivirus
  removed the renamed copy. Check Windows Security → Protection history and
  allow the folder it prints.
- Don't run PowerShell as administrator unless you need to. The tool handles
  it, but a normal window is simpler.

### Where are files stored? How do I remove it?
Everything lives in one folder: `%LOCALAPPDATA%\quest-mirror\` on Windows,
`~/Library/Caches/quest-mirror/` on macOS. Delete that folder to remove
everything. Discord's game list is cached there and refreshed every 24 hours.

## Keywords

Discord Quest completer · complete Discord Quests without playing · Discord Quest
without downloading the game · earn Discord Orbs · Discord Quest auto complete ·
fake game activity for Discord Quests · Discord Quest spoofer for Windows and macOS
