# build_apk.ps1
# Builds AdbToggler v2.0 APK using Android SDK command-line tools.
# Auto-detects SDK location, build-tools, and platform versions.
$ErrorActionPreference = "Stop"

# ── SDK Auto-Detect ─────────────────────────────────────────────────────────────
function Get-AndroidSdkPath {
    $candidates = @(
        $env:ANDROID_HOME,
        $env:ANDROID_SDK_ROOT,
        "$env:LOCALAPPDATA\Android\Sdk",
        "$env:USERPROFILE\AppData\Local\Android\Sdk",
        "C:\Android\Sdk",
        "D:\Android\Sdk"
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path "$c\platforms")) { return $c }
    }
    return $null
}

$sdkPath = Get-AndroidSdkPath
if (-not $sdkPath) {
    Write-Error "Android SDK not found. Set ANDROID_HOME or ANDROID_SDK_ROOT."
}

# ── Build Tools ────────────────────────────────────────────────────────────────
$buildToolsDirs = Get-ChildItem -Path "$sdkPath\build-tools" -Directory | Sort-Object Name -Descending
if ($buildToolsDirs.Count -eq 0) {
    Write-Error "No build-tools found in $sdkPath\build-tools"
}
$buildToolsVersion = $buildToolsDirs[0].Name
$buildToolsPath = $buildToolsDirs[0].FullName

# ── Platform ──────────────────────────────────────────────────────────────────
$platformDirs = Get-ChildItem -Path "$sdkPath\platforms" -Directory | Sort-Object Name -Descending
if ($platformDirs.Count -eq 0) {
    Write-Error "No platforms found in $sdkPath\platforms"
}
$platformPath = $platformDirs[0].FullName
$androidJar = "$platformPath\android.jar"
$compileSdk = $platformDirs[0].Name -replace 'android-', ''

# ── Tools ──────────────────────────────────────────────────────────────────────
$aapt2 = Join-Path $buildToolsPath "aapt2.exe"
$d8 = Join-Path $buildToolsPath "d8.bat"
$zipalign = Join-Path $buildToolsPath "zipalign.exe"
$apksigner = Join-Path $buildToolsPath "apksigner.bat"

foreach ($tool in @($aapt2, $d8, $zipalign, $apksigner)) {
    if (-not (Test-Path $tool)) {
        Write-Error "Required tool not found: $tool"
    }
}

# ── Build Paths ───────────────────────────────────────────────────────────────
$scriptDir = $PSScriptRoot
$projectDir = Split-Path -Parent $scriptDir
$rootDir = Split-Path -Parent $projectDir
$distDir = Join-Path $rootDir "dist"

$buildDir = Join-Path $scriptDir "build"
$genDir = Join-Path $buildDir "gen"
$objDir = Join-Path $buildDir "obj"
$dexDir = Join-Path $buildDir "dex"
$compiledResZip = Join-Path $buildDir "compiled_res.zip"
$unsignedApk = Join-Path $buildDir "unsigned.apk"
$alignedApk = Join-Path $buildDir "aligned.apk"
$finalApk = Join-Path $distDir "AdbToggler.apk"

if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir -Force | Out-Null
}

Write-Host "=== AdbToggler v2.0 Build ===" -ForegroundColor Magenta
Write-Host "SDK:        $sdkPath"
Write-Host "BuildTools: $buildToolsVersion"
Write-Host "Platform:   $($platformDirs[0].Name) (compileSdk $compileSdk)"
Write-Host "Output:    $finalApk"

# ── Clean ─────────────────────────────────────────────────────────────────────
if (Test-Path $buildDir) {
    Remove-Item -Path $buildDir -Recurse -Force
}
New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
New-Item -ItemType Directory -Path $genDir -Force | Out-Null
New-Item -ItemType Directory -Path $objDir -Force | Out-Null
New-Item -ItemType Directory -Path $dexDir -Force | Out-Null

# ── Step 1: Compile Resources ──────────────────────────────────────────────────
Write-Host "`n=== 1. Compiling Resources ===" -ForegroundColor Cyan
& "$aapt2" compile --dir res -o $compiledResZip
if ($LASTEXITCODE -ne 0) { throw "aapt2 compile failed" }

# ── Step 2: Link (generate APK with resources) ──────────────────────────────────
Write-Host "=== 2. Linking Resources ===" -ForegroundColor Cyan
& "$aapt2" link -o $unsignedApk -I "$androidJar" --manifest AndroidManifest.xml --java $genDir $compiledResZip
if ($LASTEXITCODE -ne 0) { throw "aapt2 link failed" }

# ── Step 3: Compile Java Sources ──────────────────────────────────────────────
Write-Host "=== 3. Compiling Java Sources ===" -ForegroundColor Cyan
$javaFiles = Get-ChildItem -Path "src", $genDir -Filter "*.java" -Recurse | ForEach-Object { $_.FullName }
if ($javaFiles.Count -eq 0) { throw "No Java files found" }
Write-Host "   Sources: $($javaFiles.Count) files"
& javac -d $objDir -classpath "$androidJar" -sourcepath "src;$genDir" --release 8 $javaFiles
if ($LASTEXITCODE -ne 0) { throw "javac failed" }

# ── Step 4: DEX (bytecode to Dalvik) ─────────────────────────────────────────
Write-Host "=== 4. Translating to DEX ===" -ForegroundColor Cyan
$classFiles = Get-ChildItem -Path $objDir -Filter "*.class" -Recurse | ForEach-Object { $_.FullName }
& "$d8" --lib "$androidJar" --output $dexDir $classFiles
if ($LASTEXITCODE -ne 0) { throw "d8 failed" }

# ── Step 5: Merge DEX into APK ────────────────────────────────────────────────
Write-Host "=== 5. Merging DEX into APK ===" -ForegroundColor Cyan
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$zip = [System.IO.Compression.ZipFile]::Open((Resolve-Path $unsignedApk).Path, [System.IO.Compression.ZipArchiveMode]::Update)
$existing = $zip.GetEntry("classes.dex")
if ($existing) { $existing.Delete() }
$dexPath = (Resolve-Path "$dexDir\classes.dex").Path
[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dexPath, "classes.dex")
$zip.Dispose()

# ── Step 6: Align ──────────────────────────────────────────────────────────────
Write-Host "=== 6. Aligning APK ===" -ForegroundColor Cyan
& "$zipalign" -v -f 4 $unsignedApk $alignedApk
if ($LASTEXITCODE -ne 0) { throw "zipalign failed" }

# ── Step 7: Sign ──────────────────────────────────────────────────────────────
Write-Host "=== 7. Signing APK ===" -ForegroundColor Cyan
$keystore = Join-Path $scriptDir "adbtoggler.keystore"

# Find keytool
$javaHome = $null
$javaHomes = @(
    "C:\Program Files\Java",
    "C:\Program Files (x86)\Java",
    "$env:JAVA_HOME"
)
foreach ($jh in $javaHomes) {
    if ($jh -and (Test-Path $jh)) {
        $versions = Get-ChildItem -Path $jh -Directory | Where-Object { $_.Name -match '^jdk' } | Sort-Object Name -Descending
        if ($versions) {
            $keytool = Join-Path $versions[0].FullName "bin\keytool.exe"
            if (Test-Path $keytool) {
                $javaHome = $versions[0].FullName
                break
            }
        }
    }
}
if (-not $javaHome) {
    $keytool = Get-Command keytool -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
}
if (-not $keytool) {
    Write-Error "keytool not found. Install JDK or set JAVA_HOME."
}

if (-not (Test-Path $keystore)) {
    Write-Host "   Generating keystore..."
    & $keytool -genkey -v -keystore $keystore -alias adbtoggler -keyalg RSA -keysize 2048 `
        -validity 10000 -storepass adbtoggler -keypass adbtoggler `
        -dname "CN=InotADev, O=InotADev, C=VN"
    if ($LASTEXITCODE -ne 0) { throw "keytool failed" }
}

& "$apksigner" sign `
    --ks $keystore `
    --ks-key-alias adbtoggler `
    --ks-pass pass:adbtoggler `
    --key-pass pass:adbtoggler `
    --out $finalApk $alignedApk

if ($LASTEXITCODE -ne 0) { throw "apksigner failed" }

# ── Done ──────────────────────────────────────────────────────────────────────
$apkSize = (Get-Item $finalApk).Length
Write-Host "`n=== BUILD SUCCESSFUL ===" -ForegroundColor Green
Write-Host "APK: $finalApk"
Write-Host "Size: $([math]::Round($apkSize / 1KB, 1)) KB"
