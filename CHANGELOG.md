# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), with versions numbered
`<major>.<minor>` and a two-digit minor (v1.00, v1.01 ... v1.10) to match the release names.

## [Unreleased]

## [1.04] - 2026-11-16

### Fixed
- **Homelab.cmd works again.** In v1.03 it stopped with "Join-Path: Cannot bind argument to parameter 'Path' because it is an empty string", so the release zip couldn't make its shortcut or start Homelab. `New-HomelabShortcut.ps1` worked out Homelab.ps1's path in a `param()` default, where Windows PowerShell 5.1 leaves `$PSScriptRoot` empty under `powershell.exe -File`. It now works the path out in the script body. (`Builds\Homelab.lnk` was never affected, because Build.cmd passed the path itself.)

### Changed
- `Build.cmd` runs the shortcut maker the same way Homelab.cmd does, with `powershell.exe -File` and no script path, so a build fails if the release's Homelab.cmd would.

## [1.03] - 2026-11-15

### Changed
- **No more exe.** Antivirus (ESET) kept flagging the PS2EXE-built exe as a trojan (false positives), so Homelab now ships as its script. The release is a zip, `Homelab-v1.03.zip`, holding a `Homelab v1.03` folder: `Homelab.ps1`, `assets\`, `Homelab.cmd` and `New-HomelabShortcut.ps1`.
- **Homelab.cmd** makes the Homelab shortcut next to it and in the Start menu, then starts Homelab. The shortcut starts it without a console window (`conhost --headless` on Windows 11; hidden PowerShell on older Windows) with Homelab's icon.
- Homelab sets its own taskbar ID (`jason4bury.Homelab`), shared with the shortcut, so the taskbar shows Homelab's icon, not PowerShell's, and pinning Homelab works.
- `Build.cmd` replaces `Build-Exe.cmd`: it checks the scripts, runs PSScriptAnalyzer, makes `Builds\Homelab v<version>\` and the zip, refreshes `Builds\Homelab.lnk` (for the Home Launcher) and scans the result with ESET's command-line scanner if it's installed.
- The Home Launcher starts Homelab through `Builds\Homelab.lnk` (`Target` in `launcher.json`).
- Help > Where things live says where Homelab.ps1 is and how the shortcut is made.

### Fixed
- The default Icons folder is still the one beside `Builds\` and `Source\` when Homelab runs from a release folder in `Builds\`, so every version shares it.

## [1.02] - 2026-11-15

### Fixed
- Help: a new "The header" section lists every header button, including Refresh and About, which Help didn't mention before.
- Help: the right-click menu no longer lists Open web page twice. Its second web item is now named as the menu shows it (Open via phpMyAdmin...).
- Help: the machine fields use the Settings labels (Address, SSH user, port, Folder, Compose file, Project, Web address, Path map) instead of the settings.json names. Help also says the machine button only shows once there's a machine besides This PC.
- Help: says where Cancel the remaining is (in the Actions menu while a Start all or Stop all runs), and that Restart unhealthy covers every tab, whatever the search.
- Help: the Homepage icon folder is the one set in Settings, or homepage\icons next to This PC's compose file. The refresh time (15 seconds by default) and Enter on a Running row are now in Help too.

## [1.01] - 2026-11-15

### Added
- An **↑ 2 updates** button in the header when the update check finds newer images. Its tooltip names the containers, and clicking it shows only those (on every tab, together with the search); click again to show them all.

### Changed
- The update count is no longer part of the header counts text, so a narrow window can't cut it off.
- On a narrow window the search box now shrinks to its smallest (150 px) before the counts text trims; the counts trim last, with the whole text in their tooltip.

## [1.00] - 2026-11-14
First release.

### Added
- Every service in the compose file as a tile with its icon, name, state and an Open button.
- A tab for each `home.group` label, plus an All tab with every group under its own heading.
- Open picks the right way in: the web page, a database's admin page, a command window or the live log. The `home.open` label overrides it.
- Right-click menu: web page, admin page, command window, log, config folder and copy address.
- Portainer button in the header when Portainer is running (or set by `PortainerUrl`).
- Light and dark themes, or follow Windows (Auto), with a matching title bar.
- A box over the tiles while the compose file is read or refreshed, then how many containers it found.
- Other machines over SSH: show the containers, compose file and icons on a NAS or other machine instead of this PC.
- Search (Ctrl+F), F5 to reload, and automatic reloading when the compose file is saved.
- Icons from Homelab's own Icons folder (beside Builds\ and Source\, made if missing, set in Settings > General; the same for every machine), then Homepage's icon folder (can be turned off), then Dashboard Icons (cached locally), with coloured initials as a fallback. Icons aren't shipped in the repo, since the logos belong to their projects; `Icons/` is in .gitignore. The per-machine icon folder is gone, and an old IconFolder setting becomes the Homepage folder.
- Start, Stop and Restart one container from the right-click menu, here or on another machine.
- The tile button says Open only when the container is running; otherwise it's a Start button.
- A container's web page opens only while it's running: the menu's web page items are greyed out (with a "Start the container first" tooltip), and double-clicking a tile or Running row, or Enter in the search box, just says it isn't running.
- Running tab: the running containers as a list, updated on every status check.
- Private tab lock: chosen groups stay hidden until a password is typed (stored as a salted PBKDF2 hash). The lock panel has a Cancel button (and Esc) that goes back to the previous tab without setting or checking a password.
- Help button (or F1) opening a resizable Help window explaining tiles, menus, keys, machines, icons, labels, the Private lock and settings.
- Settings window: machines (address, SSH, folders, path map, test connection), this PC's compose file and icon folder, refresh time, Portainer address, Private groups and password. Save applies the changes and keeps the window open with a Saved note; Close shuts it. The theme is set only with the header button. A machine's web address must be a host name, not an IP address (some apps, such as Radarr and Prowlarr, refuse pages opened by IP).
- Restyled menus: rounded, shadowed and themed, with each machine's address in the machine menu.
- An About box matching Help and Settings: the light or dark theme, a dark title bar in dark mode, a rounded card and an accent Close button.
- Docker and SSH run with real time limits: output and errors are read together (so a chatty command can't hang), a command that runs too long is stopped along with anything it started, and finished work is cleaned up. Reads get 90 seconds; Start and Restart get 15 minutes (compose up may pull an image first), Stop 5 minutes.
- Icon downloads run on their own background thread, one at a time with 5 seconds each, so a slow download never delays a status check.
- settings.json is written safely (a new file swapped in, the previous one kept as settings.json.bak). A file that can't be read is renamed settings.bad-<time>.json, the banner says so, and Homelab doesn't save over it on close.
- An unexpected error is logged and shown in the banner instead of closing Homelab. Copying to a busy clipboard, saving a picked compose file, a blank compose path and a bad SSH port are all handled; Settings won't save a blank compose file or a port outside 1 to 65535. A RefreshSeconds that isn't a number falls back to 15, and values outside 5 to 3600 are brought into range.
- Error banners show the lines that explain the error (Docker puts the reason last), not the first lines of output.
- Switching machine (or compose file) ignores answers still on their way from the old one, so the tiles never show the previous machine's states.
- Status checks prefer containers from this compose file's project, so two stacks with a service of the same name don't get mixed up.
- The Running tab updates its rows in place, so an open right-click menu or hover isn't lost on every status check; it's rebuilt only when what's running changes.
- The banner has a ✕ to dismiss it, and a "Couldn't start..." banner clears when that container's next start, stop or restart works. Notes on the status line go after 5 seconds.
- One Homelab at a time: starting it again brings the open window to the front.
- The window's position is remembered along with its size, and kept inside the screen's work area (for example after unplugging a monitor).
- Enter in the search box opens the first running match on the open tab, or says on the status line that none of the matches is running.
- "Updated hh:mm:ss" shows the time of the last status check that worked.
- Setting, changing or removing the Private password only says it worked once settings.json has been saved.
- Actions menu: Start all and Stop all on the open tab, and Restart unhealthy, each after a confirmation listing the containers; they run one at a time and can be cancelled. A locked Private tab is never touched.
- Windows notifications when a container becomes unhealthy or stops with an error by itself (not on the first check, and not for containers you just started, stopped or restarted). Can be turned off in Settings.
- Update badges: every 6 hours, or from Actions > Check for image updates now, each image's tag is compared with its registry (Docker Hub, ghcr.io, lscr.io, quay.io...) using read-only requests; tiles with a newer image get a small blue arrow and the header counts them. Works over SSH for the NAS. Nothing is ever pulled.
- Keyboard: tiles and Running rows take focus with an accent outline; Enter opens, the menu key (or Shift+F10) shows the right-click menu. Buttons show the same outline.
- Look: Light-theme status and hint colours meet 4.5:1 contrast (green #15803D, amber #B45309, greys #5F6673); Dark-theme hints and counts are lighter too. Initials are white or dark, whichever reads better on their colour. Icons sit on a faint plate in Dark, so dark logos stay visible. Tiles are 276 px wide. Disabled buttons look flat and grey. Text fields are rounded everywhere. The Private lock uses the Segoe lock icon instead of an emoji. Scroll bars work horizontally too. The header fits below 1300 px (the search box shrinks and the counts trim).
- Better names for MariaDB, DCM, tinyMediaManager, LazyLibrarian and ReadMeABook.
- The state shows just the state and health (Running, Unhealthy, Starting, Stopped, Stopped (error 1)...), without how long the container has been up.
