# build_apk.ps1
$ErrorActionPreference = "Stop"

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
$d8 = "$buildToolsPath\d8.bat"
$zipalign = "$buildToolsPath\zipalign.exe"
$apksigner = "$buildToolsPath\apksigner.bat"

# Verify tools exist
foreach ($tool in @($aapt2, $d8, $zipalign, $apksigner)) {
    if (-not (Test-Path $tool)) {
        Write-Error "Required tool not found: $tool"
    }
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

Write-Host "=== 3. Compiling Java Sources ==="
$javaFiles = Get-ChildItem -Path "src", $genDir -Filter *.java -Recurse | ForEach-Object { $_.FullName }
& javac -d $objDir -classpath "$androidJar" -sourcepath "src;$genDir" --release 8 $javaFiles

Write-Host "=== 4. Translating bytecode to DEX ==="
$classFiles = Get-ChildItem -Path $objDir -Filter *.class -Recurse | ForEach-Object { $_.FullName }
& "$d8" --lib "$androidJar" --output $dexDir $classFiles

Write-Host "=== 5. Merging DEX into unsigned APK ==="
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


Write-Host "=== 6. Aligning APK ==="
& "$zipalign" -v -f 4 $unsignedApk $alignedApk

Write-Host "=== 7. Signing APK ==="
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

& "$apksigner" sign --ks $keystore --ks-key-alias adbtoggler --ks-pass pass:adbtoggler --key-pass pass:adbtoggler --out $finalApk $alignedApk

Write-Host "=== BUILD SUCCESSFUL ==="
Write-Host "Final APK generated at: $finalApk"
