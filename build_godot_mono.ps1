param (
    [switch]$CloneNewVersion,
    [string]$GodotBuildName,
    [string]$NugetSourcePath = "C:\MyLocalNugetSource"
)

$logFile = "build_log.txt"
$totalSteps = 12
$currentStep = 1

# -----------------------------
# Logging function
# -----------------------------
function Write-Log {
    param([string]$Message)
    $timestamp = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $logEntry = "$timestamp - $Message`r`n"
    Write-Host $logEntry -NoNewline
    [System.IO.File]::AppendAllText($logFile, $logEntry, [System.Text.Encoding]::UTF8)
}

# -----------------------------
# Progress display
# -----------------------------
function Show-Progress {
    param([string]$Message)
    $percentage = [math]::Round(($currentStep / $totalSteps) * 100)
    Write-Host "[$currentStep/$totalSteps] $($percentage)% - $($Message)"
}

# -----------------------------
# Run command with live output
# -----------------------------
function Run-Command {
    param(
        [string]$FilePath,
        [string]$Arguments
    )

    Write-Host "Running: $FilePath $Arguments" -ForegroundColor Cyan

    $processInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processInfo.FileName = $FilePath
    $processInfo.Arguments = $Arguments
    $processInfo.RedirectStandardOutput = $true
    $processInfo.RedirectStandardError = $true
    $processInfo.UseShellExecute = $false
    $processInfo.CreateNoWindow = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processInfo
    $process.Start() | Out-Null

    while (-not $process.StandardOutput.EndOfStream) {
        $line = $process.StandardOutput.ReadLine()
        if ($line) { Write-Host $line; Write-Log $line }
    }

    while (-not $process.StandardError.EndOfStream) {
        $line = $process.StandardError.ReadLine()
        if ($line) { Write-Host $line -ForegroundColor Red; Write-Log $line }
    }

    $process.WaitForExit()
    return $process.ExitCode
}

# -----------------------------
# Fetch Godot releases
# -----------------------------
function Get-RecentGodotReleases {
    Write-Log "Fetching recent Godot releases..."
    $apiUrl = "https://api.github.com/repos/godotengine/godot/releases"
    try {
        $releases = Invoke-RestMethod -Uri $apiUrl -ErrorAction Stop
        $releases = $releases | Where-Object { 
            $_.tag_name -and ($_.tag_name.Trim() -ne "") -and ($_.tag_name -match "\d+\.\d+(\.\d+)?-stable$") 
        }
        $releases = $releases | Sort-Object {
            [Version]($_.tag_name -replace "-stable","")
        } -Descending
        return $releases | Select-Object -First 10
    }
    catch {
        Write-Error "Failed to fetch Godot releases from GitHub."
        return @()
    }
}

# -----------------------------
# Clear old log file
# -----------------------------
if (Test-Path $logFile) { Remove-Item $logFile -Force }

# -----------------------------
# Build JSON tracking
# -----------------------------
$buildsFile = Join-Path $PSScriptRoot "builds.json"
if (-not (Test-Path $buildsFile)) {
    '{}' | Out-File $buildsFile -Encoding UTF8
    Write-Log "Created new builds.json tracking file."
}

$allBuilds = Get-Content $buildsFile | ConvertFrom-Json

# -----------------------------
# Step 1: Check for required tools
# -----------------------------
Show-Progress -Message "Checking for required tools..."
foreach ($tool in @("git", "scons", "python3", "py")) {
    if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
        Write-Error "$tool is not installed or not in PATH. Please install and try again."
        Read-Host "Press Enter to exit..."
        exit 1
    }
}
$currentStep++

$godotSourceDir = ""

# -----------------------------
# Step 2: Determine if cloning new version
# -----------------------------
Show-Progress -Message "Initializing..."

$jsonContent = Get-Content $buildsFile -Raw
if ($jsonContent.Trim() -eq '') { $jsonContent = '{}' }
$parsed = $jsonContent | ConvertFrom-Json

$allBuilds = @{}
foreach ($prop in $parsed.PSObject.Properties) {
    $allBuilds[$prop.Name] = $prop.Value
}

if (-not $CloneNewVersion) {
    Write-Host ""
    $choice = Read-Host "Do you want to clone a new version of Godot? Enter 'Y' to clone, or 'N' for existing build (Default: N)"
    if ($choice -eq 'Y' -or $choice -eq 'y') { $CloneNewVersion = $true }
}

if ($CloneNewVersion) {
    # Fetch recent Godot releases
    $releases = Get-RecentGodotReleases
    if ($releases.Count -eq 0) {
        Write-Error "No releases found. Exiting."
        Read-Host "Press Enter to exit..."
        exit 1
    }

    Write-Host ""
    Write-Host "Select a Godot version to clone (latest first):"
    for ($i = 0; $i -lt $releases.Count; $i++) {
        $tag = $releases[$i].tag_name.Trim()
        Write-Host "[$i] $tag"
    }

    $selection = Read-Host "Enter the number corresponding to the version"
    if ($selection -lt 0 -or $selection -ge $releases.Count) {
        Write-Error "Invalid selection. Exiting."
        Read-Host "Press Enter to exit..."
        exit 1
    }

    $GodotBranchName = $releases[$selection].tag_name.Trim()
    Write-Log "Selected Godot version: $GodotBranchName"

    if (-not $GodotBuildName) {
        $GodotBuildName = Read-Host "Enter a name for your new build (e.g., skytech)"
        if (-not $GodotBuildName) {
            Write-Error "A build name is required. Exiting."
            Read-Host "Press Enter to exit..."
            exit 1
        }
    }

    $versionMatch = [regex]::Match($GodotBranchName, "(\d+\.\d+(\.\d+)?)")
    if (-not $versionMatch.Success) {
        Write-Error "Could not parse Godot version from branch name '$GodotBranchName'."
        exit 1
    }
    $versionNumber = $versionMatch.Groups[1].Value

    $folderName = "$versionNumber.$GodotBuildName.mono"
    $godotSourceDir = Join-Path $PSScriptRoot $folderName
    $VersionStatus = $GodotBuildName
    Write-Host "Your new Godot source folder will be: '$godotSourceDir'"

    $allBuilds[$folderName] = @{
        folder = $folderName
        version = $GodotBranchName
        buildName = $GodotBuildName
        created = (Get-Date).ToString("o")
    }
    $allBuilds | ConvertTo-Json -Depth 3 | Set-Content $buildsFile
    Write-Log "Build tracked automatically in builds.json."
}
else {
    # Selecting existing folder
    $existingGodotFolders = Get-ChildItem -Path $PSScriptRoot -Directory | Where-Object { $_.Name -like "*.*.mono" -or $_.Name -eq "godot" }
    if ($existingGodotFolders.Count -eq 0) {
        Write-Error "No existing Godot folders found. Please run the script with -CloneNewVersion."
        Read-Host "Press Enter to exit..."
        exit 1
    }

    Write-Host ""
    Write-Host "Please select a Godot build folder:"
    for ($i = 0; $i -lt $existingGodotFolders.Count; $i++) {
        $folderName = $existingGodotFolders[$i].Name
        if ($allBuilds.ContainsKey($folderName)) {
            $info = $allBuilds[$folderName]
            Write-Host "[$i] $folderName (Version: $($info.version), Build: $($info.buildName))"
        } else {
            Write-Host "[$i] $folderName (Version: unknown)"
        }
    }

    $selection = Read-Host "Enter the number corresponding to the folder"
    $selectedFolder = $existingGodotFolders[$selection].Name
    $godotSourceDir = Join-Path $PSScriptRoot $selectedFolder

    if ($allBuilds.ContainsKey($selectedFolder)) {
        $GodotBranchName = $allBuilds[$selectedFolder].version
        $GodotBuildName = $allBuilds[$selectedFolder].buildName
        Write-Host "Using tracked build info: Version $GodotBranchName, Build $GodotBuildName"
    } else {
        $GodotBranchName = Read-Host "Enter the Godot version of this build (e.g., 4.4.1-stable)"
        $GodotBuildName = Read-Host "Enter the build name for this Godot folder"

        $allBuilds[$selectedFolder] = @{
            folder = $selectedFolder
            version = $GodotBranchName
            buildName = $GodotBuildName
            created = (Get-Date).ToString("o")
        }
        $allBuilds | ConvertTo-Json -Depth 3 | Set-Content $buildsFile
        Write-Host "Build tracked in builds.json."
    }

    $VersionStatus = $GodotBuildName
}

$currentStep++

# -----------------------------
# Step 3: Clone repos & prepare SDK
# -----------------------------
# -----------------------------
# Step 3: Clone repos if needed
# -----------------------------
if ($CloneNewVersion) {

    # 1. Choose Steamworks SDK from local folder
    $sdkFolder = Join-Path $PSScriptRoot "sdks"
    if (-not (Test-Path $sdkFolder)) {
        Write-Host "SDK folder not found. Creating $sdkFolder..."
        New-Item -ItemType Directory -Path $sdkFolder | Out-Null
    }

    $availableSDKs = Get-ChildItem -Path $sdkFolder -Filter "*.zip"

    if ($availableSDKs.Count -eq 0) {
        Write-Error "No Steamworks SDK ZIPs found in $sdkFolder. Please add SDKs before continuing."
        exit 1
    }

    # If only one SDK, select automatically
    if ($availableSDKs.Count -eq 1) {
        $chosenSDK = $availableSDKs[0].Name
        Write-Host "Only one SDK found. Using: $chosenSDK"
    } else {
        Write-Host "Available Steamworks SDK versions:"
        for ($i = 0; $i -lt $availableSDKs.Count; $i++) {
            Write-Host "[$i] $($availableSDKs[$i].Name)"
        }

        $selection = Read-Host "Enter the number of the Steamworks SDK version you want to use"
        if ($selection -match '^\d+$' -and $selection -ge 0 -and $selection -lt $availableSDKs.Count) {
            $chosenSDK = $availableSDKs[$selection].Name
        } else {
            Write-Error "Invalid selection. Exiting."
            exit 1
        }
    }

    Write-Log "Chosen Steamworks SDK: $chosenSDK"
    $zipPath = Join-Path $sdkFolder $chosenSDK

    # 2. Clone Godot repo using already selected branch
    Show-Progress -Message "Cloning Godot..."
    Write-Log "Starting full setup for Godot branch '$GodotBranchName'..."
    if (Test-Path $godotSourceDir) { Remove-Item -Path $godotSourceDir -Recurse -Force }

    $exitCode = Run-Command "git" "clone -b $GodotBranchName https://github.com/godotengine/godot.git $godotSourceDir"
    if ($exitCode -ne 0) { Write-Error "Git clone failed."; exit 1 }
    $currentStep++

    # 3. Clone GodotSteam modules
    Show-Progress -Message "Cloning GodotSteam modules..."
    $modulesPath = Join-Path $godotSourceDir "modules"
    if (-not (Test-Path $modulesPath)) { New-Item -ItemType Directory -Path $modulesPath | Out-Null }

    Run-Command "git" "clone -b godot4 https://codeberg.org/godotsteam/godotsteam.git `"$modulesPath\godotsteam`""
    Run-Command "git" "clone -b main https://codeberg.org/godotsteam/multiplayerpeer.git `"$modulesPath\godotsteam_multiplayer_peer`""
    $currentStep++

    # 4. Prepare Steamworks SDK
    Show-Progress -Message "Preparing Steamworks SDK..."
    $tempDir = Join-Path $PSScriptRoot "temp_sdk"
    if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    if (-not (Test-Path $zipPath)) {
        Write-Error "Chosen SDK ZIP not found at $zipPath. Cannot continue."
        exit 1
    }

    try {
        # Expand the SDK archive
        Expand-Archive -Path $zipPath -DestinationPath $tempDir -Force -ErrorAction Stop
        Write-Log "Steamworks SDK archive expanded successfully."

        # Prepare target SDK folder
        $sdkTarget = Join-Path $godotSourceDir "modules\godotsteam\sdk"
        if (-not (Test-Path $sdkTarget)) { New-Item -ItemType Directory -Path $sdkTarget | Out-Null }

        # Copy public folder
        $publicSrc = Join-Path $tempDir "sdk\public"
        $publicDest = Join-Path $sdkTarget "public"
        Copy-Item -Path $publicSrc -Destination $publicDest -Recurse -Force

        # Copy redistributable_bin folder
        $redistSrc = Join-Path $tempDir "sdk\redistributable_bin"
        $redistDest = Join-Path $sdkTarget "redistributable_bin"
        Copy-Item -Path $redistSrc -Destination $redistDest -Recurse -Force

        Write-Log "Steamworks SDK files copied to Godot modules."
    }
    catch {
        Write-Error "Failed to extract or copy Steamworks SDK: $_"
        exit 1
    }
    finally {
        if (Test-Path $tempDir) { Remove-Item -Path $tempDir -Recurse -Force }
    }
} else {
    Write-Log "Skipping cloning. Using existing Steamworks SDK if available."
}
$currentStep++

# -----------------------------
# Step 4: Initialize Visual Studio solution
# -----------------------------
Show-Progress -Message "Initializing Visual Studio solution..."
$exitCode = Run-Command "scons" "-C $godotSourceDir platform=windows vsproj=yes"
if ($exitCode -ne 0) { Write-Error "Failed to initialize Visual Studio solution."; exit 1 }
$currentStep++

# -----------------------------
# Step 5: Build temporary editor binary
# -----------------------------
Show-Progress -Message "Building temporary editor binary..."
$binPath = Join-Path $godotSourceDir "bin"
$env:GODOT_VERSION_STATUS = $VersionStatus
$exitCode = Run-Command "scons" "-C $godotSourceDir p=windows tools=yes module_mono_enabled=yes mono_glue=no GODOT_VERSION_STATUS=$VersionStatus"
if ($exitCode -ne 0) { Write-Error "SCons build failed."; exit 1 }
$currentStep++

# -----------------------------
# Step 6b: Copy Steam API DLL into bin before final build
# -----------------------------
Show-Progress -Message "Copying steam_api64.dll into bin for final build..."
$steamDllSource = Join-Path $godotSourceDir "modules\godotsteam\sdk\redistributable_bin\win64\steam_api64.dll"
$steamDllDestination = Join-Path $binPath "steam_api64.dll"
if (Test-Path $steamDllSource) {
    Copy-Item -Path $steamDllSource -Destination $steamDllDestination -Force
    Write-Log "steam_api64.dll copied to bin for final build."
} else {
    Write-Log "steam_api64.dll not found at $steamDllSource. Skipping copy."
}
$currentStep++

# -----------------------------
# Step 6: Generate Mono glue files
# -----------------------------
Show-Progress -Message "Generating Mono glue files..."
$gluePath = Join-Path $godotSourceDir "modules\mono\glue"
$glueCommand = Join-Path $binPath "godot.windows.editor.x86_64.mono.exe"
$glueArgs = "--headless --generate-mono-glue `"$gluePath`""
$process = Start-Process -FilePath $glueCommand -ArgumentList $glueArgs -WorkingDirectory $godotSourceDir -NoNewWindow -Wait -PassThru
if ($process.ExitCode -ne 0) { Write-Error "Mono glue generation failed. Exit code: $($process.ExitCode)"; exit 1 }
$currentStep++


# -----------------------------
# Step 7: Build final editor binary
# -----------------------------
Show-Progress -Message "Building final editor binary..."
$exitCode = Run-Command "scons" "-C $godotSourceDir p=windows target=editor tools=yes module_mono_enabled=yes GODOT_VERSION_STATUS=$VersionStatus"
if ($exitCode -ne 0) { Write-Error "Final SCons build failed."; exit 1 }
$currentStep++

# -----------------------------
# Step 8: Build Windows export templates
# -----------------------------
Show-Progress -Message "Building Windows export templates..."
$exitCode = Run-Command "scons" "-C $godotSourceDir platform=windows target=template_debug module_mono_enabled=yes"
if ($exitCode -ne 0) { Write-Error "Debug export template build failed."; exit 1 }

$exitCode = Run-Command "scons" "-C $godotSourceDir platform=windows target=template_release module_mono_enabled=yes"
if ($exitCode -ne 0) { Write-Error "Release export template build failed."; exit 1 }
$currentStep++

# -----------------------------
# Step 9: Install export templates and cleanup
# -----------------------------
Show-Progress -Message "Installing export templates and cleaning up..."

$versionMatch = [regex]::Match($GodotBranchName, "(\d+\.\d+\.\d+)")
$versionNumber = $versionMatch.Groups[1].Value
$exportVersion = "$versionNumber.$GodotBuildName.mono"
$exportDir = Join-Path $env:APPDATA "Godot\export_templates\$exportVersion"
if (-not (Test-Path $exportDir)) { New-Item -ItemType Directory -Path $exportDir -Force | Out-Null }

# Define templates
$templates = @(
    @{ Src="godot.windows.template_debug.x86_64.mono.exe"; Dest="windows_debug_x86_64.exe" },
    @{ Src="godot.windows.template_release.x86_64.mono.exe"; Dest="windows_release_x86_64.exe" },
    @{ Src="godot.windows.template_debug.x86_64.mono.console.exe"; Dest="windows_debug_x86_64_console.exe" },
    @{ Src="godot.windows.template_release.x86_64.mono.console.exe"; Dest="windows_release_x86_64_console.exe" }
)

foreach ($t in $templates) {
    $srcPath = Join-Path $binPath $t.Src
    $destPath = Join-Path $exportDir $t.Dest

    if (Test-Path $srcPath) {
        Copy-Item -Path $srcPath -Destination $destPath -Force
        Write-Host "Copied $($t.Src) -> $($t.Dest)"
    } else {
        Write-Warning "Template not found: $($t.Src), skipping..."
    }
}

# Delete old build artifacts
$patternsToDelete = @(
    "godot.windows.template_debug.x86_64.mono*",
    "godot.windows.template_release.x86_64.mono*"
)
foreach ($pattern in $patternsToDelete) {
    Get-ChildItem -Path $binPath -Filter $pattern -File -ErrorAction SilentlyContinue | Remove-Item -Force
}

$currentStep++

# -----------------------------
# Step 10: Add local NuGet source
# -----------------------------
Show-Progress -Message "Adding local NuGet source..."
if (-not (Test-Path $NugetSourcePath)) { New-Item -ItemType Directory -Path $NugetSourcePath | Out-Null }
Run-Command "dotnet" "nuget add source $NugetSourcePath --name MyLocalNugetSource"
$currentStep++

# -----------------------------
# Step 11: Build and push assemblies
# -----------------------------
Show-Progress -Message "Building and pushing Mono assemblies..."
$pyScript = Join-Path $godotSourceDir "modules\mono\build_scripts\build_assemblies.py"
$exitCode = Run-Command "py" "$pyScript --godot-output-dir $binPath --push-nupkgs-local $NugetSourcePath"
if ($exitCode -ne 0) { Write-Error "Mono assemblies build failed."; exit 1 }
$currentStep++

# -----------------------------
# Step 12: Copy Steam API DLL
# -----------------------------
Show-Progress -Message "Copying steam_api64.dll..."
$steamDllSource = Join-Path $godotSourceDir "modules\godotsteam\sdk\redistributable_bin\win64\steam_api64.dll"
$steamDllDestination = Join-Path $binPath "steam_api64.dll"
if (Test-Path $steamDllSource) { Copy-Item $steamDllSource -Destination $steamDllDestination -Force }
$currentStep++

# -----------------------------
# Step 13: Build Complete
# -----------------------------
Show-Progress -Message "Build Complete!"
Write-Host ""
Write-Host "--------------------------------------------------------"
Write-Host "Script finished. Your custom Godot Mono editor is ready in '$binPath'."
Write-Host "NuGet packages pushed to: $NugetSourcePath"
Write-Host "Export templates installed in: $exportDir"
Write-Host "--------------------------------------------------------"
Write-Host "See '$logFile' for detailed output."
Read-Host -Prompt "Press Enter to exit..."
