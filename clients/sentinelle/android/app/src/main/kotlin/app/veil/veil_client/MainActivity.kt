package app.veil.veil_client

import android.content.Intent
import android.content.pm.ApplicationInfo
import android.content.pm.PackageManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.graphics.drawable.Drawable
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

/**
 * Exposes the installed-application list to Dart so split tunnelling can offer
 * a picker instead of asking people to type package names.
 *
 * Only apps that can actually reach the network are listed — anything without
 * INTERNET permission can't be affected by a VPN, so showing it would be noise.
 */
class MainActivity : FlutterActivity() {

    private val channel = "app.veil/installed_apps"

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "list" -> {
                        val withIcons = call.argument<Boolean>("icons") ?: true
                        try {
                            result.success(listApps(withIcons))
                        } catch (e: Exception) {
                            result.error("LIST_FAILED", e.message, null)
                        }
                    }
                    "openVpnSettings" -> {
                        try {
                            openVpnSettings()
                            result.success(null)
                        } catch (e: Exception) {
                            result.error("NO_VPN_SETTINGS", e.message, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }

        // Self-update. These builds come from the provider's panel rather than
        // a store, so nothing else is going to install them.
        //
        // Not registered at all in the Play flavour: Play forbids an app it
        // distributes from updating itself, and that build has no
        // REQUEST_INSTALL_PACKAGES and no FileProvider either. Leaving the
        // channel wired up would make the code reachable and the failure
        // obscure — an unregistered channel is an honest "this build cannot".
        if (BuildConfig.SELF_UPDATE) {
            MethodChannel(flutterEngine.dartExecutor.binaryMessenger, updateChannel)
                .setMethodCallHandler { call, result ->
                    when (call.method) {
                        "install" -> {
                            val path = call.argument<String>("path")
                            if (path.isNullOrBlank()) {
                                result.error("NO_PATH", "No file to install", null)
                            } else {
                                try {
                                    installApk(path)
                                    result.success(null)
                                } catch (e: Exception) {
                                    result.error("INSTALL_FAILED", e.message, null)
                                }
                            }
                        }
                        else -> result.notImplemented()
                    }
                }
        }

        // The tile and the widget both live outside the Flutter engine, so
        // they need to be told when the connection state changes — and Dart is
        // the only place that knows.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, widgetChannel)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "refresh" -> {
                        // Through VpnToggle rather than straight to the widget:
                        // the app driving the tunnel settles any toggle the
                        // widget or tile is still waiting on, and the tile has
                        // to be nudged separately from the widget.
                        VpnToggle.onExternalStateChange(this)
                        result.success(null)
                    }
                    // Was the tunnel stopped because somebody asked, or did it
                    // die? Dart has no other way to tell, and it treats a drop
                    // as something to recover from — which turned a tap on the
                    // notification's DISCONNECT into an immediate reconnect.
                    // Read-and-clear, so one stop is only ever claimed once.
                    "consumeUserStop" -> {
                        result.success(VpnToggle.consumeUserRequestedStop())
                    }
                    else -> result.notImplemented()
                }
            }

        // From here on the core's own reports keep the widget and the tile in
        // step, whoever started the tunnel.
        VpnToggle.ensureStateWatcher(this)
    }

    private val widgetChannel = "app.veil/widgets"
    private val updateChannel = "app.veil/updates"

    /**
     * Opens the system package installer on a downloaded APK.
     *
     * The file sits in app-private storage, so the installer — a different
     * process — cannot read it from a path. It gets a content:// URI from our
     * FileProvider with a read grant attached instead; a file:// URI has been
     * illegal since Android 7 and throws FileUriExposedException.
     *
     * On Android 8+ the user must also have allowed this app to install
     * packages. Rather than fail with a bare SecurityException, send them to
     * the settings screen that grants it, so the next attempt works.
     */
    private fun installApk(path: String) {
        val file = java.io.File(path)
        if (!file.isFile) throw IllegalStateException("The download is missing")

        if (android.os.Build.VERSION.SDK_INT >= android.os.Build.VERSION_CODES.O &&
            !packageManager.canRequestPackageInstalls()
        ) {
            startActivity(
                Intent(
                    android.provider.Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                    android.net.Uri.parse("package:$packageName")
                ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            )
            throw IllegalStateException(
                "Allow Sentinelle to install apps, then tap update again"
            )
        }

        val uri = androidx.core.content.FileProvider.getUriForFile(
            this, "$packageName.updates", file
        )
        startActivity(
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            }
        )
    }

    /**
     * "Block connections without VPN" is the only true kill switch on Android
     * and no app may set it — it lives behind the always-on VPN screen. Send
     * the user straight there, falling back to the network settings root on
     * the OEM builds that hide the specific screen.
     */
    private fun openVpnSettings() {
        val intents = listOf(
            Intent("android.net.vpn.SETTINGS"),
            Intent(android.provider.Settings.ACTION_VPN_SETTINGS),
            Intent(android.provider.Settings.ACTION_WIRELESS_SETTINGS)
        )
        // Trying to start each in turn rather than asking resolveActivity
        // first: package visibility on API 30+ can hide the answer even when
        // the activity is perfectly launchable.
        for (intent in intents) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            try {
                startActivity(intent)
                return
            } catch (_: Exception) {
                // Try the next one.
            }
        }
        throw IllegalStateException("No VPN settings screen on this device")
    }

    private fun listApps(withIcons: Boolean): List<Map<String, Any?>> {
        val pm = packageManager
        val launchable = pm.queryIntentActivities(
            Intent(Intent.ACTION_MAIN).addCategory(Intent.CATEGORY_LAUNCHER), 0
        ).mapNotNull { it.activityInfo?.packageName }.toSet()

        val out = ArrayList<Map<String, Any?>>()
        for (app in pm.getInstalledApplications(PackageManager.GET_META_DATA)) {
            if (app.packageName == packageName) continue

            val hasInternet = pm.checkPermission(
                android.Manifest.permission.INTERNET, app.packageName
            ) == PackageManager.PERMISSION_GRANTED
            if (!hasInternet) continue

            val isSystem = (app.flags and ApplicationInfo.FLAG_SYSTEM) != 0
            // Keep system apps that the user can actually launch (Chrome, Maps…)
            // and drop the invisible platform ones.
            if (isSystem && !launchable.contains(app.packageName)) continue

            out.add(
                mapOf(
                    "package" to app.packageName,
                    "name" to pm.getApplicationLabel(app).toString(),
                    "system" to isSystem,
                    "icon" to if (withIcons) iconBase64(pm.getApplicationIcon(app)) else null
                )
            )
        }
        out.sortWith(compareBy { (it["name"] as String).lowercase() })
        return out
    }

    /** Small PNG so the list can show real icons without a second round-trip. */
    private fun iconBase64(drawable: Drawable): String? = try {
        val size = 96
        val bitmap = if (drawable is BitmapDrawable && drawable.bitmap != null) {
            Bitmap.createScaledBitmap(drawable.bitmap, size, size, true)
        } else {
            Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888).also {
                val canvas = Canvas(it)
                drawable.setBounds(0, 0, canvas.width, canvas.height)
                drawable.draw(canvas)
            }
        }
        ByteArrayOutputStream().use { stream ->
            bitmap.compress(Bitmap.CompressFormat.PNG, 100, stream)
            android.util.Base64.encodeToString(stream.toByteArray(), android.util.Base64.NO_WRAP)
        }
    } catch (e: Exception) {
        null
    }
}
