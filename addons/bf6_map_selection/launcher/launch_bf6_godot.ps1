[CmdletBinding()]
param(
    [string]$SdkRoot = '',
    [switch]$CreateShortcut,
    [switch]$DesktopShortcut,
    [switch]$ShortcutOnly,
    [switch]$ShowErrors,
    [switch]$Inspect
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$launchMutex = $null
$ownsLaunchMutex = $false

function Find-BF6Sdk([string]$Requested) {
    if ($Requested) {
        $candidate = [IO.Path]::GetFullPath($Requested)
        if ($candidate.Length -gt [IO.Path]::GetPathRoot($candidate).Length) {
            $candidate = $candidate.TrimEnd([char]'\', [char]'/')
        }
        if ([IO.Path]::GetFileName($candidate) -eq 'project.godot') {
            $candidate = [IO.Path]::GetDirectoryName($candidate)
        }
        if ([IO.Path]::GetFileName($candidate) -eq 'GodotProject') {
            $candidate = [IO.Path]::GetDirectoryName($candidate)
        }
        return $candidate
    }
    $candidate = $PSScriptRoot
    for ($depth = 0; $depth -lt 7 -and $candidate; $depth++) {
        if ((Test-Path -LiteralPath (Join-Path $candidate 'GodotProject/project.godot') -PathType Leaf) -and
            (Test-Path -LiteralPath (Join-Path $candidate 'sdk.version.json') -PathType Leaf)) {
            return $candidate
        }
        $candidate = [IO.Path]::GetDirectoryName($candidate)
    }
    throw 'Put the complete Home addon in your SDK, or pass -SdkRoot with the SDK folder.'
}

function Write-BF6Shortcut([string]$Destination, [string]$Engine, [string]$Project, [string]$Root) {
    $shell = New-Object -ComObject WScript.Shell
    $description = 'BF6 Godot SDK project launcher'
    if (Test-Path -LiteralPath $Destination) {
        $existing = $shell.CreateShortcut($Destination)
        if ($existing.Description -ne $description) {
            throw "An unrelated shortcut already exists at $Destination. It was kept."
        }
    }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Destination)) ('.bf6-launch-' + [Guid]::NewGuid().ToString('N') + '.lnk')
    try {
        $shortcut = $shell.CreateShortcut($temporary)
        $shortcut.TargetPath = Join-Path $PSHOME 'powershell.exe'
        $argumentRoot = if ($Root.EndsWith('\')) { $Root + '.' } else { $Root }
        $shortcut.Arguments = '-NoLogo -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -SdkRoot "' + $argumentRoot + '" -ShowErrors'
        $shortcut.WorkingDirectory = $Root
        $shortcut.Description = $description
        $shortcut.IconLocation = $Engine + ',0'
        $shortcut.WindowStyle = 1
        $shortcut.Save()
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary
        }
    }
}

function Use-BF6ExistingActivity($Activity, $Result) {
    if (@($Activity.editors).Count) {
        $editor = @($Activity.editors | Sort-Object -Property focusable -Descending)[0]
        $Result.process_id = $editor.pid
        $Result.activated = $false
        $Result.mode = 'already_starting'
        if ($editor.focusable) {
            $shell = New-Object -ComObject WScript.Shell
            $Result.activated = [bool]$shell.AppActivate([int]$editor.pid)
            $Result.mode = 'already_running'
        }
        return $true
    }
    if (@($Activity.workers).Count) { throw 'A Battlefield SDK background job is using this project. Let it finish, then open BF6 Godot SDK again.' }
    if ($Activity.blocked) { throw 'Another Godot process could not be identified as a separate project. Close it before starting this editor.' }
    return $false
}

try {
    $root = Find-BF6Sdk $SdkRoot
    $project = Join-Path $root 'GodotProject'
    $projectFile = Join-Path $project 'project.godot'
    if (-not (Test-Path -LiteralPath $projectFile -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $root 'sdk.version.json') -PathType Leaf) -or
        -not (Test-Path -LiteralPath (Join-Path $project 'addons/bf_portal') -PathType Container)) {
        throw 'This folder is not a complete Battlefield Portal SDK installation.'
    }
    if (-not ([IO.File]::ReadAllText($projectFile) -match '(?m)^config_version\s*=\s*5\s*$')) {
        throw 'The Battlefield project does not contain a supported Godot 4 configuration.'
    }
    $engines = @(Get-ChildItem -LiteralPath $root -File | Where-Object {
        $_.Name -match '^Godot_v[^\\/]+_win64\.exe$' -and $_.Name -notmatch '_console'
    })
    if ($engines.Count -ne 1) {
        throw 'Expected one bundled Godot Windows editor beside GodotProject. Keep the matching SDK editor in that folder.'
    }
    $engine = $engines[0].FullName
    $arguments = @('--editor', '--path', $project)
    $result = [ordered]@{ mode = 'inspect'; engine = $engine; project = $project; arguments = $arguments; shortcuts = @() }
    if (-not $Inspect) {
        if ($ShortcutOnly -and -not ($CreateShortcut -or $DesktopShortcut)) {
            throw '-ShortcutOnly requires -CreateShortcut or -DesktopShortcut.'
        }
        if ($CreateShortcut) {
            $destination = Join-Path $root 'BF6 Godot SDK.lnk'
            Write-BF6Shortcut $destination $engine $project $root
            $result.shortcuts += $destination
        }
        if ($DesktopShortcut) {
            $destination = Join-Path ([Environment]::GetFolderPath('Desktop')) 'BF6 Godot SDK.lnk'
            Write-BF6Shortcut $destination $engine $project $root
            $result.shortcuts += $destination
        }
        if ($ShortcutOnly) {
            $result.mode = 'shortcuts_created'
        } else {
            $helper = Join-Path $PSScriptRoot 'godot_library_compat.ps1'
            $descriptor = Join-Path $PSScriptRoot 'data/scene-library-lazy-v1.json'
            if (-not (Test-Path -LiteralPath $descriptor -PathType Leaf)) {
                $descriptor = Join-Path $PSScriptRoot 'patches/scene-library-lazy-v1.json'
            }
            if (-not (Test-Path -LiteralPath $helper -PathType Leaf) -or -not (Test-Path -LiteralPath $descriptor -PathType Leaf)) {
                throw 'The Home launcher is incomplete. Reinstall the complete BF6 Godot Patch addon.'
            }
            . $helper
            $projectKey = Get-BF6LibraryHash ([Text.Encoding]::UTF8.GetBytes($project.ToUpperInvariant()))
            $launchMutex = New-Object Threading.Mutex($false, ('Local\BF6GodotLaunch-' + $projectKey))
            try { $ownsLaunchMutex = $launchMutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $ownsLaunchMutex = $true }
            if (-not $ownsLaunchMutex) {
                $result.mode = 'launch_in_progress'
                $result | ConvertTo-Json -Depth 4
                return
            }
            if (Use-BF6ExistingActivity (Get-BF6SdkGodotActivity -SdkRoot $root) $result) {
                $result | ConvertTo-Json -Depth 4
                return
            }
            $result.compatibility = Update-BF6SceneLibrary -SdkRoot $root -DescriptorPath $descriptor -Write
            if ($result.compatibility.recovery_required) {
                throw $result.compatibility.reason
            }
            if (Use-BF6ExistingActivity (Get-BF6SdkGodotActivity -SdkRoot $root) $result) {
                $result | ConvertTo-Json -Depth 4
                return
            }
            if ($result.compatibility.blocked_by_editor) {
                throw $result.compatibility.reason
            }
            $logFolder = Join-Path $root '.bf6-patch/logs'
            Assert-BF6LibraryPath $logFolder
            [void][IO.Directory]::CreateDirectory($logFolder)
            $logFile = Join-Path $logFolder ('godot-startup-' + [DateTime]::UtcNow.ToString('yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8) + '.log')
            $result.arguments += @('--log-file', $logFile)
            $process = Start-Process -FilePath $engine -ArgumentList @('--editor', '--path', ('"' + $project + '"'), '--log-file', ('"' + $logFile + '"')) -WorkingDirectory $root -WindowStyle Normal -PassThru
            $result.mode = 'launched'
            $result.process_id = $process.Id
            $result.log_file = $logFile
        }
    }
    $result | ConvertTo-Json -Depth 4
} catch {
    if ($ShowErrors) {
        try {
            $shell = New-Object -ComObject WScript.Shell
            $null = $shell.Popup($_.Exception.Message, 0, 'BF6 Godot SDK', 16)
        } catch { }
    }
    Write-Error -Message $_.Exception.Message -ErrorAction Continue
    exit 1
} finally {
    if ($ownsLaunchMutex) { $launchMutex.ReleaseMutex() }
    if ($null -ne $launchMutex) { $launchMutex.Dispose() }
}
