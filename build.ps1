<#
.SYNOPSIS
    Build & đóng gói module Zygisk HideDevMode cho 4 ABI.
.DESCRIPTION
    - Yêu cầu cài Android NDK r25+ (qua Android Studio SDK Manager là tốt nhất).
    - Yêu cầu Dobby ở external\Dobby (xem README.md).
    - Output: dist\hide_devmode.zip - flash bằng Magisk Manager / KernelSU Manager.

.EXAMPLE
    pwsh ./build.ps1
    pwsh ./build.ps1 -BuildType Debug -ABIs arm64-v8a
#>
param(
    [ValidateSet('Debug','Release')]
    [string]$BuildType = 'Release',

    [string[]]$ABIs = @('arm64-v8a','armeabi-v7a','x86_64','x86'),

    [string]$NdkPath  = $env:ANDROID_NDK_HOME,
    [int]   $ApiLevel = 26    # Zygisk yêu cầu API 26+ (Android 8.0)
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

# ---- Sanity checks ----------------------------------------------------------
if (-not $NdkPath -or -not (Test-Path $NdkPath)) {
    # thử path mặc định của Android Studio trên Windows
    $candidates = @(
        "$env:LOCALAPPDATA\Android\Sdk\ndk",
        "$env:USERPROFILE\AppData\Local\Android\Sdk\ndk"
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) {
            $NdkPath = (Get-ChildItem $c | Sort-Object Name -Descending | Select-Object -First 1).FullName
            break
        }
    }
}
if (-not $NdkPath -or -not (Test-Path $NdkPath)) {
    throw "Không tìm thấy Android NDK. Đặt biến môi trường ANDROID_NDK_HOME hoặc truyền -NdkPath."
}
Write-Host "Sử dụng NDK: $NdkPath" -ForegroundColor Cyan

if (-not (Test-Path "$root\external\Dobby\CMakeLists.txt")) {
    Write-Host "Đang clone Dobby..." -ForegroundColor Yellow
    & git clone --depth=1 https://github.com/asLody/Dobby "$root\external\Dobby"
    if ($LASTEXITCODE -ne 0) { throw "git clone Dobby thất bại" }
}

$toolchain = Join-Path $NdkPath "build\cmake\android.toolchain.cmake"
if (-not (Test-Path $toolchain)) { throw "Không tìm thấy android.toolchain.cmake tại $toolchain" }

# ---- Build từng ABI ---------------------------------------------------------
$stage = Join-Path $root "build\stage"
$zygiskDir = Join-Path $stage "zygisk"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue | Out-Null
New-Item -ItemType Directory -Force $zygiskDir | Out-Null

foreach ($abi in $ABIs) {
    Write-Host "==> Build $abi ($BuildType)" -ForegroundColor Green
    $bd = Join-Path $root "build\$abi"
    New-Item -ItemType Directory -Force $bd | Out-Null

    & cmake `
        -S "$root\jni" `
        -B  $bd `
        -G  "Ninja" `
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" `
        -DANDROID_ABI=$abi `
        -DANDROID_PLATFORM="android-$ApiLevel" `
        -DANDROID_STL=c++_static `
        -DCMAKE_BUILD_TYPE=$BuildType
    if ($LASTEXITCODE -ne 0) { throw "cmake configure $abi thất bại" }

    & cmake --build $bd --config $BuildType --parallel
    if ($LASTEXITCODE -ne 0) { throw "build $abi thất bại" }

    $so = Join-Path $bd "libzygisk_hide_devmode.so"
    Copy-Item $so (Join-Path $zygiskDir "$abi.so") -Force
    Write-Host "   produced: $abi.so" -ForegroundColor DarkGray
}

# ---- Lắp ráp module ---------------------------------------------------------
Copy-Item -Recurse -Force "$root\module\*" $stage
# /system/etc layout đã có sẵn từ customize.sh? customize.sh tạo file ở runtime,
# nhưng ta cũng sẵn sàng đóng gói luôn để giảm bước cài đặt.
$etcDir = Join-Path $stage "system\etc\hide_devmode"
New-Item -ItemType Directory -Force $etcDir | Out-Null
Set-Content -Path (Join-Path $etcDir "targets.txt") -Value @"
# Mỗi dòng là 1 package cần ẩn Developer/Debug.
# '#' là comment, '!' loại trừ, '*' áp dụng cho mọi non-system app.
*
!com.android.settings
!com.android.systemui
!com.google.android.gms
"@ -Encoding utf8

# ---- Đóng zip flashable -----------------------------------------------------
$dist = Join-Path $root "dist"
New-Item -ItemType Directory -Force $dist | Out-Null
$zip = Join-Path $dist "hide_devmode.zip"
Remove-Item -Force $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip -CompressionLevel Optimal

Write-Host "`n✔ Hoàn tất: $zip" -ForegroundColor Green
Write-Host "Flash bằng Magisk Manager hoặc KernelSU Manager." -ForegroundColor Green
