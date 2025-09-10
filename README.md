# GodotSteam Custom Build Script

This PowerShell script allows users to create a **custom Godot Mono editor build** with the **GodotSteam module** and C# support. It automates cloning Godot, integrating modules, building Mono glue files, and copying required SDK files.

---

## ⚙️ Prerequisites

Before running the script, ensure your system has the following installed and available in your `PATH`:

-   **Git** (for cloning repositories)
-   **SCons** (build system for Godot)
-   **Python 3** (used for Mono assemblies build)
-   **Mono/.NET SDK** (for C# support and NuGet)
-   **PowerShell 5+** (Windows 11 includes this by default)

> If the script is blocked by PowerShell execution policy, run it with:
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File build_godot_mono.ps1
> ```

---

## 📦 Steamworks SDK

You need a **Steamworks SDK ZIP** (cannot be distributed due to legal restrictions):

1.  Download from the [Steamworks Partner Site](https://partner.steamgames.com/downloads/steamworks_sdk).
2.  Create a folder named `sdks` in the same directory as the script.
3.  Place your Steamworks SDK ZIP(s) inside the `sdks` folder.

The script will automatically prompt you to select the correct SDK.

---

## 📝 Usage

1.  Open PowerShell and navigate to the script folder:
    ```powershell
    cd path\to\script
    ```
2.  Run the script:
    ```powershell
    .\build_godot_mono.ps1
    ```
3.  Follow the interactive prompts:
    * Choose whether to clone a new Godot version or use an an existing folder.
    * Select the Godot version to clone (if cloning).
    * Choose the Steamworks SDK ZIP to use.
    * Wait while the script clones modules, builds the editor, generates Mono glue files, and copies `steam_api64.dll` to the bin folder.

Once complete, your custom Godot Mono editor will be in the **bin** folder inside the source directory.

Local NuGet packages (for Mono assemblies) will be pushed to the folder specified in the script (default: `C:\MyLocalNugetSource`).

### 📂 Folder Structure Example
```
build_script_folder/
├─ build_godot_mono.ps1
├─ sdks/
│  ├─ steamworks_sdk_162.zip
├─ godot_custom_build/   # created by script after cloning Godot
│  ├─ bin/
│  │  ├─ godot.windows.editor.x86_64.mono.exe
│  │  └─ steam_api64.dll
│  └─ modules/
│     ├─ godotsteam/
│     └─ godotsteam_multiplayer_peer/
```

---

## ⚠️ Notes

* The script does not download the Steamworks SDK automatically. You must provide it locally.
* If any required tool is missing, the script will exit with instructions.
* Ensure your paths do not contain special characters (like `#`, `&`, `@`) as SCons or Git may fail.
* Logs are saved to `build_log.txt` in the script folder for troubleshooting.
* Works on Windows 11 with the above prerequisites installed.

---

## ✅ Support & Contributions

This script is intended for educational and community use. Feel free to fork and improve the script, add GUI support, or adapt it for other modules.
