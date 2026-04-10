#Requires -Version 7.0

param (
    [switch]$CloneNewVersion,
    [string]$GodotBuildName,
    [string]$EncryptionKeyPath = "godot.gdkey",
    [string]$NugetSourcePath = "C:\MyLocalNugetSource"
)

$ProgressPreference = 'SilentlyContinue'
$logFile = "build_log.txt"
if (Test-Path $logFile) { Remove-Item $logFile -Force }

function Write-Log {
    param([string]$Message)
    "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] $Message`r`n" | Out-File $logFile -Append -Encoding utf8
}

Write-Log "Build started"
$totalBuildStartTime = Get-Date
$buildJobs = @{}

function Show-Step([string]$msg) { Write-Host "`n>>> $msg" -ForegroundColor Cyan }

function Ensure-Scoop {
    if (!(Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-Host "[!] Scoop not found!" -ForegroundColor Yellow
        $ans = Read-Host "Install Scoop package manager now? (Y/N)"
        if ($ans -match '^[yY]') {
            Show-Step "Installing Scoop..."
            Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
            Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
            $env:PATH += ";$env:USERPROFILE\scoop\shims"
        } else {
            Write-Error "Scoop is required for automatic tool installation."
            exit 1
        }
    }
}

function Install-Tool([string]$cmd, [string]$packageName) {
    if (!(Get-Command $cmd -ErrorAction SilentlyContinue)) {
        Show-Step "Installing $packageName via Scoop..."
        scoop install $packageName
    } else {
        Write-Host "[+] $packageName is already installed." -ForegroundColor Gray
    }
}

Ensure-Scoop
Install-Tool "git" "git"
Install-Tool "python" "python"
Install-Tool "openssl" "openssl"
Install-Tool "dotnet" "dotnet-sdk"

if (!(Get-Command scons -ErrorAction SilentlyContinue)) {
    Show-Step "Installing SCons via pip..."
    & python -m pip install scons
} else {
    Write-Host "[+] scons is already installed." -ForegroundColor Gray
}

function Wait-AllJobs {
    param([string[]]$JobNames)
    $activeNames = @()
    foreach ($n in $JobNames) {
        if ($buildJobs.ContainsKey($n)) { $activeNames += $n }
    }
    if ($activeNames.Count -eq 0) { return }
    Write-Host "[~] Doing in parallel: $($activeNames -join ', ')" -ForegroundColor Cyan
    Write-Host " Progress: " -NoNewline -ForegroundColor DarkGray
    $dotCount = 0
    while ($activeNames.Count -gt 0) {
        $stillRunning = @()
        foreach ($name in $activeNames) {
            $jobEntry = $buildJobs[$name]
            $job = $jobEntry.Job
            if ($job.State -eq "Running") {
                $stillRunning += $name
            } else {
                Write-Host ""
                $duration = ((Get-Date) - $jobEntry.StartTime).TotalSeconds
                $durationFormatted = [TimeSpan]::FromSeconds($duration).ToString("mm\:ss")
                $output = Receive-Job -Job $job
                $outputText = if ($output) { $output | Out-String } else { "" }
                $hasBuildError = $false
                $errorReason = ""
                if ($job.State -eq "Failed") {
                    $hasBuildError = $true
                    $errorReason = "Job state: Failed"
                } elseif ($outputText -match "scons: \*\*\* |error:|fatal error:|Error \d+|build failed|Build terminated") {
                    $hasBuildError = $true
                    $errorReason = "Build errors detected"
                } elseif ($duration -lt 10 -and $name -notlike "*Clone*") {
                    $hasBuildError = $true
                    $errorReason = "Completed too fast (failed silently)"
                }
                if ($hasBuildError) {
                    Write-Host "[X] $name FAILED after $durationFormatted! ($errorReason)" -ForegroundColor Red
                    Write-Host "`n--- Last 50 lines of output ---" -ForegroundColor Yellow
                    $lines = $outputText -split "`n"
                    $lines | Select-Object -Last 50 | ForEach-Object { Write-Host $_ -ForegroundColor Gray }
                    Write-Log "Job '$name' FAILED after $durationFormatted - $errorReason"
                    Write-Log $outputText
                    exit 1
                }
                Write-Host "[+] $name completed in $durationFormatted" -ForegroundColor Green
                if ($output) {
                    Write-Log "=== Output from '$name' ($durationFormatted) ==="
                    Write-Log $outputText
                }
                Remove-Job -Job $job -Force
                if ($activeNames.Count -gt 1) {
                    Write-Host " Remaining: " -NoNewline -ForegroundColor DarkGray
                }
            }
        }
        $activeNames = $stillRunning
        if ($activeNames.Count -gt 0) {
            Write-Host "." -NoNewline -ForegroundColor DarkGray
            $dotCount++
            if ($dotCount % 60 -eq 0) { Write-Host "`n " -NoNewline }
            Start-Sleep -Seconds 2
        }
    }
    Write-Host "`n"
}

$buildsFile = Join-Path $PSScriptRoot "builds.json"
if (!(Test-Path $buildsFile)) {
    "{}" | Out-File $buildsFile -Encoding UTF8
    Write-Log "builds.json created"
}

$allBuilds = @{}
if (Test-Path $buildsFile) {
    $json = Get-Content $buildsFile -Raw -ErrorAction SilentlyContinue
    if ($json -and $json.Trim()) {
        try {
            $parsed = $json | ConvertFrom-Json
            foreach ($prop in $parsed.PSObject.Properties) {
                $allBuilds[$prop.Name] = $prop.Value
            }
        } catch {
            Write-Log "JSON parse error"
        }
    }
}

$modulesFile = Join-Path $PSScriptRoot "modules.json"
if (!(Test-Path $modulesFile)) {
    Write-Error "modules.json nicht gefunden!"
    exit 1
}
$modulesConfig = Get-Content $modulesFile -Raw | ConvertFrom-Json

$godotSourceDir = ""
$VersionStatus = ""
$GodotBranchName = ""
$folderName = ""
$selectedFolder = ""

if (!$CloneNewVersion) {
    $choice = Read-Host "Clone new version? (Y/N) [N]"
    if ($choice -match '^[yY]') { $CloneNewVersion = $true }
}

if ($CloneNewVersion) {
    $apiUrl = "https://api.github.com/repos/godotengine/godot/releases"
    try {
        $releases = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
        $releases = $releases | Where-Object {
            $_.tag_name -and ($_.tag_name.Trim() -ne "") -and ($_.tag_name -match "\d+\.\d+(\.\d+)?-stable$")
        }
        $releases = $releases | Sort-Object { [Version]($_.tag_name -replace "-stable","") } -Descending | Select-Object -First 10
    } catch {
        Write-Error "GitHub API failed"
        pause
        exit 1
    }
    Write-Host "`nSelect Godot version:"
    for ($i = 0; $i -lt $releases.Count; $i++) {
        Write-Host "[$i] $($releases[$i].tag_name.Trim())"
    }
    $selection = Read-Host "Number"
    if ($selection -lt 0 -or $selection -ge $releases.Count) {
        Write-Error "Invalid selection"
        pause
        exit 1
    }
    $GodotBranchName = $releases[$selection].tag_name.Trim()
    Write-Log "Selected: $GodotBranchName"
    if (!$GodotBuildName) { $GodotBuildName = Read-Host "Build name (e.g. skytech)" }
    if (!$GodotBuildName) {
        Write-Error "Build name required"
        pause
        exit 1
    }
    $versionMatch = [regex]::Match($GodotBranchName, "(\d+\.\d+(\.\d+)?)")
    if (!$versionMatch.Success) {
        Write-Error "Version parse failed"
        exit 1
    }
    $versionNumber = $versionMatch.Groups[1].Value
    $folderName = "$versionNumber.$GodotBuildName"
    $godotSourceDir = Join-Path $PSScriptRoot $folderName
    $VersionStatus = $GodotBuildName
    $allBuilds[$folderName] = @{
        folder = $folderName
        version = $GodotBranchName
        buildName = $GodotBuildName
        created = (Get-Date).ToString("o")
    }
    $allBuilds | ConvertTo-Json -Depth 3 | Set-Content $buildsFile
} else {
    $existing = Get-ChildItem -Path $PSScriptRoot -Directory | Where-Object {
        $_.Name -like "*.*" -or $_.Name -eq "godot"
    }
    if ($existing.Count -eq 0) {
        Write-Error "No build folders found"
        pause
        exit 1
    }
    Write-Host "`nSelect folder:"
    for ($i = 0; $i -lt $existing.Count; $i++) {
        $fn = $existing[$i].Name
        if ($allBuilds -and $allBuilds.ContainsKey($fn)) {
            $info = $allBuilds[$fn]
            Write-Host "[$i] $fn (v$($info.version), $($info.buildName))"
        } else {
            Write-Host "[$i] $fn"
        }
    }
    $selection = Read-Host "Number"
    if ($selection -lt 0 -or $selection -ge $existing.Count) {
        Write-Error "Invalid selection"
        pause
        exit 1
    }
    $selectedFolder = $existing[$selection].Name
    $godotSourceDir = Join-Path $PSScriptRoot $selectedFolder
    if ($allBuilds -and $allBuilds.ContainsKey($selectedFolder)) {
        $GodotBranchName = $allBuilds[$selectedFolder].version
        $GodotBuildName = $allBuilds[$selectedFolder].buildName
        $VersionStatus = $GodotBuildName
    } else {
        $GodotBranchName = Read-Host "Version (e.g. 4.4.1-stable)"
        $GodotBuildName = Read-Host "Build name"
        $VersionStatus = $GodotBuildName
        $allBuilds[$selectedFolder] = @{
            folder = $selectedFolder
            version = $GodotBranchName
            buildName = $GodotBuildName
            created = (Get-Date).ToString("o")
        }
        $allBuilds | ConvertTo-Json -Depth 3 | Set-Content $buildsFile
    }
}

Show-Step "Generating encryption key..."
$AES_KEY = & openssl rand -hex 32
$AES_KEY | Set-Clipboard
$env:SCRIPT_AES256_ENCRYPTION_KEY = $AES_KEY
Write-Log "Key generated and copied"

$exportVersionName = if ($CloneNewVersion) { $folderName } else { $selectedFolder }
$customModulesDir = Join-Path $PSScriptRoot "custom_modules"

if ($CloneNewVersion) {
    $sdkFolder = Join-Path $PSScriptRoot "sdks"
    if (!(Test-Path $sdkFolder)) { New-Item -ItemType Directory -Path $sdkFolder | Out-Null }
    $sdks = Get-ChildItem -Path $sdkFolder -Filter "*.zip"

    Show-Step "Cloning Godot..."
    $buildJobs["Godot-Clone"] = @{
        Job = (Start-Job -ScriptBlock {
            param($branch, $targetDir)
            git clone --depth 1 -b $branch https://github.com/godotengine/godot.git $targetDir 2>&1
        } -ArgumentList $GodotBranchName, $godotSourceDir -Name "Godot-Clone")
        Status = "Running"
        StartTime = Get-Date
    }
    Wait-AllJobs -JobNames @("Godot-Clone")

    if (!(Test-Path $customModulesDir)) { New-Item -ItemType Directory -Path $customModulesDir | Out-Null }

    Write-Host "`nAvailable modules:"
    $selectedIndices = @()
    for ($i = 0; $i -lt $modulesConfig.modules.Count; $i++) {
        $m = $modulesConfig.modules[$i]
        Write-Host "[$i] $($m.name) ($($m.repo))"
        if ($m.enabled_by_default -eq $true) { $selectedIndices += $i }
    }
    $selection = Read-Host "Enter numbers of modules to include (comma separated, empty = defaults)"
    if ($selection.Trim()) {
        $selectedIndices = $selection -split ',' | ForEach-Object { [int]$_.Trim() } | Where-Object { $_ -ge 0 -and $_ -lt $modulesConfig.modules.Count }
    }

    $cloneJobs = @()
    $steamSDKNeeded = $false
    foreach ($idx in $selectedIndices) {
        $mod = $modulesConfig.modules[$idx]
        $target = Join-Path $customModulesDir $mod.name
        if ($mod.name -eq "godotsteam") { $steamSDKNeeded = $true }
        $cloneJobs += "Clone-$($mod.name)"
        $buildJobs["Clone-$($mod.name)"] = @{
            Job = (Start-Job -ScriptBlock {
                param($repo, $branch, $target)
                if (Test-Path $target) { Remove-Item $target -Recurse -Force }
                git clone --depth 1 -b $branch $repo $target 2>&1
            } -ArgumentList $mod.repo, $mod.branch, $target -Name "Clone-$($mod.name)")
            Status = "Running"
            StartTime = Get-Date
        }
    }
    if ($cloneJobs.Count -gt 0) {
        Show-Step "Cloning selected modules..."
        Wait-AllJobs -JobNames $cloneJobs
    }

    $selectedModuleNames = $selectedIndices | ForEach-Object { $modulesConfig.modules[$_].name }
    $allBuilds[$folderName].selected_modules = $selectedModuleNames
    $allBuilds | ConvertTo-Json -Depth 3 | Set-Content $buildsFile

    if ($steamSDKNeeded) {
        $steamSelected = $false
        $chosenSDK = $null
        if ($sdks.Count -eq 0) {
            Write-Host "[!] No Steam SDK ZIP found in sdks/ folder" -ForegroundColor Yellow
        } elseif ($sdks.Count -eq 1) {
            $chosenSDK = $sdks[0].Name
            $steamSelected = $true
            Write-Host "[+] Using single Steam SDK: $($chosenSDK)" -ForegroundColor Green
        } else {
            Write-Host "`nAvailable Steam SDKs:"
            for ($i = 0; $i -lt $sdks.Count; $i++) {
                Write-Host "[$i] $($sdks[$i].Name)"
            }
            $sel = Read-Host "Select Steam SDK number (empty = skip)"
            if ($sel -match '^\d+$' -and $sel -lt $sdks.Count) {
                $chosenSDK = $sdks[$sel].Name
                $steamSelected = $true
            }
        }
        if ($steamSelected -and $chosenSDK) {
            Show-Step "Extracting Steam SDK..."
            $zipPath = Join-Path $sdkFolder $chosenSDK
            $tempDir = Join-Path $PSScriptRoot "temp_sdk"
            if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
            New-Item -ItemType Directory -Path $tempDir | Out-Null
            Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force
            $sdkTarget = Join-Path $customModulesDir "godotsteam\sdk"
            if (!(Test-Path $sdkTarget)) { New-Item -ItemType Directory -Path $sdkTarget | Out-Null }
            Copy-Item -Path (Join-Path $tempDir "sdk\public") -Destination (Join-Path $sdkTarget "public") -Recurse -Force
            Copy-Item -Path (Join-Path $tempDir "sdk\redistributable_bin") -Destination (Join-Path $sdkTarget "redistributable_bin") -Recurse -Force
            Remove-Item -Path $tempDir -Recurse -Force
            Write-Log "Steam SDK extracted"
        } elseif ($steamSDKNeeded -and -not $steamSelected) {
            Write-Host "[!] godotsteam selected but no Steam SDK chosen → build continues without Steam integration" -ForegroundColor Yellow
        }
    }
}

$d3dScript = Join-Path $godotSourceDir "misc\scripts\install_d3d12_sdk_windows.py"
$needsD3D = $true
if ($allBuilds.ContainsKey("_global") -and $allBuilds["_global"].d3d12_installed) {
    $needsD3D = $false
    Write-Host "[+] DirectX 12 SDK already installed" -ForegroundColor Gray
}
if ((Test-Path $d3dScript) -and $needsD3D) {
    Show-Step "Installing DirectX 12 SDK..."
    & python $d3dScript *> $null
    Write-Log "D3D12 SDK installed"
    if (!$allBuilds.ContainsKey("_global")) { $allBuilds["_global"] = @{} }
    $allBuilds["_global"].d3d12_installed = $true
    $allBuilds["_global"].d3d12_installed_date = (Get-Date).ToString("o")
    $allBuilds | ConvertTo-Json -Depth 3 | Set-Content $buildsFile
    Write-Host "[+] DirectX 12 SDK installed" -ForegroundColor Green
} elseif (!(Test-Path $d3dScript)) {
    Write-Host "[!] DirectX 12 SDK script not found" -ForegroundColor Yellow
}

$binPath = Join-Path $godotSourceDir "bin"
$env:GODOT_VERSION_STATUS = $VersionStatus
$commonArgs = "d3d12=yes GODOT_VERSION_STATUS=$VersionStatus module_mono_enabled=yes custom_modules=../custom_modules"

Show-Step "Building temporary editor (mono_glue=no)..."
$buildJobs["Temp-Editor"] = @{
    Job = (Start-Job -ScriptBlock {
        param($sourceDir, $extraArgs)
        Set-Location $sourceDir
        
        $sconsArgs = @(
            "p=windows",
            "target=editor",
            "tools=yes",
            "module_mono_enabled=yes",
            "mono_glue=no"
        )
        if ($extraArgs) {
            $sconsArgs += $extraArgs -split ' ' | Where-Object { $_ -match '\S' }
        }
        & scons $sconsArgs 2>&1
    } -ArgumentList $godotSourceDir, $commonArgs -Name "Temp-Editor")
    Status = "Running"
    StartTime = Get-Date
}
Wait-AllJobs -JobNames @("Temp-Editor")

$steamSrc = Join-Path $customModulesDir "godotsteam\sdk\redistributable_bin\win64\steam_api64.dll"
$steamDst = Join-Path $binPath "steam_api64.dll"
if (Test-Path $steamSrc) {
    Copy-Item $steamSrc $steamDst -Force -ErrorAction SilentlyContinue
    Write-Log "steam_api64.dll copied to bin"
}

Show-Step "Generating Mono glue files..."
$gluePath = Join-Path $godotSourceDir "modules\mono\glue"
if (!(Test-Path $gluePath)) { New-Item -ItemType Directory $gluePath -Force | Out-Null }

$glueCommandFile = Get-ChildItem -Path $binPath -Filter "godot.windows.editor.x86_64*.exe" | 
                   Where-Object { $_.Name -notlike "*console*" } | 
                   Sort-Object Length -Descending | Select-Object -First 1

if ($null -eq $glueCommandFile) {
    Write-Host "[X] Fehler: Keine Editor-EXE für Glue-Generierung gefunden!" -ForegroundColor Red
    exit 1
}

$glueCommand = $glueCommandFile.FullName
Write-Host "[+] Nutze für Glue: $($glueCommandFile.Name)" -ForegroundColor Gray

$glueArgs = @("--headless", "--generate-mono-glue", "$gluePath")
$glueProcess = Start-Process -FilePath $glueCommand -ArgumentList $glueArgs -WorkingDirectory $godotSourceDir -NoNewWindow -Wait -PassThru

if ($glueProcess.ExitCode -ne 0) {
    Write-Host "[X] Mono glue generation failed. Exit code: $($glueProcess.ExitCode)" -ForegroundColor Red
    exit 1
}
Write-Log "Mono glue generated"

Show-Step "Building final editor (Standalone)..."

if (Test-Path $godotSourceDir) {
    Set-Location $godotSourceDir
    Write-Host "[+] Arbeitsverzeichnis: $(Get-Location)" -ForegroundColor Gray
} else {
    Write-Host "[X] Fehler: Quellverzeichnis $godotSourceDir nicht gefunden!" -ForegroundColor Red
    exit 1
}

$editorArgs = @(
    "p=windows",
    "target=editor",
    "tools=yes",
    "module_mono_enabled=yes"
)

if ($commonArgs) { 
    $extra = $commonArgs -split ' ' | Where-Object { $_ -match '\S' }
    $editorArgs += $extra 
}

& scons $editorArgs

if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Final Editor Build failed! (Exit Code: $LASTEXITCODE)" -ForegroundColor Red
    exit 1
}
Write-Host "[+] Editor build completed successfully." -ForegroundColor Green

Show-Step "Building debug templates..."

$buildJobs["Template-Windows-Debug"] = @{
    Job = (Start-Job -ScriptBlock {
        param($sourceDir, $extraArgs)
        if (Test-Path $sourceDir) { Set-Location $sourceDir }
        $sconsArgs = @("p=windows", "target=template_debug", "module_mono_enabled=yes")
        if ($extraArgs) { $sconsArgs += $extraArgs -split ' ' | Where-Object { $_ -match '\S' } }
        & scons $sconsArgs 2>&1
    } -ArgumentList $godotSourceDir, $commonArgs -Name "Template-Windows-Debug")
    Status = "Running"
    StartTime = Get-Date
}

Wait-AllJobs -JobNames @("Template-Windows-Debug")

Show-Step "Building release templates..."

$buildJobs["Template-Windows-Release"] = @{
    Job = (Start-Job -ScriptBlock {
        param($sourceDir, $extraArgs)
        if (Test-Path $sourceDir) { Set-Location $sourceDir }
        $sconsArgs = @("p=windows", "target=template_release", "module_mono_enabled=yes")
        if ($extraArgs) { $sconsArgs += $extraArgs -split ' ' | Where-Object { $_ -match '\S' } }
        & scons $sconsArgs 2>&1
    } -ArgumentList $godotSourceDir, $commonArgs -Name "Template-Windows-Release")
    Status = "Running"
    StartTime = Get-Date
}

Wait-AllJobs -JobNames @("Template-Windows-Release")

if (Test-Path $steamSrc) {
    Copy-Item $steamSrc $steamDst -Force -ErrorAction SilentlyContinue
    Write-Log "steam_api64.dll copied"
}

Show-Step "Adding local NuGet source..."
if (-not (Test-Path $NugetSourcePath)) { New-Item -ItemType Directory -Path $NugetSourcePath | Out-Null }
& dotnet nuget add source $NugetSourcePath --name "GodotLocalNuget" *> $null

Show-Step "Building and pushing Mono assemblies..."
$pyScript = Join-Path $godotSourceDir "modules\mono\build_scripts\build_assemblies.py"
& python $pyScript --godot-output-dir $binPath --push-nupkgs-local $NugetSourcePath
if ($LASTEXITCODE -ne 0) {
    Write-Host "[X] Mono assemblies build failed." -ForegroundColor Red
    exit 1
}
Write-Log "Mono assemblies built"

Show-Step "Installing export templates..."
$exportDir = Join-Path $env:APPDATA "Godot\export_templates\$exportVersionName"
if (!(Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }
Write-Host "`nCopying templates to: $exportDir" -ForegroundColor Gray

$winTemplates = @(
    @{s="godot.windows.template_debug.x86_64.mono.exe";          d="windows_debug_x86_64.exe"},
    @{s="godot.windows.template_release.x86_64.mono.exe";        d="windows_release_x86_64.exe"},
    @{s="godot.windows.template_debug.x86_64.mono.console.exe";  d="windows_debug_x86_64_console.exe"},
    @{s="godot.windows.template_release.x86_64.mono.console.exe"; d="windows_release_x86_64_console.exe"}
)

$copiedCount = 0
foreach ($t in $winTemplates) {
    $src = Join-Path $binPath $t.s
    $dst = Join-Path $exportDir $t.d
    if (Test-Path $src) {
        Copy-Item $src $dst -Force
        Write-Host "[+] $($t.d)" -ForegroundColor Green
        $copiedCount++
    } else {
        # Fallback-Check: Manchmal lässt SCons das .mono im Namen weg
        $srcFallback = $src -replace '\.mono', ''
        if (Test-Path $srcFallback) {
            Copy-Item $srcFallback $dst -Force
            Write-Host "[+] $($t.d) (from non-mono named source)" -ForegroundColor Green
            $copiedCount++
        } else {
            Write-Host "[!] Missing: $($t.s)" -ForegroundColor Yellow
        }
    }
}

$totalDuration = ((Get-Date) - $totalBuildStartTime)
$totalHours = [Math]::Floor($totalDuration.TotalHours)
$totalMinutes = $totalDuration.Minutes
$totalSeconds = $totalDuration.Seconds
$totalTimeString = if ($totalHours -gt 0) {
    "{0:D2}:{1:D2}:{2:D2}" -f $totalHours, $totalMinutes, $totalSeconds
} else {
    "{0:D2}:{1:D2}" -f $totalMinutes, $totalSeconds
}

Write-Host "`n=============================================" -ForegroundColor Cyan
Write-Host "[+] Build completed!" -ForegroundColor Green
Write-Host "=============================================" -ForegroundColor Cyan
Write-Host "Total time: $totalTimeString" -ForegroundColor Yellow
Write-Host "Templates: $copiedCount/4" -ForegroundColor $(if ($copiedCount -eq 4) { "Green" } else { "Yellow" })
Write-Host "`nEditor: $binPath" -ForegroundColor Cyan
Write-Host "Templates: $exportDir" -ForegroundColor Cyan
Write-Host "NuGet: $NugetSourcePath" -ForegroundColor Cyan
Write-Host "Log: $logFile" -ForegroundColor Cyan
Write-Log "Build completed in $totalTimeString - $copiedCount/4 templates"
pause
