# Builds the release artefacts.
#
#   .\tool\build_release.ps1              # both
#   .\tool\build_release.ps1 -Only play
#   .\tool\build_release.ps1 -Only sideload
#   .\tool\build_release.ps1 -Only windows
#
# There are two Android builds and they are not interchangeable:
#
#   sideload — applicationId app.veil.veil_client. What the provider hands out
#              from the panel. Keeps the self-updater.
#   play     — applicationId app.Mireda.Sentinelle. An .aab for Google Play,
#              with the updater removed. `--dart-define=VEIL_SELF_UPDATE=false`
#              is what takes the update UI out; the flavour's manifest and
#              BuildConfig take out the capability.
#
#              `--dart-define=VEIL_REQUIRE_HTTPS=true` is what makes the Data
#              safety answer "all data encrypted in transit" true: without it
#              PanelApi falls back to http:// for address:port panels, which
#              would put a password on the wire in the clear.
#
#              Neither define is optional, which is why this script exists
#              rather than a note in a README.

param(
    [ValidateSet('all', 'play', 'sideload', 'windows')]
    [string]$Only = 'all'
)

$ErrorActionPreference = 'Stop'
Set-Location (Split-Path $PSScriptRoot -Parent)

function Announce($text) {
    Write-Host ''
    Write-Host "== $text" -ForegroundColor Cyan
}

if ($Only -in @('all', 'sideload')) {
    Announce 'Android — sideload APK (self-updating, from the panel)'
    flutter build apk --release --flavor sideload
    if ($LASTEXITCODE -ne 0) { throw 'sideload APK build failed' }
    Write-Host 'build/app/outputs/flutter-apk/app-sideload-release.apk'
}

if ($Only -in @('all', 'play')) {
    Announce 'Android — Play app bundle (no self-update)'
    flutter build appbundle --release --flavor play `
        --dart-define=VEIL_SELF_UPDATE=false `
        --dart-define=VEIL_REQUIRE_HTTPS=true
    if ($LASTEXITCODE -ne 0) { throw 'Play bundle build failed' }

    $bundle = 'build/app/outputs/bundle/playRelease/app-play-release.aab'
    Write-Host $bundle

    # The whole point of the flavour. Cheap to check, expensive to get wrong:
    # the permission reaching Play is an account-level enforcement, not a
    # rejection you fix and resubmit.
    $manifest = 'build/app/intermediates/merged_manifest/playRelease/' +
                'processPlayReleaseMainManifest/AndroidManifest.xml'
    if (Test-Path $manifest) {
        $text = Get-Content $manifest -Raw
        if ($text -match 'REQUEST_INSTALL_PACKAGES') {
            throw "REQUEST_INSTALL_PACKAGES is in the Play manifest. Do not upload this."
        }
        if ($text -notmatch 'app\.Mireda\.Sentinelle') {
            throw "The Play manifest does not carry the Play applicationId."
        }
        # Declared to Google as "encrypted in transit". The Dart flag is the
        # real enforcement, but if this attribute is missing the flavour
        # manifest did not merge, and the define probably did not either.
        if ($text -notmatch 'usesCleartextTraffic="false"') {
            throw "The Play manifest does not forbid cleartext traffic. Do not upload this."
        }
        Write-Host 'manifest check: no install permission, no cleartext, correct applicationId' `
            -ForegroundColor Green
    } else {
        Write-Warning "Could not find the merged manifest to check: $manifest"
    }
}

if ($Only -in @('all', 'windows')) {
    Announce 'Windows'
    flutter build windows --release
    if ($LASTEXITCODE -ne 0) { throw 'Windows build failed' }
    Write-Host 'build/windows/x64/runner/Release/Sentinelle.exe'
}

Announce 'Done'
