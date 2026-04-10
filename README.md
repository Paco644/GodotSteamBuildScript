# Godot Engine Build Script for Windows (Mono)

Automated PowerShell script to compile Godot Engine with C# support (Mono), custom modules, and Steam integration on Windows.

## Features

- Auto-clone Godot versions from GitHub
- Custom modules management (godotsteam, etc.)
- Mono/C# support with auto glue generation
- Steam SDK integration
- DirectX 12 support
- Parallel builds
- Export templates auto-configuration
- NuGet package management
- Build history tracking (builds.json)
- Detailed logging

## Requirements

### System
- **Windows 10/11** (64-Bit)
- **PowerShell 7.0+** (NOT Windows PowerShell 5.1)
- **8GB RAM minimum** (16GB recommended)
- **50GB+ free space** per Godot version

### Required Tools
The script automatically installs via **Scoop**:

| Tool | Purpose |
|------|---------|
| **Git** | Clone Godot and modules |
| **Python 3.x** | Godot build system |
| **OpenSSL** | Encryption key generation |
| **SCons** | Godot compiler |
| **.NET SDK** | Mono assembly building |

### Optional
- **Steam SDK** (ZIP file for godotsteam module)

## Quick Start

### 1. Install PowerShell 7
```powershell
scoop install pwsh
```

### 2. Clone Repository
```bash
gh repo clone Paco644/GodotSteamBuildScript
cd godot-build-script
```

### 3. Create Configuration

#### `modules.json` (required)
```json
{
  "modules": [
    {
      "name": "godotsteam",
      "repo": "https://github.com/Gramps/GodotSteam.git",
      "branch": "main",
      "enabled_by_default": true
    }
  ]
}
```

#### Place Steam SDK (optional)
- Put Steam SDK ZIP in `sdks/` folder
- Example: `sdks/steamworks_sdk_159.zip`

### 4. Set Execution Policy
```powershell
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
```

## Usage

### Simple Start
```powershell
.\build_godot.ps1
```

The script will prompt you to:
1. Clone new version or use existing
2. Select Godot version
3. Enter build name
4. Select modules
5. Choose Steam SDK (if godotsteam enabled)

### With Parameters
```powershell
# Clone new version
.\build_godot.ps1 -CloneNewVersion -GodotBuildName "myproject"

# Custom NuGet path
.\build_godot.ps1 -NugetSourcePath "D:\MyNugetPackages"

# Custom encryption key path
.\build_godot.ps1 -EncryptionKeyPath "C:\secure\my.gdkey"
```

## Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|------------|
| `-CloneNewVersion` | Switch | `$false` | Clone new Godot version |
| `-GodotBuildName` | String | - | Build name (e.g., "skytech") |
| `-EncryptionKeyPath` | String | `"godot.gdkey"` | AES-256 encryption key path |
| `-NugetSourcePath` | String | `"C:\MyLocalNugetSource"` | Local NuGet feed path |

## Directory Structure

```
project-root/
├── build_godot.ps1           # Main script
├── modules.json              # Modules config
├── builds.json               # Build history (auto-created)
├── build_log.txt             # Build log (auto-created)
├── sdks/                      # Steam SDK ZIPs
├── custom_modules/           # Cloned modules
└── 4.4.1.skytech/            # Godot source + binaries
    └── bin/                   # Compiled EXEs
```

## Build Outputs

### Editor
```
<version-folder>/bin/
├── godot.windows.editor.x86_64.mono.exe
└── godot.windows.editor.x86_64.mono.console.exe
```

### Export Templates
```
%APPDATA%/Godot/export_templates/<version>/
├── windows_debug_x86_64.exe
├── windows_release_x86_64.exe
├── windows_debug_x86_64_console.exe
└── windows_release_x86_64_console.exe
```

### NuGet Packages
```
<NugetSourcePath>/
└── *.nupkg
```

## Troubleshooting

### Build Error "scons: *** Error 1"
```powershell
# Clean temp files
Remove-Item -Path "custom_modules" -Recurse -Force
Remove-Item -Path "temp_sdk" -Recurse -Force

# Try again
.\build_godot.ps1
```

### "Mono glue generation failed"
- Ensure sufficient RAM
- Check build_log.txt for details
- Verify editor EXE was built correctly

### "No Steam SDK ZIP found"
- Download Steam SDK from Valve partner portal
- Place ZIP in `sdks/` folder

### Module clone failed
```powershell
# Check network connection
Test-NetConnection github.com -Port 443

# Update module manually
cd custom_modules\godotsteam
git pull origin main
```

## Build History

Builds are saved in `builds.json`:
```json
{
  "4.4.1.skytech": {
    "folder": "4.4.1.skytech",
    "version": "4.4.1-stable",
    "buildName": "skytech",
    "selected_modules": ["godotsteam"],
    "created": "2024-12-15T10:30:00"
  }
}
```

Reuse existing builds without cloning again!

## License

MIT License

## Support

- [Godot Documentation](https://docs.godotengine.org/)
- [Godot GitHub Issues](https://github.com/godotengine/godot/issues)
- [Godot Discord](https://discord.gg/godotengine)
