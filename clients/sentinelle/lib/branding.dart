/// The product name, in one place.
///
/// The panel's own `workspace_name` is shown as the account's brand inside the
/// app; this is the name of the application itself — window title, taskbar,
/// tray and launcher.
const String kAppName = 'PrimeNet VPN';

/// Window / task-manager title.
const String kAppWindowTitle = '$kAppName — Secure VPN';

/// Whether this build is allowed to fetch and install its own updates.
///
/// True for the builds the provider hands out themselves — a sideloaded APK,
/// or the Windows installer — where the panel is the only distribution channel
/// there is.
///
/// **False for the Google Play build, and it must stay that way.** Play's
/// Device and Network Abuse policy forbids an app distributed through the
/// store from updating itself by any other route, and enforcement is a
/// suspension rather than a warning. The Play flavour also strips
/// `REQUEST_INSTALL_PACKAGES` and the FileProvider from its manifest, so even
/// a build that somehow reached this code with the flag on could not install
/// anything — this switch is what keeps the *offer* off the screen.
///
/// Set at build time: `--dart-define=VEIL_SELF_UPDATE=false`. See
/// `android/app/build.gradle.kts` and `tool/build_play.ps1`.
const bool kSelfUpdate =
    bool.fromEnvironment('VEIL_SELF_UPDATE', defaultValue: true);

/// Whether this build refuses to talk to a panel over plain HTTP.
///
/// Off for the sideloaded build, deliberately. Most reseller panels run on a
/// bare `address:port` with no certificate, and cutting them off would break
/// working customers on their next update — a decision for their provider to
/// make, not for us to force through an app update.
///
/// **On for the Google Play build.** Play's Data safety form asks whether *all*
/// collected data is encrypted in transit, and the honest answer is only Yes if
/// there is no plaintext path at all: the sign-in carries the account's
/// username and password, and `_guessScheme` used to actively prefer `http` for
/// exactly the `address:port` panels that are most common. A build that can
/// downgrade a login to cleartext cannot claim otherwise on its store listing.
///
/// A Play user whose provider has no HTTPS address is told so plainly rather
/// than being signed in over the clear — see [PanelApi.plaintextRefusal].
///
/// Set at build time: `--dart-define=VEIL_REQUIRE_HTTPS=true`. See
/// `tool/build_release.ps1`.
const bool kRequireHttps =
    bool.fromEnvironment('VEIL_REQUIRE_HTTPS', defaultValue: false);
