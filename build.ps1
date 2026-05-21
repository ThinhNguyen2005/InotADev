<#
.SYNOPSIS
    Build & đóng gói 2 module: hide_devmode (Zygisk) + auto_toggle (daemon).
.DESCRIPTION
    - Yêu cầu Android NDK r25+ (qua Android Studio SDK Manager) để build hide_devmode.
    - auto_toggle thuần shell, không cần NDK.
    - Output: dist\hide_devmode.zip, dist\auto_toggle.zip
.EXAMPLE
    pwsh ./build.ps1                          # build cả 2
    pwsh ./build.ps1 -Only auto_toggle        # chỉ AutoToggle (skip native)
    pwsh ./build.ps1 -Only hide_devmode       # chỉ HideDevMode
    pwsh ./build.ps1 -BuildType Debug -ABIs arm64-v8a
#>
param(
    [ValidateSet('Debug','Release')]
    [string]$BuildType = 'Release',

    [string[]]$ABIs = @('arm64-v8a','armeabi-v7a','x86_64','x86'),

    [ValidateSet('all','hide_devmode','auto_toggle','adb_toggler')]
    [string]$Only = 'all',

    [string]$NdkPath  = $env:ANDROID_NDK_HOME,
    [int]   $ApiLevel = 26
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Force $dist | Out-Null

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
function Resolve-Tool([string]$name) {
    $cmd = Get-Command $name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $sdkRoots = @(
        "$env:LOCALAPPDATA\Android\Sdk\cmake",
        "$env:USERPROFILE\AppData\Local\Android\Sdk\cmake"
    )
    foreach ($r in $sdkRoots) {
        if (-not (Test-Path $r)) { continue }
        $latest = Get-ChildItem $r -Directory | Sort-Object Name -Descending | Select-Object -First 1
        if ($latest) {
            $exe = Join-Path $latest.FullName "bin\$name.exe"
            if (Test-Path $exe) { return $exe }
        }
    }
    return $null
}

# ZipArchive API (forward-slash entries) thay cho Compress-Archive
# (PS 5.1 Compress-Archive dùng '\' -> Magisk/KSU không đọc được).
function New-FlashableZip([string]$stageDir, [string]$outZip) {
    Remove-Item -Force $outZip -ErrorAction SilentlyContinue
    $fs = [System.IO.File]::Open($outZip, [System.IO.FileMode]::Create)
    $archive = New-Object System.IO.Compression.ZipArchive(
        $fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        $stageFull = (Resolve-Path $stageDir).Path
        Get-ChildItem -Path $stageDir -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($stageFull.Length + 1) -replace '\\','/'
            $entry = $archive.CreateEntry($rel,
                [System.IO.Compression.CompressionLevel]::Optimal)
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
}

# ----------------------------------------------------------------------------
# 1) Build hide_devmode (Zygisk module - cần NDK)
# ----------------------------------------------------------------------------
function Build-HideDevMode {
    Write-Host "`n=== Building hide_devmode ===" -ForegroundColor Magenta

    if (-not $NdkPath -or -not (Test-Path $NdkPath)) {
        $candidates = @(
            "$env:LOCALAPPDATA\Android\Sdk\ndk",
            "$env:USERPROFILE\AppData\Local\Android\Sdk\ndk"
        )
        foreach ($c in $candidates) {
            if (Test-Path $c) {
                $script:NdkPath = (Get-ChildItem $c | Sort-Object Name -Descending | Select-Object -First 1).FullName
                break
            }
        }
    }
    if (-not $NdkPath -or -not (Test-Path $NdkPath)) {
        throw "Không tìm thấy Android NDK. Đặt ANDROID_NDK_HOME hoặc -NdkPath."
    }
    Write-Host "NDK: $NdkPath" -ForegroundColor Cyan

    $cmakeExe = Resolve-Tool 'cmake'
    $ninjaExe = Resolve-Tool 'ninja'
    if (-not $cmakeExe) { throw "Không tìm thấy cmake." }
    if (-not $ninjaExe) { throw "Không tìm thấy ninja." }

    $toolchain = Join-Path $NdkPath "build\cmake\android.toolchain.cmake"
    if (-not (Test-Path $toolchain)) { throw "Không có $toolchain" }

    $modSrc = Join-Path $root 'modules\hide_devmode'
    $stage = Join-Path $root "build\stage_hide_devmode"
    $zygiskDir = Join-Path $stage "zygisk"
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Force $zygiskDir | Out-Null

    foreach ($abi in $ABIs) {
        Write-Host "==> Build $abi ($BuildType)" -ForegroundColor Green
        $bd = Join-Path $root "build\$abi"
        New-Item -ItemType Directory -Force $bd | Out-Null

        & $cmakeExe `
            -S "$root\jni" `
            -B  $bd `
            -G  "Ninja" `
            "-DCMAKE_MAKE_PROGRAM=$ninjaExe" `
            "-DCMAKE_TOOLCHAIN_FILE=$toolchain" `
            "-DANDROID_ABI=$abi" `
            "-DANDROID_PLATFORM=android-$ApiLevel" `
            "-DANDROID_STL=c++_static" `
            "-DCMAKE_BUILD_TYPE=$BuildType"
        if ($LASTEXITCODE -ne 0) { throw "cmake configure $abi thất bại" }

        & $cmakeExe --build $bd --config $BuildType --parallel
        if ($LASTEXITCODE -ne 0) { throw "build $abi thất bại" }

        # Magisk convention: arm64.so / arm.so / x86.so / x86_64.so
        $zygiskName = switch ($abi) {
            'arm64-v8a'   { 'arm64' }
            'armeabi-v7a' { 'arm' }
            'x86_64'      { 'x86_64' }
            'x86'         { 'x86' }
            default       { $abi }
        }
        $so = Join-Path $bd "libzygisk_hide_devmode.so"
        Copy-Item $so (Join-Path $zygiskDir "$zygiskName.so") -Force
        Write-Host "   produced: zygisk/$zygiskName.so" -ForegroundColor DarkGray
    }

    Copy-Item -Recurse -Force "$modSrc\*" $stage

    # Đóng gói luôn template targets.txt mặc định để service.sh seed.
    $etcDir = Join-Path $stage "system\etc\hide_devmode"
    New-Item -ItemType Directory -Force $etcDir | Out-Null
    Set-Content -Path (Join-Path $etcDir "targets.txt") -Value @"
# Mỗi dòng 1 package; '!' loại trừ; '*' áp dụng cho mọi non-system app.
*
!com.android.settings
!com.android.systemui
!com.google.android.gms
"@ -Encoding utf8

    $zip = Join-Path $dist 'hide_devmode.zip'
    New-FlashableZip -stageDir $stage -outZip $zip
    Write-Host "✔ $zip" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# 2) Build auto_toggle (shell-only, không cần NDK)
# ----------------------------------------------------------------------------
function Build-AutoToggle {
    Write-Host "`n=== Building auto_toggle ===" -ForegroundColor Magenta
    $modSrc = Join-Path $root 'modules\auto_toggle'
    if (-not (Test-Path $modSrc)) { throw "Không tìm thấy $modSrc" }

    $stage = Join-Path $root "build\stage_auto_toggle"
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue | Out-Null
    New-Item -ItemType Directory -Force $stage | Out-Null
    Copy-Item -Recurse -Force "$modSrc\*" $stage

    # Normalize line endings của shell scripts sang LF (toybox đôi khi không
    # parse CRLF đúng, đặc biệt khi gặp `'EOF'` heredoc).
    Get-ChildItem $stage -Recurse -File -Include '*.sh' | ForEach-Object {
        $content = [System.IO.File]::ReadAllText($_.FullName) -replace "`r`n","`n"
        [System.IO.File]::WriteAllText($_.FullName, $content,
            (New-Object System.Text.UTF8Encoding($false)))  # NO BOM
    }

    $zip = Join-Path $dist 'auto_toggle.zip'
    New-FlashableZip -stageDir $stage -outZip $zip
    Write-Host "✔ $zip" -ForegroundColor Green
}

# ----------------------------------------------------------------------------
# 3) Build AdbToggler.apk (Màn hình chính & Control Center Quick Tile)
# ----------------------------------------------------------------------------
function Build-AdbToggler {
    Write-Host "`n=== Building AdbToggler.apk ===" -ForegroundColor Magenta
    $adbTogglerDir = Join-Path $root 'external\adbtoggler'
    $buildScript = Join-Path $adbTogglerDir 'build_apk.ps1'
    if (-not (Test-Path $buildScript)) {
        throw "Không tìm thấy build script của AdbToggler tại $buildScript"
    }

    $oldDir = Get-Location
    try {
        Set-Location $adbTogglerDir
        & powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
    } finally {
        Set-Location $oldDir
    }
}

# ----------------------------------------------------------------------------
# Dispatch
# ----------------------------------------------------------------------------
if ($Only -eq 'all' -or $Only -eq 'hide_devmode') { Build-HideDevMode }
if ($Only -eq 'all' -or $Only -eq 'auto_toggle')  { Build-AutoToggle  }
if ($Only -eq 'all' -or $Only -eq 'adb_toggler')  { Build-AdbToggler }

Write-Host "`n--- Done ---" -ForegroundColor Green
Get-ChildItem $dist | Where-Object { $_.Extension -in '.zip', '.apk' } | Sort-Object Name | ForEach-Object {
    Write-Host ("  {0,8} bytes  {1}" -f $_.Length, $_.Name) -ForegroundColor White
}
Write-Host "`nFlash zip bằng KernelSU/APatch/Magisk Manager. Cài đặt trực tiếp file APK." -ForegroundColor Green
