<#
.SYNOPSIS
    Homelab - Every container in your compose file as a tile, grouped by label, one click from its web page.

.DESCRIPTION
    PowerShell/WPF tool for opening every Docker container in a compose file from one window of tiles.

    Project layout (house style):
        <project>\Source\               the git repo (this script is in Source\src\)
        <project>\Source\assets\        icon (.ico) and logo (.png)
        <project>\Builds\               Homelab v<version>\ (this script, assets\ and Homelab.cmd) and
                                        Homelab-v<version>.zip, made by Build.cmd
    No exe: the script runs in Windows PowerShell, started hidden by the Homelab shortcut
    (made by Homelab.cmd / New-HomelabShortcut.ps1).
    Settings and data: %APPDATA%\Homelab

.NOTES
    Author:    Jason Rhodes
    Copyright: (c) 2026 Jason Rhodes - MIT licence (see LICENSE)
    Version:   see $script:AppVersion below and CHANGELOG.md
    Runs in Windows PowerShell 5.1 on an STA thread (WPF needs it).
#>

#Requires -Version 5.1

$ErrorActionPreference = 'Stop'

# The version lives here and in CHANGELOG.md; Build.cmd stops if they disagree.
# Two-digit minor: 1.00, 1.01 ... 1.10. The release folder is "Homelab v<version>".
$script:AppName     = 'Homelab'
$script:AppVersion  = '1.06'
# The taskbar identity, shared with the Homelab shortcut, so the taskbar shows Homelab's icon
# (not PowerShell's) and a pinned Homelab starts Homelab.
$script:AppId       = 'jason4bury.Homelab'
$script:Description = 'PowerShell/WPF tool for opening every Docker container in a compose file from one window of tiles'
$script:Copyright   = 'Copyright (c) 2026 Jason Rhodes'
$script:RepoUrl     = 'https://github.com/jason4bury/Homelab'
$script:IsPrivate   = $false   # private tools keep their data in <project>\Data, inside the vault

# ---------------------------------------------------------------------------
#  Where is everything?
# ---------------------------------------------------------------------------
if (-not $PSCommandPath) {
    throw 'Run Homelab.ps1 as a file (the Homelab shortcut, Homelab.cmd or powershell -File), not pasted or dot-sourced.'
}

# WPF needs an STA thread. Started any other way, restart in Windows PowerShell with -STA.
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Start-Process -FilePath $ps -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-WindowStyle', 'Hidden', '-File', "`"$PSCommandPath`"")
    return
}

# One Homelab at a time: a second launch brings the open window to the front, then ends.
$script:FirstInstance = $false
$script:InstanceMutex = New-Object Threading.Mutex($true, "Local\$($script:AppName)-SingleInstance", [ref]$script:FirstInstance)
if (-not $script:FirstInstance) {
    try {
        if (-not ('Homelab.Win' -as [type])) {
            Add-Type -Namespace 'Homelab' -Name 'Win' -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
[DllImport("user32.dll")] public static extern bool IsIconic(IntPtr hWnd);
'@
        }
        $other = Get-Process | Where-Object { $_.Id -ne $PID -and $_.MainWindowHandle -ne [IntPtr]::Zero -and $_.MainWindowTitle -match "^$([regex]::Escape($script:AppName)) v\d" } | Select-Object -First 1
        if ($other) {
            if ([Homelab.Win]::IsIconic($other.MainWindowHandle)) { [void][Homelab.Win]::ShowWindow($other.MainWindowHandle, 9) }   # 9 = restore
            [void][Homelab.Win]::SetForegroundWindow($other.MainWindowHandle)
        }
    } catch { Write-Verbose "Couldn't bring the open Homelab to the front: $($_.Exception.Message)" }
    exit 0
}

# The taskbar groups windows by this ID. Set before any window opens; the Homelab shortcut
# carries the same ID and the icon, so the taskbar button and a pinned Homelab use them.
try {
    if (-not ('Homelab.Shell' -as [type])) {
        Add-Type -Namespace 'Homelab' -Name 'Shell' -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string appId);'
    }
    [void][Homelab.Shell]::SetCurrentProcessExplicitAppUserModelID($script:AppId)
} catch { Write-Verbose "No taskbar ID: $($_.Exception.Message)" }

# From the repo the script is in Source\src\ and the assets in Source\assets\;
# in a release folder (Homelab v<version>\) they sit together: Homelab.ps1 and assets\.
$script:ProgramDir = Split-Path -Parent $PSCommandPath
$script:AssetsDir  = Join-Path $script:ProgramDir 'assets'
if (-not (Test-Path -LiteralPath $script:AssetsDir)) { $script:AssetsDir = Join-Path (Split-Path -Parent $script:ProgramDir) 'assets' }

function Get-ProjectDir {
    <# <project>, the folder holding Source\ and Builds\: up from Source\src\ (the repo) or
       from Builds\Homelab v<version>\ (a release). A release unzipped anywhere else is its own. #>
    $dir = $script:ProgramDir
    if ((Split-Path -Leaf (Split-Path -Parent $dir)) -eq 'Builds') { $dir = Split-Path -Parent $dir }
    foreach ($leaf in 'src', 'Source', 'Builds') {
        if ((Split-Path -Leaf $dir) -eq $leaf) { $dir = Split-Path -Parent $dir }
    }
    return $dir
}

function Get-DataDir {
    <# Public tools: %APPDATA%\<App Name>. Private tools: <project>\Data, beside Source\ and
       Builds\, so nothing is written to the unencrypted drive. Never inside Source\ (keeps
       personal data out of git) or Builds\ (rebuilding must not touch it). #>
    if (-not $script:IsPrivate) { return (Join-Path $env:APPDATA $script:AppName) }
    return (Join-Path (Get-ProjectDir) 'Data')
}
$script:DataDir      = Get-DataDir
$script:SettingsPath = Join-Path $script:DataDir 'settings.json'
$script:LogPath      = Join-Path $script:DataDir "$($script:AppName).log"
if (-not (Test-Path -LiteralPath $script:DataDir)) { New-Item -ItemType Directory -Path $script:DataDir -Force | Out-Null }

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# ---------------------------------------------------------------------------
#  Small helpers
# ---------------------------------------------------------------------------
function Write-AppLog {
    param([string]$Message)
    try { Add-Content -LiteralPath $script:LogPath -Value ('{0}  {1}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message) -Encoding UTF8 }
    catch { Write-Verbose "Couldn't write the log: $($_.Exception.Message)" }
}

function Get-AssetBytes {
    <# An asset by file name, from the assets folder ($script:AssetsDir). #>
    param([string]$Name)
    $path = Join-Path $script:AssetsDir $Name
    if (Test-Path -LiteralPath $path) { return [IO.File]::ReadAllBytes($path) }
    return $null
}

function Get-AssetImage {
    <# A frozen BitmapImage for a WPF Image or window Icon, or $null if the asset is missing. #>
    param([string]$Name)
    $bytes = Get-AssetBytes $Name
    if (-not $bytes) { return $null }
    $img = New-Object Windows.Media.Imaging.BitmapImage
    $img.BeginInit()
    $img.StreamSource = New-Object IO.MemoryStream (, $bytes)
    $img.CacheOption  = 'OnLoad'
    $img.EndInit(); $img.Freeze()
    return $img
}

# Set when settings.json couldn't be read: the banner says so, and closing doesn't save
# (a Save the user asks for still does; the bad file has been moved aside by then).
$script:SettingsProblem = ''
$script:SkipSaveOnClose = $false

function Get-AppSetting {
    <# Settings from settings.json in the data folder; $null where unset. A file that can't be
       read is renamed settings.bad-<time>.json, so nothing is saved over it. #>
    if (-not (Test-Path -LiteralPath $script:SettingsPath)) { return [pscustomobject]@{} }
    try {
        $s = Get-Content -LiteralPath $script:SettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($s -is [pscustomobject]) { return $s }
        throw 'it does not hold a settings object.'
    } catch {
        $why = $_.Exception.Message
        $bad = Join-Path $script:DataDir ('settings.bad-{0}.json' -f (Get-Date).ToString('yyyyMMdd-HHmmss'))
        try { Move-Item -LiteralPath $script:SettingsPath -Destination $bad -ErrorAction Stop; $kept = "It was kept as $(Split-Path -Leaf $bad)" }
        catch { $kept = "It couldn't be renamed ($($_.Exception.Message))" }
        Write-AppLog "settings.json couldn't be read: $why $kept."
        $hasBak = Test-Path -LiteralPath "$script:SettingsPath.bak"
        $script:SettingsProblem = "settings.json couldn't be read, so Homelab started with default settings. $kept$(if ($hasBak) { '; the last good copy is settings.json.bak' }), in $script:DataDir. Settings won't be saved when Homelab closes."
        $script:SkipSaveOnClose = $true
    }
    return [pscustomobject]@{}
}

function Save-AppSetting {
    <# Writes settings.json.tmp, then swaps it in, keeping the previous file as settings.json.bak,
       so a crash or full disk mid-write never leaves a half-written settings.json. #>
    param([Parameter(Mandatory)][object]$Settings)
    $json = $Settings | ConvertTo-Json -Depth 6
    $tmp = "$script:SettingsPath.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding($false)))
    if (Test-Path -LiteralPath $script:SettingsPath) { [IO.File]::Replace($tmp, $script:SettingsPath, "$script:SettingsPath.bak") }
    else { [IO.File]::Move($tmp, $script:SettingsPath) }
}

function Get-ParentFolder([string]$Path) {
    <# The folder a file is in, or '' for a blank or unusable path (Split-Path throws on those). #>
    if (-not $Path -or -not $Path.Trim()) { return '' }
    try { $d = [IO.Path]::GetDirectoryName($Path.Trim()); if ($d) { return $d } else { return '' } } catch { return '' }
}

function Test-FilePath([string]$Path, [switch]$Folder) {
    <# Test-Path that says $false for a blank or malformed path instead of throwing. #>
    if (-not $Path -or -not $Path.Trim()) { return $false }
    try { return (Test-Path -LiteralPath $Path -PathType $(if ($Folder) { 'Container' } else { 'Leaf' })) } catch { return $false }
}

function New-XamlWindow {
    param([Parameter(Mandatory)][string]$Xaml)
    $reader = New-Object System.Xml.XmlNodeReader ([xml]$Xaml)
    return [Windows.Markup.XamlReader]::Load($reader)
}

#region ABOUT-BOX
# ---------------------------------------------------------------------------
#  About box (house style)
#  Every Home tool's About shows: logo, name, version, the one-line description,
#  the copyright and MIT licence, the repo link and where settings live.
#  House style sets WHAT it says, not how it looks: restyle the XAML to match the
#  app's own window (colours, fonts, buttons), or move these lines onto an existing
#  About tab. Keep the wording.
# ---------------------------------------------------------------------------
$script:AboutXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        SizeToContent="WidthAndHeight" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WinBg}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI" FontSize="13">
    <StackPanel Margin="14" Width="460">
        <Border Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="20,18">
            <StackPanel>
                <StackPanel Orientation="Horizontal">
                    <Image x:Name="AboutLogo" Width="64" Height="64" Margin="0,0,16,0" RenderOptions.BitmapScalingMode="HighQuality"/>
                    <StackPanel VerticalAlignment="Center">
                        <TextBlock x:Name="AboutName" FontSize="20" FontWeight="SemiBold"/>
                        <TextBlock x:Name="AboutVersion" Foreground="{DynamicResource Muted}" Margin="0,2,0,0"/>
                    </StackPanel>
                </StackPanel>
                <TextBlock x:Name="AboutDescription" TextWrapping="Wrap" Margin="0,16,0,0" LineHeight="20"/>
                <TextBlock x:Name="AboutNew" TextWrapping="Wrap" Margin="0,10,0,0" LineHeight="20"/>
                <Border Height="1" Background="{DynamicResource Line}" Margin="0,14,0,12"/>
                <TextBlock x:Name="AboutData" TextWrapping="Wrap" Foreground="{DynamicResource Muted}"/>
                <TextBlock Margin="0,8,0,0"><Hyperlink x:Name="AboutRepo" Foreground="{DynamicResource Link}"><Run x:Name="AboutRepoText"/></Hyperlink></TextBlock>
                <TextBlock x:Name="AboutCopyright" Margin="0,8,0,0" Foreground="{DynamicResource Muted}"/>
            </StackPanel>
        </Border>
        <Button x:Name="AboutClose" Content="Close" HorizontalAlignment="Right" MinWidth="84" Padding="16,5" Margin="0,12,0,0"
                Style="{DynamicResource AccentButton}" IsDefault="True" IsCancel="True"/>
    </StackPanel>
</Window>
'@

function Show-About {
    param([Windows.Window]$Owner)
    $w = New-XamlWindow $script:AboutXaml
    if ($Owner) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    # The main window's colours and styles (buttons), so the theme matches Help and Settings.
    if ($script:Window) { $w.Resources.MergedDictionaries.Add($script:Window.Resources) }
    $w.Add_SourceInitialized({ Set-DarkTitleBar $script:IsDark $this })
    $w.Title = "About $script:AppName"
    $w.FindName('AboutLogo').Source       = Get-AssetImage 'Homelab.png'
    $w.FindName('AboutName').Text         = $script:AppName
    $w.FindName('AboutVersion').Text      = "Version $script:AppVersion"
    $w.FindName('AboutDescription').Text  = $script:Description
    $w.FindName('AboutNew').Text          = "New in 1.05: Start all, Stop all and Restart unhealthy ask in Homelab's own light or dark box instead of Windows' grey one, with Start them, Stop them or Restart them and Cancel."
    $w.FindName('AboutData').Text         = "Settings and data: $script:DataDir"
    $w.FindName('AboutRepoText').Text     = $script:RepoUrl
    $w.FindName('AboutRepo').NavigateUri  = [Uri]$script:RepoUrl
    $w.FindName('AboutRepo').Add_RequestNavigate({ param($s, $e) Start-Process $e.Uri.AbsoluteUri; $e.Handled = $true })
    $w.FindName('AboutCopyright').Text    = "$script:Copyright  ·  MIT licence"
    $w.FindName('AboutClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    [void]$w.ShowDialog()
}
#endregion ABOUT-BOX

# ---------------------------------------------------------------------------
#  Settings
# ---------------------------------------------------------------------------
$script:DefaultCompose = ''   # none to begin with: the first start asks for the compose file
$script:Settings = Get-AppSetting
foreach ($pair in @(
        @('ComposePath', $script:DefaultCompose),
        @('RefreshSeconds', 15),
        @('LastTab', 'All'),
        @('Theme', 'System'),
        @('Width', 1400), @('Height', 900), @('Maximized', $false))) {
    if ($null -eq $script:Settings.PSObject.Properties[$pair[0]]) {
        $script:Settings | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1]
    }
}
function Get-RefreshSeconds {
    <# RefreshSeconds as a whole number from 5 to 3600; 15 when it's missing or not a number. #>
    $n = 0
    if (-not [int]::TryParse(([string]$script:Settings.RefreshSeconds).Trim(), [ref]$n)) { return 15 }
    return [Math]::Min(3600, [Math]::Max(5, $n))
}
$script:Settings.RefreshSeconds = Get-RefreshSeconds
if ($null -eq $script:Settings.PSObject.Properties['Machine']) { $script:Settings | Add-Member -NotePropertyName Machine -NotePropertyValue '' }
# Groups kept behind the Private lock (hidden from All, Running and search until unlocked).
if ($null -eq $script:Settings.PSObject.Properties['PrivateGroups']) { $script:Settings | Add-Member -NotePropertyName PrivateGroups -NotePropertyValue @('Private') }
foreach ($k in 'PrivatePasswordHash', 'PrivatePasswordSalt') {
    if ($null -eq $script:Settings.PSObject.Properties[$k]) { $script:Settings | Add-Member -NotePropertyName $k -NotePropertyValue '' }
}
if ($null -eq $script:Settings.PSObject.Properties['Machines']) {
    # Other machines (a NAS, a laptop...) reached over SSH. The first time, copy them from
    # Docker Container Manager, which keeps the same list.
    $machines = @()
    $dcmSettings = Join-Path (Join-Path ([Environment]::GetFolderPath('ApplicationData')) 'Docker Container Manager') 'settings.json'
    try {
        if (Test-Path -LiteralPath $dcmSettings) {
            $dcm = Get-Content -LiteralPath $dcmSettings -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($m in @($dcm.Machines)) {
                if (-not $m -or -not $m.Name -or -not $m.Login) { continue }
                $machines += [pscustomobject]@{
                    Name        = [string]$m.Name
                    Login       = [string]$m.Login
                    Port        = [string]$m.Port
                    Folder      = [string]$m.Folder
                    ComposeFile = if ([string]$m.ComposeFile -like '/*') { [string]$m.ComposeFile } else { 'docker-compose.yml' }
                    Project     = [string]$m.Project
                    WebHost     = [string]$m.WebHost
                    PathMap     = [pscustomobject]@{}
                }
            }
        }
    } catch { Write-AppLog "Couldn't read Docker Container Manager's machines: $($_.Exception.Message)" }
    $script:Settings | Add-Member -NotePropertyName Machines -NotePropertyValue $machines
}

# Icons: your own Icons folder (IconsFolder; blank = the Icons folder beside Builds\ and Source\),
# then optionally Homepage's icon folder (UseHomepageIcons; HomepageIconFolder, blank = homepage\icons
# next to the compose file). The old IconFolder setting was the Homepage folder, so it moves across.
if ($null -ne $script:Settings.PSObject.Properties['IconFolder']) {
    if ($null -eq $script:Settings.PSObject.Properties['HomepageIconFolder']) {
        $script:Settings | Add-Member -NotePropertyName HomepageIconFolder -NotePropertyValue ([string]$script:Settings.IconFolder)
    }
    $script:Settings.PSObject.Properties.Remove('IconFolder')
}
foreach ($pair in @(@('IconsFolder', ''), @('HomepageIconFolder', ''), @('UseHomepageIcons', $true), @('NotifyProblems', $true), @('CheckUpdates', $true))) {
    if ($null -eq $script:Settings.PSObject.Properties[$pair[0]]) { $script:Settings | Add-Member -NotePropertyName $pair[0] -NotePropertyValue $pair[1] }
}

function Get-DefaultIconsFolder {
    <# <project>\Icons: beside Builds\ and Source\, never inside Source\, so the icons (other
       projects' logos) never go to GitHub, and not inside a release folder, so every version
       shares them. #>
    return (Join-Path (Get-ProjectDir) 'Icons')
}

$script:IconDir    = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) $script:AppName) 'Icons'
# Docker Container Manager keeps the same icons; reuse any it already downloaded.
$script:DcmIconDir = Join-Path (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Docker Container Manager') 'Icons'
$script:IconBase   = 'https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/png/'

# Container ports that are never a web page (databases, VNC, Guacamole, proxies...).
$script:NotWebPorts = @(21, 22, 25, 53, 110, 143, 465, 587, 993, 995, 1194, 1883, 3129, 3306, 4822,
    5432, 5900, 5901, 6379, 6881, 8883, 9300, 11211, 27017, 51413)
$script:HttpsPorts  = @(443, 444, 8443, 9443)
# Apps whose web page isn't at the root of their port.
$script:WebPaths    = @{ 32400 = '/web' }
# Apps on the host network (no published ports): their usual web port.
$script:HostNetPorts = @{ ntopng = 3000; 'home-assistant' = 8123; homeassistant = 8123; plex = 32400 }
# Databases open their admin tool when one is in the compose file, else a command window.
$script:DbAdmins = @(
    @{ Match = '(^|/)(mariadb|mysql)(:|$)'; Admin = @('phpmyadmin', 'adminer'); Name = 'phpMyAdmin' },
    @{ Match = '(postgres|pgvecto|vchord)'; Admin = @('pgadmin', 'adminer'); Name = 'pgAdmin' },
    @{ Match = '(^|/)(mongo|redis|elasticsearch|valkey|influxdb|couchdb)(:|$)'; Admin = @(); Name = '' }
)

# ---------------------------------------------------------------------------
#  Docker, without ever making the window wait
# ---------------------------------------------------------------------------
function Find-Docker {
    $cmd = Get-Command docker.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    foreach ($p in @(
            (Join-Path $env:ProgramFiles 'Docker\Docker\resources\bin\docker.exe'),
            (Join-Path $env:ProgramData 'DockerDesktop\version-bin\docker.exe'))) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}
$script:DockerExe = Find-Docker

# ---------------------------------------------------------------------------
#  Machines: "This PC" runs docker.exe here; any other machine is reached with
#  Windows' own ssh.exe, and docker runs there against that machine's compose file.
# ---------------------------------------------------------------------------
function Get-Machine {
    $name = [string]$script:Settings.Machine
    if (-not $name -or $name -eq 'This PC') { return $null }
    $m = @($script:Settings.Machines | Where-Object { $_.Name -eq $name })
    if ($m.Count) { return $m[0] } else { return $null }
}

function Get-MachineName { $m = Get-Machine; if ($m) { return [string]$m.Name } else { return 'This PC' } }

function Find-Ssh {
    foreach ($dir in @((Join-Path $env:SystemRoot 'Sysnative\OpenSSH'), (Join-Path $env:SystemRoot 'System32\OpenSSH'))) {
        $p = Join-Path $dir 'ssh.exe'
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $cmd = Get-Command ssh.exe -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function ConvertTo-ShQuote([string]$Text) {
    <# One word for the remote (POSIX) shell. #>
    if ($Text -match '^[A-Za-z0-9_./:=@%+,-]+$') { return $Text }
    return "'" + $Text.Replace("'", "'\''") + "'"
}

function Join-CommandLine([string[]]$Arguments) {
    <# A Windows command line from separate arguments, quoted the way programs read them back. #>
    return (($Arguments | ForEach-Object {
                if ($_ -eq '') { '""' }
                elseif ($_ -match '[\s"]') { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }
                else { $_ }
            }) -join ' ')
}

function Get-SshArguments($Machine, [switch]$Tty) {
    $a = @('-o', 'BatchMode=yes', '-o', 'ConnectTimeout=8', '-o', 'StrictHostKeyChecking=accept-new', '-o', 'ServerAliveInterval=20')
    if ($Machine.Port) { $a += @('-p', [string]$Machine.Port) }
    if ($Tty) { $a += '-t' }
    return $a + @([string]$Machine.Login)
}

function Get-RemoteCommand([string[]]$DockerArguments) {
    # SSH commands don't read the login profile, so Synology's /usr/local/bin isn't on PATH.
    return 'PATH="$PATH:/usr/local/bin:/usr/bin:/bin"; docker ' + (($DockerArguments | ForEach-Object { ConvertTo-ShQuote ([string]$_) }) -join ' ')
}

function Get-WebHost {
    <# The host name web addresses use: localhost here, the machine's address elsewhere. #>
    $m = Get-Machine
    if (-not $m) { return 'localhost' }
    if ($m.WebHost) { return [string]$m.WebHost }
    return (([string]$m.Login -split '@')[-1])
}

function Get-RemoteComposePath($Machine) {
    $f = if ($Machine.ComposeFile) { [string]$Machine.ComposeFile } else { 'docker-compose.yml' }
    if ($f -like '/*') { return $f }
    return ('{0}/{1}' -f ([string]$Machine.Folder).TrimEnd('/'), $f)
}

function Get-ComposeLabel {
    <# The compose file as shown in the window: a path here, "NAS: /path" elsewhere. #>
    $m = Get-Machine
    if ($m) { return "$($m.Name): $(Get-RemoteComposePath $m)" }
    return [string]$script:Settings.ComposePath
}

# Runs a program (docker.exe or ssh.exe) in a background runspace and returns ExitCode, Output,
# Error and TimedOut. Both streams are read at the same time, so a chatty program can't fill one
# pipe and hang; past the timeout the program and anything it started are ended.
$script:DockerWork = {
    param($Exe, [string]$ArgumentLine, $Dir, [int]$TimeoutSeconds)
    if ($TimeoutSeconds -lt 1) { $TimeoutSeconds = 90 }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $ArgumentLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($Dir -and [IO.Directory]::Exists($Dir)) { $psi.WorkingDirectory = $Dir }
    $p = New-Object Diagnostics.Process
    $p.StartInfo = $psi
    try {
        [void]$p.Start()
        $outTask = $p.StandardOutput.ReadToEndAsync()
        $errTask = $p.StandardError.ReadToEndAsync()
        $timedOut = -not $p.WaitForExit($TimeoutSeconds * 1000)
        if ($timedOut) {
            # The whole tree: ssh or docker compose may have started others that hold the pipes open.
            try {
                $tk = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\taskkill.exe') -ArgumentList @('/T', '/F', '/PID', $p.Id) -WindowStyle Hidden -PassThru -Wait
                $tk.Dispose()
            } catch { Write-Verbose "taskkill failed: $($_.Exception.Message)" }
            try { if (-not $p.HasExited) { $p.Kill() } } catch { Write-Verbose 'Already ended.' }
            [void]$p.WaitForExit(5000)
        } else {
            $p.WaitForExit()   # lets the stream readers reach the end
        }
        [void][Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($outTask, $errTask), 5000)
        $out = if ($outTask.IsCompleted -and -not $outTask.IsFaulted) { $outTask.Result } else { '' }
        $err = if ($errTask.IsCompleted -and -not $errTask.IsFaulted) { $errTask.Result } else { '' }
        if ($timedOut) {
            $span = if ($TimeoutSeconds -ge 120) { "$([int]($TimeoutSeconds / 60)) minutes" } else { "$TimeoutSeconds seconds" }
            $err = ("$err`nTimed out after $span and was stopped.").Trim()
        }
        [pscustomobject]@{ ExitCode = $(if ($timedOut) { -1 } else { $p.ExitCode }); Output = $out; Error = $err; TimedOut = $timedOut }
    } finally { $p.Dispose() }
}

# Downloads app icons in the background, one at a time, each given 5 seconds.
# Each job: Key (file name) and Url.
$script:IconWork = {
    param($Jobs, $Dir)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    foreach ($j in $Jobs) {
        $resp = $null
        try {
            $req = [Net.HttpWebRequest][Net.WebRequest]::Create($j.Url)
            $req.UserAgent = 'Homelab'
            $req.Timeout = 5000
            $req.ReadWriteTimeout = 5000
            $resp = $req.GetResponse()
            $ms = New-Object IO.MemoryStream
            try {
                $stream = $resp.GetResponseStream()
                $buf = New-Object byte[] 65536
                $deadline = [DateTime]::Now.AddSeconds(5)
                while (($n = $stream.Read($buf, 0, $buf.Length)) -gt 0) {
                    $ms.Write($buf, 0, $n)
                    if ($ms.Length -gt 4MB -or [DateTime]::Now -gt $deadline) { throw 'Too big or too slow.' }
                }
                $bytes = $ms.ToArray()
            } finally { $ms.Dispose() }
            $hex = if ($bytes.Length -ge 4) { [BitConverter]::ToString($bytes, 0, 4) } else { '' }
            if ($hex -match '^(89-50-4E-47|FF-D8-FF|47-49-46-38|00-00-01-00|42-4D)') {
                [IO.File]::WriteAllBytes((Join-Path $Dir ($j.Key + '.png')), $bytes); 'ok'
            } else {
                [IO.File]::WriteAllText((Join-Path $Dir ($j.Key + '.none')), ''); 'none'
            }
        } catch {
            $ex = $_.Exception
            while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
            if ($ex -and $ex.Response -and [int]$ex.Response.StatusCode -eq 404) {
                [IO.File]::WriteAllText((Join-Path $Dir ($j.Key + '.none')), ''); 'none'
            } else { 'error' }
        } finally { if ($resp) { $resp.Close() } }
    }
}

$script:MyIconsLogged = -1
$script:PortainerUrl  = ''
$script:BusyHideAt    = $null
# Docker and ssh share one pool; icon downloads get their own single thread, so a slow
# download never holds up a status check.
$script:BgPools    = @{}
$script:PoolSizes  = @{ Docker = 4; Icons = 1; Updates = 1 }
$script:BgTasks    = New-Object System.Collections.ArrayList
$script:BgStopping = New-Object System.Collections.ArrayList   # timed-out work being stopped, disposed once it ends

function Start-Background([scriptblock]$Work, [object[]]$Arguments, [scriptblock]$OnDone, $State, [string]$Pool = 'Docker', [int]$TimeoutSeconds = 150) {
    <# Runs Work on a pool thread; Update-Background calls OnDone(output, error, State) on the UI thread.
       TimeoutSeconds is a backstop: it must be longer than any timeout inside Work. #>
    try {
        if (-not $script:BgPools[$Pool]) {
            $rp = [RunspaceFactory]::CreateRunspacePool(1, $script:PoolSizes[$Pool])
            $rp.Open()
            $script:BgPools[$Pool] = $rp
        }
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $script:BgPools[$Pool]
        [void]$ps.AddScript($Work.ToString())
        foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
        $handle = $ps.BeginInvoke()
        [void]$script:BgTasks.Add(@{ PS = $ps; Handle = $handle; OnDone = $OnDone; State = $State; Started = [DateTime]::Now; Timeout = $TimeoutSeconds })
    } catch {
        Write-AppLog "Couldn't start background work: $($_.Exception.Message)"
        try { & $OnDone @() $_.Exception.Message $State } catch { Write-AppLog "Internal error: $($_.Exception.Message)" }
    }
}

function Update-Background {
    foreach ($t in @($script:BgTasks)) {
        $timedOut = (([DateTime]::Now - $t.Started).TotalSeconds -gt $t.Timeout)
        if (-not $t.Handle.IsCompleted -and -not $timedOut) { continue }
        $script:BgTasks.Remove($t)
        $out = @(); $err = ''
        if (-not $t.Handle.IsCompleted) {
            $err = 'Timed out.'
            Write-AppLog "Background work timed out after $($t.Timeout) seconds; stopping it."
            try { $t.StopHandle = $t.PS.BeginStop($null, $null); [void]$script:BgStopping.Add($t) }
            catch { Write-AppLog "Couldn't stop background work: $($_.Exception.Message)" }
        } else {
            try { $out = @($t.PS.EndInvoke($t.Handle)) } catch { $err = $_.Exception.Message }
            if (-not $err -and $t.PS.Streams.Error.Count) { $err = [string]$t.PS.Streams.Error[0] }
            $t.PS.Dispose()
        }
        try { & $t.OnDone $out $err $t.State } catch { Write-AppLog "Internal error: $($_.Exception.Message)" }
    }
    # Stopped work is disposed once it has really ended, so its runspace goes back to the pool.
    foreach ($t in @($script:BgStopping)) {
        if (-not $t.StopHandle.IsCompleted -and -not $t.Handle.IsCompleted) { continue }
        $script:BgStopping.Remove($t)
        try { $t.PS.EndStop($t.StopHandle) } catch { Write-Verbose 'Already ended.' }
        try { $t.PS.Dispose() } catch { Write-AppLog "Couldn't dispose stopped work: $($_.Exception.Message)" }
    }
}

function Start-Docker([string[]]$Arguments, [scriptblock]$OnDone, $Context, [int]$TimeoutSeconds = 90) {
    <# Runs docker here, or over ssh on the chosen machine. OnDone gets the result, then Context.
       TimeoutSeconds: how long docker may take before it's stopped (and reported as timed out). #>
    $m = Get-Machine
    if ($m) {
        $exe = Find-Ssh
        if (-not $exe) {
            & $OnDone ([pscustomobject]@{ ExitCode = -1; Output = ''; Error = "ssh.exe wasn't found, so $($m.Name) can't be reached. Turn on the OpenSSH Client in Windows Settings > System > Optional features." }) $Context
            return
        }
        $Arguments = @(Get-SshArguments $m) + @(Get-RemoteCommand $Arguments)
        $dir = $env:USERPROFILE
    } else {
        if (-not $script:DockerExe) {
            & $OnDone ([pscustomobject]@{ ExitCode = -1; Output = ''; Error = 'Docker was not found on this PC. Install Docker Desktop.' }) $Context
            return
        }
        $exe = $script:DockerExe
        $dir = Get-ParentFolder ([string]$script:Settings.ComposePath)
    }
    Start-Program $exe $Arguments $dir $OnDone $Context $TimeoutSeconds
}

function Start-Program([string]$Exe, [string[]]$Arguments, [string]$Dir, [scriptblock]$OnDone, $Context, [int]$TimeoutSeconds = 90) {
    <# DockerWork on the Docker pool; OnDone gets the result (ExitCode, Output, Error, TimedOut), then Context. #>
    # The callback travels with the task (no closures: they can't see this script's functions).
    # The backstop is a minute past DockerWork's own timeout, so only DockerWork ever reports one.
    Start-Background -Work $script:DockerWork -Arguments @($Exe, (Join-CommandLine $Arguments), $Dir, $TimeoutSeconds) -TimeoutSeconds ($TimeoutSeconds + 60) `
        -State @{ Callback = $OnDone; Context = $Context } -OnDone {
        param($out, $err, $state)
        $res = if ($out.Count) { $out[0] } else { [pscustomobject]@{ ExitCode = -1; Output = ''; Error = $err; TimedOut = ($err -eq 'Timed out.') } }
        & $state.Callback $res $state.Context
    }
}

function Get-ErrorSummary([string]$Text, [int]$Count = 3) {
    <# The useful part of an error: its last lines that mention an error, else its last lines.
       Docker and ssh print progress first and the reason last. #>
    $lines = @(($Text -split "`r?`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $errs = @($lines | Where-Object { $_ -match '(?i)error|failed|denied|refused|timed out|not found|no such|cannot|can''t|unable' })
    $pick = if ($errs.Count) { $errs } else { $lines }
    return ((@($pick | Select-Object -Last $Count)) -join ' ').Trim()
}

function Test-DockerDown([string]$Text) {
    return ($Text -match 'error during connect|Cannot connect to the Docker daemon|docker daemon is not running|dockerDesktopLinuxEngine|docker_engine|The system cannot find the file specified|failed to connect to the docker API|ssh: |Connection refused|Connection timed out|Could not resolve hostname|Permission denied|Host key verification failed|No route to host')
}

# ---------------------------------------------------------------------------
#  Reading the compose file
# ---------------------------------------------------------------------------
function Get-PropValue($Object, [string]$Name) {
    if ($null -eq $Object) { return $null }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { return $p.Value }
    return $null
}

function Get-ServiceLabels($Service) {
    $labels = @{}
    $raw = Get-PropValue $Service 'labels'
    if ($null -eq $raw) { return $labels }
    if ($raw -is [array]) {
        foreach ($l in $raw) { $kv = ([string]$l).Split('=', 2); $labels[$kv[0]] = if ($kv.Count -gt 1) { $kv[1] } else { '' } }
    } else {
        foreach ($p in $raw.PSObject.Properties) { $labels[$p.Name] = [string]$p.Value }
    }
    return $labels
}

function Get-EnvFileArguments {
    # Values such as ${CONFIGS} come from .env next to the compose file. Without one, use the
    # Windows template from the env folder (Env_Windows), if there is one.
    $dir = Get-ParentFolder ([string]$script:Settings.ComposePath)
    if (-not $dir -or (Test-FilePath (Join-Path $dir '.env'))) { return @() }
    foreach ($name in @('env\Env_Windows', 'env\Env_Windows.env', 'Env_Windows')) {
        $p = Join-Path $dir $name
        if (Test-FilePath $p) { return @('--env-file', $p) }
    }
    return @()
}

function Get-ComposeArguments {
    $m = Get-Machine
    if ($m) {
        $a = @('compose', '--ansi', 'never', '-f', (Get-RemoteComposePath $m), '--project-directory', [string]$m.Folder)
        # The stack may have been started under another name (Synology Container Manager uses the project's name).
        if ($m.Project) { $a += @('-p', [string]$m.Project) }
        return $a
    }
    $path = [string]$script:Settings.ComposePath
    return @('compose', '--ansi', 'never', '-f', $path, '--project-directory', (Get-ParentFolder $path)) + @(Get-EnvFileArguments)
}

function Get-WebPorts($Service) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($p in @(Get-PropValue $Service 'ports')) {
        if ($null -eq $p) { continue }
        $proto = [string](Get-PropValue $p 'protocol')
        if ($proto -and $proto -ne 'tcp') { continue }
        $published = ([string](Get-PropValue $p 'published') -split '-')[0]
        $target = [int]([string](Get-PropValue $p 'target') -replace '-.*$', '')
        if (-not $published -or $script:NotWebPorts -contains $target) { continue }
        $list.Add(@{ Published = [int]$published; Target = $target })
    }
    return $list
}

function Get-WebUrl($Service, [string]$Name) {
    $ports = @(Get-WebPorts $Service)
    if ($ports.Count) {
        $p = $ports[0]
        $scheme = if ($script:HttpsPorts -contains $p.Target) { 'https' } else { 'http' }
        $path = if ($script:WebPaths.ContainsKey($p.Target)) { $script:WebPaths[$p.Target] } else { '/' }
        return "${scheme}://$($script:WebHost):$($p.Published)$path"
    }
    if ([string](Get-PropValue $Service 'network_mode') -eq 'host' -and $script:HostNetPorts.ContainsKey($Name)) {
        return "http://$($script:WebHost):$($script:HostNetPorts[$Name])/"
    }
    return ''
}

function ConvertTo-SharePath([string]$Path) {
    <# A folder on another machine as a Windows share path, using that machine's PathMap
       (for example /volume1/docker -> \\nas\docker). Empty when no mapping fits. #>
    $m = Get-Machine
    if (-not $m -or -not $m.PathMap) { return '' }
    $best = ''; $to = ''
    foreach ($p in $m.PathMap.PSObject.Properties) {
        $from = ([string]$p.Name).TrimEnd('/')
        if (($Path -eq $from -or $Path.StartsWith("$from/")) -and $from.Length -gt $best.Length) { $best = $from; $to = [string]$p.Value }
    }
    if (-not $best) { return '' }
    return ($to.TrimEnd('\') + ($Path.Substring($best.Length) -replace '/', '\'))
}

function Get-ConfigFolder($Service) {
    # The first host folder the service mounts that exists on this PC (its config folder, usually).
    # On another machine, the first one its PathMap turns into a share path (not checked, to keep loading quick).
    $remote = [bool](Get-Machine)
    foreach ($v in @(Get-PropValue $Service 'volumes')) {
        if ($null -eq $v -or [string](Get-PropValue $v 'type') -ne 'bind') { continue }
        $src = [string](Get-PropValue $v 'source')
        if ($src -match '(?i)docker\.sock|^/(var|run|dev|proc|sys|etc)(/|$)') { continue }
        if ($remote) { $share = ConvertTo-SharePath $src; if ($share) { return $share } else { continue } }
        $win = $src -replace '/', '\'
        if ($win -match '^\\mnt\\host\\([a-z])\\(.*)$') { $win = "$($Matches[1]):\$($Matches[2])" }
        if ($win -match '^[A-Za-z]:\\' -and (Test-Path -LiteralPath $win -PathType Container)) { return $win }
    }
    return ''
}

function Get-IconSlugs($Item) {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($Item.IconLabel -and $Item.IconLabel -notmatch '[\\/:.]') { $cands.Add($Item.IconLabel) }
    $cands.Add($Item.Service)
    $img = [string]$Item.Image
    if ($img) {
        $n = ($img -split '@')[0]
        $slash = $n.LastIndexOf('/'); $colon = $n.LastIndexOf(':')
        if ($colon -gt $slash) { $n = $n.Substring(0, $colon) }
        $n = $n.Substring($slash + 1)
        $cands.Add($n)
        $cands.Add(($n -replace '[-_]?\d+$', ''))
        $cands.Add(($n -replace '[-_](server|web|app|docker|ce|oss)$', ''))
    }
    $cands.Add(($Item.Service -replace '[-_]?\d+$', ''))
    $cands.Add(($Item.Service -split '[-_]')[0])
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($c in $cands) {
        $s = (([string]$c).ToLowerInvariant() -replace '[^a-z0-9-]+', '-').Trim('-')
        if ($s -and -not $out.Contains($s)) { $out.Add($s) }
    }
    return $out.ToArray()
}

# Names that don't come out right from the service name alone. home.name beats these.
$script:KnownTitles = @{ phpmyadmin = 'phpMyAdmin'; pgadmin = 'pgAdmin'; 'it-tools' = 'IT-Tools'; 'yt-dlp-web-ui' = 'yt-dlp Web UI'
    'ytdl-material' = 'YTDL Material'; nzbhydra2 = 'NZBHydra2'; nzbget = 'NZBGet'; sabnzbd = 'SABnzbd'; get_iplayer = 'get_iplayer'
    lms = 'LMS'; mstream = 'mStream'; 'calibre-web' = 'Calibre-Web'; 'calibre-web-automated' = 'Calibre-Web Automated'
    mariadb = 'MariaDB'; dcm = 'DCM'; 'docker-container-manager' = 'Docker Container Manager'
    tinymediamanager = 'tinyMediaManager'; 'tiny-media-manager' = 'tinyMediaManager'; tmm = 'tinyMediaManager'
    lazylibrarian = 'LazyLibrarian'; readmeabook = 'ReadMeABook'; 'read-me-a-book' = 'ReadMeABook' }

function ConvertTo-Title([string]$Name) {
    if ($script:KnownTitles.ContainsKey($Name)) { return $script:KnownTitles[$Name] }
    $words = $Name -split '[-_ ]+' | Where-Object { $_ } | ForEach-Object { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
    return ($words -join ' ')
}

# Builds the list of containers (one item per service) from docker compose config's JSON.
function Import-Compose($Config) {
    $services = Get-PropValue $Config 'services'
    $items = New-Object System.Collections.Generic.List[object]
    $byName = @{}
    if ($services) {
        foreach ($prop in $services.PSObject.Properties) {
            $svc = $prop.Value
            $labels = Get-ServiceLabels $svc
            if ($labels['home.hide'] -eq 'true') { continue }
            $group = if ($labels['home.group']) { $labels['home.group'].Trim() } else { 'Other' }
            $cn = [string](Get-PropValue $svc 'container_name')
            $item = [pscustomobject]@{
                Service     = $prop.Name
                Container   = if ($cn) { $cn } else { '' }
                Title       = if ($labels['home.name']) { $labels['home.name'] } else { ConvertTo-Title $prop.Name }
                Description = [string]$labels['home.description']
                Group       = $group
                Image       = [string](Get-PropValue $svc 'image')
                IconLabel   = [string]$labels['home.icon']
                OpenLabel   = ([string]$labels['home.open']).Trim()
                UrlLabel    = ([string]$labels['home.url']).Trim()
                WebUrl      = Get-WebUrl $svc $prop.Name
                Folder      = Get-ConfigFolder $svc
                State       = ''
                StateText   = 'Not created'
                StateKey    = 'none'
                Running     = $false
                Busy        = ''      # 'Starting', 'Stopping' or 'Restarting' while that runs
                UpdateAvailable = $false   # a newer image is in the registry (Start-UpdateCheck)
                Action      = $null
                IconPath    = ''
                Tiles       = New-Object System.Collections.Generic.List[object]
            }
            if ($item.UrlLabel -and $item.UrlLabel -ne 'none') { $item.WebUrl = $item.UrlLabel }
            if ($item.UrlLabel -eq 'none') { $item.WebUrl = '' }
            $items.Add($item)
            $byName[$prop.Name] = $item
        }
    }
    foreach ($i in $items) { $i.Action = Get-OpenAction $i $byName }
    return $items
}

# What Open does for a container: Kind is Web, Shell, Log or None; Text says it on the tile.
function Get-OpenAction($Item, [hashtable]$ByName) {
    $o = $Item.OpenLabel.ToLowerInvariant()
    if ($o -eq 'shell') { return @{ Kind = 'Shell'; Url = ''; Text = 'Command window' } }
    if ($o -eq 'log' -or $o -eq 'logs') { return @{ Kind = 'Log'; Url = ''; Text = 'Log' } }
    if ($o -eq 'none') { return @{ Kind = 'None'; Url = ''; Text = '' } }
    if ($o -match '^https?://') { return @{ Kind = 'Web'; Url = $Item.OpenLabel; Text = ($Item.OpenLabel -replace '^https?://', '') } }
    if ($o -and $ByName.ContainsKey($o) -and $ByName[$o].WebUrl) {
        return @{ Kind = 'Web'; Url = $ByName[$o].WebUrl; Text = "via $($ByName[$o].Title)" }
    }
    if (-not $Item.UrlLabel) {
        foreach ($db in $script:DbAdmins) {
            if ($Item.Image -notmatch $db.Match -and $Item.Service -notmatch $db.Match) { continue }
            foreach ($a in $db.Admin) {
                if ($ByName.ContainsKey($a) -and $ByName[$a].WebUrl) {
                    return @{ Kind = 'Web'; Url = $ByName[$a].WebUrl; Text = "via $($ByName[$a].Title)" }
                }
            }
            return @{ Kind = 'Shell'; Url = ''; Text = 'Command window' }
        }
    }
    if ($Item.WebUrl) { return @{ Kind = 'Web'; Url = $Item.WebUrl; Text = ($Item.WebUrl -replace '^https?://', '' -replace '/$', '') } }
    return @{ Kind = 'Log'; Url = ''; Text = 'Log (no web page)' }
}

# ---------------------------------------------------------------------------
#  Container status (docker ps)
# ---------------------------------------------------------------------------
function Get-StateInfo([string]$State, [string]$Status) {
    switch ($State) {
        'running' {
            # Just the state and health: how long it has been up isn't shown.
            if ($Status -match '\(unhealthy\)') { return @{ Key = 'bad'; Text = 'Unhealthy'; Running = $true } }
            if ($Status -match '\(health: starting\)') { return @{ Key = 'warn'; Text = 'Starting'; Running = $true } }
            return @{ Key = 'ok'; Text = 'Running'; Running = $true }
        }
        'exited' {
            $code = if ($Status -match 'Exited \((-?\d+)\)') { [int]$Matches[1] } else { 0 }
            if ($code -in 0, 137, 143) { return @{ Key = 'off'; Text = 'Stopped'; Running = $false } }
            return @{ Key = 'bad'; Text = "Stopped (error $code)"; Running = $false }
        }
        'restarting' { return @{ Key = 'bad'; Text = 'Restarting'; Running = $false } }
        'paused'     { return @{ Key = 'warn'; Text = 'Paused'; Running = $true } }
        'created'    { return @{ Key = 'off'; Text = 'Created, not started'; Running = $false } }
        'dead'       { return @{ Key = 'bad'; Text = 'Dead'; Running = $false } }
    }
    return @{ Key = 'off'; Text = $State; Running = $false }
}

function Import-Status([string]$Output) {
    # One line per container: name, compose service, compose project, state, status.
    # Two stacks can both have a service called "db": the one in this compose file's project wins.
    $byContainer = @{}
    $byService = @{}
    foreach ($line in ($Output -split "`r?`n")) {
        $f = $line.Split("`t")
        if ($f.Count -lt 5) { continue }
        $rec = @{ State = $f[3]; Status = $f[4]; Ours = [bool]($script:ProjectName -and $f[2] -eq $script:ProjectName) }
        $byContainer[$f[0]] = $rec
        if ($f[1]) {
            $had = $byService[$f[1]]
            if (-not $had -or ($rec.Ours -and -not $had.Ours)) { $byService[$f[1]] = $rec }
        }
    }
    $problems = New-Object System.Collections.Generic.List[object]
    foreach ($i in $script:Items) {
        $wasKey = $i.StateKey
        $rec = $null
        if ($i.Container -and $byContainer.ContainsKey($i.Container)) { $rec = $byContainer[$i.Container] }
        elseif ($byService.ContainsKey($i.Service)) { $rec = $byService[$i.Service] }
        elseif ($byContainer.ContainsKey($i.Service)) { $rec = $byContainer[$i.Service] }
        if ($rec) {
            $info = Get-StateInfo $rec.State $rec.Status
            $i.State = $rec.State; $i.StateKey = $info.Key; $i.StateText = $info.Text; $i.Running = $info.Running
        } else {
            $i.State = ''; $i.StateKey = 'none'; $i.StateText = 'Not created'; $i.Running = $false
        }
        foreach ($t in $i.Tiles) { Update-Tile $t $i }
        if ($i.StateKey -eq 'bad' -and $wasKey -ne 'bad' -and $wasKey -ne 'none') { $problems.Add($i) }
    }
    # The first check after a start or machine switch only learns the states; after that a
    # container going wrong by itself (not one you just stopped or restarted) gets a notification.
    if ($script:StatusSeeded) { Send-ProblemNotice $problems }
    $script:StatusSeeded = $true
    Update-Counts
    Update-RunningList
}

# ---------------------------------------------------------------------------
#  Opening things
# ---------------------------------------------------------------------------
function Get-ContainerName($Item) { if ($Item.Container) { return $Item.Container } return $Item.Service }

function Open-Web([string]$Url) {
    if ($Url -notmatch '^(?i)https?://') { return }
    try { Start-Process -FilePath $Url } catch { Set-Status "Couldn't open $Url" }
}

function Test-CanOpenWeb($Item) { return ($Item.State -eq 'running') }

function Open-ItemWeb($Item, [string]$Url) {
    <# A container's web page opens only while it's running; otherwise just say so (no browser). #>
    if (-not (Test-CanOpenWeb $Item)) { Set-Status "$($Item.Title) isn't running ($($Item.StateText)). Start it first to open its web page."; return }
    Open-Web $Url
}

function Open-Shell($Item) {
    if (-not $Item.Running) { Set-Status "$($Item.Title) isn't running, so there's no command window to open."; return }
    $name = Get-ContainerName $Item
    $m = Get-Machine
    if ($m) {
        $remote = Get-RemoteCommand @('exec', '-it', $name, 'sh', '-c', 'if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi')
        try { Start-Process -FilePath (Find-Ssh) -ArgumentList (Join-CommandLine (@(Get-SshArguments $m -Tty) + @($remote))) }
        catch { Set-Status "Couldn't open a command window: $($_.Exception.Message)" }
        return
    }
    $argLine = 'exec -it {0} sh -c "if command -v bash >/dev/null 2>&1; then exec bash; else exec sh; fi"' -f $name
    try { Start-Process -FilePath $script:DockerExe -ArgumentList $argLine } catch { Set-Status "Couldn't open a command window: $($_.Exception.Message)" }
}

function Open-Log($Item) {
    if ($Item.StateKey -eq 'none') { Set-Status "$($Item.Title) hasn't been created yet, so it has no log."; return }
    $name = Get-ContainerName $Item
    $m = Get-Machine
    if ($m) {
        # The window stays open after the log ends, until Enter is pressed.
        $remote = (Get-RemoteCommand @('logs', '-f', '--tail', '300', $name)) + "; printf '\nPress Enter to close. '; read x"
        try { Start-Process -FilePath (Find-Ssh) -ArgumentList (Join-CommandLine (@(Get-SshArguments $m -Tty) + @($remote))) }
        catch { Set-Status "Couldn't show the log: $($_.Exception.Message)" }
        return
    }
    # cmd /k keeps the window open after the container stops; the last 300 lines, then live.
    $argLine = '/k "title {0} log&&"{1}" logs -f --tail 300 {0}"' -f $name, $script:DockerExe
    try { Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\cmd.exe') -ArgumentList $argLine } catch { Set-Status "Couldn't show the log: $($_.Exception.Message)" }
}

function Invoke-Open($Item) {
    switch ($Item.Action.Kind) {
        'Web'   { Open-ItemWeb $Item $Item.Action.Url }
        'Shell' { Open-Shell $Item }
        'Log'   { Open-Log $Item }
    }
}

# ---------------------------------------------------------------------------
#  Start, Stop and Restart one container (docker compose, here or over ssh)
# ---------------------------------------------------------------------------
function Test-CanStart($Item) { return (-not $Item.Busy -and $Item.State -notin 'running', 'paused', 'restarting') }
function Test-CanStop($Item) { return (-not $Item.Busy -and ($Item.Running -or $Item.State -eq 'restarting')) }

# Timeout: compose up may pull a large image first, so Start and Restart get 15 minutes.
$script:ContainerVerbs = @{
    Start   = @{ Args = @('up', '-d', '--no-deps'); Doing = 'Starting';   Done = 'Started';   Timeout = 900 }
    Stop    = @{ Args = @('stop');                  Doing = 'Stopping';   Done = 'Stopped';   Timeout = 300 }
    Restart = @{ Args = @('restart');               Doing = 'Restarting'; Done = 'Restarted'; Timeout = 900 }
}

function Invoke-ContainerAction($Item, [string]$Verb) {
    <# Start (compose up -d --no-deps, so "not created" works too), Stop or Restart one service. #>
    $v = $script:ContainerVerbs[$Verb]
    if (-not $v -or $Item.Busy) { return }
    if ($Verb -eq 'Start' -and -not (Test-CanStart $Item)) { return }
    if ($Verb -ne 'Start' -and -not (Test-CanStop $Item)) { return }
    $Item.Busy = $v.Doing
    $script:UserActions[$Item.Service] = [DateTime]::Now   # no "stopped with an error" notice for what you did yourself
    foreach ($t in $Item.Tiles) { Update-Tile $t $Item }
    Update-RunningList
    Write-AppLog "$Verb $($Item.Service) on $(Get-MachineName)"
    Show-Busy "$($v.Doing) $($Item.Title)..." "$(Get-MachineName): docker compose $($v.Args -join ' ') $($Item.Service)"
    Start-Docker (@(Get-ComposeArguments) + $v.Args + @($Item.Service)) {
        param($res, $ctx)
        $it = $ctx.Item; $vb = $script:ContainerVerbs[$ctx.Verb]
        $it.Busy = ''
        if ($ctx.Gen -ne $script:Generation) {
            # Another machine is shown now; this one's tiles are gone, so only log it.
            Write-AppLog "$($ctx.Verb) $($it.Service) on $($ctx.Machine) finished with code $($res.ExitCode) (another machine is shown now)"
            return
        }
        if ($res.ExitCode -ne 0) {
            $msg = Get-ErrorSummary $res.Error 4
            if (-not $msg) { $msg = "docker compose stopped with code $($res.ExitCode)." }
            Show-Busy ''
            Show-Banner "Couldn't $($ctx.Verb.ToLowerInvariant()) $($it.Title): $msg" "container:$($it.Service)"
            Write-AppLog "$($ctx.Verb) $($it.Service) failed: $msg"
        } else {
            Show-Busy "$($vb.Done) $($it.Title)" (Get-MachineName) -Done
            Clear-Banner "container:$($it.Service)"
            Write-AppLog "$($vb.Done) $($it.Service)"
        }
        foreach ($t in $it.Tiles) { Update-Tile $t $it }
        Update-RunningList
        # Read the status straight away (or as soon as a poll already running has finished).
        $script:UserActions[$it.Service] = [DateTime]::Now
        $script:NextPoll = [DateTime]::MinValue
        if ($script:Polling) { $script:PollSoon = $true }
    } @{ Item = $Item; Verb = $Verb; Gen = $script:Generation; Machine = (Get-MachineName) } -TimeoutSeconds $v.Timeout
}

function Invoke-TileButton($Item) {
    <# The tile's button: Open when running, Start when not. #>
    if ($Item.Running) { Invoke-Open $Item } else { Invoke-ContainerAction $Item 'Start' }
}

# ---------------------------------------------------------------------------
#  Tiles
# ---------------------------------------------------------------------------
$script:Brushes = @{}
function Get-Brush([string]$Hex) {
    if (-not $script:Brushes.ContainsKey($Hex)) {
        # ::new, not New-Object: a PowerShell-wrapped brush stored as a window resource is rejected by WPF.
        $b = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color][Windows.Media.ColorConverter]::ConvertFromString($Hex))
        $b.Freeze()
        $script:Brushes[$Hex] = $b
    }
    return $script:Brushes[$Hex]
}
# ---------------------------------------------------------------------------
#  Light and dark themes. Every colour is a window resource, so switching is instant.
# ---------------------------------------------------------------------------
$script:Palettes = @{
    Light = @{
        # Text colours are at least 4.5:1 on the tiles, dimmed tiles and tab strip they sit on (WCAG AA).
        WinBg = '#F3F4F6'; Panel = '#FFFFFF'; Line = '#DADDE3'; Text = '#1F2328'; Muted = '#555B66'; Faint = '#5F6673'
        Hint = '#5F6673'; Where = '#5F6673'; Tile = '#FFFFFF'; TileDim = '#F6F7F9'; Accent = '#1A56DB'; AccentText = '#FFFFFF'
        Footer = '#E9EBEF'; BannerBg = '#FFF4D6'; BannerLine = '#E8C66A'; BannerText = '#1F2328'; TabBg = '#E9EBEF'; TabSel = '#FFFFFF'
        BtnBg = '#F3F4F6'; Input = '#FFFFFF'; Thumb = '#C4C9D2'; Link = '#1A56DB'; MenuHover = '#E8EEFB'; IconPlate = '#00000000'
        BtnOffBg = '#ECEEF1'; Badge = '#1A56DB'; BadgeText = '#FFFFFF'
        St_ok = '#15803D'; St_warn = '#B45309'; St_bad = '#DC2626'; St_off = '#596070'; St_none = '#5F6673'
    }
    Dark  = @{
        WinBg = '#16181D'; Panel = '#1E2127'; Line = '#343842'; Text = '#E6E8EB'; Muted = '#A3A9B4'; Faint = '#8E95A1'
        Hint = '#9AA0AA'; Where = '#8E95A1'; Tile = '#23262D'; TileDim = '#1C1F25'; Accent = '#2F6FEB'; AccentText = '#FFFFFF'
        Footer = '#1B1E23'; BannerBg = '#3A3218'; BannerLine = '#6B5A22'; BannerText = '#F3E3B0'; TabBg = '#23262D'; TabSel = '#2C3038'
        BtnBg = '#2A2E36'; Input = '#23262D'; Thumb = '#4A505C'; Link = '#7FA7FF'; MenuHover = '#2D3548'
        # A soft light plate behind each icon, so dark logos don't vanish into a dark tile.
        IconPlate = '#1FFFFFFF'; BtnOffBg = '#24272E'; Badge = '#4C8DFF'; BadgeText = '#0B1220'
        St_ok = '#22C55E'; St_warn = '#F59E0B'; St_bad = '#F87171'; St_off = '#9CA3AF'; St_none = '#8E95A1'
    }
}

function Test-SystemDark {
    try {
        $v = Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop
        return ([int]$v.AppsUseLightTheme -eq 0)
    } catch { return $false }
}

function Set-DarkTitleBar([bool]$Dark, $Win) {
    <# Windows 10 20H1+ and 11: dark title bar to match. Older Windows just ignores it. #>
    if (-not $Win) { $Win = $script:Window }
    try {
        if (-not ('Homelab.Dwm' -as [type])) {
            Add-Type -Namespace 'Homelab' -Name 'Dwm' -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
        }
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($Win)).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $v = [int]$Dark
        [void][Homelab.Dwm]::DwmSetWindowAttribute($hwnd, 20, [ref]$v, 4)
    } catch { Write-AppLog "Title bar colour not set: $($_.Exception.Message)" }
}

function Set-Theme {
    <# Applies the Theme setting (System, Light or Dark). #>
    $mode = [string]$script:Settings.Theme
    $dark = if ($mode -eq 'Dark') { $true } elseif ($mode -eq 'Light') { $false } else { Test-SystemDark }
    $script:IsDark = $dark
    $pal = $script:Palettes[$(if ($dark) { 'Dark' } else { 'Light' })]
    foreach ($k in $pal.Keys) { $script:Window.Resources[$k] = Get-Brush $pal[$k] }
    $script:Ui.BtnTheme.Content = switch ($mode) { 'Dark' { 'Dark' } 'Light' { 'Light' } default { 'Auto' } }
    $script:Ui.BtnTheme.ToolTip = "Theme: $(switch ($mode) { 'Dark' { 'dark' } 'Light' { 'light' } default { "same as Windows (now $(if ($dark) { 'dark' } else { 'light' }))" } }). Click to change."
    Set-DarkTitleBar $dark
    foreach ($i in $script:Items) { foreach ($t in $i.Tiles) { Update-Tile $t $i } }
}

function Switch-Theme {
    $script:Settings.Theme = switch ([string]$script:Settings.Theme) { 'System' { 'Light' } 'Light' { 'Dark' } default { 'System' } }
    Set-Theme
}

function Set-Res($Element, $Property, [string]$Key) { $Element.SetResourceReference($Property, $Key) }

function Get-AvatarColour([string]$Name) {
    $h = 0
    foreach ($ch in $Name.ToCharArray()) { $h = ($h * 31 + [int]$ch) % 360 }
    # HSL(h, 45%, 45%) to RGB.
    $s = 0.45; $l = 0.45
    $c = (1 - [Math]::Abs(2 * $l - 1)) * $s
    $x = $c * (1 - [Math]::Abs((($h / 60) % 2) - 1))
    $m = $l - $c / 2
    $rgb = switch ([int][Math]::Floor($h / 60)) { 0 { $c, $x, 0 } 1 { $x, $c, 0 } 2 { 0, $c, $x } 3 { 0, $x, $c } 4 { $x, 0, $c } default { $c, 0, $x } }
    return ('#{0:X2}{1:X2}{2:X2}' -f [int](($rgb[0] + $m) * 255), [int](($rgb[1] + $m) * 255), [int](($rgb[2] + $m) * 255))
}

function Get-InitialsColour([string]$Background) {
    <# White or near-black initials, whichever stands out more on this avatar colour. #>
    $lum = {
        param([string]$Hex)
        $c = @(1, 3, 5 | ForEach-Object { [Convert]::ToInt32($Hex.Substring($_, 2), 16) / 255.0 } | ForEach-Object {
                if ($_ -le 0.03928) { $_ / 12.92 } else { [Math]::Pow(($_ + 0.055) / 1.055, 2.4) } })
        0.2126 * $c[0] + 0.7152 * $c[1] + 0.0722 * $c[2]
    }
    $l = & $lum $Background
    $onWhite = 1.05 / ($l + 0.05)
    $onDark = ($l + 0.05) / ((& $lum '#1F2328') + 0.05)
    if ($onWhite -ge $onDark) { return '#FFFFFF' } else { return '#1F2328' }
}

function New-Avatar($Item, [double]$Radius, [double]$FontSize) {
    <# Coloured initials for a container with no icon. #>
    $hex = Get-AvatarColour $Item.Service
    $avatar = New-Object Windows.Controls.Border
    $avatar.CornerRadius = $Radius
    $avatar.Background = Get-Brush $hex
    $ini = New-Object Windows.Controls.TextBlock
    $ini.Text = Get-Initials $Item.Title
    $ini.Foreground = Get-Brush (Get-InitialsColour $hex); $ini.FontWeight = 'Bold'; $ini.FontSize = $FontSize
    $ini.HorizontalAlignment = 'Center'; $ini.VerticalAlignment = 'Center'
    $avatar.Child = $ini
    return $avatar
}

function New-UpdateBadge {
    <# The small "update available" dot on an icon's corner; Set-TileIcon shows or hides it. #>
    $b = New-Object Windows.Controls.Border
    $b.Width = 14; $b.Height = 14; $b.CornerRadius = 7; $b.BorderThickness = 2
    $b.HorizontalAlignment = 'Right'; $b.VerticalAlignment = 'Top'; $b.Margin = '0,-4,-4,0'
    Set-Res $b ([Windows.Controls.Border]::BackgroundProperty) 'Badge'
    Set-Res $b ([Windows.Controls.Border]::BorderBrushProperty) 'Tile'
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = [string][char]0xE74A; $t.FontFamily = 'Segoe MDL2 Assets'; $t.FontSize = 7; $t.FontWeight = 'Bold'
    $t.HorizontalAlignment = 'Center'; $t.VerticalAlignment = 'Center'
    Set-Res $t ([Windows.Controls.TextBlock]::ForegroundProperty) 'BadgeText'
    $b.Child = $t
    $b.Visibility = 'Collapsed'
    $b.ToolTip = 'A newer image is available'
    return $b
}

function Add-KeyboardOpen($Element) {
    <# Tiles and Running rows take keyboard focus (Tab), with the accent outline: Enter opens,
       the menu key or Shift+F10 shows the right-click menu, and a click focuses it too. #>
    $Element.Focusable = $true
    $Element.FocusVisualStyle = $script:Window.FindResource('AccentFocus')
    $Element.Add_KeyDown({
            param($s, $e)
            if ($e.OriginalSource -ne $s) { return }
            if ($e.Key -eq 'Return') { Invoke-Open $s.Tag; $e.Handled = $true }
            elseif ($e.Key -eq 'Apps' -or ($e.Key -eq 'System' -and $e.SystemKey -eq 'F10' -and [Windows.Input.Keyboard]::Modifiers -band [Windows.Input.ModifierKeys]::Shift)) {
                if ($s.ContextMenu) { $s.ContextMenu.PlacementTarget = $s; $s.ContextMenu.Placement = 'Bottom'; $s.ContextMenu.IsOpen = $true }
                $e.Handled = $true
            }
        })
    $Element.Add_PreviewMouseLeftButtonDown({ param($s, $e) if (-not (Test-InButton $e.OriginalSource $s)) { [void]$s.Focus() } })
}

function Get-Initials([string]$Title) {
    $w = @($Title -split '\s+' | Where-Object { $_ })
    if ($w.Count -ge 2) { return ($w[0].Substring(0, 1) + $w[1].Substring(0, 1)).ToUpperInvariant() }
    if ($w.Count -eq 1) { return $w[0].Substring(0, [Math]::Min(2, $w[0].Length)).ToUpperInvariant() }
    return '?'
}

$script:IconImages = @{}
function Get-IconImage([string]$Path) {
    if ($script:IconImages.ContainsKey($Path)) { return $script:IconImages[$Path] }
    $bmp = $null
    try {
        $bmp = New-Object Windows.Media.Imaging.BitmapImage
        $bmp.BeginInit()
        $bmp.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bmp.DecodePixelWidth = 80
        $bmp.UriSource = New-Object Uri($Path)
        $bmp.EndInit()
        $bmp.Freeze()
    } catch { $bmp = $null }
    $script:IconImages[$Path] = $bmp
    return $bmp
}

function Set-TileIcon($Tile, $Item) {
    $img = if ($Item.IconPath) { Get-IconImage $Item.IconPath } else { $null }
    if ($img) {
        $Tile.Icon.Source = $img
        $Tile.Icon.Visibility = 'Visible'
        $Tile.Avatar.Visibility = 'Collapsed'
    } else {
        $Tile.Icon.Visibility = 'Collapsed'
        $Tile.Avatar.Visibility = 'Visible'
    }
    # The plate only behind a real icon (the initials have their own colour).
    if ($img) { $Tile.Plate.SetResourceReference([Windows.Controls.Border]::BackgroundProperty, 'IconPlate') }
    else { $Tile.Plate.ClearValue([Windows.Controls.Border]::BackgroundProperty) }
    $Tile.Badge.Visibility = if ($Item.UpdateAvailable) { 'Visible' } else { 'Collapsed' }
}

function New-Tile($Item) {
    $border = New-Object Windows.Controls.Border
    $border.Width = 276; $border.Height = 78
    $border.Margin = '0,0,10,10'
    $border.CornerRadius = 8
    $border.BorderThickness = 1
    Set-Res $border ([Windows.Controls.Border]::BorderBrushProperty) 'Line'
    Set-Res $border ([Windows.Controls.Border]::BackgroundProperty) 'Tile'
    $border.Padding = '10,8,10,8'
    $border.Cursor = 'Hand'
    $border.Tag = $Item

    $grid = New-Object Windows.Controls.Grid
    foreach ($w in @(46, '*', 'Auto')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } elseif ($w -eq 'Auto') { [Windows.GridLength]::Auto } else { New-Object Windows.GridLength($w) }
        $grid.ColumnDefinitions.Add($cd)
    }

    $iconHost = New-Object Windows.Controls.Grid
    $iconHost.Width = 40; $iconHost.Height = 40; $iconHost.VerticalAlignment = 'Center'; $iconHost.HorizontalAlignment = 'Left'
    # Plate (Dark theme only shows it) > icon or initials > update badge on the corner.
    $plate = New-Object Windows.Controls.Border
    $plate.CornerRadius = 8; $plate.Padding = '3'
    $icon = New-Object Windows.Controls.Image
    [Windows.Media.RenderOptions]::SetBitmapScalingMode($icon, 'HighQuality')
    $plate.Child = $icon
    $avatar = New-Avatar $Item 8 15
    $badge = New-UpdateBadge
    [void]$iconHost.Children.Add($avatar)
    [void]$iconHost.Children.Add($plate)
    [void]$iconHost.Children.Add($badge)
    [Windows.Controls.Grid]::SetColumn($iconHost, 0)

    $text = New-Object Windows.Controls.StackPanel
    $text.VerticalAlignment = 'Center'
    $text.Margin = '6,0,6,0'
    $name = New-Object Windows.Controls.TextBlock
    $name.Text = $Item.Title; $name.FontWeight = 'SemiBold'; $name.FontSize = 13.5
    $name.TextTrimming = 'CharacterEllipsis'
    $state = New-Object Windows.Controls.TextBlock
    $state.FontSize = 11.5; $state.TextTrimming = 'CharacterEllipsis'
    $where = New-Object Windows.Controls.TextBlock
    $where.FontSize = 11; Set-Res $where ([Windows.Controls.TextBlock]::ForegroundProperty) 'Where'; $where.TextTrimming = 'CharacterEllipsis'
    $where.Text = $Item.Action.Text
    [void]$text.Children.Add($name); [void]$text.Children.Add($state); [void]$text.Children.Add($where)
    [Windows.Controls.Grid]::SetColumn($text, 1)

    # Open when running, Start when not: Update-Tile sets which.
    $btn = New-Object Windows.Controls.Button
    $btn.Padding = '12,4'
    $btn.MinWidth = 58
    $btn.VerticalAlignment = 'Center'
    $btn.Tag = $Item
    $btn.Add_Click({ Invoke-TileButton $this.Tag })
    [Windows.Controls.Grid]::SetColumn($btn, 2)

    [void]$grid.Children.Add($iconHost); [void]$grid.Children.Add($text); [void]$grid.Children.Add($btn)
    $border.Child = $grid

    $border.ToolTip = Get-ItemTip $Item

    # Double-click anywhere on the tile except its button opens it (never starts it).
    $border.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ClickCount -eq 2 -and -not (Test-InButton $e.OriginalSource $s)) { Invoke-Open $s.Tag; $e.Handled = $true } })
    $border.Add_MouseEnter({ $this.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Accent') })
    $border.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Line') })
    $border.ContextMenu = New-TileMenu $Item
    Add-KeyboardOpen $border

    $tile = [pscustomobject]@{ Border = $border; Icon = $icon; Avatar = $avatar; Plate = $plate; Badge = $badge; State = $state; Button = $btn; Item = $Item }
    Set-TileIcon $tile $Item
    Update-Tile $tile $Item
    $Item.Tiles.Add($tile)
    return $border
}

function Test-InButton($Element, $Stop) {
    $node = $Element
    while ($node -and $node -ne $Stop) {
        if ($node -is [Windows.Controls.Primitives.ButtonBase]) { return $true }
        $node = if ($node -is [Windows.Media.Visual] -or $node -is [Windows.Media.Media3D.Visual3D]) { [Windows.Media.VisualTreeHelper]::GetParent($node) } else { $node.Parent }
    }
    return $false
}

function New-TileMenu($Item) {
    $menu = New-Object Windows.Controls.ContextMenu
    $add = {
        param([string]$Header, [scriptblock]$Do, [bool]$Enabled = $true)
        $mi = New-Object Windows.Controls.MenuItem
        $mi.Header = $Header
        $mi.Tag = $Item
        $mi.IsEnabled = $Enabled
        $mi.Add_Click($Do)
        [void]$menu.Items.Add($mi)
    }
    # Start / Stop / Restart: enabled to match the container's state each time the menu opens.
    $menu.Tag = $Item
    & $add 'Start' { Invoke-ContainerAction $this.Tag 'Start' }
    & $add 'Stop' { Invoke-ContainerAction $this.Tag 'Stop' }
    & $add 'Restart' { Invoke-ContainerAction $this.Tag 'Restart' }
    foreach ($n in 0..2) { $menu.Items[$n].Uid = [string]$menu.Items[$n].Header }
    $menu.Add_Opened({ Update-TileMenu $this })
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))
    # Web page items: Uid 'Web', enabled only while the container is running.
    if ($Item.WebUrl) { & $add 'Open web page' { Open-ItemWeb $this.Tag $this.Tag.WebUrl }; $menu.Items[$menu.Items.Count - 1].Uid = 'Web' }
    if ($Item.Action.Kind -eq 'Web' -and $Item.Action.Url -ne $Item.WebUrl) { & $add "Open $($Item.Action.Text)" { Open-ItemWeb $this.Tag $this.Tag.Action.Url }; $menu.Items[$menu.Items.Count - 1].Uid = 'Web' }
    & $add 'Command window' { Open-Shell $this.Tag }
    & $add 'Log' { Open-Log $this.Tag }
    & $add 'Config folder' { if ($this.Tag.Folder) { Start-Process -FilePath 'explorer.exe' -ArgumentList "`"$($this.Tag.Folder)`"" } } ([bool]$Item.Folder)
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))
    & $add "Copy $(if ($Item.WebUrl) { 'address' } else { 'container name' })" { Copy-ItemText $this.Tag }
    Update-TileMenu $menu
    return $menu
}

function Copy-ItemText($Item) {
    <# Copy address (or the container name). The clipboard can be held by another program, so retry briefly. #>
    $u = if ($Item.WebUrl) { $Item.WebUrl } else { Get-ContainerName $Item }
    for ($n = 1; $n -le 3; $n++) {
        try { [Windows.Clipboard]::SetText($u); Set-Status "Copied $u"; return }
        catch { if ($n -eq 3) { Write-AppLog "Clipboard busy: $($_.Exception.Message)" } else { Start-Sleep -Milliseconds 80 } }
    }
    Set-Status "Couldn't copy: another program is using the clipboard. Try again."
}

function Update-TileMenu($Menu) {
    <# Enables Start / Stop / Restart and the web page items to match the container's state.
       Run when the menu opens and on every status update. #>
    if (-not $Menu) { return }
    $it = $Menu.Tag
    foreach ($mi in $Menu.Items) {
        if ($mi -isnot [Windows.Controls.MenuItem]) { continue }
        switch ($mi.Uid) {
            'Start'   { $mi.IsEnabled = Test-CanStart $it }
            'Stop'    { $mi.IsEnabled = Test-CanStop $it }
            'Restart' { $mi.IsEnabled = Test-CanStop $it }
            'Web' {
                $ok = Test-CanOpenWeb $it
                $mi.IsEnabled = $ok
                $mi.ToolTip = if ($ok) { $null } else { 'Start the container first' }
                [Windows.Controls.ToolTipService]::SetShowOnDisabled($mi, $true)
            }
        }
    }
}

function Set-ActionButton($Button, $Item) {
    <# Open (accent) when the container is running; Start (green outline) when it isn't. #>
    if ($Item.Busy) {
        $Button.Content = "$($Item.Busy)..."
        $Button.Style = $script:Window.FindResource('StartButton')
        $Button.IsEnabled = $false
        $Button.Visibility = 'Visible'
        $Button.ToolTip = $null
    } elseif ($Item.Running) {
        $Button.Content = 'Open'
        $Button.Style = $script:Window.FindResource('AccentButton')
        $Button.IsEnabled = $true
        $Button.Visibility = if ($Item.Action.Kind -eq 'None') { 'Hidden' } else { 'Visible' }
        $Button.ToolTip = $null
    } else {
        $Button.Content = 'Start'
        $Button.Style = $script:Window.FindResource('StartButton')
        $Button.IsEnabled = (Test-CanStart $Item)
        $Button.Visibility = 'Visible'
        $Button.ToolTip = "Start $($Item.Title) (docker compose up -d $($Item.Service))"
    }
}

function Update-Tile($Tile, $Item) {
    $Tile.State.Text = [string][char]0x25CF + ' ' + $(if ($Item.Busy) { "$($Item.Busy)..." } else { $Item.StateText })
    Set-Res $Tile.State ([Windows.Controls.TextBlock]::ForegroundProperty) "St_$($Item.StateKey)"
    Set-ActionButton $Tile.Button $Item
    Update-TileMenu $Tile.Border.ContextMenu
    $dim = ($Item.StateKey -eq 'off' -or $Item.StateKey -eq 'none')
    Set-Res $Tile.Border ([Windows.Controls.Border]::BackgroundProperty) $(if ($dim) { 'TileDim' } else { 'Tile' })
    # Faded a little when not running; less in dark mode, where dark icons would vanish.
    $op = if (-not $dim) { 1.0 } elseif ($script:IsDark) { 0.85 } else { 0.7 }
    $Tile.Icon.Opacity = $op; $Tile.Avatar.Opacity = $op
}

# ---------------------------------------------------------------------------
#  Icons: your Icons folder, then Homepage's (optional), then the download cache
# ---------------------------------------------------------------------------
$script:IconRequested = @{}
function Get-IconsFolder {
    <# Homelab's own Icons folder (the same for every machine), made if it isn't there yet. #>
    $dir = [string]$script:Settings.IconsFolder
    if (-not $dir.Trim()) { $dir = Get-DefaultIconsFolder }
    if (-not (Test-FilePath $dir -Folder)) {
        try { New-Item -ItemType Directory -Path $dir -Force | Out-Null; Write-AppLog "Made the Icons folder $dir" }
        catch { Write-AppLog "Icons folder $dir couldn't be made: $($_.Exception.Message)" }
    }
    return $dir
}

function Get-HomepageIconFolder {
    <# The fallback: HomepageIconFolder, or homepage\icons next to this PC's compose file. '' when turned off. #>
    if ($script:Settings.UseHomepageIcons -eq $false) { return '' }
    if ([string]$script:Settings.HomepageIconFolder) { return [string]$script:Settings.HomepageIconFolder }
    $dir = Get-ParentFolder ([string]$script:Settings.ComposePath)
    if (-not $dir) { return '' }
    return (Join-Path (Join-Path $dir 'homepage') 'icons')
}

function Get-MyIcons {
    <# Map of simplified name (letters and digits only) to icon file: the Icons folder first, then
       Homepage's icon folder if that's turned on. Read once per load. #>
    if ($script:MyIconsCache) { return $script:MyIconsCache }
    $map = @{}
    $dirs = @(Get-IconsFolder) + @(Get-HomepageIconFolder)
    foreach ($dir in $dirs) {
        if (-not (Test-FilePath $dir -Folder)) { continue }
        foreach ($f in @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -match '^\.(png|jpe?g|gif|bmp|ico)$' })) {
            $key = ($f.BaseName.ToLowerInvariant() -replace '[^a-z0-9]', '')
            if ($key -and -not $map.ContainsKey($key)) { $map[$key] = $f.FullName }
        }
    }
    $script:MyIconsCache = $map
    return $map
}

function Update-Icons {
    if (-not (Test-Path -LiteralPath $script:IconDir)) {
        try { New-Item -ItemType Directory -Path $script:IconDir -Force | Out-Null } catch { Write-AppLog "Icon cache folder couldn't be made: $($_.Exception.Message)" }
    }
    $mine = Get-MyIcons
    if ($script:MyIconsLogged -ne $mine.Count) {
        $script:MyIconsLogged = $mine.Count
        $hp = Get-HomepageIconFolder
        $where = if ($hp) { "$(Get-IconsFolder), then $hp" } else { Get-IconsFolder }
        Write-AppLog "Icon folders $($where): $($mine.Count) icons"
    }
    $fetch = [ordered]@{}
    $runIconsChanged = $false
    foreach ($i in $script:Items) {
        $found = ''
        $label = $i.IconLabel
        $slugs = @(Get-IconSlugs $i)
        if ($label -match '^[A-Za-z]:\\' -and (Test-FilePath $label)) { $found = $label }
        if (-not $found -and $label -and $mine.Count) {
            $key = (([IO.Path]::GetFileNameWithoutExtension($label)).ToLowerInvariant() -replace '[^a-z0-9]', '')
            if ($mine.ContainsKey($key) -and (Get-IconImage $mine[$key])) { $found = $mine[$key] }
        }
        if (-not $found -and $mine.Count) {
            foreach ($k in $slugs) {
                $key = $k -replace '[^a-z0-9]', ''
                # Skip files WPF can't read (WebP or SVG saved as .png) and try the next source.
                if ($mine.ContainsKey($key) -and (Get-IconImage $mine[$key])) { $found = $mine[$key]; break }
            }
        }
        if (-not $found -and (Test-Path -LiteralPath $script:IconDir)) {
            foreach ($k in $slugs) {
                $hit = @((Join-Path $script:IconDir "$k.png"), (Join-Path $script:DcmIconDir "$k.png")) | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
                if ($hit) { $found = $hit; break }
                $miss = Get-Item -LiteralPath (Join-Path $script:IconDir "$k.none") -ErrorAction SilentlyContinue
                if ($miss -and ([DateTime]::Now - $miss.LastWriteTime).TotalDays -lt 14) { continue }
                if (-not $script:IconRequested.ContainsKey($k)) { $fetch[$k] = $script:IconBase + "$k.png" }
                break
            }
        }
        if ($found -ne $i.IconPath) {
            $i.IconPath = $found
            foreach ($t in $i.Tiles) { Set-TileIcon $t $i }
            if ($i.Running) { $runIconsChanged = $true }
        }
    }
    if ($runIconsChanged) { Update-RunningList }
    if (-not $fetch.Count) { return }
    $jobs = @(foreach ($k in $fetch.Keys) { $script:IconRequested[$k] = $true; @{ Key = $k; Url = $fetch[$k] } })
    # Batches of 6 on the single icon thread, so the tiles fill in as each batch lands.
    # Each download has 5 seconds (plus 5 to connect), so a batch is done within about a minute.
    for ($p = 0; $p -lt $jobs.Count; $p += 6) {
        $chunk = @($jobs[$p..([Math]::Min($p + 5, $jobs.Count - 1))])
        Start-Background -Work $script:IconWork -Arguments @($chunk, $script:IconDir) -Pool 'Icons' -TimeoutSeconds (60 + 15 * $chunk.Count * ($p / 6 + 1)) -OnDone {
            param($out, $err)
            if (@($out | Where-Object { $_ -eq 'ok' -or $_ -eq 'none' }).Count) { Update-Icons }
        }
    }
}

# ---------------------------------------------------------------------------
#  Main window
# ---------------------------------------------------------------------------
$mainXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        MinWidth="640" MinHeight="420" Background="{DynamicResource WinBg}" Foreground="{DynamicResource Text}"
        WindowStartupLocation="CenterScreen" FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <!-- Keyboard focus: an accent outline around buttons, tiles and Running rows. -->
        <Style x:Key="AccentFocus">
            <Setter Property="Control.Template">
                <Setter.Value>
                    <ControlTemplate>
                        <Border Margin="-3" BorderThickness="2" CornerRadius="9" BorderBrush="{DynamicResource Accent}" SnapsToDevicePixels="True"/>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="Button">
            <Setter Property="Background" Value="{DynamicResource BtnBg}"/>
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
            <Setter Property="BorderThickness" Value="1"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource AccentFocus}"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Button">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                                BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="5" Padding="{TemplateBinding Padding}">
                            <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.85"/></Trigger>
                            <Trigger Property="IsPressed" Value="True"><Setter TargetName="Bd" Property="Opacity" Value="0.7"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <!-- Disabled: flat and grey (colours, not fading, so the text stays readable). Styles based on this one get it too. -->
            <Style.Triggers>
                <Trigger Property="IsEnabled" Value="False">
                    <Setter Property="Background" Value="{DynamicResource BtnOffBg}"/>
                    <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
                    <Setter Property="Foreground" Value="{DynamicResource Faint}"/>
                    <Setter Property="Cursor" Value="Arrow"/>
                </Trigger>
            </Style.Triggers>
        </Style>
        <Style x:Key="AccentButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="{DynamicResource Accent}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="Foreground" Value="{DynamicResource AccentText}"/>
        </Style>
        <!-- The header's updates pill while it isn't filtering (filtering, it uses AccentButton). -->
        <Style x:Key="UpdatesPill" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="Foreground" Value="{DynamicResource Link}"/>
            <Setter Property="FontWeight" Value="SemiBold"/>
        </Style>
        <Style x:Key="StartButton" TargetType="Button" BasedOn="{StaticResource {x:Type Button}}">
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="BorderBrush" Value="{DynamicResource St_ok}"/>
            <Setter Property="Foreground" Value="{DynamicResource St_ok}"/>
        </Style>
        <!-- Text fields: rounded, with an accent border while typing. Settings and the lock panel use these too. -->
        <Style TargetType="TextBox">
            <Setter Property="Background" Value="{DynamicResource Input}"/>
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
            <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
            <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="Padding" Value="7,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TextBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.5"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="PasswordBox">
            <Setter Property="Background" Value="{DynamicResource Input}"/>
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="BorderBrush" Value="{DynamicResource Line}"/>
            <Setter Property="CaretBrush" Value="{DynamicResource Text}"/>
            <Setter Property="SelectionBrush" Value="{DynamicResource Accent}"/>
            <Setter Property="Padding" Value="7,5"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="PasswordBox">
                        <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="5">
                            <ScrollViewer x:Name="PART_ContentHost" Margin="{TemplateBinding Padding}" VerticalAlignment="Center"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.5"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="CheckBox">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="FocusVisualStyle" Value="{StaticResource AccentFocus}"/>
        </Style>
        <Style TargetType="TabItem">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="TabItem">
                        <Border x:Name="Bd" Background="{DynamicResource TabBg}" BorderBrush="{DynamicResource Line}" BorderThickness="1"
                                CornerRadius="5,5,0,0" Padding="{TemplateBinding Padding}" Margin="0,0,3,3">
                            <ContentPresenter ContentSource="Header"/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource TabSel}"/>
                                <Setter TargetName="Bd" Property="BorderBrush" Value="{DynamicResource Accent}"/>
                            </Trigger>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource TabSel}"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <!-- Slim scroll bars, vertical and horizontal (a narrow Settings window or a wide Help table). -->
        <Style TargetType="ScrollBar">
            <Setter Property="Width" Value="12"/>
            <Setter Property="Background" Value="Transparent"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ScrollBar">
                        <Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True">
                            <Track.Thumb>
                                <Thumb>
                                    <Thumb.Template>
                                        <ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource Thumb}" CornerRadius="4" Margin="3,2"/></ControlTemplate>
                                    </Thumb.Template>
                                </Thumb>
                            </Track.Thumb>
                        </Track>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
            <Style.Triggers>
                <Trigger Property="Orientation" Value="Horizontal">
                    <Setter Property="Width" Value="Auto"/>
                    <Setter Property="Height" Value="12"/>
                    <Setter Property="Template">
                        <Setter.Value>
                            <ControlTemplate TargetType="ScrollBar">
                                <Track x:Name="PART_Track" Orientation="Horizontal" IsDirectionReversed="False">
                                    <Track.Thumb>
                                        <Thumb>
                                            <Thumb.Template>
                                                <ControlTemplate TargetType="Thumb"><Border Background="{DynamicResource Thumb}" CornerRadius="4" Margin="2,3"/></ControlTemplate>
                                            </Thumb.Template>
                                        </Thumb>
                                    </Track.Thumb>
                                </Track>
                            </ControlTemplate>
                        </Setter.Value>
                    </Setter>
                </Trigger>
            </Style.Triggers>
        </Style>
        <!-- Menus (tile right-click and the machine button): rounded card, soft shadow, accent tick. -->
        <Style TargetType="ContextMenu">
            <Setter Property="HasDropShadow" Value="False"/>
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ContextMenu">
                        <Border Margin="0,0,10,10" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="6">
                            <Border.Effect><DropShadowEffect BlurRadius="14" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
                            <ItemsPresenter KeyboardNavigation.DirectionalNavigation="Cycle"/>
                        </Border>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="MenuItem">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="FontSize" Value="13"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="MenuItem">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="5" Padding="10,6" MinWidth="170" SnapsToDevicePixels="True">
                            <Grid>
                                <Grid.ColumnDefinitions>
                                    <ColumnDefinition Width="22"/>
                                    <ColumnDefinition Width="*"/>
                                </Grid.ColumnDefinitions>
                                <TextBlock x:Name="Check" Text="&#xE73E;" FontFamily="Segoe MDL2 Assets" FontSize="12" Foreground="{DynamicResource Accent}"
                                           VerticalAlignment="Center" Visibility="Hidden"/>
                                <ContentPresenter Grid.Column="1" ContentSource="Header" RecognizesAccessKey="True" VerticalAlignment="Center"/>
                            </Grid>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsChecked" Value="True"><Setter TargetName="Check" Property="Visibility" Value="Visible"/></Trigger>
                            <Trigger Property="IsHighlighted" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource MenuHover}"/></Trigger>
                            <Trigger Property="IsEnabled" Value="False"><Setter TargetName="Bd" Property="Opacity" Value="0.45"/></Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style x:Key="{x:Static MenuItem.SeparatorStyleKey}" TargetType="Separator">
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="Separator"><Border Height="1" Margin="4,4" Background="{DynamicResource Line}"/></ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
    </Window.Resources>
    <DockPanel>
        <Border DockPanel.Dock="Top" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="0,0,0,1" Padding="16,10">
            <!-- The counts fill what's left; on narrow windows the search box shrinks first and the counts trim last (Update-HeaderFit).
                 The updates pill sits between them and never trims. -->
            <DockPanel x:Name="HeaderBar" LastChildFill="True">
                <Image x:Name="Logo" DockPanel.Dock="Left" Width="30" Height="30" Margin="0,0,10,0" VerticalAlignment="Center" RenderOptions.BitmapScalingMode="HighQuality"/>
                <TextBlock DockPanel.Dock="Left" Text="Homelab" FontSize="20" FontWeight="SemiBold" VerticalAlignment="Center"/>
                <Button x:Name="BtnMachine" DockPanel.Dock="Left" Margin="16,0,0,0" Padding="10,4" VerticalAlignment="Center" ToolTip="Which machine's containers to show" Visibility="Collapsed"/>
                <Button x:Name="BtnAbout" DockPanel.Dock="Right" Content="About" Padding="12,5" Margin="8,0,0,0"/>
                <Button x:Name="BtnHelp" DockPanel.Dock="Right" Content="Help" Padding="12,5" Margin="8,0,0,0" ToolTip="How Homelab works (F1)"/>
                <Button x:Name="BtnSettings" DockPanel.Dock="Right" Content="Settings" Padding="12,5" Margin="8,0,0,0" ToolTip="Machines (NAS address, SSH...), compose file, refresh, icons, Private tabs"/>
                <Button x:Name="BtnTheme" DockPanel.Dock="Right" Padding="12,5" Margin="8,0,0,0" MinWidth="64"/>
                <Button x:Name="BtnPortainer" DockPanel.Dock="Right" Content="Portainer" Padding="12,5" Margin="8,0,0,0" Visibility="Collapsed"/>
                <Button x:Name="BtnActions" DockPanel.Dock="Right" Padding="12,5" Margin="8,0,0,0" ToolTip="Start or stop every container on this tab, restart unhealthy ones, check for image updates"/>
                <Button x:Name="BtnRefresh" DockPanel.Dock="Right" Content="Refresh" Padding="12,5" Margin="8,0,0,0" ToolTip="Read the compose file and the containers again (F5)"/>
                <Grid x:Name="SearchBox" DockPanel.Dock="Right" Width="260" Margin="12,0,0,0" VerticalAlignment="Center">
                    <TextBox x:Name="TxtSearch" Padding="7,4" VerticalContentAlignment="Center"/>
                    <TextBlock x:Name="SearchHint" Text="Search containers  (Ctrl+F)" Foreground="{DynamicResource Hint}" Margin="9,0,8,0" VerticalAlignment="Center" IsHitTestVisible="False" TextTrimming="CharacterEllipsis"/>
                </Grid>
                <Button x:Name="BtnUpdates" DockPanel.Dock="Right" Padding="10,3" Margin="12,0,0,0" VerticalAlignment="Center" Visibility="Collapsed"/>
                <TextBlock x:Name="TxtCounts" Margin="16,0,0,0" Foreground="{DynamicResource Muted}" VerticalAlignment="Center" TextTrimming="CharacterEllipsis"/>
            </DockPanel>
        </Border>
        <Border DockPanel.Dock="Bottom" Background="{DynamicResource Footer}" BorderBrush="{DynamicResource Line}" BorderThickness="0,1,0,0" Padding="12,4">
            <DockPanel>
                <TextBlock DockPanel.Dock="Right" x:Name="TxtUpdated" Foreground="{DynamicResource Muted}"/>
                <TextBlock Foreground="{DynamicResource Muted}">
                    <Run Text="Compose file: "/><Hyperlink x:Name="LnkCompose" Foreground="{DynamicResource Link}" ToolTip="Pick another compose file"><Run x:Name="TxtCompose"/></Hyperlink>
                    <Run x:Name="TxtStatus" Text=""/>
                </TextBlock>
            </DockPanel>
        </Border>
        <Border x:Name="Banner" DockPanel.Dock="Top" Background="{DynamicResource BannerBg}" BorderBrush="{DynamicResource BannerLine}" BorderThickness="0,0,0,1" Padding="16,8" Visibility="Collapsed">
            <DockPanel>
                <Button x:Name="BtnBannerClose" DockPanel.Dock="Right" Content="&#x2715;" Padding="8,2" Margin="12,0,0,0" VerticalAlignment="Top"
                        Background="Transparent" BorderBrush="{DynamicResource BannerLine}" Foreground="{DynamicResource BannerText}" ToolTip="Dismiss"/>
                <TextBlock x:Name="TxtBanner" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="{DynamicResource BannerText}"/>
            </DockPanel>
        </Border>
        <Grid>
        <TabControl x:Name="Tabs" Margin="10,8,10,8" Background="{DynamicResource WinBg}" BorderBrush="{DynamicResource Line}" Padding="0">
            <TabControl.Template>
                <ControlTemplate TargetType="TabControl">
                    <DockPanel>
                        <WrapPanel DockPanel.Dock="Top" IsItemsHost="True" Margin="2,0,2,-1"/>
                        <Border BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Background="{TemplateBinding Background}">
                            <ContentPresenter ContentSource="SelectedContent"/>
                        </Border>
                    </DockPanel>
                </ControlTemplate>
            </TabControl.Template>
        </TabControl>
        <Border x:Name="BusyBox" HorizontalAlignment="Center" VerticalAlignment="Center" MinWidth="340" MaxWidth="560" Padding="24,18"
                CornerRadius="10" BorderThickness="1.5" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Accent}" Visibility="Collapsed">
            <Border.Effect><DropShadowEffect BlurRadius="18" ShadowDepth="2" Opacity="0.25"/></Border.Effect>
            <StackPanel>
                <TextBlock x:Name="BusyTitle" FontSize="15" FontWeight="SemiBold"/>
                <TextBlock x:Name="BusyDetail" Margin="0,4,0,0" Foreground="{DynamicResource Muted}" TextTrimming="CharacterEllipsis"/>
                <ProgressBar x:Name="BusyBar" Height="4" Margin="0,14,0,0" IsIndeterminate="True" BorderThickness="0"
                             Foreground="{DynamicResource Accent}" Background="{DynamicResource Line}"/>
            </StackPanel>
        </Border>
        </Grid>
    </DockPanel>
</Window>
'@

function Show-Busy([string]$Title, [string]$Detail, [switch]$Done) {
    <# The box over the tiles while the compose file is read. -Done shows the result briefly, then hides it. #>
    if (-not $Title) { $script:Ui.BusyBox.Visibility = 'Collapsed'; $script:BusyHideAt = $null; return }
    $script:Ui.BusyTitle.Text = $Title
    $script:Ui.BusyDetail.Text = $Detail
    $script:Ui.BusyBar.Visibility = if ($Done) { 'Collapsed' } else { 'Visible' }
    $script:Ui.BusyBox.Visibility = 'Visible'
    $script:BusyHideAt = if ($Done) { [DateTime]::Now.AddSeconds(1.5) } else { $null }
}

$script:StatusClearAt = $null
function Set-Status([string]$Text, [switch]$Sticky) {
    <# The note after the compose file name. It goes after 5 seconds unless -Sticky
       (for "Reading the compose file...", which is cleared when the read ends). #>
    if (-not $script:Ui) { return }
    $script:Ui.TxtStatus.Text = if ($Text) { "   ·   $Text" } else { '' }
    $script:StatusClearAt = if ($Text -and -not $Sticky) { [DateTime]::Now.AddSeconds(5) } else { $null }
}

$script:BannerOwner = ''
function Show-Banner([string]$Text, [string]$Owner = 'general') {
    <# The yellow bar under the header. Owner says what put it there (load, poll, container:<service>,
       settings, error), so a later success clears only its own banner. Its button dismisses it. #>
    $script:Ui.TxtBanner.Text = $Text
    $script:Ui.Banner.Visibility = if ($Text) { 'Visible' } else { 'Collapsed' }
    $script:BannerOwner = if ($Text) { $Owner } else { '' }
}

function Clear-Banner([string[]]$Owner) {
    <# Takes the banner away only when one of these put it there. #>
    if ($script:BannerOwner -and $Owner -contains $script:BannerOwner) { Show-Banner '' }
}

function Update-Counts {
    $all = @(Get-VisibleItems)
    $running = @($all | Where-Object Running).Count
    $stopped = @($all | Where-Object { $_.StateKey -eq 'off' }).Count
    $problems = @($all | Where-Object { $_.StateKey -eq 'bad' }).Count
    $missing = @($all | Where-Object { $_.StateKey -eq 'none' }).Count
    $parts = @("$($all.Count) containers", "$running running")
    if ($stopped) { $parts += "$stopped stopped" }
    if ($problems) { $parts += "$problems with a problem" }
    if ($missing) { $parts += "$missing not created" }
    $script:Ui.TxtCounts.Text = $parts -join '  ·  '
    $script:Ui.TxtCounts.ToolTip = $parts -join "`n"   # the whole list, for when a narrow window trims it
    Update-UpdatesPill
    Update-UpdatedText
    Request-HeaderFit   # the counts' length changed, so the search box may have room again (or need to give some)
}

$script:UpdatesOnly = $false   # the updates pill is pressed: only containers with a newer image are shown
function Update-UpdatesPill {
    <# The "↑ 2 updates" pill next to the counts: shown only when an update check found some. Its
       tooltip names them; clicking it shows only those (and again shows everything). #>
    $b = $script:Ui.BtnUpdates
    $names = @(Get-VisibleItems | Where-Object { $_.UpdateAvailable } | Sort-Object Title | ForEach-Object { $_.Title })
    $n = $names.Count
    if (-not $n -and $script:UpdatesOnly) { $script:UpdatesOnly = $false; Update-SearchFilter }   # nothing left to filter to
    $b.Visibility = if ($n) { 'Visible' } else { 'Collapsed' }
    if (-not $n) { return }
    $b.Content = "$([char]0x2191) $n update$(if ($n -ne 1) { 's' })"
    $b.Style = $script:Window.FindResource($(if ($script:UpdatesOnly) { 'AccentButton' } else { 'UpdatesPill' }))
    $b.FontWeight = 'SemiBold'
    $list = @($names | Select-Object -First 20 | ForEach-Object { "  $([char]0x2022) $_" })
    if ($n -gt 20) { $list += "  ...and $($n - 20) more" }
    $what = if ($n -eq 1) { 'This container has a newer image' } else { "These $n containers have a newer image" }
    $click = if ($script:UpdatesOnly) { 'Click to show every container again.' } else { 'Click to show only these.' }
    $b.ToolTip = "$($what):`n$($list -join "`n")`n`n$click"
}

function Switch-UpdatesOnly {
    <# The updates pill: show only the containers with an update, or everything again. The search still applies on top. #>
    $script:UpdatesOnly = -not $script:UpdatesOnly
    Update-SearchFilter
    Update-UpdatesPill
    Request-HeaderFit
    if ($script:UpdatesOnly) { Set-Status 'Showing only containers with a newer image. Click the updates button again to show them all.' }
    else { Set-Status '' }
}

$script:LastPollAt = $null
function Update-UpdatedText {
    <# "Updated hh:mm:ss": the time of the last status check that worked, not of the last redraw. #>
    $when = if ($script:LastPollAt) { "Updated $($script:LastPollAt.ToString('HH:mm:ss'))" } else { 'Not checked yet' }
    $script:Ui.TxtUpdated.Text = "$when  ·  every $($script:Settings.RefreshSeconds) seconds"
}

function Update-HeaderFit {
    <# When the header runs short, the search box gives way first (260 down to 150 px) so the counts
       keep their whole text; only once it's at 150 px do the counts trim (full text in their tooltip).
       The buttons and the updates pill keep their size: if even that doesn't fit (a very narrow
       window), the search box goes below 150 px (down to 60) rather than squeeze the pill. #>
    $bar = $script:Ui.HeaderBar
    if (-not $bar -or $bar.ActualWidth -le 0) { return }
    $fixed = 0.0
    $inf = New-Object Windows.Size([double]::PositiveInfinity, [double]::PositiveInfinity)
    foreach ($c in $bar.Children) {
        if ($c -eq $script:Ui.SearchBox -or $c -eq $script:Ui.TxtCounts -or $c.Visibility -ne 'Visible') { continue }
        # Natural width (DesiredSize includes the margin); ActualWidth is already squeezed when the bar is short.
        $c.Measure($inf)
        $fixed += $c.DesiredSize.Width
    }
    # The counts' untrimmed width (their ActualWidth is already trimmed on a narrow window).
    $tc = $script:Ui.TxtCounts
    $countsW = $tc.Margin.Left + $tc.Margin.Right + 2
    if ($tc.Text) {
        $ft = New-Object Windows.Media.FormattedText($tc.Text, [Globalization.CultureInfo]::CurrentUICulture, 'LeftToRight',
            (New-Object Windows.Media.Typeface($tc.FontFamily, $tc.FontStyle, $tc.FontWeight, $tc.FontStretch)), $tc.FontSize, $tc.Foreground,
            [Windows.Media.VisualTreeHelper]::GetDpi($tc).PixelsPerDip)
        $countsW += [Math]::Ceiling($ft.WidthIncludingTrailingWhitespace)
    }
    $spare = $bar.ActualWidth - $fixed - $script:Ui.SearchBox.Margin.Left   # for the search box and the counts
    $w = [Math]::Max(150, [Math]::Min(260, $spare - $countsW))
    if ($w -gt $spare) { $w = [Math]::Max(60, [Math]::Floor($spare)) }
    if ([Math]::Abs($script:Ui.SearchBox.Width - $w) -ge 1) { $script:Ui.SearchBox.Width = $w }
}

function Request-HeaderFit {
    <# Update-HeaderFit once the header has been measured (after a resize, or a button showing or hiding). #>
    if ($script:Window) { [void]$script:Window.Dispatcher.BeginInvoke([Action] { Update-HeaderFit }, [Windows.Threading.DispatcherPriority]::Loaded) }
}

function New-Glyph([string]$Code, [double]$Size = 12) {
    <# A Segoe MDL2 Assets icon as a Run, for text such as the lock on Private tabs (E72E). #>
    $r = New-Object Windows.Documents.Run([string][char][Convert]::ToInt32($Code, 16))
    $r.FontFamily = 'Segoe MDL2 Assets'; $r.FontSize = $Size; $r.BaselineAlignment = 'Center'
    return $r
}

function New-TabHeader([string]$Text, [string]$Count, [switch]$Locked) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Inlines.Add((New-Object Windows.Documents.Run($Text)))
    if ($Locked) {
        $tb.Inlines.Add((New-Object Windows.Documents.Run('  ')))
        $g = New-Glyph 'E72E' 11
        Set-Res $g ([Windows.Documents.TextElement]::ForegroundProperty) 'Faint'
        $tb.Inlines.Add($g)
    }
    if ($Count) {
        $c = New-Object Windows.Documents.Run("  $Count")
        Set-Res $c ([Windows.Documents.TextElement]::ForegroundProperty) 'Faint'; $c.FontSize = 11
        $tb.Inlines.Add($c)
    }
    return $tb
}

# ---------------------------------------------------------------------------
#  Private groups: hidden everywhere until unlocked with a password. This only
#  hides them in Homelab; it is not encryption.
# ---------------------------------------------------------------------------
$script:PrivateUnlocked = $false
$script:TabBeforeLock = ''

function Test-PrivateGroup([string]$Group) { return (@($script:Settings.PrivateGroups | ForEach-Object { [string]$_ }) -contains $Group) }
function Test-Hidden($Item) { return ((-not $script:PrivateUnlocked) -and (Test-PrivateGroup $Item.Group)) }
function Get-VisibleItems { return @($script:Items | Where-Object { -not (Test-Hidden $_) }) }

function Get-SecureBytes([Security.SecureString]$Secure) {
    <# A PasswordBox's SecurePassword as UTF-8 bytes; the caller clears them after use. #>
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToGlobalAllocUnicode($Secure)
    try {
        $chars = New-Object char[] $Secure.Length
        [Runtime.InteropServices.Marshal]::Copy($ptr, $chars, 0, $Secure.Length)
        $bytes = [Text.Encoding]::UTF8.GetBytes($chars)
        [Array]::Clear($chars, 0, $chars.Length)
        return , $bytes
    } finally { [Runtime.InteropServices.Marshal]::ZeroFreeGlobalAllocUnicode($ptr) }
}

function Test-SameSecure([Security.SecureString]$A, [Security.SecureString]$B) {
    $x = Get-SecureBytes $A; $y = Get-SecureBytes $B
    try { return ([Convert]::ToBase64String($x) -eq [Convert]::ToBase64String($y)) }
    finally { [Array]::Clear($x, 0, $x.Length); [Array]::Clear($y, 0, $y.Length) }
}

function Get-PasswordHash([Security.SecureString]$Password, [byte[]]$Salt) {
    <# PBKDF2 (SHA-256, 100,000 rounds), base64. #>
    $bytes = Get-SecureBytes $Password
    try {
        $kdf = New-Object Security.Cryptography.Rfc2898DeriveBytes(([byte[]]$bytes), $Salt, 100000, [Security.Cryptography.HashAlgorithmName]::SHA256)
        try { return [Convert]::ToBase64String($kdf.GetBytes(32)) } finally { $kdf.Dispose() }
    } finally { [Array]::Clear($bytes, 0, $bytes.Length) }
}

function Test-PrivatePassword([Security.SecureString]$Password) {
    try {
        $salt = [Convert]::FromBase64String([string]$script:Settings.PrivatePasswordSalt)
        $want = [Convert]::FromBase64String([string]$script:Settings.PrivatePasswordHash)
    } catch { return $false }
    if (-not $salt.Length -or -not $want.Length) { return $false }
    $got = [Convert]::FromBase64String((Get-PasswordHash $Password $salt))
    if ($got.Length -ne $want.Length) { return $false }
    $diff = 0
    for ($n = 0; $n -lt $got.Length; $n++) { $diff = $diff -bor ($got[$n] -bxor $want[$n]) }
    return ($diff -eq 0)
}

function Save-PrivatePassword([Security.SecureString]$Password) {
    <# Stores a new salted hash (or removes it, given $null) and saves settings.json.
       Returns '' when saved; otherwise puts the old hash back and returns why. #>
    $s = $script:Settings
    $oldSalt = [string]$s.PrivatePasswordSalt; $oldHash = [string]$s.PrivatePasswordHash
    if ($Password) {
        $salt = New-Object byte[] 16
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($salt) } finally { $rng.Dispose() }
        $s.PrivatePasswordSalt = [Convert]::ToBase64String($salt)
        $s.PrivatePasswordHash = Get-PasswordHash $Password $salt
    } else {
        $s.PrivatePasswordSalt = ''; $s.PrivatePasswordHash = ''
    }
    try { Save-AppSetting $s; $script:SkipSaveOnClose = $false; return '' }
    catch {
        $s.PrivatePasswordSalt = $oldSalt; $s.PrivatePasswordHash = $oldHash
        Write-AppLog "Private password not saved: $($_.Exception.Message)"
        return $_.Exception.Message
    }
}

function Invoke-Unlock($Ctx) {
    $Ctx.Msg.Text = ''
    $pw = $Ctx.Pw1.SecurePassword
    if ($Ctx.First) {
        if ($pw.Length -lt 4) { $Ctx.Msg.Text = 'Use at least 4 characters.'; return }
        if (-not (Test-SameSecure $pw $Ctx.Pw2.SecurePassword)) { $Ctx.Msg.Text = "The two passwords don't match. Type them again."; $Ctx.Pw2.Clear(); return }
        $problem = Save-PrivatePassword $pw
        if ($problem) { $Ctx.Msg.Text = "The password couldn't be saved, so the tab stays locked: $problem"; return }
        Write-AppLog 'Private password set'
    } elseif (-not (Test-PrivatePassword $pw)) {
        $Ctx.Msg.Text = "That isn't the password."
        $Ctx.Pw1.Clear()
        Write-AppLog 'Private unlock: wrong password'
        return
    }
    $script:PrivateUnlocked = $true
    Write-AppLog 'Private tabs unlocked'
    $script:Settings.LastTab = $Ctx.Group
    Update-Tabs
    Update-Counts
}

function Invoke-LockCancel($Ctx) {
    <# Cancel on a lock panel: no password is set or checked, the fields are emptied, and
       the tab that was open before (else All) comes back. The private tab stays locked. #>
    $Ctx.Pw1.Clear()
    if ($Ctx.Pw2) { $Ctx.Pw2.Clear() }
    $Ctx.Msg.Text = ''
    $tabs = $script:Ui.Tabs
    $want = [string]$script:TabBeforeLock
    $pick = @($tabs.Items | Where-Object { $want -and $_.Tag -eq $want -and -not (Test-PrivateGroup $_.Tag) } | Select-Object -First 1)
    $tabs.SelectedItem = if ($pick.Count) { $pick[0] } else { $tabs.Items[0] }
}

function Get-LockContext {
    <# The open tab's lock panel details, or $null when the open tab isn't a locked one. #>
    $t = $script:Ui.Tabs.SelectedItem
    if (-not $t -or -not $t.Content) { return $null }
    $card = $t.Content.Content
    if ($card -is [Windows.Controls.Border] -and $card.Tag -is [hashtable] -and $card.Tag.ContainsKey('Pw1')) { return $card.Tag }
    return $null
}

function Invoke-Lock {
    $script:PrivateUnlocked = $false
    Write-AppLog 'Private tabs locked'
    Update-Tabs
    Update-Counts
}

function New-LockPanel([string]$Group) {
    $first = -not [string]$script:Settings.PrivatePasswordHash
    $card = New-Object Windows.Controls.Border
    $card.Width = 400; $card.HorizontalAlignment = 'Center'; $card.VerticalAlignment = 'Top'
    $card.Margin = '0,60,0,20'; $card.Padding = '26,22'; $card.CornerRadius = 10; $card.BorderThickness = 1
    Set-Res $card ([Windows.Controls.Border]::BackgroundProperty) 'Panel'
    Set-Res $card ([Windows.Controls.Border]::BorderBrushProperty) 'Line'
    $sp = New-Object Windows.Controls.StackPanel
    $title = New-Object Windows.Controls.TextBlock
    $title.Inlines.Add((New-Glyph 'E72E' 16))
    $title.Inlines.Add((New-Object Windows.Documents.Run('   ' + $(if ($first) { "Set a password for $Group" } else { "$Group is locked" }))))
    $title.FontSize = 17; $title.FontWeight = 'SemiBold'
    $body = New-Object Windows.Controls.TextBlock
    $body.TextWrapping = 'Wrap'; $body.Margin = '0,8,0,14'
    Set-Res $body ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    $body.Text = if ($first) { "Choose a password for the private tabs. Until it's typed in, their containers are hidden from All, Running and search. It hides them in Homelab; it isn't encryption." }
                 else { "Type the password to show these containers. They stay unlocked until Homelab closes or you press Lock." }
    [void]$sp.Children.Add($title); [void]$sp.Children.Add($body)
    $ctx = @{ First = $first; Group = $Group; Pw1 = $null; Pw2 = $null; Msg = $null }
    $boxes = @()
    foreach ($label in @('Password') + @(if ($first) { 'Same password again' })) {
        $l = New-Object Windows.Controls.TextBlock
        $l.Text = $label; $l.Margin = '0,6,0,3'; $l.FontSize = 12
        Set-Res $l ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
        $pb = New-Object Windows.Controls.PasswordBox
        $pb.Tag = $ctx
        $pb.Add_KeyDown({ param($s, $e) if ($e.Key -eq 'Return') { Invoke-Unlock $s.Tag; $e.Handled = $true } })
        [void]$sp.Children.Add($l); [void]$sp.Children.Add($pb)
        $boxes += $pb
    }
    $ctx.Pw1 = $boxes[0]
    if ($first) { $ctx.Pw2 = $boxes[1] }
    $boxes[0].Add_Loaded({ [void]$this.Focus() })
    $msg = New-Object Windows.Controls.TextBlock
    $msg.TextWrapping = 'Wrap'; $msg.Margin = '0,10,0,0'
    Set-Res $msg ([Windows.Controls.TextBlock]::ForegroundProperty) 'St_bad'
    $ctx.Msg = $msg
    $btn = New-Object Windows.Controls.Button
    $btn.Content = if ($first) { 'Set password and unlock' } else { 'Unlock' }
    $btn.Style = $script:Window.FindResource('AccentButton')
    $btn.Padding = '14,5'
    $btn.Tag = $ctx
    $btn.Add_Click({ Invoke-Unlock $this.Tag })
    $cancel = New-Object Windows.Controls.Button
    $cancel.Content = 'Cancel'
    $cancel.Padding = '16,5'; $cancel.MinWidth = 84; $cancel.Margin = '0,0,8,0'
    $cancel.ToolTip = $(if ($first) { 'Go back without setting a password. This tab stays locked.' } else { 'Go back without unlocking.' })
    $cancel.Tag = $ctx
    $cancel.Add_Click({ Invoke-LockCancel $this.Tag })
    $buttons = New-Object Windows.Controls.StackPanel
    $buttons.Orientation = 'Horizontal'; $buttons.HorizontalAlignment = 'Right'; $buttons.Margin = '0,14,0,0'
    [void]$buttons.Children.Add($cancel); [void]$buttons.Children.Add($btn)
    [void]$sp.Children.Add($msg); [void]$sp.Children.Add($buttons)
    $card.Child = $sp
    $card.Tag = $ctx
    return $card
}

function New-UnlockedPanel($Panel) {
    <# An unlocked private group: a Lock button above its tiles. #>
    $dock = New-Object Windows.Controls.DockPanel
    $bar = New-Object Windows.Controls.DockPanel
    $bar.Margin = '14,10,14,0'
    [Windows.Controls.DockPanel]::SetDock($bar, 'Top')
    $lock = New-Object Windows.Controls.Button
    $lockText = New-Object Windows.Controls.TextBlock
    $lockText.Inlines.Add((New-Glyph 'E72E' 12)); $lockText.Inlines.Add((New-Object Windows.Documents.Run('  Lock')))
    $lock.Content = $lockText
    $lock.Padding = '12,4'
    $lock.ToolTip = 'Hide the private tabs again'
    $lock.Add_Click({ Invoke-Lock })
    [Windows.Controls.DockPanel]::SetDock($lock, 'Right')
    $note = New-Object Windows.Controls.TextBlock
    $note.Text = 'Unlocked until Homelab closes.'
    $note.VerticalAlignment = 'Center'
    Set-Res $note ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    [void]$bar.Children.Add($lock); [void]$bar.Children.Add($note)
    [void]$dock.Children.Add($bar); [void]$dock.Children.Add($Panel)
    return $dock
}

# ---------------------------------------------------------------------------
#  Running tab: the running containers as a list
# ---------------------------------------------------------------------------
$script:RunList = $null
$script:RunTab = $null
$script:RunRows = @{}      # service -> the row's parts, for updating it in place
$script:RunSig = $null     # which rows are built (Update-RunningList rebuilds when it changes)
$script:RunCount = -1
$script:RunCols = @(@{ W = 38 }, @{ W = '2*' }, @{ W = '1*' }, @{ W = '1.4*' }, @{ W = '2*' }, @{ W = 84 })

function New-RunGrid {
    $grid = New-Object Windows.Controls.Grid
    foreach ($c in $script:RunCols) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = if ($c.W -eq 'Auto') { [Windows.GridLength]::Auto }
                    elseif ([string]$c.W -like '*`*') { New-Object Windows.GridLength([double]([string]$c.W).TrimEnd('*'), 'Star') }
                    else { New-Object Windows.GridLength([double]$c.W) }
        $grid.ColumnDefinitions.Add($cd)
    }
    return $grid
}

function Add-GridText($Grid, [int]$Column, [string]$Text, [string]$Brush, [switch]$Bold) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.VerticalAlignment = 'Center'; $tb.TextTrimming = 'CharacterEllipsis'; $tb.Margin = '0,0,12,0'
    if ($Bold) { $tb.FontWeight = 'SemiBold' }
    if ($Brush) { Set-Res $tb ([Windows.Controls.TextBlock]::ForegroundProperty) $Brush }
    [Windows.Controls.Grid]::SetColumn($tb, $Column)
    [void]$Grid.Children.Add($tb)
    return $tb
}

function Get-ItemTip($Item) {
    $tip = "$($Item.Title)`n$($Item.Service) · $($Item.Image)"
    if ($Item.Description) { $tip = "$($Item.Description)`n$tip" }
    $tip += "`nOpen: " + $(switch ($Item.Action.Kind) { 'Web' { $Item.Action.Url } 'Shell' { 'a command window inside the container' } 'Log' { 'its log' } default { 'nothing' } })
    return $tip
}

function New-RunRow($Item) {
    $row = New-Object Windows.Controls.Border
    $row.Padding = '8,6'; $row.BorderThickness = '1'; $row.CornerRadius = 6; $row.Margin = '0,0,0,4'
    Set-Res $row ([Windows.Controls.Border]::BackgroundProperty) 'Tile'
    Set-Res $row ([Windows.Controls.Border]::BorderBrushProperty) 'Line'
    $row.Cursor = 'Hand'
    $row.Tag = $Item
    $grid = New-RunGrid

    $iconHost = New-Object Windows.Controls.Grid
    $iconHost.Width = 26; $iconHost.Height = 26; $iconHost.HorizontalAlignment = 'Left'
    $img = if ($Item.IconPath) { Get-IconImage $Item.IconPath } else { $null }
    if ($img) {
        $plate = New-Object Windows.Controls.Border
        $plate.CornerRadius = 6; $plate.Padding = '2'
        Set-Res $plate ([Windows.Controls.Border]::BackgroundProperty) 'IconPlate'
        $icon = New-Object Windows.Controls.Image
        $icon.Source = $img
        [Windows.Media.RenderOptions]::SetBitmapScalingMode($icon, 'HighQuality')
        $plate.Child = $icon
        [void]$iconHost.Children.Add($plate)
    } else {
        [void]$iconHost.Children.Add((New-Avatar $Item 6 10.5))
    }
    if ($Item.UpdateAvailable) {
        $badge = New-UpdateBadge
        $badge.Width = 12; $badge.Height = 12; $badge.Margin = '0,-4,-5,0'; $badge.Visibility = 'Visible'
        [void]$iconHost.Children.Add($badge)
    }
    [void]$grid.Children.Add($iconHost)

    [void](Add-GridText $grid 1 $Item.Title '' -Bold)
    [void](Add-GridText $grid 2 $Item.Group 'Muted')
    $status = Add-GridText $grid 3 '' ''
    $where = if ($Item.WebUrl) { $Item.WebUrl -replace '^https?://', '' -replace '/$', '' } else { $Item.Action.Text }
    [void](Add-GridText $grid 4 $where 'Where')

    $btn = New-Object Windows.Controls.Button
    $btn.Padding = '12,3'; $btn.MinWidth = 58; $btn.VerticalAlignment = 'Center'; $btn.HorizontalAlignment = 'Right'
    $btn.Tag = $Item
    $btn.Add_Click({ Invoke-TileButton $this.Tag })
    [Windows.Controls.Grid]::SetColumn($btn, 5)
    [void]$grid.Children.Add($btn)

    $row.Child = $grid
    $row.ToolTip = Get-ItemTip $Item
    $row.Add_MouseLeftButtonDown({ param($s, $e) if ($e.ClickCount -eq 2 -and -not (Test-InButton $e.OriginalSource $s)) { Invoke-Open $s.Tag; $e.Handled = $true } })
    $row.Add_MouseEnter({ $this.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Accent') })
    $row.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Border]::BorderBrushProperty, 'Line') })
    $row.ContextMenu = New-TileMenu $Item
    Add-KeyboardOpen $row
    $script:RunRows[$Item.Service] = @{ Row = $row; Status = $status; Button = $btn; Item = $Item }
    Update-RunRow $script:RunRows[$Item.Service]
    return $row
}

function Update-RunRow($Parts) {
    <# A Running row's status, button and menu, changed in place (an open menu stays open). #>
    $it = $Parts.Item
    $st = if ($it.Busy) { "$($it.Busy)..." } else { $it.StateText }
    $Parts.Status.Text = [string][char]0x25CF + ' ' + $st
    Set-Res $Parts.Status ([Windows.Controls.TextBlock]::ForegroundProperty) "St_$($it.StateKey)"
    Set-ActionButton $Parts.Button $it
    Update-TileMenu $Parts.Row.ContextMenu
}

function Add-RunNote([string]$Text) {
    $tb = New-Object Windows.Controls.TextBlock
    $tb.Text = $Text; $tb.Margin = '8,14,0,0'
    Set-Res $tb ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    [void]$script:RunList.Children.Add($tb)
}

function Update-RunningList {
    <# Called on every status poll, search, icon change and start/stop. Sorted by name. The rows are
       rebuilt only when which containers are listed (or their icons) changes; otherwise each row is
       updated in place, so an open right-click menu, focus and hover aren't lost every few seconds. #>
    if (-not $script:RunList) { return }
    $running = @(Get-VisibleItems | Where-Object { $_.Running } | Sort-Object Title)
    if ($script:RunTab -and $script:RunCount -ne $running.Count) {
        $script:RunTab.Header = New-TabHeader 'Running' ([string]$running.Count)
        $script:RunCount = $running.Count
    }
    $shown = @($running | Where-Object { Test-SearchMatch $_ })
    $sig = "$(Get-MachineName)|$([bool]$running.Count)|" +(($shown | ForEach-Object { "$($_.Service)>$($_.IconPath)>$($_.UpdateAvailable)" }) -join '|')
    if ($sig -eq $script:RunSig) {
        foreach ($i in $shown) { if ($script:RunRows.ContainsKey($i.Service)) { Update-RunRow $script:RunRows[$i.Service] } }
        return
    }
    $script:RunSig = $sig
    $script:RunRows = @{}
    $script:RunList.Children.Clear()
    if (-not $running.Count) { Add-RunNote "Nothing is running on $(Get-MachineName)."; return }
    $head = New-RunGrid
    $head.Margin = '8,0,8,6'
    $n = 1
    foreach ($h in 'Name', 'Group', 'Status', 'Address') {
        $t = Add-GridText $head $n $h.ToUpperInvariant() 'Faint' -Bold
        $t.FontSize = 11
        $n++
    }
    [void]$script:RunList.Children.Add($head)
    foreach ($i in $shown) { [void]$script:RunList.Children.Add((New-RunRow $i)) }
    if (-not $shown.Count) { Add-RunNote 'No running container matches the search.' }
}

# ---------------------------------------------------------------------------
#  Help window (the Help button and F1)
# ---------------------------------------------------------------------------
$script:HelpText = @(
    @('h', 'What Homelab does'),
    @('p', 'Homelab reads your docker compose file and shows every container as a tile, grouped by its home.group label, with its state (running, stopped, not created...) read from Docker every 15 seconds (change it in Settings > General). One click opens its web page. It works on this PC, and on other machines (a NAS) over SSH.'),
    @('h', 'The header'),
    @('t', @(@('Machine button', 'Next to the title: picks the machine (see Machines). It shows once Settings has a machine besides This PC.'),
            @('Refresh', 'Read the compose file and the containers again (F5).'),
            @('Actions', 'Start all, Stop all, Restart unhealthy and Check for image updates now (see Actions menu).'),
            @('↑ 2 updates', 'Appears when newer images are found; click it to show only those (see Image updates).'),
            @('Portainer', 'Opens Portainer, when it is running on the chosen machine or PortainerUrl is set.'),
            @('Auto/Light/Dark', 'The theme button (see Themes and Portainer).'),
            @('Settings', 'Machines, this PC''s compose file and the General settings (see Settings).'),
            @('Help', 'This window (F1).'),
            @('About', 'The version, what Homelab does, the copyright and licence, the GitHub link and where settings live.'))),
    @('h', 'Tiles and the Open / Start button'),
    @('p', 'A running container''s button says Open. A container that isn''t running (stopped, exited or not created) shows a green-outlined Start button instead; clicking it starts that container (docker compose up -d --no-deps <service>). Double-clicking a tile opens it, but never starts it. A web page only opens while its container is running; otherwise the status line says to start it first.'),
    @('p', 'What Open does, in order:'),
    @('b', 'home.open label: a web address, another service''s name (open that one''s page), shell (command window), log, or none (no button).'),
    @('b', 'home.url label: that address (or none for no web page). It replaces the published port and skips the database rule below.'),
    @('b', 'A database (MariaDB, MySQL, Postgres...) opens its admin tool (phpMyAdmin, pgAdmin, Adminer) when the compose file has one, else a command window.'),
    @('b', 'Otherwise the first published web port (https for 443, 8443, 9443...).'),
    @('b', 'No web page at all: its log.'),
    @('h', 'Right-click menu'),
    @('b', 'Start, Stop, Restart: this one container only (docker compose up -d --no-deps, stop, restart). Only the ones that fit its state are enabled. They work on the NAS too, over SSH.'),
    @('b', 'Open web page, plus Open via <name> (such as Open via phpMyAdmin) when Open goes somewhere else: greyed out until the container is running.'),
    @('b', 'Command window (a shell inside the container), Log (last 300 lines, then live), Config folder (its first mounted folder; on the NAS through the path map).'),
    @('b', 'Copy address (or the container name when it has no web page).'),
    @('h', 'Running tab'),
    @('p', 'Every running container as a list: icon, name, group, status, address and Open. It updates on every status check, follows the search box, and has the same right-click menu. Double-click a row to open it.'),
    @('h', 'Search and keys'),
    @('t', @(@('Ctrl+F', 'Go to the search box. Words match name, service, container, group, image and description.'),
            @('Esc', 'Clear the search (in the search box), or leave a locked tab without unlocking it.'),
            @('Enter', 'Open the first running container on this tab that matches (in the search box). If none is running, the status line says so.'),
            @('Tab', 'Move between buttons, tiles and Running rows (the focused one has an accent outline).'),
            @('Enter (on a tile)', 'Open it, like double-click (a Running row too).'),
            @('Menu key', 'Show the focused tile''s right-click menu (Shift+F10 works too).'),
            @('F5', 'Read the compose file and the containers again (same as Refresh).'),
            @('F1', 'Open this Help window (same as the Help button).'))),
    @('h', 'Actions menu'),
    @('b', 'Start all / Stop all on the open tab: every container shown there (the search and the updates button count) that isn''t already in that state. A locked Private tab has none. Homelab lists them and asks first, then runs them one at a time. While they run, the menu has Cancel the remaining, which stops the rest.'),
    @('b', 'Restart unhealthy: every container whose health check says unhealthy, on any tab (not hidden Private ones, and whatever the search), after asking.'),
    @('b', 'Check for image updates now: see below.'),
    @('h', 'Notifications'),
    @('p', 'When a container becomes unhealthy or stops with an error between two status checks, Windows shows a notification (click it to come back to Homelab). Not on the first check after starting or switching machine, not for containers you started, stopped or restarted in the last few minutes, and not for hidden Private ones. Turn it off in Settings > General.'),
    @('h', 'Image updates'),
    @('p', 'Every 6 hours (and from Actions > Check for image updates now) Homelab compares the image each container uses (its tag, such as latest) with the registry: Docker Hub, ghcr.io, lscr.io and others that allow anonymous reads. A container with a newer image gets a small blue arrow on its icon, and a blue button such as "↑ 2 updates" appears in the header (hover over it for their names). Click it to show only those containers, and again to show them all; the search still works on top. It only reads; it never pulls or recreates anything. On a NAS the image list comes over SSH. Turn it off in Settings > General.'),
    @('h', 'Machines'),
    @('p', 'The button next to the title picks the machine: This PC runs docker.exe here; any other machine is reached with Windows'' own ssh.exe (key login, no password prompts) and docker runs there. Web addresses use that machine''s address, and command windows and logs open over ssh -t. Icons come from the same Icons folder for every machine. The list starts as a copy of Docker Container Manager''s machines. Change it in Settings > Machines (Test connection checks SSH and Docker); each machine has:'),
    @('t', @(@('Name', 'Shown on the machine button, for example NAS.'),
            @('Address', 'Its IP address or host name.'),
            @('SSH user, port', 'Who ssh logs in as (with your key) and the port (blank for 22).'),
            @('Folder', 'The compose project folder there.'),
            @('Compose file', 'In that folder, or a full /path.'),
            @('Project', 'The compose project name the stack runs under (blank: the folder name; Synology uses the project''s name).'),
            @('Web address', 'The host web pages use (blank: the Address). Use a host name such as nas, not an IP address: some apps (Radarr, Prowlarr) only answer to names on their allowed-hosts list, so Settings won''t save an IP here, or a blank one when the Address is an IP.'),
            @('Path map', 'Its folders as Windows shares, for Config folder, e.g. /volume1/docker = \\nas\docker.'))),
    @('h', 'Icons'),
    @('p', 'Put your own icons in the Icons folder (Settings > General; by default the Icons folder beside Homelab''s Builds and Source folders), named after the service or container, for example jellyfin.png. Case, spaces, - and _ don''t matter. The same folder is used for every machine. Icons aren''t shipped with Homelab, because the logos belong to their projects.'),
    @('p', 'A tile''s icon is looked for in this order:'),
    @('b', 'home.icon: a full path to an image, or a name looked up as below.'),
    @('b', 'The Icons folder.'),
    @('b', 'Homepage''s icon folder (Settings > General > Homepage icons, or homepage\icons next to This PC''s compose file), if Fall back to Homepage icons is ticked.'),
    @('b', 'The download cache (Homelab''s, then Docker Container Manager''s), then a download from the Dashboard Icons set, one at a time in the background.'),
    @('b', 'With none, the initials.'),
    @('h', 'Labels in the compose file'),
    @('t', @(@('home.group', 'The tab and heading it goes under (default Other).'),
            @('home.name', 'The name on the tile.'),
            @('home.description', 'Shown in the tile''s tooltip.'),
            @('home.icon', 'An icon name (e.g. jellyfin) or a full path to an image.'),
            @('home.url', 'The address to open, or none for no web page.'),
            @('home.open', 'What Open does: a web address, a service name, shell, log or none.'),
            @('home.hide', 'true leaves it out of Homelab altogether.'))),
    @('h', 'Private tab lock'),
    @('p', 'Groups listed in PrivateGroups (default Private) are hidden from All, Running, search and the counts, and their tab asks for a password. The first time, you choose one (typed twice). Cancel (or Esc) goes back to the tab you were on without setting or checking a password, and the tab stays locked. Only a salted PBKDF2 hash is kept in settings.json. Unlocking lasts until Homelab closes, or until you press Lock on the tab. This hides the containers in Homelab; it isn''t encryption, and they still show in Docker and the compose file.'),
    @('h', 'Themes and Portainer'),
    @('p', 'The theme button switches Auto (same as Windows), Light and Dark. The Portainer button appears when a Portainer container is running on the chosen machine (or PortainerUrl is set) and opens it.'),
    @('h', 'Settings'),
    @('b', 'Machines: add, remove and edit machines (name, address, SSH user and port, folder, compose file, project, web address, path map) and test the connection.'),
    @('b', 'This PC: the compose file Docker Desktop runs.'),
    @('b', 'General: refresh time, Portainer address, Private groups, notifications, the update check, the Icons folder, the Homepage fallback and its folder, and setting, changing or removing the Private password (changing or removing needs the current one).'),
    @('p', 'Save writes settings.json and reads the containers again if anything that affects them changed. The window stays open and shows Saved until you change something. Close shuts it; changes since the last Save are dropped (a password change is saved straight away).'),
    @('h', 'Where things live'),
    @('p', "Settings and log: $script:DataDir (settings.json, its last good copy settings.json.bak, and Homelab.log). If settings.json can't be read, it's kept as settings.bad-<date>.json, Homelab starts with default settings and says so, and nothing is saved over it on close. Icon cache: $script:IconDir. The window's size and position are remembered. Only one Homelab runs at a time: starting it again brings the open one to the front."),
    @('p', "Homelab itself: $PSCommandPath, run by Windows PowerShell (there's no exe). In a release folder, Homelab.cmd makes the Homelab shortcut next to it and in the Start menu, and the shortcut starts Homelab without a console window. Pin Homelab from the Start menu or its taskbar button.")
)

function New-HelpPage {
    $sp = New-Object Windows.Controls.StackPanel
    $sp.Margin = '24,8,24,24'; $sp.MaxWidth = 860; $sp.HorizontalAlignment = 'Left'
    foreach ($e in $script:HelpText) {
        switch ($e[0]) {
            'h' {
                $tb = New-Object Windows.Controls.TextBlock
                $tb.Text = $e[1]; $tb.FontSize = 16; $tb.FontWeight = 'SemiBold'; $tb.Margin = '0,18,0,4'
                [void]$sp.Children.Add($tb)
            }
            'p' {
                $tb = New-Object Windows.Controls.TextBlock
                $tb.Text = $e[1]; $tb.TextWrapping = 'Wrap'; $tb.Margin = '0,3,0,3'; $tb.LineHeight = 20
                [void]$sp.Children.Add($tb)
            }
            'b' {
                $tb = New-Object Windows.Controls.TextBlock
                $tb.Text = [string][char]0x2022 + '  ' + $e[1]; $tb.TextWrapping = 'Wrap'; $tb.Margin = '12,2,0,2'; $tb.LineHeight = 20
                [void]$sp.Children.Add($tb)
            }
            't' {
                $grid = New-Object Windows.Controls.Grid
                $grid.Margin = '12,4,0,6'
                $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength(170)
                $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength(1, 'Star')
                $grid.ColumnDefinitions.Add($c1); $grid.ColumnDefinitions.Add($c2)
                $r = 0
                foreach ($pair in $e[1]) {
                    $grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
                    $k = New-Object Windows.Controls.TextBlock
                    $k.Text = $pair[0]; $k.FontFamily = 'Consolas'; $k.Margin = '0,3,12,3'
                    Set-Res $k ([Windows.Controls.TextBlock]::ForegroundProperty) 'Link'
                    $v = New-Object Windows.Controls.TextBlock
                    $v.Text = $pair[1]; $v.TextWrapping = 'Wrap'; $v.Margin = '0,3,0,3'
                    [Windows.Controls.Grid]::SetRow($k, $r); [Windows.Controls.Grid]::SetRow($v, $r)
                    [Windows.Controls.Grid]::SetColumn($v, 1)
                    [void]$grid.Children.Add($k); [void]$grid.Children.Add($v)
                    $r++
                }
                [void]$sp.Children.Add($grid)
            }
        }
    }
    return $sp
}

$script:HelpXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="900" Height="700" MinWidth="480" MinHeight="320" ShowInTaskbar="False" ResizeMode="CanResize"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WinBg}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI" FontSize="13">
    <DockPanel>
        <DockPanel DockPanel.Dock="Bottom" Margin="14,8,14,14">
            <Button x:Name="HelpClose" DockPanel.Dock="Right" Content="Close" Padding="16,5" MinWidth="84" IsCancel="True"/>
            <TextBlock/>
        </DockPanel>
        <ScrollViewer x:Name="HelpScroll" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled"/>
    </DockPanel>
</Window>
'@

function Show-Help {
    <# Help in its own window beside the main one; a second click (or F1) brings the open one to the front. #>
    if ($script:HelpWindow) { $script:HelpWindow.Activate() | Out-Null; return }
    $w = New-XamlWindow $script:HelpXaml
    $w.Owner = $script:Window
    $w.Icon = $script:Window.Icon
    $w.Title = "$script:AppName Help"
    # The main window's colours and styles (buttons, scroll bars), so the theme matches.
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    $w.FindName('HelpScroll').Content = New-HelpPage
    $w.FindName('HelpClose').Add_Click({ [Windows.Window]::GetWindow($this).Close() })
    $w.Add_SourceInitialized({ Set-DarkTitleBar $script:IsDark $script:HelpWindow })
    $w.Add_Closed({ $script:HelpWindow = $null })
    $script:HelpWindow = $w
    $w.Show()
}

function New-GroupPanel([object[]]$Items) {
    $wrap = New-Object Windows.Controls.WrapPanel
    foreach ($i in $Items) { [void]$wrap.Children.Add((New-Tile $i)) }
    return $wrap
}

function Update-Tabs {
    $tabs = $script:Ui.Tabs
    $tabs.Items.Clear()
    foreach ($i in $script:Items) { $i.Tiles.Clear() }
    $script:Sections = New-Object System.Collections.Generic.List[object]   # group heading + panel, for search
    $groups = @($script:Items | Group-Object Group | Sort-Object @{ Expression = { if ($_.Name -eq 'Other') { 1 } else { 0 } } }, @{ Expression = { $_.Name } })
    $shownGroups = @($groups | Where-Object { $script:PrivateUnlocked -or -not (Test-PrivateGroup $_.Name) })

    # All: every group, one under another (private ones only once unlocked).
    $allStack = New-Object Windows.Controls.StackPanel
    $allStack.Margin = '14,4,4,8'
    foreach ($g in $shownGroups) {
        $head = New-Object Windows.Controls.TextBlock
        $head.Text = $g.Name.ToUpperInvariant() + "   $($g.Count)"
        $head.FontWeight = 'SemiBold'; $head.FontSize = 12; Set-Res $head ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
        $head.Margin = '0,12,0,8'
        $panel = New-GroupPanel @($g.Group | Sort-Object Title)
        [void]$allStack.Children.Add($head); [void]$allStack.Children.Add($panel)
        $script:Sections.Add(@{ Head = $head; Panel = $panel })
    }
    [void](Add-Tab 'All' ([string]@(Get-VisibleItems).Count) $allStack)

    # Running: a list, second after All; Update-RunningList fills it and its count.
    $script:RunList = New-Object Windows.Controls.StackPanel
    $script:RunList.Margin = '14,12,14,8'
    $script:RunTab = Add-Tab 'Running' '' $script:RunList
    $script:RunSig = $null; $script:RunRows = @{}; $script:RunCount = -1

    foreach ($g in $groups) {
        if ((Test-PrivateGroup $g.Name) -and -not $script:PrivateUnlocked) {
            [void](Add-Tab $g.Name '' (New-LockPanel $g.Name) -Locked)
            continue
        }
        $panel = New-GroupPanel @($g.Group | Sort-Object Title)
        $panel.Margin = '14,14,4,8'
        $script:Sections.Add(@{ Head = $null; Panel = $panel })
        $content = if (Test-PrivateGroup $g.Name) { New-UnlockedPanel $panel } else { $panel }
        [void](Add-Tab $g.Name ([string]$g.Count) $content)
    }
    $want = [string]$script:Settings.LastTab
    $pick = @($tabs.Items | Where-Object { $_.Tag -eq $want } | Select-Object -First 1)
    $tabs.SelectedItem = if ($pick.Count) { $pick[0] } else { $tabs.Items[0] }
    Update-SearchFilter
}

function Add-Tab([string]$Name, [string]$Count, $Content, [switch]$Locked) {
    $scroll = New-Object Windows.Controls.ScrollViewer
    $scroll.VerticalScrollBarVisibility = 'Auto'
    $scroll.Content = $Content
    $tab = New-Object Windows.Controls.TabItem
    $tab.Header = New-TabHeader $Name $Count -Locked:$Locked
    $tab.Tag = $Name
    $tab.Padding = '10,5'
    $tab.Content = $scroll
    [void]$script:Ui.Tabs.Items.Add($tab)
    return $tab
}

function Test-SearchMatch($Item) {
    <# Every word in the search box is in the container's name, service, group, image or description
       (and, while the updates pill is pressed, it has a newer image). #>
    if ($script:UpdatesOnly -and -not $Item.UpdateAvailable) { return $false }
    $words = @($script:Ui.TxtSearch.Text.Trim().ToLowerInvariant() -split '\s+' | Where-Object { $_ })
    if (-not $words.Count) { return $true }
    $hay = ("$($Item.Title) $($Item.Service) $($Item.Container) $($Item.Group) $($Item.Image) $($Item.Description)").ToLowerInvariant()
    foreach ($w in $words) { if (-not $hay.Contains($w)) { return $false } }
    return $true
}

function Update-SearchFilter {
    $q = $script:Ui.TxtSearch.Text.Trim()
    $script:Ui.SearchHint.Visibility = if ($q) { 'Collapsed' } else { 'Visible' }
    foreach ($i in $script:Items) {
        $show = Test-SearchMatch $i
        foreach ($t in $i.Tiles) { $t.Border.Visibility = if ($show) { 'Visible' } else { 'Collapsed' } }
    }
    Update-RunningList
    foreach ($s in $script:Sections) {
        $any = $false
        foreach ($c in $s.Panel.Children) { if ($c.Visibility -eq 'Visible') { $any = $true; break } }
        if ($s.Head) { $s.Head.Visibility = if ($any) { 'Visible' } else { 'Collapsed' }; $s.Panel.Visibility = $s.Head.Visibility }
    }
}

# ---------------------------------------------------------------------------
#  Loading and refreshing
# ---------------------------------------------------------------------------
$script:Items = New-Object System.Collections.Generic.List[object]
$script:Sections = New-Object System.Collections.Generic.List[object]
$script:Loading = $false
$script:Polling = $false
$script:PollSoon = $false
$script:NextPoll = [DateTime]::MaxValue
$script:ComposeStamp = ''
$script:OldCompose = $false
$script:WebHost = 'localhost'
$script:MyIconsCache = $null
$script:ProjectName = ''   # the compose project (from docker compose config), to tell same-named services apart
# Goes up whenever the machine or compose file changes. Every load, poll and Portainer check
# carries the number it started with, and a result for an older one is dropped.
$script:Generation = 0

function Get-ComposeStamp {
    if (Get-Machine) { return '' }   # another machine's file: read again with Refresh
    $p = [string]$script:Settings.ComposePath
    try { $f = Get-Item -LiteralPath $p -ErrorAction Stop; return "$($f.LastWriteTimeUtc.Ticks)|$($f.Length)" } catch { return '' }
}

function Start-Load {
    if ($script:Loading) { return }
    $path = Get-ComposeLabel
    $script:Ui.TxtCompose.Text = if ($path) { $path } else { 'Pick your compose file...' }
    $script:WebHost = Get-WebHost
    $script:MyIconsCache = $null
    if (-not (Get-Machine) -and -not (Test-FilePath $path)) {
        $msg = if ($path) { "The compose file $path wasn't found. Click its name at the bottom (or use Settings > This PC) to pick one." }
               else { 'Welcome to Homelab. Pick your docker-compose.yml: click Pick your compose file... at the bottom, or use Settings > This PC.' }
        Show-Banner $msg 'load'
        return
    }
    $script:Loading = $true
    $script:ComposeStamp = Get-ComposeStamp
    Set-Status 'Reading the compose file...' -Sticky
    Show-Busy $(if ($script:Items.Count) { 'Refreshing the compose file...' } else { 'Reading the compose file...' }) $path
    # --no-env-resolution: a missing env_file shouldn't stop the list loading. Compose before 2.24
    # doesn't know it, so it's dropped if Docker says so.
    $cfgArgs = @('config', '--format', 'json')
    if (-not $script:OldCompose) { $cfgArgs += '--no-env-resolution' }
    Start-Docker (@(Get-ComposeArguments) + $cfgArgs) {
        param($res, $ctx)
        $script:Loading = $false
        # The machine or compose file changed while this was being read: read the new one instead.
        if ($ctx.Gen -ne $script:Generation) { Start-Load; return }
        if ($res.ExitCode -ne 0 -and -not $script:OldCompose -and $res.Error -match 'unknown flag: --no-env-resolution') {
            $script:OldCompose = $true
            Start-Load
            return
        }
        if ($res.ExitCode -ne 0) {
            $msg = Get-ErrorSummary $res.Error 4
            if (-not $msg) { $msg = "docker compose config stopped with code $($res.ExitCode)." }
            if ($res.TimedOut) { $msg = "$(Get-MachineName) didn't answer in time. Press Refresh to try again. ($msg)" }
            elseif (Get-Machine) {
                if (Test-DockerDown $res.Error) { $msg = "$(Get-MachineName) couldn't be reached over SSH. Check it's on, then press Refresh. ($msg)" }
            } elseif (Test-DockerDown $res.Error) { $msg = "Docker isn't running. Start Docker Desktop, then press Refresh. ($msg)" }
            Show-Busy ''
            Show-Banner "Couldn't read the compose file: $msg" 'load'
            Write-AppLog "Compose read failed: $msg"
            Set-Status ''
            $script:NextPoll = [DateTime]::Now.AddSeconds(30)
            return
        }
        try { $cfg = $res.Output | ConvertFrom-Json } catch {
            Show-Busy ''
            Show-Banner "Couldn't understand docker compose's answer: $($_.Exception.Message)" 'load'
            Set-Status ''
            $script:NextPoll = [DateTime]::Now.AddSeconds(30)
            return
        }
        Clear-Banner 'load', 'poll'
        $script:ProjectName = [string](Get-PropValue $cfg 'name')
        $path = Get-ComposeLabel   # this runs after Start-Load has returned, so its $path is gone
        # Keep each container's last known state, so the counts don't flash to "not created" until the next poll.
        $known = @{}
        foreach ($o in $script:Items) { $known[$o.Service] = $o }
        $script:Items = Import-Compose $cfg
        foreach ($n in $script:Items) {
            $o = $known[$n.Service]
            if ($o) { $n.State = $o.State; $n.StateText = $o.StateText; $n.StateKey = $o.StateKey; $n.Running = $o.Running }
        }
        Show-Busy "Building $($script:Items.Count) tiles..." $path
        $script:Window.Dispatcher.Invoke([Action]{}, [Windows.Threading.DispatcherPriority]::Render)
        Update-Tabs
        Set-UpdateBadges   # what the last update check found, on the new tiles
        Update-Icons
        Start-PortainerCheck
        # The first update check a couple of minutes after the first read, then every 6 hours.
        if ($script:NextUpdateCheck -eq [DateTime]::MaxValue) { $script:NextUpdateCheck = [DateTime]::Now.AddMinutes(2) }
        Set-Status ''
        Write-AppLog "Read $($script:Items.Count) containers from $path"
        Show-Busy "Read $($script:Items.Count) containers" $path -Done
        $script:NextPoll = [DateTime]::MinValue
    } @{ Gen = $script:Generation }
}

function Get-PortainerUrl([string]$Text) {
    <# From "image<tab>ports" lines of docker ps: Portainer's address, preferring its https port 9443. #>
    $http = ''
    foreach ($line in ($Text -split "`r?`n")) {
        $parts = $line -split "`t"
        if ($parts.Count -lt 2 -or $parts[0] -notmatch '(^|/)portainer/portainer(-ce|-ee)?(:|@|$)') { continue }
        foreach ($m in [regex]::Matches($parts[1], ':(\d+)->(\d+)/tcp')) {
            $hostPort = $m.Groups[1].Value
            switch ($m.Groups[2].Value) {
                '9443' { return "https://$($script:WebHost):$hostPort/" }
                '9000' { if (-not $http) { $http = "http://$($script:WebHost):$hostPort/" } }
            }
        }
    }
    return $http
}

function Set-PortainerButton([string]$Url) {
    $script:PortainerUrl = $Url
    $script:Ui.BtnPortainer.Visibility = if ($Url) { 'Visible' } else { 'Collapsed' }
    $script:Ui.BtnPortainer.ToolTip = if ($Url) { "Open Portainer ($Url)" } else { $null }
    Request-HeaderFit
}

function Start-PortainerCheck {
    <# The Portainer button: the PortainerUrl setting, or a running Portainer container on this PC. #>
    if ($script:Settings.PortainerUrl) { Set-PortainerButton ([string]$script:Settings.PortainerUrl); return }
    Start-Docker @('ps', '--format', "{{.Image}}`t{{.Ports}}") {
        param($res, $ctx)
        if ($ctx.Gen -ne $script:Generation -or $res.ExitCode -ne 0) { return }
        Set-PortainerButton (Get-PortainerUrl ([string]$res.Output))
    } @{ Gen = $script:Generation }
}

function Reset-ForNewSource {
    <# The machine or compose file changed: forget the old containers and read the new ones.
       Anything still running for the old one is ignored when it comes back (Generation). #>
    param([switch]$ClearTiles)
    $script:Generation++
    $script:OldCompose = $false
    $script:ProjectName = ''
    if ($ClearTiles) {
        $script:Items = New-Object System.Collections.Generic.List[object]
        $script:Ui.Tabs.Items.Clear()
        $script:RunList = $null; $script:RunSig = $null; $script:RunRows = @{}
    }
    $script:Polling = $false
    $script:PollSoon = $false
    $script:LastPollAt = $null
    $script:StatusSeeded = $false
    $script:ActionQueue.Clear(); $script:ActionTotal = 0
    $script:UpdateChecking = $false; $script:UpdateRemote = @{}; $script:UpdateLocal = @{}; $script:UpdateCount = 0; $script:UpdatesOnly = $false
    $script:NextUpdateCheck = [DateTime]::MaxValue
    Set-PortainerButton ''
    $script:NextPoll = [DateTime]::MaxValue
    # A load still running sees the new Generation when it ends and starts this one itself.
    if (-not $script:Loading) { Start-Load }
}

function Switch-Machine([string]$Name) {
    if ($Name -eq (Get-MachineName)) { return }
    $script:Settings.Machine = if ($Name -eq 'This PC') { '' } else { $Name }
    try { Save-AppSetting $script:Settings } catch { Write-AppLog "Settings not saved: $($_.Exception.Message)" }
    Write-AppLog "Switched to $Name"
    Update-MachineButton
    Reset-ForNewSource -ClearTiles
}

function Update-MachineButton {
    $script:Ui.BtnMachine.Content = "$(Get-MachineName)  " + [string][char]0x25BE
    $menu = New-Object Windows.Controls.ContextMenu
    foreach ($m in @([pscustomobject]@{ Name = 'This PC'; Login = '' }) + @($script:Settings.Machines)) {
        $n = [string]$m.Name
        $selected = ($n -eq (Get-MachineName))
        # Header: a device glyph, then the name over its address.
        $row = New-Object Windows.Controls.StackPanel
        $row.Orientation = 'Horizontal'
        $glyph = New-Object Windows.Controls.TextBlock
        $glyph.Text = if ($n -eq 'This PC') { [string][char]0xE7F4 } else { [string][char]0xE968 }
        $glyph.FontFamily = 'Segoe MDL2 Assets'; $glyph.FontSize = 16; $glyph.VerticalAlignment = 'Center'; $glyph.Margin = '0,0,10,0'
        Set-Res $glyph ([Windows.Controls.TextBlock]::ForegroundProperty) $(if ($selected) { 'Accent' } else { 'Muted' })
        $lines = New-Object Windows.Controls.StackPanel
        $name = New-Object Windows.Controls.TextBlock
        $name.Text = $n
        if ($selected) { $name.FontWeight = 'SemiBold' }
        $addr = New-Object Windows.Controls.TextBlock
        $addr.Text = if ($n -eq 'This PC') { 'Docker Desktop' } else { ([string]$m.Login -split '@')[-1] }
        $addr.FontSize = 11
        Set-Res $addr ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
        [void]$lines.Children.Add($name); [void]$lines.Children.Add($addr)
        [void]$row.Children.Add($glyph); [void]$row.Children.Add($lines)
        $mi = New-Object Windows.Controls.MenuItem
        $mi.Header = $row
        $mi.Tag = $n
        $mi.IsCheckable = $true
        $mi.IsChecked = $selected
        $mi.Add_Click({ Switch-Machine ([string]$this.Tag) })
        [void]$menu.Items.Add($mi)
    }
    $script:Ui.BtnMachine.ContextMenu = $menu
    $script:Ui.BtnMachine.Visibility = if (@($script:Settings.Machines).Count) { 'Visible' } else { 'Collapsed' }
    Request-HeaderFit
}

function Start-Poll {
    if ($script:Polling -or -not $script:Items.Count) { return }
    $script:Polling = $true
    $format = "{{.Names}}`t{{.Label `"com.docker.compose.service`"}}`t{{.Label `"com.docker.compose.project`"}}`t{{.State}}`t{{.Status}}"
    Start-Docker @('ps', '-a', '--no-trunc', '--format', $format) {
        param($res, $ctx)
        # From before a machine switch: Reset-ForNewSource has already reset the polling state.
        if ($ctx.Gen -ne $script:Generation) { return }
        $script:Polling = $false
        $script:NextPoll = if ($script:PollSoon) { [DateTime]::MinValue } else { [DateTime]::Now.AddSeconds((Get-RefreshSeconds)) }
        $script:PollSoon = $false
        if ($res.ExitCode -ne 0) {
            $msg = Get-ErrorSummary $res.Error 2
            $down = if (Get-Machine) { "$(Get-MachineName) didn't answer, so the status shown may be out of date. It will catch up when it's back." }
                    else { "Docker isn't running, so the status shown may be out of date. Start Docker Desktop and it will catch up." }
            Show-Banner $(if ($res.TimedOut -or (Test-DockerDown $res.Error)) { $down } else { "Docker didn't answer: $msg" }) 'poll'
            return
        }
        Clear-Banner 'poll'
        $script:LastPollAt = [DateTime]::Now
        Import-Status $res.Output
    } @{ Gen = $script:Generation }
}

function Select-ComposeFile {
    if (Get-Machine) { Set-Status "$(Get-MachineName)'s compose file is set in settings.json (Machines). Switch to This PC to pick a file here."; return }
    $dlg = New-Object Microsoft.Win32.OpenFileDialog
    $dlg.Title = 'Pick your compose file'
    $dlg.Filter = 'Compose files (*.yml;*.yaml)|*.yml;*.yaml|All files (*.*)|*.*'
    $curDir = Get-ParentFolder ([string]$script:Settings.ComposePath)
    if (Test-FilePath $curDir -Folder) { $dlg.InitialDirectory = $curDir }
    if ($dlg.ShowDialog($script:Window)) {
        $script:Settings.ComposePath = $dlg.FileName
        try { Save-AppSetting $script:Settings; $script:SkipSaveOnClose = $false }
        catch { Write-AppLog "Settings not saved: $($_.Exception.Message)"; Set-Status "The compose file is used now but couldn't be saved in settings.json: $($_.Exception.Message)" }
        Write-AppLog "Compose file: $($dlg.FileName)"
        $script:MyIconsCache = $null; $script:MyIconsLogged = -1
        Reset-ForNewSource
    }
}

# ---------------------------------------------------------------------------
#  Settings window: machines (NAS address, SSH...), this PC, general
# ---------------------------------------------------------------------------
$script:SettingsXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Settings" Width="880" Height="660" MinWidth="720" MinHeight="520" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WinBg}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI" FontSize="13">
    <Window.Resources>
        <!-- TextBox, PasswordBox, Button, CheckBox and scroll bar styles come from the main window. -->
        <Style TargetType="ListBoxItem">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="Cursor" Value="Hand"/>
            <Setter Property="Template">
                <Setter.Value>
                    <ControlTemplate TargetType="ListBoxItem">
                        <Border x:Name="Bd" Background="Transparent" CornerRadius="5" Padding="10,7" Margin="0,0,0,2">
                            <ContentPresenter/>
                        </Border>
                        <ControlTemplate.Triggers>
                            <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Bd" Property="Background" Value="{DynamicResource MenuHover}"/></Trigger>
                            <Trigger Property="IsSelected" Value="True">
                                <Setter TargetName="Bd" Property="Background" Value="{DynamicResource MenuHover}"/>
                                <Setter Property="FontWeight" Value="SemiBold"/>
                            </Trigger>
                        </ControlTemplate.Triggers>
                    </ControlTemplate>
                </Setter.Value>
            </Setter>
        </Style>
        <Style TargetType="RadioButton">
            <Setter Property="Foreground" Value="{DynamicResource Text}"/>
            <Setter Property="Margin" Value="0,0,18,0"/>
            <Setter Property="VerticalContentAlignment" Value="Center"/>
        </Style>
    </Window.Resources>
    <DockPanel Margin="14">
        <DockPanel DockPanel.Dock="Bottom" Margin="0,12,0,0">
            <Button x:Name="SetClose" DockPanel.Dock="Right" Content="Close" Padding="16,5" MinWidth="84" Margin="8,0,0,0" IsCancel="True" ToolTip="Close Settings. Changes since the last Save are dropped."/>
            <Button x:Name="SetSave" DockPanel.Dock="Right" Content="Save" Padding="16,5" MinWidth="84" Style="{DynamicResource AccentButton}" ToolTip="Save and apply the settings. The window stays open."/>
            <TextBlock x:Name="SetMsg" TextWrapping="Wrap" VerticalAlignment="Center" Foreground="{DynamicResource St_bad}"/>
        </DockPanel>
        <TabControl x:Name="SetTabs" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" Padding="0">
            <TabControl.Template>
                <ControlTemplate TargetType="TabControl">
                    <DockPanel>
                        <WrapPanel DockPanel.Dock="Top" IsItemsHost="True" Margin="2,0,2,-1"/>
                        <Border BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" Background="{TemplateBinding Background}" CornerRadius="0,6,6,6">
                            <ContentPresenter ContentSource="SelectedContent"/>
                        </Border>
                    </DockPanel>
                </ControlTemplate>
            </TabControl.Template>
            <TabItem Header="Machines" Padding="12,5">
                <Grid Margin="16">
                    <Grid.ColumnDefinitions>
                        <ColumnDefinition Width="210"/>
                        <ColumnDefinition Width="18"/>
                        <ColumnDefinition Width="*"/>
                    </Grid.ColumnDefinitions>
                    <DockPanel>
                        <TextBlock DockPanel.Dock="Top" Text="Other machines, reached over SSH. This PC is always there." TextWrapping="Wrap" Foreground="{DynamicResource Muted}" Margin="0,0,0,8" FontSize="12"/>
                        <StackPanel DockPanel.Dock="Bottom" Orientation="Horizontal" Margin="0,8,0,0">
                            <Button x:Name="MAdd" Content="Add" Padding="14,4"/>
                            <Button x:Name="MRemove" Content="Remove" Padding="14,4" Margin="8,0,0,0"/>
                        </StackPanel>
                        <ListBox x:Name="MList" Background="{DynamicResource Input}" BorderBrush="{DynamicResource Line}" Padding="4"/>
                    </DockPanel>
                    <ScrollViewer Grid.Column="2" VerticalScrollBarVisibility="Auto">
                        <StackPanel x:Name="MHost"/>
                    </ScrollViewer>
                </Grid>
            </TabItem>
            <TabItem Header="This PC" Padding="12,5">
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="PcHost" Margin="16"/></ScrollViewer>
            </TabItem>
            <TabItem Header="General" Padding="12,5">
                <ScrollViewer VerticalScrollBarVisibility="Auto"><StackPanel x:Name="GenHost" Margin="16"/></ScrollViewer>
            </TabItem>
        </TabControl>
    </DockPanel>
</Window>
'@

function Set-Prop($Object, [string]$Name, $Value) {
    if ($Object.PSObject.Properties[$Name]) { $Object.$Name = $Value } else { $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function New-FormGrid {
    $g = New-Object Windows.Controls.Grid
    $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = New-Object Windows.GridLength(140)
    $c2 = New-Object Windows.Controls.ColumnDefinition; $c2.Width = New-Object Windows.GridLength(1, 'Star')
    $g.ColumnDefinitions.Add($c1); $g.ColumnDefinitions.Add($c2)
    return $g
}

function Add-FormRow($Grid, [string]$Label, $Control, [string]$Hint) {
    <# One labelled field, with an optional hint under it. #>
    $r = $Grid.RowDefinitions.Count
    $Grid.RowDefinitions.Add((New-Object Windows.Controls.RowDefinition))
    $l = New-Object Windows.Controls.TextBlock
    $l.Text = $Label; $l.Margin = '0,10,12,0'; $l.VerticalAlignment = 'Top'
    Set-Res $l ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    $cell = New-Object Windows.Controls.StackPanel
    $cell.Margin = '0,4,0,4'
    [void]$cell.Children.Add($Control)
    if ($Hint) {
        $h = New-Object Windows.Controls.TextBlock
        $h.Text = $Hint; $h.FontSize = 11.5; $h.TextWrapping = 'Wrap'; $h.Margin = '2,3,0,0'
        Set-Res $h ([Windows.Controls.TextBlock]::ForegroundProperty) 'Faint'
        [void]$cell.Children.Add($h)
    }
    [Windows.Controls.Grid]::SetRow($l, $r); [Windows.Controls.Grid]::SetRow($cell, $r)
    [Windows.Controls.Grid]::SetColumn($cell, 1)
    [void]$Grid.Children.Add($l); [void]$Grid.Children.Add($cell)
    # Line the label up with the middle of its field (fields, check boxes and Browse rows differ in height).
    $Control.Add_SizeChanged({
            param($s, $e)
            $lab = $null
            foreach ($c in $s.Parent.Parent.Children) { if ([Windows.Controls.Grid]::GetRow($c) -eq [Windows.Controls.Grid]::GetRow($s.Parent) -and [Windows.Controls.Grid]::GetColumn($c) -eq 0) { $lab = $c } }
            if (-not $lab -or $lab.ActualHeight -le 0) { return }
            $top = $s.Parent.Margin.Top + $s.Margin.Top + [Math]::Max(0, ($s.ActualHeight - $lab.ActualHeight) / 2)
            if ([Math]::Abs($lab.Margin.Top - $top) -ge 0.5) { $lab.Margin = New-Object Windows.Thickness(0, $top, 12, 0) }
        })
}

function New-Field([double]$Width) {
    $tb = New-Object Windows.Controls.TextBox
    if ($Width) { $tb.Width = $Width; $tb.HorizontalAlignment = 'Left' }
    return $tb
}

function New-CheckBox([string]$Text) {
    $c = New-Object Windows.Controls.CheckBox
    $c.Content = $Text; $c.Margin = '0,6,0,0'; $c.VerticalContentAlignment = 'Center'
    Set-Res $c ([Windows.Controls.Control]::ForegroundProperty) 'Text'
    return $c
}

function New-BrowseField($TextBox, [scriptblock]$OnBrowse) {
    <# A field with a Browse... button on its right. The button's Tag is the field. #>
    $d = New-Object Windows.Controls.DockPanel
    $b = New-Object Windows.Controls.Button
    $b.Content = 'Browse...'; $b.Padding = '12,4'; $b.Margin = '8,0,0,0'; $b.Tag = $TextBox
    $b.Add_Click($OnBrowse)
    [Windows.Controls.DockPanel]::SetDock($b, 'Right')
    [void]$d.Children.Add($b); [void]$d.Children.Add($TextBox)
    return $d
}

function Select-Folder([string]$Start) {
    Add-Type -AssemblyName System.Windows.Forms
    $dlg = New-Object Windows.Forms.FolderBrowserDialog
    $dlg.ShowNewFolderButton = $false
    if (Test-FilePath $Start -Folder) { $dlg.SelectedPath = $Start }
    try { if ($dlg.ShowDialog() -eq 'OK') { return $dlg.SelectedPath } } finally { $dlg.Dispose() }
    return $null
}

function New-SectionTitle([string]$Text) {
    $t = New-Object Windows.Controls.TextBlock
    $t.Text = $Text; $t.FontSize = 15; $t.FontWeight = 'SemiBold'; $t.Margin = '0,6,0,6'
    return $t
}

function Add-PathRow([string]$From, [string]$To) {
    $row = New-Object Windows.Controls.DockPanel
    $row.Margin = '0,0,0,6'
    $del = New-Object Windows.Controls.Button
    $del.Content = [string][char]0x2715; $del.Padding = '9,3'; $del.Margin = '8,0,0,0'; $del.ToolTip = 'Remove this folder'
    $del.Tag = $row
    $del.Add_Click({ $script:Set.PathRows.Children.Remove($this.Tag); Clear-SavedMessage })
    [Windows.Controls.DockPanel]::SetDock($del, 'Right')
    $g = New-Object Windows.Controls.Grid
    foreach ($w in @('*', 26, '*')) {
        $cd = New-Object Windows.Controls.ColumnDefinition
        $cd.Width = if ($w -eq '*') { New-Object Windows.GridLength(1, 'Star') } else { New-Object Windows.GridLength($w) }
        $g.ColumnDefinitions.Add($cd)
    }
    $a = New-Field; $a.Text = $From; $a.ToolTip = 'Folder on the machine, e.g. /volume1/docker'
    $arrow = New-Object Windows.Controls.TextBlock
    $arrow.Text = [string][char]0x2192; $arrow.HorizontalAlignment = 'Center'; $arrow.VerticalAlignment = 'Center'
    Set-Res $arrow ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    $b = New-Field; $b.Text = $To; $b.ToolTip = 'The same folder as a Windows share, e.g. \\nas\docker'
    [Windows.Controls.Grid]::SetColumn($arrow, 1); [Windows.Controls.Grid]::SetColumn($b, 2)
    [void]$g.Children.Add($a); [void]$g.Children.Add($arrow); [void]$g.Children.Add($b)
    [void]$row.Children.Add($del); [void]$row.Children.Add($g)
    $row.Tag = @{ From = $a; To = $b }
    [void]$script:Set.PathRows.Children.Add($row)
}

function Split-Login([string]$Login) {
    <# "user@host" into user and host (the host is after the last @). #>
    $at = $Login.LastIndexOf('@')
    if ($at -lt 0) { return @('', $Login) }
    return @($Login.Substring(0, $at), $Login.Substring($at + 1))
}

$script:WebIpAdvice = 'Use the machine''s host name here (for example nas), not an IP address. Some apps, such as Radarr and Prowlarr, only answer to names on their allowed-hosts list and refuse pages opened by IP.'

function Test-IpAddress([string]$Text) {
    <# True for an IPv4 or IPv6 address (with or without [ ]), not for a host name. #>
    $t = $Text.Trim().Trim('[', ']')
    if (-not $t) { return $false }
    $ip = $null
    if (-not [Net.IPAddress]::TryParse($t, [ref]$ip)) { return $false }
    # TryParse also takes plain numbers like "1234"; only count dotted IPv4 or IPv6.
    return ($ip.AddressFamily -eq 'InterNetworkV6' -or $t -match '^\d{1,3}(\.\d{1,3}){3}$')
}

function Get-WebAddressProblem([string]$Web, [string]$HostName) {
    <# Why this machine's web address won't do, or '' when it's fine. #>
    if ($Web.Trim()) {
        if (Test-IpAddress $Web) { return $script:WebIpAdvice }
        return ''
    }
    if (Test-IpAddress $HostName) { return "Web address is blank, so web pages would use the IP address $($HostName.Trim()). $script:WebIpAdvice" }
    return ''
}

function Update-WebAddressHint {
    $f = $script:Set.F
    $script:Set.WebWarn.Text = Get-WebAddressProblem $f.Web.Text $f.Host.Text
    $script:Set.WebWarn.Visibility = if ($script:Set.WebWarn.Text) { 'Visible' } else { 'Collapsed' }
}

function Show-MachineForm {
    $f = $script:Set.F
    $w = $script:Set.Current
    $script:Set.Form.IsEnabled = [bool]$w
    $script:Set.PathRows.Children.Clear()
    $script:Set.TestText.Text = ''
    # Filling the form isn't an edit, so it leaves Saved showing.
    $script:Set.Filling = $true
    try { Set-MachineFormField $f $w } finally { $script:Set.Filling = $false }
    Update-WebAddressHint
}

function Set-MachineFormField($f, $w) {
    if (-not $w) { foreach ($k in $f.Keys) { $f[$k].Text = '' }; return }
    $d = $w.Data
    $ul = Split-Login ([string]$d.Login)
    $f.Name.Text = [string]$d.Name; $f.User.Text = $ul[0]; $f.Host.Text = $ul[1]
    $f.Port.Text = [string]$d.Port; $f.Folder.Text = [string]$d.Folder; $f.Compose.Text = [string]$d.ComposeFile
    $f.Project.Text = [string]$d.Project; $f.Web.Text = [string]$d.WebHost
    if ($d.PathMap) { foreach ($p in $d.PathMap.PSObject.Properties) { Add-PathRow $p.Name ([string]$p.Value) } }
}

function Save-MachineForm {
    $w = $script:Set.Current
    if (-not $w) { return }
    $f = $script:Set.F
    $d = $w.Data
    $hostName = $f.Host.Text.Trim(); $user = $f.User.Text.Trim()
    Set-Prop $d 'Name' $f.Name.Text.Trim()
    Set-Prop $d 'Login' $(if ($user) { "$user@$hostName" } else { $hostName })
    Set-Prop $d 'Port' $f.Port.Text.Trim()
    Set-Prop $d 'Folder' $f.Folder.Text.Trim()
    Set-Prop $d 'ComposeFile' $(if ($f.Compose.Text.Trim()) { $f.Compose.Text.Trim() } else { 'docker-compose.yml' })
    Set-Prop $d 'Project' $f.Project.Text.Trim()
    Set-Prop $d 'WebHost' $f.Web.Text.Trim()
    $map = [ordered]@{}
    foreach ($row in $script:Set.PathRows.Children) {
        $from = $row.Tag.From.Text.Trim(); $to = $row.Tag.To.Text.Trim()
        if ($from -and $to) { $map[$from] = $to }
    }
    Set-Prop $d 'PathMap' ([pscustomobject]$map)
    $w.Item.Content = if ($d.Name) { $d.Name } else { '(no name)' }
}

function Add-MachineEntry($Data, [string]$Original) {
    $li = New-Object Windows.Controls.ListBoxItem
    $li.Content = [string]$Data.Name
    $w = [pscustomobject]@{ Data = $Data; Original = $Original; Item = $li }
    $li.Tag = $w
    [void]$script:Set.List.Items.Add($li)
    return $li
}

function Test-MachineConnection {
    Save-MachineForm
    $d = $script:Set.Current.Data
    $tb = $script:Set.TestText
    Set-Res $tb ([Windows.Controls.TextBlock]::ForegroundProperty) 'St_bad'
    if (-not (Split-Login ([string]$d.Login))[1]) { $tb.Text = 'Type the address first.'; return }
    $ssh = Find-Ssh
    if (-not $ssh) { $tb.Text = "ssh.exe wasn't found. Turn on the OpenSSH Client in Windows Settings > System > Optional features."; return }
    if ($d.Port -and -not (Test-PortNumber ([string]$d.Port))) { $tb.Text = 'The SSH port must be a number from 1 to 65535.'; return }
    Set-Res $tb ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    $tb.Text = "Connecting to $($d.Login)..."
    $a = @(Get-SshArguments $d) + @(Get-RemoteCommand @('version', '--format', '{{.Server.Version}}'))
    Start-Program $ssh $a $env:USERPROFILE {
        param($res, $text)
        $ver = ([string]$res.Output).Trim()
        if ($res.ExitCode -eq 0 -and $ver) {
            Set-Res $text ([Windows.Controls.TextBlock]::ForegroundProperty) 'St_ok'
            $text.Text = "Connected. Docker $ver."
        } else {
            Set-Res $text ([Windows.Controls.TextBlock]::ForegroundProperty) 'St_bad'
            $msg = Get-ErrorSummary $res.Error 3
            $text.Text = "Couldn't connect: $(if ($msg) { $msg } else { "ssh stopped with code $($res.ExitCode)." })"
        }
    } $tb 30
}

function Set-PasswordMessage([string]$Text, [switch]$Ok) {
    $m = $script:Set.PwMsg
    $m.Text = $Text
    Set-Res $m ([Windows.Controls.TextBlock]::ForegroundProperty) $(if ($Ok) { 'St_ok' } else { 'St_bad' })
}

function Update-PasswordButtons {
    $has = [bool][string]$script:Settings.PrivatePasswordHash
    $script:Set.PwChange.Content = if ($has) { 'Change password' } else { 'Set password' }
    $script:Set.PwRemove.IsEnabled = $has
    $script:Set.PwCurrent.IsEnabled = $has
}

function Invoke-PasswordChange {
    $has = [bool][string]$script:Settings.PrivatePasswordHash
    if ($has -and -not (Test-PrivatePassword $script:Set.PwCurrent.SecurePassword)) { Set-PasswordMessage "The current password isn't right."; return }
    $new = $script:Set.PwNew.SecurePassword
    if ($new.Length -lt 4) { Set-PasswordMessage 'Use at least 4 characters for the new password.'; return }
    if (-not (Test-SameSecure $new $script:Set.PwAgain.SecurePassword)) { Set-PasswordMessage "The two new passwords don't match."; return }
    $problem = Save-PrivatePassword $new
    if ($problem) { Set-PasswordMessage "The password couldn't be saved, so it hasn't changed: $problem"; return }
    Write-AppLog $(if ($has) { 'Private password changed' } else { 'Private password set' })
    foreach ($pb in $script:Set.PwCurrent, $script:Set.PwNew, $script:Set.PwAgain) { $pb.Clear() }
    $script:Set.Rebuild = $true
    Update-PasswordButtons
    Set-PasswordMessage $(if ($has) { 'Password changed.' } else { 'Password set.' }) -Ok
}

function Invoke-PasswordRemove {
    if (-not (Test-PrivatePassword $script:Set.PwCurrent.SecurePassword)) { Set-PasswordMessage 'Type the current password to remove it.'; return }
    $problem = Save-PrivatePassword $null
    if ($problem) { Set-PasswordMessage "The password couldn't be removed: $problem"; return }
    $script:PrivateUnlocked = $false
    Write-AppLog 'Private password removed'
    $script:Set.PwCurrent.Clear()
    $script:Set.Rebuild = $true
    Update-PasswordButtons
    Set-PasswordMessage 'Password removed. The Private tabs will ask for a new one.' -Ok
}

function Get-LoadKey {
    <# Everything that needs the compose file read again when it changes. #>
    $s = $script:Settings
    return ([ordered]@{ Machines = @($s.Machines); Machine = [string]$s.Machine; Compose = [string]$s.ComposePath; Icons = [string]$s.IconsFolder
            Homepage = [string]$s.HomepageIconFolder; UseHomepage = [bool]($s.UseHomepageIcons -ne $false)
            Private = @($s.PrivateGroups | ForEach-Object { [string]$_ }); Portainer = [string]$s.PortainerUrl } | ConvertTo-Json -Depth 6 -Compress)
}

function Set-SettingsMessage([string]$Text, [switch]$Ok) {
    <# The line by Save and Close: an error (red) or Saved (green). #>
    $m = $script:Set.Msg
    $m.Text = $Text
    Set-Res $m ([Windows.Controls.TextBlock]::ForegroundProperty) $(if ($Ok) { 'St_ok' } else { 'St_bad' })
    $script:Set.ShowsSaved = [bool]$Ok
}

function Clear-SavedMessage {
    <# Something was edited after a Save: take Saved away (errors stay until the next Save). #>
    if ($script:Set -and $script:Set.ShowsSaved -and -not $script:Set.Filling) { Set-SettingsMessage '' }
}

function Test-PortNumber([string]$Text) {
    <# A whole number from 1 to 65535 (TryParse, so "99999999999" is just wrong, not an error). #>
    $n = 0
    return ([int]::TryParse($Text.Trim(), [Globalization.NumberStyles]::None, [Globalization.CultureInfo]::InvariantCulture, [ref]$n) -and $n -ge 1 -and $n -le 65535)
}

function Save-SettingsWindow {
    Save-MachineForm
    $entries = @(foreach ($li in $script:Set.List.Items) { $li.Tag })
    $seen = @{}
    foreach ($w in $entries) {
        $d = $w.Data
        $problem = ''
        if (-not $d.Name) { $problem = 'needs a name' }
        elseif ($d.Name -eq 'This PC') { $problem = "can't be called This PC" }
        elseif ($seen.ContainsKey($d.Name.ToLowerInvariant())) { $problem = 'has the same name as another machine' }
        elseif (-not (Split-Login ([string]$d.Login))[1]) { $problem = 'needs an address' }
        elseif ($d.Port -and -not (Test-PortNumber ([string]$d.Port))) { $problem = 'needs an SSH port from 1 to 65535' }
        $webProblem = if ($problem) { '' } else { Get-WebAddressProblem ([string]$d.WebHost) ((Split-Login ([string]$d.Login))[1]) }
        if ($problem -or $webProblem) {
            $script:Set.Tabs.SelectedIndex = 0
            $script:Set.List.SelectedItem = $w.Item
            Set-SettingsMessage $(if ($problem) { "The machine $(if ($d.Name) { "'$($d.Name)'" } else { 'with no name' }) $problem." }
                else { "The machine '$($d.Name)': type a host name in Web address. $webProblem" })
            if ($webProblem) { $script:Set.F.Web.Focus() | Out-Null }
            return
        }
        $seen[$d.Name.ToLowerInvariant()] = $true
    }
    $g = $script:Set.G
    $secs = 0
    if (-not [int]::TryParse($g.Refresh.Text.Trim(), [ref]$secs) -or $secs -lt 5 -or $secs -gt 3600) {
        $script:Set.Tabs.SelectedIndex = 2
        Set-SettingsMessage 'Refresh every: type a number of seconds from 5 to 3600.'
        return
    }
    $composeText = $script:Set.P.Compose.Text.Trim()
    if (-not $composeText) {
        $script:Set.Tabs.SelectedIndex = 1
        Set-SettingsMessage 'This PC: the compose file can''t be blank. Type its path or use Browse.'
        $script:Set.P.Compose.Focus() | Out-Null
        return
    }

    $s = $script:Settings
    $before = Get-LoadKey
    $oldMachine = [string]$s.Machine
    # Copies, so edits made after this Save stay in the window until the next one (Close drops them).
    $s.Machines = @($entries | ForEach-Object { $_.Data | ConvertTo-Json -Depth 6 | ConvertFrom-Json })
    # Follow a rename of the chosen machine; fall back to This PC if it was removed.
    if ($oldMachine) {
        $hit = @($entries | Where-Object { $_.Original -eq $oldMachine } | Select-Object -First 1)
        $s.Machine = if ($hit.Count) { [string]$hit[0].Data.Name } else { '' }
    }
    $s.ComposePath = $composeText
    Set-Prop $s 'IconsFolder' $g.Icons.Text.Trim()
    Set-Prop $s 'HomepageIconFolder' $g.Homepage.Text.Trim()
    Set-Prop $s 'UseHomepageIcons' ([bool]$g.UseHomepage.IsChecked)
    Set-Prop $s 'NotifyProblems' ([bool]$g.Notify.IsChecked)
    Set-Prop $s 'CheckUpdates' ([bool]$g.Updates.IsChecked)
    $s.RefreshSeconds = $secs
    Set-Prop $s 'PortainerUrl' $g.Portainer.Text.Trim()
    $s.PrivateGroups = @($g.Private.Text -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    try { Save-AppSetting $s } catch { Set-SettingsMessage "Couldn't save settings.json: $($_.Exception.Message)"; return }
    $script:SkipSaveOnClose = $false
    Clear-Banner 'settings'
    Write-AppLog 'Settings saved'
    # The saved names are now the originals, so a later rename in this window is followed too.
    foreach ($w in $entries) { $w.Original = [string]$w.Data.Name }

    Update-MachineButton
    if ($script:NextPoll -ne [DateTime]::MaxValue -and -not $script:Polling) { $script:NextPoll = [DateTime]::Now.AddSeconds($secs) }
    Update-UpdatedText
    if ($before -ne (Get-LoadKey)) {
        # Another machine now: start from an empty window, as the machine button does.
        $switched = ([string]$s.Machine -ne $oldMachine)
        if ($switched) { Write-AppLog "Switched to $(Get-MachineName)" }
        $script:MyIconsCache = $null
        $script:MyIconsLogged = -1
        Reset-ForNewSource -ClearTiles:$switched
    } elseif ($script:Set.Rebuild -and $script:Items.Count) {
        Update-Tabs
        Update-Counts
    }
    $script:Set.Rebuild = $false
    Set-SettingsMessage 'Saved.' -Ok
}

function Show-Settings {
    $w = New-XamlWindow $script:SettingsXaml
    $w.Owner = $script:Window
    $w.Icon = $script:Window.Icon
    # The main window's colours and styles (buttons, tabs, scroll bars, menus), so the theme matches.
    $w.Resources.MergedDictionaries.Add($script:Window.Resources)
    $script:Set = @{ Window = $w; Msg = $w.FindName('SetMsg'); Tabs = $w.FindName('SetTabs'); List = $w.FindName('MList')
        Current = $null; Rebuild = $false; Loading = $false; Filling = $false; ShowsSaved = $false }

    # Machines
    $f = [ordered]@{ Name = (New-Field); Host = (New-Field); User = (New-Field 220); Port = (New-Field 90); Folder = (New-Field)
        Compose = (New-Field); Project = (New-Field 220); Web = (New-Field) }
    $script:Set.F = $f
    $form = New-Object Windows.Controls.StackPanel
    $script:Set.Form = $form
    $grid = New-FormGrid
    Add-FormRow $grid 'Name' $f.Name 'Shown on the machine button.'
    Add-FormRow $grid 'Address' $f.Host 'IP address or host name, e.g. 192.168.1.10.'
    Add-FormRow $grid 'SSH user' $f.User 'Uses your SSH key (no password prompts).'
    Add-FormRow $grid 'SSH port' $f.Port 'Blank for 22.'
    Add-FormRow $grid 'Folder' $f.Folder 'The compose project folder there, e.g. /volume1/homes/you.'
    Add-FormRow $grid 'Compose file' $f.Compose 'In that folder, or a full /path.'
    Add-FormRow $grid 'Project' $f.Project 'The compose project name the stack runs under (blank: the folder name).'
    Add-FormRow $grid 'Web address' $f.Web 'For the tiles'' web pages: the machine''s host name (e.g. nas), not an IP address. Blank: same as Address, which must then be a name.'
    # Live warning under Web address when it (or a blank one falling back to Address) is an IP address.
    $script:Set.WebWarn = New-Object Windows.Controls.TextBlock
    $script:Set.WebWarn.FontSize = 11.5; $script:Set.WebWarn.TextWrapping = 'Wrap'; $script:Set.WebWarn.Margin = '2,3,0,0'; $script:Set.WebWarn.Visibility = 'Collapsed'
    Set-Res $script:Set.WebWarn ([Windows.Controls.TextBlock]::ForegroundProperty) 'St_bad'
    [void]$f.Web.Parent.Children.Add($script:Set.WebWarn)
    $f.Web.Add_TextChanged({ Update-WebAddressHint })
    $f.Host.Add_TextChanged({ Update-WebAddressHint })
    $iconBrowse = { $p = Select-Folder $this.Tag.Text; if ($p) { $this.Tag.Text = $p } }
    [void]$form.Children.Add($grid)

    $pathHead = New-Object Windows.Controls.TextBlock
    $pathHead.Text = 'Path map: its folders as Windows shares (for Config folder)'; $pathHead.Margin = '0,12,0,6'
    Set-Res $pathHead ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    [void]$form.Children.Add($pathHead)
    $script:Set.PathRows = New-Object Windows.Controls.StackPanel
    [void]$form.Children.Add($script:Set.PathRows)
    $addPath = New-Object Windows.Controls.Button
    $addPath.Content = 'Add folder'; $addPath.Padding = '12,4'; $addPath.HorizontalAlignment = 'Left'
    $addPath.Add_Click({ Add-PathRow '' ''; Clear-SavedMessage })
    [void]$form.Children.Add($addPath)

    $testBar = New-Object Windows.Controls.DockPanel
    $testBar.Margin = '0,18,0,0'
    $test = New-Object Windows.Controls.Button
    $test.Content = 'Test connection'; $test.Padding = '14,5'
    $test.ToolTip = 'Runs docker version on the machine over ssh'
    $test.Add_Click({ Test-MachineConnection })
    [Windows.Controls.DockPanel]::SetDock($test, 'Left')
    $script:Set.TestText = New-Object Windows.Controls.TextBlock
    $script:Set.TestText.TextWrapping = 'Wrap'; $script:Set.TestText.VerticalAlignment = 'Center'; $script:Set.TestText.Margin = '12,0,0,0'
    [void]$testBar.Children.Add($test); [void]$testBar.Children.Add($script:Set.TestText)
    [void]$form.Children.Add($testBar)
    [void]$w.FindName('MHost').Children.Add($form)

    foreach ($m in @($script:Settings.Machines)) {
        if (-not $m) { continue }
        $copy = $m | ConvertTo-Json -Depth 6 | ConvertFrom-Json
        [void](Add-MachineEntry $copy ([string]$m.Name))
    }
    $script:Set.List.Add_SelectionChanged({
            if ($script:Set.Loading) { return }
            Save-MachineForm
            $sel = $script:Set.List.SelectedItem
            $script:Set.Current = if ($sel) { $sel.Tag } else { $null }
            Show-MachineForm
        })
    $w.FindName('MAdd').Add_Click({
            $n = 1; $names = @(foreach ($li in $script:Set.List.Items) { [string]$li.Tag.Data.Name })
            while ($names -contains "Machine $n") { $n++ }
            $d = [pscustomobject]@{ Name = "Machine $n"; Login = ''; Port = '22'; Folder = ''; ComposeFile = 'docker-compose.yml'
                Project = ''; WebHost = ''; PathMap = [pscustomobject]@{} }
            $script:Set.List.SelectedItem = Add-MachineEntry $d ''
            Clear-SavedMessage
            $script:Set.F.Name.Focus() | Out-Null; $script:Set.F.Name.SelectAll()
        })
    $w.FindName('MRemove').Add_Click({
            $sel = $script:Set.List.SelectedItem
            if (-not $sel) { return }
            $script:Set.Loading = $true
            $script:Set.List.Items.Remove($sel)
            $script:Set.Current = $null
            $script:Set.Loading = $false
            if ($script:Set.List.Items.Count) { $script:Set.List.SelectedIndex = 0 } else { Show-MachineForm }
            Clear-SavedMessage
        })
    if ($script:Set.List.Items.Count) {
        # The machine in use, else the first.
        $pick = @($script:Set.List.Items | Where-Object { $_.Tag.Original -eq [string]$script:Settings.Machine } | Select-Object -First 1)
        $script:Set.List.SelectedItem = if ($pick.Count) { $pick[0] } else { $script:Set.List.Items[0] }
    } else { Show-MachineForm }

    # This PC
    $p = @{ Compose = (New-Field) }
    $p.Compose.Text = [string]$script:Settings.ComposePath
    $script:Set.P = $p
    $pc = $w.FindName('PcHost')
    [void]$pc.Children.Add((New-SectionTitle 'This PC'))
    $pg = New-FormGrid
    $composeBrowse = {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Pick your compose file'
        $dlg.Filter = 'Compose files (*.yml;*.yaml)|*.yml;*.yaml|All files (*.*)|*.*'
        $curDir = Get-ParentFolder ([string]$this.Tag.Text)
        if (Test-FilePath $curDir -Folder) { $dlg.InitialDirectory = $curDir }
        if ($dlg.ShowDialog($script:Set.Window)) { $this.Tag.Text = $dlg.FileName }
    }
    Add-FormRow $pg 'Compose file' (New-BrowseField $p.Compose $composeBrowse) 'Docker Desktop runs this one when This PC is chosen.'
    [void]$pc.Children.Add($pg)

    # General
    $g = @{ Refresh = (New-Field 90); Portainer = (New-Field); Private = (New-Field); Icons = (New-Field); Homepage = (New-Field)
        UseHomepage = (New-CheckBox 'Fall back to Homepage icons'); Notify = (New-CheckBox 'Tell me when a container becomes unhealthy or stops with an error')
        Updates = (New-CheckBox 'Check for image updates every 6 hours (never pulls anything)') }
    $g.Refresh.Text = [string](Get-RefreshSeconds)
    $g.Portainer.Text = [string]$script:Settings.PortainerUrl
    $g.Private.Text = (@($script:Settings.PrivateGroups) -join ', ')
    $g.Icons.Text = [string]$script:Settings.IconsFolder
    $g.Homepage.Text = [string]$script:Settings.HomepageIconFolder
    $g.UseHomepage.IsChecked = ($script:Settings.UseHomepageIcons -ne $false)
    $g.Notify.IsChecked = ($script:Settings.NotifyProblems -ne $false)
    $g.Updates.IsChecked = ($script:Settings.CheckUpdates -ne $false)
    $g.Homepage.IsEnabled = [bool]$g.UseHomepage.IsChecked
    $g.UseHomepage.Add_Click({ $script:Set.G.Homepage.IsEnabled = [bool]$this.IsChecked; Clear-SavedMessage })
    $g.Notify.Add_Click({ Clear-SavedMessage })
    $g.Updates.Add_Click({ Clear-SavedMessage })
    $script:Set.G = $g
    $gen = $w.FindName('GenHost')
    [void]$gen.Children.Add((New-SectionTitle 'General'))
    $gg = New-FormGrid
    Add-FormRow $gg 'Refresh every' $g.Refresh 'Seconds between status checks (5 to 3600).'
    Add-FormRow $gg 'Portainer address' $g.Portainer 'Blank: find a running Portainer on the chosen machine.'
    Add-FormRow $gg 'Private groups' $g.Private 'Group names, separated by commas. Hidden until unlocked.'
    Add-FormRow $gg 'Notifications' $g.Notify 'Not on the first read, and not for containers you stopped yourself.'
    Add-FormRow $gg 'Updates' $g.Updates 'Compares each image with its registry. Actions > Check for image updates now checks straight away.'
    [void]$gen.Children.Add($gg)

    [void]$gen.Children.Add((New-SectionTitle 'Icons'))
    $ig = New-FormGrid
    Add-FormRow $ig 'Icons folder' (New-BrowseField $g.Icons $iconBrowse) "Your icons, named after the service or container (jellyfin.png). Used for every machine. Blank: $(Get-DefaultIconsFolder)."
    Add-FormRow $ig 'Homepage' $g.UseHomepage 'Icons missing from the Icons folder are looked for in Homepage''s icon folder.'
    Add-FormRow $ig 'Homepage icons' (New-BrowseField $g.Homepage $iconBrowse) 'Blank: homepage\icons next to This PC''s compose file.'
    [void]$gen.Children.Add($ig)

    [void]$gen.Children.Add((New-SectionTitle 'Private password'))
    $note = New-Object Windows.Controls.TextBlock
    $note.Text = 'Changes here are saved straight away. The lock hides the Private tabs in Homelab; it isn''t encryption.'
    $note.TextWrapping = 'Wrap'; $note.Margin = '0,0,0,6'
    Set-Res $note ([Windows.Controls.TextBlock]::ForegroundProperty) 'Muted'
    [void]$gen.Children.Add($note)
    $script:Set.PwCurrent = New-Object Windows.Controls.PasswordBox; $script:Set.PwCurrent.Width = 260; $script:Set.PwCurrent.HorizontalAlignment = 'Left'
    $script:Set.PwNew = New-Object Windows.Controls.PasswordBox; $script:Set.PwNew.Width = 260; $script:Set.PwNew.HorizontalAlignment = 'Left'
    $script:Set.PwAgain = New-Object Windows.Controls.PasswordBox; $script:Set.PwAgain.Width = 260; $script:Set.PwAgain.HorizontalAlignment = 'Left'
    $pw = New-FormGrid
    Add-FormRow $pw 'Current password' $script:Set.PwCurrent ''
    Add-FormRow $pw 'New password' $script:Set.PwNew 'At least 4 characters.'
    Add-FormRow $pw 'New again' $script:Set.PwAgain ''
    [void]$gen.Children.Add($pw)
    $pwBar = New-Object Windows.Controls.StackPanel
    $pwBar.Orientation = 'Horizontal'; $pwBar.Margin = '140,6,0,0'
    $script:Set.PwChange = New-Object Windows.Controls.Button; $script:Set.PwChange.Padding = '14,4'
    $script:Set.PwChange.Add_Click({ Invoke-PasswordChange })
    $script:Set.PwRemove = New-Object Windows.Controls.Button; $script:Set.PwRemove.Padding = '14,4'; $script:Set.PwRemove.Margin = '8,0,0,0'
    $script:Set.PwRemove.Content = 'Remove password'
    $script:Set.PwRemove.Add_Click({ Invoke-PasswordRemove })
    [void]$pwBar.Children.Add($script:Set.PwChange); [void]$pwBar.Children.Add($script:Set.PwRemove)
    [void]$gen.Children.Add($pwBar)
    $script:Set.PwMsg = New-Object Windows.Controls.TextBlock
    $script:Set.PwMsg.Margin = '140,8,0,0'; $script:Set.PwMsg.TextWrapping = 'Wrap'
    [void]$gen.Children.Add($script:Set.PwMsg)
    Update-PasswordButtons

    $w.FindName('SetSave').Add_Click({ Save-SettingsWindow })
    $w.FindName('SetClose').Add_Click({ $script:Set.Window.Close() })
    # Typing in any field (or Browse filling one) takes Saved away.
    $w.AddHandler([Windows.Controls.Primitives.TextBoxBase]::TextChangedEvent, [Windows.Controls.TextChangedEventHandler] { Clear-SavedMessage })
    $w.Add_SourceInitialized({ Set-DarkTitleBar $script:IsDark $script:Set.Window })
    Write-AppLog 'Settings opened'
    [void]$w.ShowDialog()
    # A password set or removed since the last Save: show the tabs to match.
    if ($script:Set.Rebuild -and $script:Items.Count) { Update-Tabs; Update-Counts }
    $script:Set = $null
}

# ---------------------------------------------------------------------------
#  Notifications: a container that becomes unhealthy or stops with an error
# ---------------------------------------------------------------------------
$script:UserActions = @{}      # service -> when you last started, stopped or restarted it
$script:StatusSeeded = $false  # false until the first status check after a start or switch
$script:Tray = $null

function Show-MainWindow {
    $w = $script:Window
    if ($w.WindowState -eq 'Minimized') { $w.WindowState = 'Normal' }
    [void]$w.Activate()
}

function Show-Notice([string]$Title, [string]$Text) {
    <# A Windows notification, from a Homelab icon in the notification area (made the first time). #>
    try {
        if (-not $script:Tray) {
            Add-Type -AssemblyName System.Windows.Forms, System.Drawing
            $ni = New-Object Windows.Forms.NotifyIcon
            $bytes = Get-AssetBytes 'Homelab.ico'
            $ni.Icon = if ($bytes) { New-Object Drawing.Icon((New-Object IO.MemoryStream(, $bytes))) } else { [Drawing.SystemIcons]::Information }
            $ni.Text = $script:AppName
            $ni.Add_BalloonTipClicked({ Show-MainWindow })
            $ni.Add_MouseClick({ Show-MainWindow })
            $script:Tray = $ni
        }
        $script:Tray.Visible = $true
        $script:Tray.ShowBalloonTip(10000, $Title, $Text, [Windows.Forms.ToolTipIcon]::Warning)
    } catch { Write-AppLog "Notification not shown: $($_.Exception.Message)" }
}

function Send-ProblemNotice($Problems) {
    <# Containers that just went wrong by themselves: not hidden Private ones, and not ones you
       started, stopped or restarted in the last 3 minutes. #>
    $list = @($Problems | Where-Object {
            -not (Test-Hidden $_) -and -not ($script:UserActions.ContainsKey($_.Service) -and ([DateTime]::Now - $script:UserActions[$_.Service]).TotalMinutes -lt 3)
        })
    if (-not $list.Count) { return }
    foreach ($i in $list) { Write-AppLog "Problem: $($i.Service) on $(Get-MachineName) is now $($i.StateText)" }
    if ($script:Settings.NotifyProblems -eq $false) { return }
    $title = if ($list.Count -eq 1) { "$($list[0].Title): $($list[0].StateText)" } else { "$($list.Count) containers have a problem" }
    $text = (@($list | Select-Object -First 5 | ForEach-Object { "$($_.Title) - $($_.StateText)" }) -join "`n")
    if ($list.Count -gt 5) { $text += "`n...and $($list.Count - 5) more" }
    Show-Notice $title "$text`n(on $(Get-MachineName))"
}

# ---------------------------------------------------------------------------
#  Group actions: Start all / Stop all on a tab, Restart unhealthy (one at a time)
# ---------------------------------------------------------------------------
$script:ActionQueue = New-Object System.Collections.Generic.Queue[object]
$script:ActionTotal = 0

function Get-TabTargets([string]$Verb) {
    <# The containers on the open tab (as shown, so the search counts) that this verb would change.
       A locked Private tab shows none, so it's never touched. #>
    $tab = $script:Ui.Tabs.SelectedItem
    if (-not $tab) { return @() }
    $shown = @(Get-ShownItems $tab.Content)
    switch ($Verb) {
        'Start' { return @($shown | Where-Object { Test-CanStart $_ }) }
        'Stop'  { return @($shown | Where-Object { Test-CanStop $_ }) }
    }
    return @()
}

function Get-UnhealthyItems { return @(Get-VisibleItems | Where-Object { $_.State -eq 'running' -and $_.StateText -like 'Unhealthy*' -and (Test-CanStop $_) }) }

$script:MessageXaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Width="480" SizeToContent="Height" ResizeMode="NoResize" ShowInTaskbar="False"
        WindowStartupLocation="CenterOwner" Background="{DynamicResource WinBg}" Foreground="{DynamicResource Text}"
        FontFamily="Segoe UI" FontSize="13">
    <StackPanel Margin="0" Background="{DynamicResource WinBg}">
        <Border Margin="14,14,14,0" Background="{DynamicResource Panel}" BorderBrush="{DynamicResource Line}" BorderThickness="1" CornerRadius="8" Padding="20,18">
            <StackPanel>
                <StackPanel Orientation="Horizontal">
                    <Border x:Name="MsgBadge" Width="28" Height="28" CornerRadius="14" VerticalAlignment="Center">
                        <TextBlock x:Name="MsgGlyph" FontSize="15" FontWeight="Bold" Foreground="#FFFFFF" HorizontalAlignment="Center" VerticalAlignment="Center"/>
                    </Border>
                    <TextBlock x:Name="MsgHeading" FontSize="18" FontWeight="SemiBold" Margin="12,0,0,0" VerticalAlignment="Center"/>
                </StackPanel>
                <ScrollViewer MaxHeight="420" Margin="0,14,0,0" VerticalScrollBarVisibility="Auto" HorizontalScrollBarVisibility="Disabled" Focusable="False">
                    <TextBox x:Name="MsgText" IsReadOnly="True" IsTabStop="False" TextWrapping="Wrap" BorderThickness="0" Padding="0"
                             Background="Transparent" Foreground="{DynamicResource Text}">
                        <TextBox.Template><ControlTemplate TargetType="TextBox"><ScrollViewer x:Name="PART_ContentHost" Focusable="False"/></ControlTemplate></TextBox.Template>
                    </TextBox>
                </ScrollViewer>
            </StackPanel>
        </Border>
        <StackPanel x:Name="MsgButtons" Orientation="Horizontal" HorizontalAlignment="Right" Margin="14,12,14,14"/>
    </StackPanel>
</Window>
'@

function Show-HomelabMessage {
    <# A message or question in Homelab's own look (light or dark, like About, Help and Settings)
       instead of Windows' plain grey MessageBox: a coloured badge and heading on a panel, the
       message (selectable, scrolls when long) and Homelab's buttons. $Kind is Information,
       Warning, Error or Question. The first of $Buttons is the main (accent) button and Enter
       presses it; the last is pressed by Esc or the X and has the focus, so a stray Space
       doesn't confirm. Returns the text of the button pressed. #>
    param([string]$Text, [string]$Kind = 'Information', [string[]]$Buttons = @('OK'), [string]$Heading = '', [Windows.Window]$Owner = $script:Window)
    $kinds = @{
        Information = @{ Glyph = 'i';               Brush = 'Accent';  Heading = 'Good to know' }
        Warning     = @{ Glyph = '!';               Brush = 'St_warn'; Heading = 'Heads up' }
        Error       = @{ Glyph = [string][char]0xD7; Brush = 'St_bad';  Heading = 'Something went wrong' }
        Question    = @{ Glyph = '?';               Brush = 'Accent';  Heading = 'Just checking' }
    }
    $k = $kinds[$Kind]; if (-not $k) { $k = $kinds['Information'] }
    if (-not $Heading) { $Heading = $k.Heading }
    if (-not $Buttons -or $Buttons.Count -eq 0) { $Buttons = @('OK') }
    $w = New-XamlWindow $script:MessageXaml
    if ($Text.Length -gt 380) { $w.Width = 580 }
    # The main window's colours and styles, so the box follows the light or dark theme.
    if ($script:Window) { $w.Resources.MergedDictionaries.Add($script:Window.Resources) }
    if ($Owner -and $Owner.IsVisible) { $w.Owner = $Owner; $w.Icon = $Owner.Icon }
    else { $w.WindowStartupLocation = 'CenterScreen'; $w.Topmost = $true; $w.ShowInTaskbar = $true }
    $w.Add_SourceInitialized({ Set-DarkTitleBar $script:IsDark $this })
    $w.Title = $script:AppName
    $w.FindName('MsgBadge').SetResourceReference([Windows.Controls.Border]::BackgroundProperty, $k.Brush)
    $w.FindName('MsgGlyph').Text = $k.Glyph
    $w.FindName('MsgHeading').Text = $Heading
    $w.FindName('MsgText').Text = $Text
    $row = $w.FindName('MsgButtons')
    for ($i = 0; $i -lt $Buttons.Count; $i++) {
        $b = New-Object Windows.Controls.Button
        $b.Content = $Buttons[$i]; $b.Tag = $Buttons[$i]
        $b.MinWidth = 84; $b.Padding = New-Object Windows.Thickness 16, 5, 16, 5
        if ($i -eq 0) { $b.SetResourceReference([Windows.FrameworkElement]::StyleProperty, 'AccentButton'); $b.IsDefault = $true }
        if ($i -lt $Buttons.Count - 1) { $b.Margin = New-Object Windows.Thickness 0, 0, 8, 0 }
        if ($i -eq $Buttons.Count - 1) { $b.IsCancel = $true }
        $b.Add_Click({ $win = [Windows.Window]::GetWindow($this); $win.Tag = [string]$this.Tag; $win.Close() })
        [void]$row.Children.Add($b)
    }
    $w.Add_ContentRendered({ [void]$this.Activate(); $r = $this.FindName('MsgButtons'); [void]$r.Children[$r.Children.Count - 1].Focus() })
    [void]$w.ShowDialog()
    if ($w.Tag) { return [string]$w.Tag }
    return $Buttons[-1]
}

function Confirm-GroupAction([string]$Question, $Items, [string]$YesText = 'Yes') {
    $names = @($Items | Sort-Object Title | Select-Object -First 20 | ForEach-Object { "  $([char]0x2022) $($_.Title)" })
    if ($Items.Count -gt 20) { $names += "  ...and $($Items.Count - 20) more" }
    $text = "$Question`n`n$($names -join "`n")`n`nThey run one at a time on $(Get-MachineName)."
    return ((Show-HomelabMessage $text 'Question' @($YesText, 'Cancel')) -eq $YesText)
}

function Invoke-GroupAction([string]$Verb) {
    $tabName = [string]$script:Ui.Tabs.SelectedItem.Tag
    $items = switch ($Verb) { 'Restart' { @(Get-UnhealthyItems) } default { @(Get-TabTargets $Verb) } }
    if (-not $items.Count) { Set-Status 'Nothing to do.'; return }
    $n = $items.Count; $s = if ($n -eq 1) { '' } else { 's' }
    $onTab = "on $tabName" + $(if ($script:UpdatesOnly) { ' with an update' } else { '' }) + $(if ($script:Ui.TxtSearch.Text.Trim()) { ' matching the search' } else { '' })
    $q = if ($Verb -eq 'Restart') { "Restart $n unhealthy container$($s)?" } else { "$Verb $n container$s $($onTab)?" }
    $yes = switch ($Verb) { 'Restart' { 'Restart them' } 'Stop' { 'Stop them' } default { 'Start them' } }
    if ($n -eq 1) { $yes = $yes -replace 'them$', 'it' }
    if (-not (Confirm-GroupAction $q $items $yes)) { return }
    Write-AppLog "$Verb all: $n on $(Get-MachineName) ($tabName)"
    foreach ($i in ($items | Sort-Object Title)) { $script:ActionQueue.Enqueue(@{ Item = $i; Verb = $Verb; Gen = $script:Generation }) }
    $script:ActionTotal = $script:ActionQueue.Count
    Update-ActionQueue
}

function Update-ActionQueue {
    <# Heartbeat: when nothing is starting or stopping, run the next queued action. #>
    if (-not $script:ActionTotal) { return }
    if (@($script:Items | Where-Object { $_.Busy }).Count) { return }
    if (-not $script:ActionQueue.Count) {
        Set-Status "Done: $($script:ActionTotal) container$(if ($script:ActionTotal -ne 1) { 's' }). Any that failed are in the banner."
        $script:ActionTotal = 0
        return
    }
    while ($script:ActionQueue.Count) {
        $a = $script:ActionQueue.Dequeue()
        if ($a.Gen -ne $script:Generation) { continue }
        $ok = if ($a.Verb -eq 'Start') { Test-CanStart $a.Item } else { Test-CanStop $a.Item }
        if (-not $ok) { continue }   # already in that state (or changed meanwhile)
        $done = $script:ActionTotal - $script:ActionQueue.Count
        Set-Status "$($a.Verb) all: $done of $($script:ActionTotal)" -Sticky
        Invoke-ContainerAction $a.Item $a.Verb
        return
    }
}

function Show-ActionsMenu {
    $menu = New-Object Windows.Controls.ContextMenu
    $tabName = [string]$script:Ui.Tabs.SelectedItem.Tag
    $add = {
        param([string]$Header, [scriptblock]$Do, [bool]$Enabled = $true)
        $mi = New-Object Windows.Controls.MenuItem
        $mi.Header = $Header; $mi.IsEnabled = $Enabled
        $mi.Add_Click($Do)
        [void]$menu.Items.Add($mi)
    }
    $busy = $script:ActionQueue.Count -gt 0
    $nStart = @(Get-TabTargets 'Start').Count; $nStop = @(Get-TabTargets 'Stop').Count; $nBad = @(Get-UnhealthyItems).Count
    & $add "Start all on $tabName ($nStart)" { Invoke-GroupAction 'Start' } ($nStart -gt 0 -and -not $busy)
    & $add "Stop all on $tabName ($nStop)" { Invoke-GroupAction 'Stop' } ($nStop -gt 0 -and -not $busy)
    & $add "Restart unhealthy ($nBad)" { Invoke-GroupAction 'Restart' } ($nBad -gt 0 -and -not $busy)
    if ($busy) { & $add "Cancel the remaining $($script:ActionQueue.Count)" { $script:ActionQueue.Clear(); $script:ActionTotal = 0; Set-Status 'Cancelled the rest.'; Write-AppLog 'Group action cancelled' } }
    [void]$menu.Items.Add((New-Object Windows.Controls.Separator))
    & $add $(if ($script:UpdateChecking) { 'Checking for image updates...' } else { 'Check for image updates now' }) { Start-UpdateCheck -Manual } (-not $script:UpdateChecking -and $script:Items.Count -gt 0)
    $b = $script:Ui.BtnActions
    $menu.PlacementTarget = $b; $menu.Placement = 'Bottom'
    $b.ContextMenu = $menu
    $menu.IsOpen = $true
}

# ---------------------------------------------------------------------------
#  Image updates: the registry's digest for each image's tag against the one pulled.
#  Only reads (HEAD requests and docker image ls); never pulls.
# ---------------------------------------------------------------------------
$script:UpdateChecking = $false
$script:NextUpdateCheck = [DateTime]::MaxValue
$script:UpdateRemote = @{}     # image key -> registry digest
$script:UpdateLocal = @{}      # image key -> digests pulled on the chosen machine
$script:UpdateCount = 0

# Asks each registry for a tag's digest (HEAD, with an anonymous token when it asks for one).
# Each job: Key, Api (registry host), Repo, Tag. Returns Key, Digest, Error.
$script:UpdateWork = {
    param($Jobs)
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $accept = 'application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.oci.image.manifest.v1+json'
    foreach ($j in $Jobs) {
        $res = [pscustomobject]@{ Key = $j.Key; Digest = ''; Error = '' }
        $token = ''
        try {
            for ($try = 0; $try -lt 2; $try++) {
                $req = [Net.HttpWebRequest][Net.WebRequest]::Create("https://$($j.Api)/v2/$($j.Repo)/manifests/$($j.Tag)")
                $req.Method = 'HEAD'; $req.Accept = $accept; $req.UserAgent = 'Homelab'
                $req.Timeout = 10000; $req.ReadWriteTimeout = 10000
                if ($token) { $req.Headers['Authorization'] = "Bearer $token" }
                $resp = $null
                try {
                    $resp = $req.GetResponse()
                    $res.Digest = [string]$resp.Headers['Docker-Content-Digest']
                    if (-not $res.Digest) { $res.Error = 'The registry gave no digest.' }
                    break
                } catch {
                    $ex = $_.Exception
                    while ($ex -and -not ($ex -is [Net.WebException])) { $ex = $ex.InnerException }
                    $er = if ($ex) { $ex.Response } else { $null }
                    if (-not $er -or [int]$er.StatusCode -ne 401 -or $try -gt 0) { throw }
                    # 401: get an anonymous pull token from the realm it names, then ask again.
                    $h = [string]$er.Headers['WWW-Authenticate']; $er.Close()
                    if ($h -notmatch '^Bearer\s') { throw 'The registry needs a login.' }
                    $p = @{}
                    foreach ($m in [regex]::Matches($h, '(\w+)="([^"]*)"')) { $p[$m.Groups[1].Value] = $m.Groups[2].Value }
                    if (-not $p.realm) { throw 'The registry gave no token address.' }
                    $scope = if ($p.scope) { $p.scope } else { "repository:$($j.Repo):pull" }
                    $q = @()
                    if ($p.service) { $q += 'service=' + [Uri]::EscapeDataString($p.service) }
                    $q += 'scope=' + [Uri]::EscapeDataString($scope)
                    $treq = [Net.HttpWebRequest][Net.WebRequest]::Create($p.realm + '?' + ($q -join '&'))
                    $treq.UserAgent = 'Homelab'; $treq.Timeout = 10000; $treq.ReadWriteTimeout = 10000
                    $tresp = $treq.GetResponse()
                    try {
                        $sr = New-Object IO.StreamReader($tresp.GetResponseStream())
                        $json = $sr.ReadToEnd() | ConvertFrom-Json
                    } finally { $tresp.Close() }
                    $token = if ($json.token) { [string]$json.token } else { [string]$json.access_token }
                    if (-not $token) { throw 'No token from the registry.' }
                } finally { if ($resp) { $resp.Close() } }
            }
        } catch { $res.Error = $_.Exception.Message }
        $res
    }
}

function ConvertTo-ImageRef([string]$Image) {
    <# "lscr.io/linuxserver/sonarr", "jellyfin/jellyfin:10.9", "nginx" ... as Key (registry/repo:tag)
       plus where to ask: Api host, Repo, Tag. $null for images pinned by digest or with ${...} left in. #>
    if (-not $Image -or $Image -match '@|\$') { return $null }
    $name = $Image.Trim(); $tag = 'latest'
    $slash = $name.LastIndexOf('/'); $colon = $name.LastIndexOf(':')
    if ($colon -gt $slash) { $tag = $name.Substring($colon + 1); $name = $name.Substring(0, $colon) }
    $parts = @($name.Split('/'))
    if ($parts.Count -gt 1 -and ($parts[0] -match '[.:]' -or $parts[0] -eq 'localhost')) { $reg = $parts[0].ToLowerInvariant(); $repo = ($parts[1..($parts.Count - 1)] -join '/') }
    else { $reg = 'docker.io'; $repo = $name }
    if ($reg -in 'docker.io', 'index.docker.io', 'registry-1.docker.io') { $reg = 'docker.io'; if ($repo -notmatch '/') { $repo = "library/$repo" } }
    $repo = $repo.ToLowerInvariant()
    # lscr.io is LinuxServer's front for ghcr.io; Docker Hub's API lives at registry-1.
    $api = switch ($reg) { 'docker.io' { 'registry-1.docker.io' } 'lscr.io' { 'ghcr.io' } default { $reg } }
    return @{ Key = "$reg/$($repo):$tag"; Api = $api; Repo = $repo; Tag = $tag }
}

function Start-UpdateCheck([switch]$Manual) {
    <# Reads the pulled images' digests on the chosen machine (docker image ls, over ssh for a NAS),
       then asks the registries, a few images at a time on their own thread. #>
    if ($script:UpdateChecking -or -not $script:Items.Count) { return }
    $script:UpdateChecking = $true
    $script:NextUpdateCheck = [DateTime]::Now.AddHours(6)
    if ($Manual) { Set-Status 'Checking for image updates...' -Sticky }
    Write-AppLog "Update check on $(Get-MachineName)$(if ($Manual) { ' (asked for)' })"
    Start-Docker @('image', 'ls', '--digests', '--no-trunc', '--format', "{{.Repository}}`t{{.Tag}}`t{{.Digest}}") {
        param($res, $ctx)
        if ($ctx.Gen -ne $script:Generation) { $script:UpdateChecking = $false; return }
        if ($res.ExitCode -ne 0) {
            $script:UpdateChecking = $false
            $msg = Get-ErrorSummary $res.Error 2
            Write-AppLog "Update check: image list failed: $msg"
            if ($ctx.Manual) { Set-Status "Couldn't list the images: $msg" }
            return
        }
        $local = @{}
        foreach ($line in ([string]$res.Output -split "`r?`n")) {
            $f = $line.Split("`t")
            if ($f.Count -lt 3 -or $f[2] -notlike 'sha256:*' -or $f[1] -eq '<none>') { continue }
            $r = ConvertTo-ImageRef "$($f[0]):$($f[1])"
            if (-not $r) { continue }
            if (-not $local[$r.Key]) { $local[$r.Key] = New-Object System.Collections.Generic.List[string] }
            $local[$r.Key].Add($f[2])
        }
        $script:UpdateLocal = $local
        # Only images of containers that exist and have a pulled digest to compare with.
        $jobs = @{}
        foreach ($i in $script:Items) {
            if ($i.StateKey -eq 'none') { continue }
            $r = ConvertTo-ImageRef $i.Image
            if ($r -and $local.ContainsKey($r.Key) -and -not $jobs.ContainsKey($r.Key)) { $jobs[$r.Key] = $r }
        }
        $list = @($jobs.Values)
        $script:UpdatePending = [Math]::Ceiling($list.Count / 10)
        $script:UpdateErrors = 0
        $script:UpdateManual = [bool]$ctx.Manual
        $script:UpdateRemote = @{}
        if (-not $list.Count) { Complete-UpdateCheck; return }
        for ($p = 0; $p -lt $list.Count; $p += 10) {
            $chunk = @($list[$p..([Math]::Min($p + 9, $list.Count - 1))])
            Start-Background -Work $script:UpdateWork -Arguments @(, $chunk) -Pool 'Updates' -TimeoutSeconds (120 + 25 * $chunk.Count * ($p / 10 + 1)) -State $ctx.Gen -OnDone {
                param($out, $err, $gen)
                if ($gen -ne $script:Generation) { return }
                foreach ($o in @($out)) {
                    if ($o.Digest) { $script:UpdateRemote[$o.Key] = $o.Digest } else { $script:UpdateErrors++; Write-AppLog "Update check: $($o.Key): $($o.Error)" }
                }
                if ($err) { Write-AppLog "Update check: $err" }
                $script:UpdatePending--
                if ($script:UpdatePending -le 0) { Complete-UpdateCheck }
            }
        }
    } @{ Gen = $script:Generation; Manual = [bool]$Manual }
}

function Complete-UpdateCheck {
    $script:UpdateChecking = $false
    Set-UpdateBadges
    Write-AppLog "Update check: $($script:UpdateCount) with an update, $($script:UpdateRemote.Count) checked, $($script:UpdateErrors) couldn't be checked"
    if ($script:UpdateManual) {
        $msg = if ($script:UpdateCount) { "$($script:UpdateCount) container$(if ($script:UpdateCount -ne 1) { 's have' } else { ' has' }) a newer image (marked on the tiles). Nothing was pulled." } else { 'Every image is up to date.' }
        if ($script:UpdateErrors) { $msg += " $($script:UpdateErrors) couldn't be checked (see the log)." }
        Set-Status $msg
    }
}

function Set-UpdateBadges {
    <# Marks each container whose image tag has a newer digest in the registry than the one pulled. #>
    foreach ($i in $script:Items) {
        $r = ConvertTo-ImageRef $i.Image
        $new = $false
        if ($r -and $i.StateKey -ne 'none' -and $script:UpdateRemote.ContainsKey($r.Key) -and $script:UpdateLocal.ContainsKey($r.Key)) {
            $new = -not ($script:UpdateLocal[$r.Key] -contains $script:UpdateRemote[$r.Key])
        }
        if ($new -ne $i.UpdateAvailable) {
            $i.UpdateAvailable = $new
            foreach ($t in $i.Tiles) { Set-TileIcon $t $i }
        }
    }
    $script:UpdateCount = @(Get-VisibleItems | Where-Object { $_.UpdateAvailable }).Count
    if ($script:UpdatesOnly) { Update-SearchFilter }   # which tiles the updates pill shows may have changed
    Update-Counts
    Update-RunningList
}

# ---------------------------------------------------------------------------
#  Window size and position, kept on screen
# ---------------------------------------------------------------------------
function Get-SavedNumber([string]$Name) {
    <# A number from settings.json, or $null when it's missing or not a number. #>
    $v = 0.0
    $raw = [string]$script:Settings.$Name
    if ($raw -and [double]::TryParse($raw, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and -not [double]::IsNaN($v) -and -not [double]::IsInfinity($v)) { return $v }
    return $null
}

function Set-WindowBounds {
    <# The saved size (and position, if there is one) before the window shows. With no saved
       position Windows centres it; the size is capped at the main screen's work area either way. #>
    $w = $script:Window
    $wa = [Windows.SystemParameters]::WorkArea
    $width = Get-SavedNumber 'Width'; $height = Get-SavedNumber 'Height'
    if ($null -eq $width) { $width = 1400 }; if ($null -eq $height) { $height = 900 }
    $w.Width = [Math]::Max($w.MinWidth, [Math]::Min($width, $wa.Width))
    $w.Height = [Math]::Max($w.MinHeight, [Math]::Min($height, $wa.Height))
    $left = Get-SavedNumber 'Left'; $top = Get-SavedNumber 'Top'
    if ($null -ne $left -and $null -ne $top) {
        $w.WindowStartupLocation = 'Manual'
        $w.Left = $left; $w.Top = $top
    }
    if ($script:Settings.Maximized -eq $true) { $w.WindowState = 'Maximized' }
}

function Limit-WindowToScreen {
    <# Once the window exists: fit it inside the work area of the screen it's on (or nearest to),
       so a screen that's gone or got smaller since last time doesn't leave it out of reach. #>
    $w = $script:Window
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $hwnd = (New-Object Windows.Interop.WindowInteropHelper($w)).Handle
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $wa = [Windows.Forms.Screen]::FromHandle($hwnd).WorkingArea
        $src = [Windows.PresentationSource]::FromVisual($w)
        if (-not $src -or -not $src.CompositionTarget) { return }
        $toDip = $src.CompositionTarget.TransformFromDevice
        $tl = $toDip.Transform((New-Object Windows.Point($wa.Left, $wa.Top)))
        $br = $toDip.Transform((New-Object Windows.Point($wa.Right, $wa.Bottom)))
        $maxW = $br.X - $tl.X; $maxH = $br.Y - $tl.Y
        if ($w.Width -gt $maxW) { $w.Width = [Math]::Max($w.MinWidth, $maxW) }
        if ($w.Height -gt $maxH) { $w.Height = [Math]::Max($w.MinHeight, $maxH) }
        if ($w.WindowStartupLocation -eq 'Manual') {
            $w.Left = [Math]::Max($tl.X, [Math]::Min($w.Left, $br.X - $w.Width))
            $w.Top = [Math]::Max($tl.Y, [Math]::Min($w.Top, $br.Y - $w.Height))
        }
    } catch { Write-AppLog "Window position not checked: $($_.Exception.Message)" }
}

function Save-WindowBounds {
    <# The normal (not maximised) size and position, so the next start comes back to the same place. #>
    $w = $script:Window
    $script:Settings.Maximized = ($w.WindowState -eq 'Maximized')
    $rb = $w.RestoreBounds
    if ($rb.IsEmpty -or $rb.Width -lt 1) { return }
    foreach ($pair in @(@('Left', $rb.Left), @('Top', $rb.Top), @('Width', $rb.Width), @('Height', $rb.Height))) {
        Set-Prop $script:Settings $pair[0] ([int][Math]::Round($pair[1]))
    }
}

# ---------------------------------------------------------------------------
#  Enter in the search box
# ---------------------------------------------------------------------------
function Get-ShownItems($Element) {
    <# The containers shown (not collapsed) on a tab, in screen order: tiles and Running rows. #>
    $found = New-Object System.Collections.Generic.List[object]
    $stack = New-Object System.Collections.Generic.Stack[object]
    $stack.Push($Element)
    while ($stack.Count) {
        $e = $stack.Pop()
        if ($null -eq $e -or ($e -is [Windows.UIElement] -and $e.Visibility -ne 'Visible')) { continue }
        if ($e -is [Windows.Controls.Border] -and $e.Tag -is [psobject] -and $e.Tag.PSObject.Properties['Service']) { $found.Add($e.Tag); continue }
        $kids = @()
        if ($e -is [Windows.Controls.Panel]) { $kids = @($e.Children) }
        elseif ($e -is [Windows.Controls.Decorator]) { $kids = @($e.Child) }
        elseif ($e -is [Windows.Controls.ContentControl]) { $kids = @($e.Content) }
        # Pushed last-first, so they come off the stack in order.
        for ($n = $kids.Count - 1; $n -ge 0; $n--) { $stack.Push($kids[$n]) }
    }
    return $found.ToArray()
}

function Invoke-SearchEnter {
    <# Opens the first container on the open tab that matches the search and is running. #>
    $tab = $script:Ui.Tabs.SelectedItem
    if (-not $tab) { return }
    $shown = @(Get-ShownItems $tab.Content)
    if (-not $shown.Count) { Set-Status "Nothing on the $($tab.Tag) tab matches the search."; return }
    $first = @($shown | Where-Object { $_.Running } | Select-Object -First 1)
    if ($first.Count) { Invoke-Open $first[0]; return }
    $n = $shown.Count
    Set-Status "$(if ($n -eq 1) { "$($shown[0].Title) matches but isn't running" } else { "None of the $n matches on this tab is running" }). Start it first."
}

# ---------------------------------------------------------------------------
#  Start
# ---------------------------------------------------------------------------
# An error in a click or timer handler is logged and shown in the banner; it never closes Homelab.
$script:Started = $false
[Windows.Threading.Dispatcher]::CurrentDispatcher.Add_UnhandledException({
        param($s, $e)
        $msg = $e.Exception.Message
        if ($e.Exception.InnerException) { $msg = $e.Exception.InnerException.Message }
        Write-AppLog "Unexpected error: $($e.Exception.ToString())"
        try { if ($script:Ui) { Show-Banner "Something went wrong: $msg Homelab carried on; details are in $script:LogPath." 'error' } } catch { Write-Verbose 'No banner yet.' }
        $e.Handled = $true
    })
try {
    $script:Window = New-XamlWindow $mainXaml
    $window = $script:Window
    $window.Title = "$script:AppName v$script:AppVersion"
    # A BitmapFrame keeps every size in the .ico, so Windows picks the right one for the taskbar.
    $icoBytes = Get-AssetBytes 'Homelab.ico'
    if ($icoBytes) {
        try { $window.Icon = [Windows.Media.Imaging.BitmapFrame]::Create((New-Object IO.MemoryStream (, $icoBytes)), 'None', 'OnLoad') }
        catch { Write-AppLog "Window icon not set: $($_.Exception.Message)" }
    }
    $script:Ui = @{}
    foreach ($n in 'Logo', 'BtnMachine', 'TxtCounts', 'BtnAbout', 'BtnHelp', 'BtnSettings','BtnTheme', 'BtnPortainer', 'BtnRefresh', 'TxtSearch', 'SearchHint', 'TxtUpdated', 'LnkCompose',
        'TxtCompose', 'TxtStatus', 'Banner', 'TxtBanner', 'BtnBannerClose', 'Tabs', 'BusyBox', 'BusyTitle', 'BusyDetail', 'BusyBar',
        'HeaderBar', 'SearchBox', 'BtnActions', 'BtnUpdates') { $script:Ui[$n] = $window.FindName($n) }
    $script:Ui.BtnUpdates.Add_Click({ Switch-UpdatesOnly })
    $script:Ui.BtnActions.Content = "Actions  " + [string][char]0x25BE
    $script:Ui.BtnActions.Add_Click({ Show-ActionsMenu })
    $window.Add_SizeChanged({ Request-HeaderFit })
    $window.Add_ContentRendered({ Request-HeaderFit })
    $script:Ui.Logo.Source = Get-AssetImage 'Homelab.png'
    Set-WindowBounds
    $script:Ui.BtnBannerClose.Add_Click({ Show-Banner '' })
    if ($script:SettingsProblem) { Show-Banner $script:SettingsProblem 'settings' }

    $script:Ui.BtnAbout.Add_Click({ Show-About -Owner $script:Window })
    $script:Ui.BtnHelp.Add_Click({ Show-Help })
    $script:Ui.BtnSettings.Add_Click({ Show-Settings })
    $script:Ui.BtnRefresh.Add_Click({ Start-Load })
    $script:Ui.BtnPortainer.Add_Click({ Open-Web $script:PortainerUrl })
    $script:Ui.BtnTheme.Add_Click({ Switch-Theme })
    $script:Ui.BtnMachine.Add_Click({ $b = $script:Ui.BtnMachine; $b.ContextMenu.PlacementTarget = $b; $b.ContextMenu.Placement = 'Bottom'; $b.ContextMenu.IsOpen = $true })
    Update-MachineButton
    Set-Theme
    $window.Add_SourceInitialized({ Set-DarkTitleBar $script:IsDark; Limit-WindowToScreen })
    $script:Ui.LnkCompose.Add_Click({ Select-ComposeFile })
    $script:Ui.TxtSearch.Add_TextChanged({ Update-SearchFilter })
    $script:Ui.Tabs.Add_SelectionChanged({
            param($s, $e)
            if ($e.OriginalSource -ne $s) { return }
            $t = $s.SelectedItem
            if ($t) { $script:Settings.LastTab = [string]$t.Tag }
            # Remember the last ordinary tab, so Cancel on a lock panel can go back to it.
            foreach ($old in @($e.RemovedItems)) {
                if ($old -is [Windows.Controls.TabItem] -and -not (Test-PrivateGroup ([string]$old.Tag))) { $script:TabBeforeLock = [string]$old.Tag }
            }
        })
    $window.Add_PreviewKeyDown({
            param($s, $e)
            if ($e.Key -eq 'F5') { Start-Load; $e.Handled = $true }
            elseif ($e.Key -eq 'F1') { Show-Help; $e.Handled = $true }
            elseif ($e.Key -eq 'F' -and [Windows.Input.Keyboard]::Modifiers -eq 'Control') { $script:Ui.TxtSearch.Focus() | Out-Null; $script:Ui.TxtSearch.SelectAll(); $e.Handled = $true }
            elseif ($e.Key -eq 'Escape' -and $script:Ui.TxtSearch.IsKeyboardFocused) { $script:Ui.TxtSearch.Text = ''; $e.Handled = $true }
            elseif ($e.Key -eq 'Escape' -and $null -ne (Get-LockContext)) { Invoke-LockCancel (Get-LockContext); $e.Handled = $true }
            elseif ($e.Key -eq 'Return' -and $script:Ui.TxtSearch.IsKeyboardFocused) { Invoke-SearchEnter; $e.Handled = $true }
        })
    $window.Add_Closing({
            try { Save-WindowBounds } catch { Write-AppLog "Window size not kept: $($_.Exception.Message)" }
            if ($script:SkipSaveOnClose) { Write-AppLog 'Settings not saved on close (settings.json couldn''t be read at start).' }
            else { try { Save-AppSetting $script:Settings } catch { Write-AppLog "Couldn't save settings: $($_.Exception.Message)" } }
            foreach ($t in @($script:BgTasks)) { try { [void]$t.PS.BeginStop($null, $null) } catch { Write-Verbose 'Already ending.' } }
            # Otherwise its icon lingers in the notification area until the mouse passes over it.
            if ($script:Tray) { try { $script:Tray.Visible = $false; $script:Tray.Dispose() } catch { Write-Verbose 'Tray icon already gone.' } }
        })

    # One heartbeat: collects background results, refreshes the status, and notices a changed compose file.
    $timer = New-Object Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:LastStampCheck = [DateTime]::Now
    $timer.Add_Tick({
            try {
                Update-Background
                if ($script:BusyHideAt -and [DateTime]::Now -ge $script:BusyHideAt) { Show-Busy '' }
                if ($script:StatusClearAt -and [DateTime]::Now -ge $script:StatusClearAt) { Set-Status '' }
                Update-ActionQueue
                if ($script:Settings.CheckUpdates -ne $false -and [DateTime]::Now -ge $script:NextUpdateCheck -and -not $script:Loading) { Start-UpdateCheck }
                if ([DateTime]::Now -ge $script:NextPoll) {
                    if ($script:Items.Count) { Start-Poll } elseif (-not $script:Loading) { Start-Load }
                }
                if (([DateTime]::Now - $script:LastStampCheck).TotalSeconds -ge 5) {
                    $script:LastStampCheck = [DateTime]::Now
                    if ([string]$script:Settings.Theme -notin 'Light', 'Dark' -and (Test-SystemDark) -ne $script:IsDark) { Set-Theme }
                    $stamp = Get-ComposeStamp
                    if ($stamp -and $script:ComposeStamp -and $stamp -ne $script:ComposeStamp) { Write-AppLog 'Compose file changed; reading it again.'; Start-Load }
                }
            } catch { Write-AppLog "Heartbeat error: $($_.Exception.Message)" }
        })
    $timer.Start()

    $window.Add_ContentRendered({ Start-Load })
    Write-AppLog "Started v$script:AppVersion from $PSCommandPath"
    $script:Started = $true
    [void]$window.ShowDialog()
    $timer.Stop()
    Write-AppLog 'Closed'
    # Background work (docker, icon downloads) runs on pool threads that would keep the process alive.
    [Environment]::Exit(0)
} catch {
    Write-AppLog "Error: $($_.Exception.ToString())"
    $what = if ($script:Started) { 'stopped because of an error' } else { "couldn't start" }
    [void][Windows.MessageBox]::Show("$script:AppName $($what):`n`n$($_.Exception.Message)`n`nDetails are in $script:LogPath", $script:AppName, 'OK', 'Error')
    exit 1
}
