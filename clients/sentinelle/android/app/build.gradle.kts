import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing. Kept out of the repository: `key.properties` holds the
// passwords and `sentinelle-upload.jks` is the key itself, both git-ignored.
//
// Absent — on a fresh clone, or a CI box that has no business signing — the
// release build falls back to the debug key so `flutter run --release` still
// works. A build meant for the store must not do that, so `assemblePlay*`
// checks below and fails rather than producing an upload Play would reject.
val keystoreProperties = Properties().apply {
    val f = rootProject.file("key.properties")
    if (f.exists()) f.inputStream().use { load(it) }
}
val hasReleaseKey = keystoreProperties.getProperty("storeFile") != null

android {
    // Deliberately *not* the applicationId. The namespace is where R and
    // BuildConfig are generated and it has to match the Kotlin sources, so it
    // stays where it was; the two flavours below each pick their own
    // applicationId on top of it.
    namespace = "app.veil.veil_client"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // applicationId is set per flavour — see productFlavors below.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildFeatures {
        // MainActivity branches on BuildConfig.SELF_UPDATE.
        buildConfig = true
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = rootProject.file(keystoreProperties.getProperty("storeFile"))
                storePassword = keystoreProperties.getProperty("storePassword")
                keyAlias = keystoreProperties.getProperty("keyAlias")
                keyPassword = keystoreProperties.getProperty("keyPassword")
            }
        }
    }

    // Two ways this app reaches a phone, and they are not allowed to behave
    // the same way.
    flavorDimensions += "distribution"
    productFlavors {
        // Handed out by the provider, from the panel. Keeps the original
        // applicationId: changing it would land as a *second* app on every
        // phone that already has this one, with no upgrade path.
        create("sideload") {
            dimension = "distribution"
            applicationId = "app.veil.veil_client"
            buildConfigField("boolean", "SELF_UPDATE", "true")
            isDefault = true

            // Deliberately the debug key, and it has to stay that way.
            //
            // Every build handed out so far was signed `CN=Android Debug`, and
            // Android refuses an update whose signing certificate differs from
            // the installed one. Signing this flavour with the upload key would
            // make the next self-update fail with "App not installed" on every
            // phone that already has it — and the user would have to uninstall,
            // losing their accounts, to recover.
            //
            // That means the sideload channel depends on ~/.android/debug.keystore.
            // Back that file up. If it is lost or regenerated, no existing
            // install can ever be updated again. Moving this channel to a real
            // key is a one-time uninstall/reinstall for every customer, so it is
            // a decision to make deliberately rather than by editing this line.
            signingConfig = signingConfigs.getByName("debug")
        }

        // Google Play. Play's Device and Network Abuse policy forbids an app
        // it distributes from updating itself by any other route, so this
        // flavour has the whole updater removed: no REQUEST_INSTALL_PACKAGES
        // and no FileProvider (see src/play/AndroidManifest.xml), no update
        // method channel (BuildConfig.SELF_UPDATE), and no update UI
        // (--dart-define=VEIL_SELF_UPDATE=false).
        create("play") {
            dimension = "distribution"
            applicationId = "app.Mireda.Sentinelle"
            buildConfigField("boolean", "SELF_UPDATE", "false")
            // A fresh listing, so it starts on a proper key with nothing to
            // stay compatible with. Play App Signing re-signs the delivered
            // APKs anyway; this is only the upload key.
            if (hasReleaseKey) {
                signingConfig = signingConfigs.getByName("release")
            }
        }
    }

    // flutter_v2ray ships tun2socks as `libtun2socks.so` and *executes* it with
    // ProcessBuilder from `nativeLibraryDir`. Since AGP 4.2 the default is to
    // leave native libraries compressed inside the APK (extractNativeLibs
    // false), so nothing is ever written to that directory as a real file and
    // the exec fails. The VpnService still establishes the TUN device, so the
    // system says "VPN connected" while nothing reads the tun fd and no packet
    // ever reaches Xray — the tunnel looks up and carries no traffic.
    //
    // Legacy packaging extracts the libraries at install time, which is what
    // makes them executable. v2rayNG sets exactly this for the same reason.
    //
    // Verified: without this block the merged release manifest carries
    // extractNativeLibs="false"; with it, "true".
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    buildTypes {
        release {
            // Signing is set per flavour, not here. AGP gives the build type
            // priority over the flavour, so a signingConfig on this line would
            // silently override the sideload flavour's debug key — which is the
            // one thing that must not happen, because it is the key every
            // installed copy was signed with.
        }
    }
}

// A Play artefact signed with the debug key is worse than no artefact: the
// upload is rejected, and the version code is burnt in the meantime.
gradle.taskGraph.whenReady {
    // Only the tasks that actually produce the artefact count. A sideload build
    // still drags three Play-named tasks into the graph — AGP's own
    // `prePlayReleaseBuild` anchor, and Flutter's `compileFlutterBuildPlayRelease`
    // and `packJniLibsflutterBuildPlayRelease` — all skipped, all matching a
    // bare `contains("PlayRelease")`. That made this guard fire on every build
    // without the key, so `--flavor sideload` could not be built at all on a
    // machine that has no upload key: CI, or anyone who clones the repo.
    val producesArtefact = listOf("assemble", "bundle", "package", "sign")
    val buildingPlayRelease = allTasks.any { task ->
        task.project == project &&
            task.name.contains("PlayRelease") &&
            producesArtefact.any { task.name.startsWith(it) }
    }
    if (buildingPlayRelease && !hasReleaseKey) {
        throw GradleException(
            "The Play build needs the upload key. Expected android/key.properties " +
                "with storeFile, storePassword, keyAlias and keyPassword. " +
                "See tool/README-release.md."
        )
    }
}

dependencies {
    // FileProvider, used to hand a downloaded APK to the system installer.
    // Declared explicitly rather than leaned on: both the Flutter embedding and
    // the flutter_v2ray plugin pull androidx.core in, but they do it at
    // `implementation` scope, which keeps it off this module's compile
    // classpath.
    implementation("androidx.core:core:1.13.1")
}

flutter {
    source = "../.."
}
