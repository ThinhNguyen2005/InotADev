$ErrorActionPreference = "Stop"

# 1. Tu dong nap Cargo vao PATH
$env:Path = "$env:USERPROFILE\.cargo\bin;$env:Path"
if (-not (Get-Command cargo -ErrorAction SilentlyContinue)) {
    throw "Khong tim thay Cargo trong $env:USERPROFILE\.cargo\bin"
}

Write-Host "=== 1. Build Rust Daemon (arm64-v8a) ===" -ForegroundColor Cyan
$NdkBin = "$env:LOCALAPPDATA\Android\Sdk\ndk\28.2.13676358\toolchains\llvm\prebuilt\windows-x86_64\bin"
$env:CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER = "$NdkBin\aarch64-linux-android26-clang.cmd"
$env:CC_aarch64_linux_android = "$NdkBin\aarch64-linux-android26-clang.cmd"
$env:AR_aarch64_linux_android = "$NdkBin\llvm-ar.exe"

Push-Location "daemon-rs"
cargo build --target aarch64-linux-android --release
Pop-Location

$BinDir = "modules/auto_toggle/bin"
New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
Copy-Item "daemon-rs/target/aarch64-linux-android/release/auto_toggle_d" "$BinDir/auto_toggle_d" -Force

Write-Host "`n=== 2. Build WebUI (React + Material You) ===" -ForegroundColor Cyan
if (Test-Path "modules/auto_toggle/webui") {
    Push-Location "modules/auto_toggle/webui"
    try {
        & pnpm build
    } finally {
        Pop-Location
    }
}

Write-Host "`n=== 3. Dong goi Magisk/KSU Module (.zip) ===" -ForegroundColor Cyan
$Stage = "build/stage_auto_toggle"
Remove-Item -Recurse -Force $Stage -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

Get-ChildItem "modules/auto_toggle" -Exclude "webui" | ForEach-Object {
    Copy-Item -Recurse -Force $_.FullName (Join-Path $Stage $_.Name)
}

# Chuan hoa line endings cua tat ca script .sh sang Linux LF
Get-ChildItem $Stage -Recurse -File -Include '*.sh' | ForEach-Object {
    $raw = [System.IO.File]::ReadAllText($_.FullName) -replace "`r`n", "`n"
    [System.IO.File]::WriteAllText($_.FullName, $raw, (New-Object System.Text.UTF8Encoding($false)))
}

$DistDir = "dist"
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$ZipPath = "$DistDir/auto_toggle_v2.1.zip"
if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force }

# Dong goi zip chuan forward-slash '/' tuong thich Magisk / KernelSU / APatch
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$fs = [System.IO.File]::Open($ZipPath, [System.IO.FileMode]::Create)
$archive = New-Object System.IO.Compression.ZipArchive($fs, [System.IO.Compression.ZipArchiveMode]::Create)
try {
    $stageFull = (Resolve-Path $Stage).Path
    Get-ChildItem -Path $Stage -Recurse -File | ForEach-Object {
        $rel = $_.FullName.Substring($stageFull.Length + 1) -replace '\\', '/'
        $entry = $archive.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
        $es = $entry.Open()
        try {
            $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
            $es.Write($bytes, 0, $bytes.Length)
        } finally { $es.Dispose() }
    }
} finally {
    $archive.Dispose()
    $fs.Dispose()
}

Write-Host "`n[OK] Da tao thanh cong module: $ZipPath" -ForegroundColor Green

Write-Host "`n=== 3. Build AdbToggler Companion APK ===" -ForegroundColor Cyan
Push-Location "external/adbtoggler"
try {
    & powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
} finally {
    Pop-Location
}

Write-Host "`n=== HOAN TAT TOAN BO! ===" -ForegroundColor Green
Get-ChildItem $DistDir | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize