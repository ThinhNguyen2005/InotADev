# build_apk.ps1 - Kotlin Android build pipeline with R8 Tree-Shaking
$ErrorActionPreference = "Stop"

Push-Location $PSScriptRoot
try {

$sdkPath = "C:\Users\Abc\AppData\Local\Android\Sdk"
if (-not (Test-Path $sdkPath)) {
    Write-Error "Android SDK not found at $sdkPath!"
}

# Auto-detect latest build-tools
$buildToolsDirs = Get-ChildItem -Path "$sdkPath\build-tools" -Directory | Sort-Object Name -Descending
if ($buildToolsDirs.Count -eq 0) {
    Write-Error "No build-tools found!"
}
$buildToolsVersion = $buildToolsDirs[0].Name
$buildToolsPath = $buildToolsDirs[0].FullName
Write-Host "Using Build Tools version: $buildToolsVersion"

# Auto-detect latest platform SDK
$platformDirs = Get-ChildItem -Path "$sdkPath\platforms" -Directory | Sort-Object Name -Descending
if ($platformDirs.Count -eq 0) {
    Write-Error "No platforms found in Android SDK!"
}
$platformPath = $platformDirs[0].FullName
$androidJar = "$platformPath\android.jar"
Write-Host "Using Platform: $($platformDirs[0].Name) ($androidJar)"

# Set up paths to build tools
$aapt2 = "$buildToolsPath\aapt2.exe"
$d8Jar = "$buildToolsPath\lib\d8.jar"
$zipalign = "$buildToolsPath\zipalign.exe"
$apksigner = "$buildToolsPath\apksigner.bat"

# Detect Kotlin Compiler
$ktHome = "C:\Program Files\Android\Android Studio\plugins\Kotlin\kotlinc"
$ktCompilerJar = "$ktHome\lib\kotlin-compiler.jar"
$ktStdlibJar = "$ktHome\lib\kotlin-stdlib.jar"

if (-not (Test-Path $ktCompilerJar)) {
    Write-Error "Kotlin compiler not found at $ktCompilerJar!"
}

# Directories
$buildDir = "build"
$compiledResZip = "$buildDir\compiled_res.zip"
$genDir = "$buildDir\gen"
$objDir = "$buildDir\obj"
$dexDir = "$buildDir\dex"
$unsignedApk = "$buildDir\unsigned.apk"
$alignedApk = "$buildDir\aligned.apk"
$distDir = "..\..\dist"
$finalApk = "$distDir\AdbToggler.apk"
$keystore = "adbtoggler.keystore"

# Clean & recreate build directories
if (Test-Path $buildDir) {
    Remove-Item -Path $buildDir -Recurse -Force
}
New-Item -ItemType Directory -Path $buildDir | Out-Null
New-Item -ItemType Directory -Path $genDir | Out-Null
New-Item -ItemType Directory -Path $objDir | Out-Null
New-Item -ItemType Directory -Path $dexDir | Out-Null

if (-not (Test-Path $distDir)) {
    New-Item -ItemType Directory -Path $distDir | Out-Null
}

Write-Host "=== 1. Compiling Resources ==="
& "$aapt2" compile --dir res -o $compiledResZip

Write-Host "=== 2. Linking Resources ==="
& "$aapt2" link -o $unsignedApk -I "$androidJar" --manifest AndroidManifest.xml --java $genDir $compiledResZip

Write-Host "=== 3. Compiling Generated R.java ==="
$rJavaFiles = Get-ChildItem -Path $genDir -Filter *.java -Recurse | ForEach-Object { $_.FullName }
if ($rJavaFiles.Count -gt 0) {
    & javac -d $objDir -classpath "$androidJar" $rJavaFiles
    if ($LASTEXITCODE -ne 0) { throw "R.java compilation failed!" }
}

Write-Host "=== 4. Compiling Kotlin Sources ==="
$ktFiles = Get-ChildItem -Path "src" -Filter *.kt -Recurse | ForEach-Object { $_.FullName }
& java -cp "$ktCompilerJar" org.jetbrains.kotlin.cli.jvm.K2JVMCompiler `
    -cp "$androidJar;$objDir" `
    -d $objDir `
    -jvm-target 1.8 `
    $ktFiles
if ($LASTEXITCODE -ne 0) { throw "Kotlin compilation failed!" }

Write-Host "=== 5. Optimizing & Dexing with R8 Tree-Shaking ==="
$r8Keep = "$buildDir\keep.txt"
@"
-keep public class com.inotadev.adbtoggler.MainActivity { *; }
-keep public class com.inotadev.adbtoggler.AdbTileService { *; }
-keep public class com.inotadev.adbtoggler.Constants* { *; }
-keep public class com.inotadev.adbtoggler.DaemonMode* { *; }
-keep public class com.inotadev.adbtoggler.R* { *; }
-dontobfuscate
-dontwarn **
"@ | Set-Content -Path $r8Keep -Encoding UTF8

$classFiles = Get-ChildItem -Path $objDir -Filter *.class -Recurse | ForEach-Object { $_.FullName }
& java -cp $d8Jar com.android.tools.r8.R8 `
    --release `
    --min-api 24 `
    --lib "$androidJar" `
    --output $dexDir `
    --pg-conf $r8Keep `
    $classFiles "$ktStdlibJar"
if ($LASTEXITCODE -ne 0) { throw "R8 tree-shaking failed!" }

Write-Host "=== 6. Merging DEX into unsigned APK ==="
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$unsignedApkFullPath = (Resolve-Path $unsignedApk).Path
$zip = [System.IO.Compression.ZipFile]::Open($unsignedApkFullPath, [System.IO.Compression.ZipArchiveMode]::Update)
$existing = $zip.GetEntry("classes.dex")
if ($existing -ne $null) {
    $existing.Delete()
}
$dexFilePath = (Resolve-Path "$dexDir\classes.dex").Path
[System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $dexFilePath, "classes.dex")
$zip.Dispose()

Write-Host "=== 7. Aligning APK ==="
& "$zipalign" -v -f 4 $unsignedApk $alignedApk

Write-Host "=== 8. Signing APK ==="
$keytool = "C:\Program Files\Java\jdk-23\bin\keytool.exe"
if (-not (Test-Path $keytool)) {
    $keytool = "C:\Program Files\Java\latest\bin\keytool.exe"
}
if (-not (Test-Path $keytool)) {
    $keytool = "keytool"
}

if (-not (Test-Path $keystore)) {
    Write-Host "Generating temporary signing keystore..."
    & "$keytool" -genkey -v -keystore $keystore -alias adbtoggler -keyalg RSA -keysize 2048 -validity 10000 -storepass adbtoggler -keypass adbtoggler -dname "CN=InotADev, O=InotADev, C=VN"
}

& "$apksigner" sign --ks $keystore --ks-key-alias adbtoggler --ks-pass pass:adbtoggler --key-pass pass:adbtoggler --v4-signing-enabled false --out $finalApk $alignedApk
Remove-Item "$finalApk.idsig" -Force -ErrorAction SilentlyContinue

Write-Host "`n=== BUILD SUCCESSFUL ==="
Write-Host "Final APK generated at: $finalApk"
Get-Item $finalApk | Select-Object Name, Length, LastWriteTime | Format-Table -AutoSize

} finally {
    Pop-Location
}
