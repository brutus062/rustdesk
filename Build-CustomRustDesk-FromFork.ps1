<#
.SYNOPSIS
    Automated build and packaging script for a bespoke, locked-down RustDesk client
    built directly from a personal GitHub fork.
    Version: v2.2.0
.DESCRIPTION
    Clones the specified GitHub repository and submodules into an isolated workspace,
    substitutes private security tokens into the placeholder-tagged files:
    - __SERVER_HOST__
    - __SERVER_KEY__
    - __ADMIN_PASSWORD__
    - __SUPPORT_CLIENT_ID__
    
    Executes the complete Flutter/Rust compilation and produces a single-file portable executable.
.NOTES
    Compatible with PowerShell 7.0 and newer.
    
    Example Usage:
    ./Build-CustomRustDesk-FromFork.ps1 `
        -ServerHost "xxx.xxx.xxx.xxx_or.domain" `
        -ServerKey "your_server_public_key_here=" `
        -AdminPassword "YourAdminUnlockPassword" `
        -SupportClientID "123456789" `
        -RepoUrl "https://github.com/brutus062/rustdesk.git" `
        -TargetBranch "master" `
        -ProjectRoot "C:\projects\rustdesk_custom" `
        -OutputDirectory "C:\dist_custom" `
        -OutputFilename "RustDesk-Support.exe"
#>

#Requires -Version 7.0
[CmdletBinding()]
param (
    # =========================================================================
    # User-Configurable Parameters (Supplied entirely via CLI, no defaults)
    # =========================================================================
    [Parameter(Mandatory = $true, HelpMessage = "Private Rendezvous/Relay server IP or FQDN")]
    [string]$ServerHost,

    [Parameter(Mandatory = $true, HelpMessage = "Server public encryption key")]
    [string]$ServerKey,

    [Parameter(Mandatory = $true, HelpMessage = "Client settings unlock and admin password")]
    [string]$AdminPassword,

    [Parameter(Mandatory = $true, HelpMessage = "Technician / Support console RustDesk ID")]
    [string]$SupportClientID,

    [Parameter(Mandatory = $true, HelpMessage = "Git repository URL to clone")]
    [string]$RepoUrl,

    [Parameter(Mandatory = $true, HelpMessage = "Target Git branch to build")]
    [string]$TargetBranch,

    [Parameter(Mandatory = $true, HelpMessage = "Destination directory for cloning and compilation")]
    [string]$ProjectRoot,

    [Parameter(Mandatory = $true, HelpMessage = "Destination directory for the finished artifact")]
    [string]$OutputDirectory,

    [Parameter(Mandatory = $true, HelpMessage = "Output binary filename")]
    [string]$OutputFilename,

    [Parameter(Mandatory = $false, HelpMessage = "Run without interactive confirmation checkpoints")]
    [switch]$NonInteractive
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$ScriptVersion = "v2.1.0"

# Sanitise Client ID: strip all whitespace so network matching never fails
$SupportClientID = $SupportClientID -replace '\s+', ''

# ---------------------------------------------------------------------------
# Logging and Flow-Control Functions
# ---------------------------------------------------------------------------
function Write-Step {
    param ([string]$Message)
    Write-Host "`n[+] $Message" -ForegroundColor Cyan
}

function Write-Success {
    param ([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function Pause-Step {
    param ([string]$PromptMessage = "Press any key to continue...")

    if (-not $NonInteractive) {
        Write-Host "`n>>> CHECKPOINT: $PromptMessage" -ForegroundColor Yellow
        Write-Host "Auto-resuming in 5 seconds unless a key is pressed..." -ForegroundColor Cyan

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $keyPressed = $false
        $resumed = $false

        while ($sw.ElapsedMilliseconds -lt 5000) {
            if ([System.Console]::KeyAvailable) {
                [void][System.Console]::ReadKey($true)
                $keyPressed = $true
                break
            }
            Start-Sleep -Milliseconds 50
        }

        $sw.Stop()

        if (-not $keyPressed) {
            Write-Host "No key pressed. Auto-resuming now..." -ForegroundColor Green
            return
        }

        Write-Host "`nPaused. Type R and press ENTER to resume." -ForegroundColor Yellow

        while (-not $resumed) {
            $inputText = Read-Host

            if ($inputText -ceq "R") {
                $resumed = $true
            }
            else {
                Write-Host "Still paused. Type R and press ENTER to resume." -ForegroundColor Yellow
            }
        }

        Write-Host "Resuming now..." -ForegroundColor Green
    }
}

# ---------------------------------------------------------------------------
# 0. Startup Banner
# ---------------------------------------------------------------------------
Write-Host "========================================================" -ForegroundColor Magenta
Write-Host " RustDesk Portable Builder Script ($ScriptVersion)" -ForegroundColor Magenta
Write-Host "========================================================" -ForegroundColor Magenta

# ---------------------------------------------------------------------------
# 1. Base Environment and Toolchain Validation
# ---------------------------------------------------------------------------
Write-Step "Validating foundational dependencies and toolchain..."

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    throw "Windows Package Manager (winget) is required but was not found."
}

function Ensure-WingetPackage {
    param (
        [string]$CommandName,
        [string]$PackageId,
        [string]$CustomArgs = ""
    )
    if (-not (Get-Command $CommandName -ErrorAction SilentlyContinue)) {
        Write-Host "Installing $PackageId via winget..." -ForegroundColor Yellow
        if ($CustomArgs) {
            winget install --id $PackageId --silent --override $CustomArgs
        } else {
            winget install --id $PackageId -e --source winget --silent --accept-source-agreements --accept-package-agreements
        }
    } else {
        Write-Success "$CommandName is already installed."
    }
}

Ensure-WingetPackage -CommandName "git" -PackageId "Git.Git"
Ensure-WingetPackage -CommandName "python" -PackageId "Python.Python.3.12" -CustomArgs "InstallAllUsers=1 PrependPath=1 Include_test=0"
Ensure-WingetPackage -CommandName "rustup" -PackageId "Rustlang.Rustup"
Ensure-WingetPackage -CommandName "clang" -PackageId "LLVM.LLVM"

$vsPath = "C:\Program Files\Microsoft Visual Studio\2022\Community"
if (-not (Test-Path $vsPath)) {
    Write-Host "Installing Visual Studio 2022 C++ Build Tools..." -ForegroundColor Yellow
    winget install --id Microsoft.VisualStudio.2022.Community --silent --override "--wait --quiet --add Microsoft.VisualStudio.Workload.NativeDesktop --includeRecommended"
} else {
    Write-Success "Visual Studio 2022 installation detected."
}

# Ensure persistent and session environment variables
$env:LIBCLANG_PATH = "C:\Program Files\LLVM\bin"
$env:VCPKG_ROOT = "C:\vcpkg"
$cargoBin = "$HOME\.cargo\bin"
$machinePath = [System.Environment]::GetEnvironmentVariable('Path', 'Machine')
$userPath = [System.Environment]::GetEnvironmentVariable('Path', 'User')

$env:PATH = "$machinePath;$userPath;$cargoBin;C:\flutter\bin;C:\vcpkg;C:\Program Files\LLVM\bin"

# ---------------------------------------------------------------------------
# 2. Vcpkg and Codec Dependencies
# ---------------------------------------------------------------------------
Write-Step "Verifying vcpkg and codec dependencies..."

if (-not (Test-Path "C:\vcpkg")) {
    git clone https://github.com/microsoft/vcpkg.git C:\vcpkg
    & "C:\vcpkg\bootstrap-vcpkg.bat"
}

$requiredLibs = @("libvpx:x64-windows-static", "libyuv:x64-windows-static", "opus:x64-windows-static", "aom:x64-windows-static")
foreach ($lib in $requiredLibs) {
    & "C:\vcpkg\vcpkg.exe" install $lib
}
Write-Success "All native codec libraries compiled and ready."

# ---------------------------------------------------------------------------
# 3. Flutter SDK Setup (Pinned to 3.24.5)
# ---------------------------------------------------------------------------
Write-Step "Verifying Flutter SDK..."

if (-not (Test-Path "C:\flutter")) {
    git clone -b 3.24.5 https://github.com/flutter/flutter.git C:\flutter
} else {
    Push-Location "C:\flutter"
    git checkout 3.24.5
    Pop-Location
}
& "flutter.bat" config --enable-windows-desktop | Out-Null
& "python" -m pip install --upgrade brotli | Out-Null

& "rustup" default stable-x86_64-pc-windows-msvc | Out-Null
& "cargo" install flutter_rust_bridge_codegen --version 1.80.1 --features "uuid" | Out-Null

# ---------------------------------------------------------------------------
# 4. Isolated Fork Repository Initialisation
# ---------------------------------------------------------------------------
Write-Step "Initialising custom fork workspace at $ProjectRoot..."

if (-not (Test-Path $ProjectRoot)) {
    Write-Host "Cloning repository from $RepoUrl..." -ForegroundColor Yellow
    git clone --recurse-submodules -b $TargetBranch $RepoUrl $ProjectRoot
}

Push-Location $ProjectRoot
git fetch --all
git checkout -f $TargetBranch
git submodule sync --recursive
git submodule update --init --recursive --force
Write-Success "Repository cleanly initialised."

Pause-Step "Workspace verified. Press any key to substitute private tokens..."

# ---------------------------------------------------------------------------
# 5. Injecting Private Variables into Placeholder Files
# ---------------------------------------------------------------------------
Write-Step "Injecting private configuration into placeholders..."

function Replace-PlaceholderInFile {
    param (
        [string]$RelativeFilePath,
        [hashtable]$TokenMap
    )

    $fullPath = Join-Path $ProjectRoot $RelativeFilePath
    if (-not (Test-Path $fullPath)) {
        throw "Target file for substitution not found: $fullPath"
    }

    $fileContent = [System.IO.File]::ReadAllText($fullPath, [System.Text.Encoding]::UTF8)
    
    foreach ($token in $TokenMap.Keys) {
        $replacementValue = $TokenMap[$token]
        $fileContent = $fileContent.Replace($token, $replacementValue)
    }

    [System.IO.File]::WriteAllText($fullPath, $fileContent, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "Injected values into: $RelativeFilePath" -ForegroundColor Green
}

$replacementTokens = @{
    "__SERVER_HOST__"        = $ServerHost
    "__SERVER_KEY__"         = $ServerKey
    "__ADMIN_PASSWORD__"     = $AdminPassword
    "__SUPPORT_CLIENT_ID__"  = $SupportClientID
}

# The four files containing our custom placeholders
Replace-PlaceholderInFile -RelativeFilePath "libs\hbb_common\src\config.rs" -TokenMap $replacementTokens
Replace-PlaceholderInFile -RelativeFilePath "flutter\lib\mobile\widgets\dialog.dart" -TokenMap $replacementTokens
Replace-PlaceholderInFile -RelativeFilePath "flutter\lib\desktop\pages\desktop_setting_page.dart" -TokenMap $replacementTokens
Replace-PlaceholderInFile -RelativeFilePath "src\server\connection.rs" -TokenMap $replacementTokens

Write-Success "All security tokens successfully substituted."

# Display Git diff summary to verify injection
Write-Host "`n--- MODIFIED WORKSPACE STATUS ---" -ForegroundColor Magenta
git status --short
Write-Host "---------------------------------" -ForegroundColor Magenta

Pause-Step "Placeholders substituted. Press any key to start the compilation pipeline..."

# ---------------------------------------------------------------------------
# 6. Compilation Pipeline
# ---------------------------------------------------------------------------
Write-Step "Resolving Flutter dependencies..."
Push-Location "$ProjectRoot\flutter"
& "flutter.bat" pub get
Pop-Location

Write-Step "Executing Flutter bridge codegen..."
& "$HOME\.cargo\bin\flutter_rust_bridge_codegen.exe" --rust-input .\src\flutter_ffi.rs --dart-output .\flutter\lib\generated_bridge.dart

Pause-Step "Bridge generated. Press any key to begin Rust core compilation..."

Write-Step "Compiling Rust core dynamic library..."
& "cargo" build --release --lib --features "flutter"

Pause-Step "Rust dynamic library compiled successfully. Press any key to build Windows Release bundle..."

Write-Step "Compiling Flutter Windows Release bundle..."
Push-Location "$ProjectRoot\flutter"
& "flutter.bat" build windows --release
Pop-Location

# ---------------------------------------------------------------------------
# 7. Standalone Packaging
# ---------------------------------------------------------------------------
Pause-Step "Windows executable created. Press any key to pack into a single standalone .exe..."

Write-Step "Packaging all assets and dynamic libraries into portable executable..."

$releaseDir = Join-Path $ProjectRoot "flutter\build\windows\x64\runner\Release"
Push-Location "$ProjectRoot\libs\portable"
& "python" ./generate.py -f $releaseDir -o . -e "$releaseDir\rustdesk.exe"
Pop-Location

if (-not (Test-Path $OutputDirectory)) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}

$packedExe = Join-Path $ProjectRoot "target\release\rustdesk-portable-packer.exe"
$finalArtifact = Join-Path $OutputDirectory $OutputFilename

Copy-Item -Path $packedExe -Destination $finalArtifact -Force
Pop-Location

Write-Step "Build process completed successfully!"
Write-Success "Bespoke portable client created at: $finalArtifact"