# Captures tablet screenshots for the Play listing, from an emulator.
#
#   .\tool\tablet_shots.ps1 -Avd Sentinelle_Tablet_10
#   .\tool\tablet_shots.ps1 -Avd Sentinelle_Tablet_7
#
# Play asks for 7-inch and 10-inch tablet screenshots. Without them the app is
# flagged as not optimised for large screens and loses placement on tablets and
# Chromebooks — but you do not need a tablet to produce them.
#
# Both AVDs are landscape on purpose. In portrait a 7-inch tablet is 600 dp
# wide, which is under the app's 900 dp threshold, so it draws the phone layout
# — a stretched phone UI is the exact thing Google penalises. Landscape is
# 960 dp and 1280 dp, which draws the sidebar layout and demonstrates that the
# app actually adapts.
#
# The emulator cannot sign itself in, so this stops and waits for you.

param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Sentinelle_Tablet_7', 'Sentinelle_Tablet_10')]
    [string]$Avd,

    [string]$Sdk = 'D:\androidsdkkk',
    [string]$Out = "$env:USERPROFILE\Desktop\sentinelle-shots",
    [string]$Apk = 'build\app\outputs\flutter-apk\app-sideload-release.apk'
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

$adb      = Join-Path $Sdk 'platform-tools\adb.exe'
$emulator = Join-Path $Sdk 'emulator\emulator.exe'
foreach ($tool in @($adb, $emulator)) {
    if (-not (Test-Path $tool)) { throw "Not found: $tool  (pass -Sdk)" }
}
if (-not (Test-Path $Apk)) {
    throw "No APK at $Apk. Build one first:  flutter build apk --release --flavor sideload"
}

$label = if ($Avd -match '_7$') { 'tablet7' } else { 'tablet10' }
New-Item -ItemType Directory -Force -Path $Out | Out-Null

# ── Boot ──────────────────────────────────────────────────────────────────────
$running = & $adb devices | Select-String '^emulator-\d+\s+device'
if (-not $running) {
    Write-Host "Launching $Avd ..." -ForegroundColor Cyan
    Start-Process -FilePath $emulator -ArgumentList @('-avd', $Avd, '-no-snapshot-load')
    Write-Host 'Waiting for the device (first boot can take a few minutes)...'
    & $adb wait-for-device
    do {
        Start-Sleep -Seconds 3
        $booted = (& $adb shell getprop sys.boot_completed 2>$null).Trim()
    } while ($booted -ne '1')
    Start-Sleep -Seconds 5
} else {
    Write-Host 'Using the emulator that is already running.' -ForegroundColor Yellow
}

# ── Landscape, and no on-screen clutter ───────────────────────────────────────
& $adb shell settings put system accelerometer_rotation 0 | Out-Null
& $adb shell settings put system user_rotation 1 | Out-Null   # 1 = 90°, landscape
# Tidies the status bar: full signal, no notification icons, fixed clock.
& $adb shell am broadcast -a com.android.systemui.demo -e command enter | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command clock -e hhmm 0930 | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command battery -e level 100 -e plugged false | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command network -e wifi show -e level 4 | Out-Null
& $adb shell am broadcast -a com.android.systemui.demo -e command notifications -e visible false | Out-Null

Write-Host 'Installing the app...' -ForegroundColor Cyan
& $adb install -r -d $Apk

Write-Host ''
Write-Host '── Now do this in the emulator ──────────────────────────────' -ForegroundColor Green
Write-Host '  1. Open Sentinelle and sign in with the review account'
Write-Host '  2. Connect to a location'
Write-Host '  3. Come back here and press Enter for each screen you want'
Write-Host ''
Write-Host 'Good ones: Connect (connected, map + route), Locations, Stats.'
Write-Host 'Type q then Enter when finished.'
Write-Host ''

$i = 0
while ($true) {
    $key = Read-Host "Enter = capture, q = quit"
    if ($key -eq 'q') { break }
    $i++
    $name = '{0}-{1:d2}.png' -f $label, $i
    $dest = Join-Path $Out $name
    # Via a file on the device, not `exec-out ... > file`: PowerShell's
    # redirection is text, and it corrupts a PNG on the way through.
    & $adb shell screencap -p /sdcard/_shot.png | Out-Null
    & $adb pull /sdcard/_shot.png $dest 2>&1 | Out-Null
    & $adb shell rm -f /sdcard/_shot.png | Out-Null
    if (-not (Test-Path $dest)) {
        Write-Warning 'Capture failed - is the emulator still up?'
        $i--
        continue
    }
    $size = (Get-Item $dest).Length
    if ($size -lt 1024) {
        Remove-Item $dest
        Write-Warning 'Capture failed — is the emulator still up?'
        $i--
    } else {
        Write-Host ("  {0}  ({1:n0} KB)" -f $name, ($size / 1KB)) -ForegroundColor Green
    }
}

# Leave the device as we found it.
& $adb shell am broadcast -a com.android.systemui.demo -e command exit | Out-Null
& $adb shell settings put system accelerometer_rotation 1 | Out-Null

Write-Host ''
Write-Host "$i screenshots in $Out" -ForegroundColor Cyan
Write-Host 'Now convert them to the aspect ratio Play wants:'
Write-Host "  python tool\play_screenshots.py `"$Out`""
