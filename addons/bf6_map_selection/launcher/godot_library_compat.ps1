# Functions only. Dot-source from the SDK launcher. No edits without -Write.
function Get-BF6LibraryHash([byte[]]$Bytes) {
    $algorithm = [Security.Cryptography.SHA256]::Create()
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($Bytes))).Replace('-', '').ToLowerInvariant() }
    finally { $algorithm.Dispose() }
}

function Assert-BF6LibraryPath([string]$Path) {
    if (-not [IO.Path]::IsPathRooted($Path)) { throw 'An absolute local SDK path is required.' }
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $entry = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Reparse paths are unsupported: $cursor" }
        }
        $next = [IO.Path]::GetDirectoryName($cursor)
        if ($next -eq $cursor) { break }
        $cursor = $next
    }
}

function Get-BF6LibraryGodotProcesses {
    # Fail closed if process inspection is unavailable. Command lines are never logged.
    return @(Get-CimInstance Win32_Process -Filter "Name LIKE 'Godot%'" -ErrorAction Stop)
}

function Get-BF6LibrarySdkRoot([string]$Path) {
    $root = [IO.Path]::GetFullPath($Path)
    if ($root.Length -gt [IO.Path]::GetPathRoot($root).Length) { $root = $root.TrimEnd('\', '/') }
    if ([IO.Path]::GetFileName($root) -eq 'GodotProject') { $root = [IO.Path]::GetDirectoryName($root) }
    return $root
}

function Get-BF6LibraryWindowState([int]$ProcessId) {
    try { $process = Get-Process -Id $ProcessId -ErrorAction Stop }
    catch { return [pscustomobject]@{ exists=$false; visible=$false; handle=0 } }
    $process.Refresh()
    # Process.MainWindowHandle is the OS-enumerated visible, unowned main window.
    # A headless process has no such window; a starting editor may acquire it later.
    $handle = $process.MainWindowHandle.ToInt64()
    return [pscustomobject]@{ exists=$true; visible=($handle -ne 0); handle=$handle }
}

function Get-BF6SdkGodotActivity {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SdkRoot)
    $activity = [ordered]@{ status='idle'; blocked=$false; editors=@(); workers=@(); ambiguous=@() }
    try {
        $root = Get-BF6LibrarySdkRoot $SdkRoot
        $project = [IO.Path]::GetFullPath((Join-Path $root 'GodotProject')).TrimEnd('\', '/')
        foreach ($process in @(Get-BF6LibraryGodotProcesses)) {
            $processId = [int]$process.ProcessId
            $command = [string]$process.CommandLine
            if (-not $command) {
                $activity.ambiguous += [pscustomobject]@{pid=$processId;reason='Running Godot command line is unavailable.'}; continue
            }
            if ($command -match '(?:^|\s)(?:--project-manager|-p)(?:\s|$)') { continue }
            $projectArgument = ''
            $match = [regex]::Match($command, '(?:^|\s)--path(?:=|\s+)(?:"([^"]+)"|([^\s]+))')
            if ($match.Success) {
                $projectArgument = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
            } else {
                # Windows absolute project.godot argument, quoted when it has spaces.
                $match = [regex]::Match($command, '(?i)(?:^|\s)(?:"([A-Z]:[\\/][^"]*?[\\/]project\.godot)"|([A-Z]:[\\/][^\s"]*?[\\/]project\.godot))(?=\s|$)')
                if ($match.Success) {
                    $file = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
                    $projectArgument = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($file))
                }
            }
            if (-not $projectArgument -or -not [IO.Path]::IsPathRooted($projectArgument)) {
                $activity.ambiguous += [pscustomobject]@{pid=$processId;reason='Running Godot has no inspectable absolute project path.'}; continue
            }
            # An explicit unrelated project is safe to ignore even with our bundled engine.
            if ([IO.Path]::GetFullPath($projectArgument).TrimEnd('\', '/') -ne $project) { continue }
            $headless = $command -match '(?:^|\s)--headless(?:\s|$)' -or $command -match '(?:^|\s)--display-driver(?:=|\s+)"?headless"?(?:\s|$)'
            $worker = $headless -or $command -match '(?:^|\s)(?:--script|-s|--import|--quit|--quit-after)(?:=|\s|$)'
            $editor = $command -match '(?:^|\s)(?:--editor|-e)(?:\s|$)'
            if ($worker -or -not $editor) {
                $kind = if ($headless) { 'headless_worker' } elseif ($worker) { 'script_or_import_worker' } else { 'game_or_other_project_process' }
                $activity.workers += [pscustomobject]@{pid=$processId;kind=$kind}; continue
            }
            $window = Get-BF6LibraryWindowState $processId
            if (-not $window.exists) { continue }
            $activity.editors += [pscustomobject]@{pid=$processId;focusable=[bool]$window.visible;window_handle=$window.handle;starting=(-not $window.visible)}
        }
    } catch { $activity.ambiguous += [pscustomobject]@{pid=0;reason=$_.Exception.Message} }
    $activity.blocked = $activity.editors.Count -gt 0 -or $activity.workers.Count -gt 0 -or $activity.ambiguous.Count -gt 0
    if ($activity.ambiguous.Count) { $activity.status = 'ambiguous' } elseif ($activity.blocked) { $activity.status = 'active' }
    return [pscustomobject]$activity
}

function Test-BF6LibraryEditorRunning([string]$Root, [string]$Project) {
    $activity = Get-BF6SdkGodotActivity -SdkRoot $Root
    if ($activity.workers.Count) { throw 'A Godot background worker or game is using this SDK project. Wait for it to finish before applying updates.' }
    if ($activity.ambiguous.Count) { throw 'A running Godot process cannot be associated with an absolute project safely. Close it or relaunch it with an absolute --path.' }
    return $activity.editors.Count -gt 0
}

function Write-BF6LibraryNewFile([string]$Path, [byte[]]$Bytes) {
    Assert-BF6LibraryPath $Path
    $stream = New-Object IO.FileStream($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($Bytes, 0, $Bytes.Length); $stream.Flush($true) }
    finally { $stream.Dispose() }
    if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($Path))) -ne (Get-BF6LibraryHash $Bytes)) { throw "Written file verification failed: $Path" }
}

function Update-BF6SceneLibrary {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)][string]$SdkRoot,
          [Parameter(Mandatory=$true)][string]$DescriptorPath,
          [switch]$Write)
    $result = [ordered]@{ status = 'unsupported'; reason = ''; changed = 0; files = @(); recovery_required = $false; blocked_by_editor = $false }
    $prepared = New-Object 'Collections.Generic.List[object]'
    $published = New-Object 'Collections.Generic.List[object]'
    try {
        Assert-BF6LibraryPath $SdkRoot
        $root = Get-BF6LibrarySdkRoot $SdkRoot
        $project = Join-Path $root 'GodotProject'
        Assert-BF6LibraryPath $project
        if (-not (Test-Path -LiteralPath (Join-Path $project 'project.godot') -PathType Leaf)) {
            $result.status = 'missing'; $result.reason = 'GodotProject/project.godot is missing.'; return [pscustomobject]$result
        }
        if (-not (Test-Path -LiteralPath $DescriptorPath -PathType Leaf)) {
            $result.status = 'missing'; $result.reason = 'Compatibility descriptor is missing.'; return [pscustomobject]$result
        }
        Assert-BF6LibraryPath $DescriptorPath
        if ((Get-Item -LiteralPath $DescriptorPath).Length -gt 1048576) { throw 'Compatibility descriptor is too large.' }
        $utf8 = New-Object Text.UTF8Encoding($false, $true)
        $descriptor = $utf8.GetString([IO.File]::ReadAllBytes($DescriptorPath)) | ConvertFrom-Json -ErrorAction Stop
        if ($descriptor.format -ne 'bf6-scene-library-compatibility-patch' -or $descriptor.version -ne 1 -or $descriptor.newlineNormalization -ne 'LF') { throw 'Unsupported compatibility descriptor format.' }
        $allowed = @('addons/scene-library/scripts/scene_library.gd', 'addons/bf6_sfx_fx/scene_library_patch/scene_library.gd.patched')
        $targets = @($descriptor.targets)
        if ($targets.Count -ne 2 -or @($targets | Select-Object -Unique).Count -ne 2 -or @($targets | Where-Object { $_ -cnotin $allowed }).Count) { throw 'Descriptor targets do not match the two supported code files.' }
        $transforms = @($descriptor.transforms)
        if ($transforms.Count -lt 1 -or $transforms.Count -gt 32) { throw 'Invalid compatibility transform count.' }
        $inputs = @{}
        foreach ($transform in $transforms) {
            if ($transform.input_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $transform.output_sha256 -cnotmatch '^[0-9a-f]{64}$' -or $inputs.ContainsKey($transform.input_sha256)) { throw 'Invalid or duplicate compatibility hashes.' }
            $inputs[$transform.input_sha256] = $transform
            if (@($transform.replacements).Count -lt 1) { throw 'Empty compatibility transform.' }
            foreach ($replacement in $transform.replacements) {
                if ($replacement.before -isnot [string] -or -not $replacement.before -or $replacement.after -isnot [string]) { throw 'Invalid literal replacement.' }
            }
        }
        $unknown = $false
        foreach ($relative in $targets) {
            $path = Join-Path $project $relative
            Assert-BF6LibraryPath $path
            $entry = [pscustomobject][ordered]@{ path = $relative; status = 'missing'; input_sha256 = ''; output_sha256 = ''; backup = '' }
            if (Test-Path -LiteralPath $path -PathType Leaf) {
                if ((Get-Item -LiteralPath $path).Length -gt 4194304) { throw 'Scene Library source exceeds the supported size.' }
                $original = [IO.File]::ReadAllBytes($path)
                $hash = Get-BF6LibraryHash $original
                $entry.input_sha256 = $hash
                if (@($transforms | Where-Object { $_.output_sha256 -eq $hash }).Count) {
                    $entry.status = 'already_current'; $entry.output_sha256 = $hash
                } elseif ($inputs.ContainsKey($hash)) {
                    $transform = $inputs[$hash]
                    $text = $utf8.GetString($original).Replace("`r`n", "`n")
                    foreach ($replacement in $transform.replacements) {
                        $before = [string]$replacement.before
                        $at = $text.IndexOf($before, [StringComparison]::Ordinal)
                        if ($at -lt 0 -or $text.IndexOf($before, $at + $before.Length, [StringComparison]::Ordinal) -ge 0) { throw "Expected exactly one literal replacement in $relative." }
                        $text = $text.Substring(0, $at) + [string]$replacement.after + $text.Substring($at + $before.Length)
                    }
                    $output = $utf8.GetBytes($text)
                    if ((Get-BF6LibraryHash $output) -ne $transform.output_sha256) { throw "Compatibility output hash does not match for $relative." }
                    $entry.status = 'planned'; $entry.output_sha256 = $transform.output_sha256
                    $prepared.Add([pscustomobject]@{ path=$path; original=$original; output=$output; input_hash=$hash; output_hash=$transform.output_sha256; entry=$entry; stage='' })
                } else { $entry.status = 'unsupported'; $unknown = $true }
            } elseif (Test-Path -LiteralPath $path) { throw "Code target is not a regular file: $relative" }
            $result.files += [pscustomobject]$entry
        }
        if ($unknown) { $result.reason = 'An unrecognized or modified Scene Library was preserved. No targets were patched.'; return [pscustomobject]$result }
        if ($prepared.Count -eq 0) {
            $result.status = if (@($result.files | Where-Object status -eq 'already_current').Count) { 'already_current' } else { 'missing' }
            return [pscustomobject]$result
        }
        if (-not $Write) { $result.status = 'planned'; $result.reason = 'Recognized source; no files written.'; return [pscustomobject]$result }
        try { $editorRunning = Test-BF6LibraryEditorRunning $root $project }
        catch { $result.blocked_by_editor = $true; throw }
        if ($editorRunning) { $result.blocked_by_editor = $true; $result.reason = 'Close the Godot editor using this SDK before applying compatibility updates.'; return [pscustomobject]$result }
        $backupRoot = Join-Path $root '.bf6-patch/backups'
        Assert-BF6LibraryPath $backupRoot
        [void][IO.Directory]::CreateDirectory($backupRoot)
        foreach ($item in $prepared) {
            Assert-BF6LibraryPath $item.path
            if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($item.path))) -ne $item.input_hash) { throw 'Scene Library changed after preflight. No new content will replace it.' }
            $backup = Join-Path $backupRoot ($item.input_hash + '.original')
            Assert-BF6LibraryPath $backup
            if (Test-Path -LiteralPath $backup) {
                if (-not (Test-Path -LiteralPath $backup -PathType Leaf) -or (Get-BF6LibraryHash ([IO.File]::ReadAllBytes($backup))) -ne $item.input_hash) { throw 'Existing compatibility backup is not the expected original. It was preserved.' }
            } else { Write-BF6LibraryNewFile $backup $item.original }
            $item.entry.backup = $backup
            $item.stage = $item.path + '.bf6-stage-' + [Guid]::NewGuid().ToString('N')
            Write-BF6LibraryNewFile $item.stage $item.output
        }
        # Recheck every target and process after all backups/stages exist, before publishing.
        try { $editorRunning = Test-BF6LibraryEditorRunning $root $project }
        catch { $result.blocked_by_editor = $true; throw }
        if ($editorRunning) { $result.blocked_by_editor = $true; throw 'Godot started during preparation. Original files were preserved.' }
        foreach ($item in $prepared) {
            Assert-BF6LibraryPath $item.path
            if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($item.path))) -ne $item.input_hash) { throw 'Scene Library changed during preparation. Original files were preserved.' }
        }
        foreach ($item in $prepared) {
            Assert-BF6LibraryPath $item.path
            Assert-BF6LibraryPath $item.stage
            if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($item.path))) -ne $item.input_hash) { throw 'Scene Library changed before publication.' }
            [IO.File]::Replace($item.stage, $item.path, [NullString]::Value)
            $published.Add($item)
            if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($item.path))) -ne $item.output_hash) { throw 'Published Scene Library verification failed.' }
        }
        $result.status = 'applied'; $result.changed = $published.Count
        foreach ($entry in $result.files) { if ($entry.status -eq 'planned') { $entry.status = 'applied' } }
        return [pscustomobject]$result
    } catch {
        $result.reason = $_.Exception.Message
        for ($index = $published.Count - 1; $index -ge 0; $index--) {
            $item = $published[$index]
            try {
                Assert-BF6LibraryPath $item.path
                if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($item.path))) -ne $item.output_hash) { throw 'A published target changed externally; retained backup requires review.' }
                $rollback = $item.path + '.bf6-rollback-' + [Guid]::NewGuid().ToString('N')
                Write-BF6LibraryNewFile $rollback $item.original
                [IO.File]::Replace($rollback, $item.path, [NullString]::Value)
                if ((Get-BF6LibraryHash ([IO.File]::ReadAllBytes($item.path))) -ne $item.input_hash) { throw 'Rollback verification failed.' }
            } catch { $result.recovery_required = $true; $result.reason += ' Recovery: ' + $_.Exception.Message }
        }
        $result.status = 'unsupported'
        return [pscustomobject]$result
    } finally {
        # Remove only our uniquely named stages; originals/backups are never deleted.
        foreach ($item in $prepared) {
            if ($item.stage -and (Test-Path -LiteralPath $item.stage -PathType Leaf)) {
                try { Assert-BF6LibraryPath $item.stage; [IO.File]::Delete($item.stage) } catch { }
            }
        }
    }
}
