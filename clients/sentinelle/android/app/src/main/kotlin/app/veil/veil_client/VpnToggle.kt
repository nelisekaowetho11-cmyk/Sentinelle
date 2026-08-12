package app.veil.veil_client

import android.content.BroadcastReceiver
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.VpnService
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.service.quicksettings.TileService
import com.github.blueboytm.flutter_v2ray.v2ray.V2rayController
import com.github.blueboytm.flutter_v2ray.v2ray.core.V2rayCoreManager
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs

/**
 * Turning the tunnel on and off from outside the Flutter UI — the quick
 * settings tile and the home screen widget both go through here.
 *
 * Neither of those can rely on Dart running: the tile is built by SystemUI and
 * the widget by the launcher, and in both cases the Flutter engine may never
 * have started. So the last connection is mirrored into the same
 * SharedPreferences file Flutter writes, and this reads it back natively.
 */
object VpnToggle {

    /** Flutter's plugin stores everything in this file, with a `flutter.` prefix. */
    private const val PREFS = "FlutterSharedPreferences"
    private const val KEY_CONFIG = "flutter.last_vpn_config"
    private const val KEY_REMARK = "flutter.last_vpn_remark"
    private const val KEY_PROXY_ONLY = "flutter.last_vpn_proxy_only"

    /** Broadcast the widget listens for so it can repaint. */
    const val ACTION_STATE_CHANGED = "app.veil.veil_client.VPN_STATE_CHANGED"

    /** What the core itself broadcasts, once a second while it is running. */
    private const val ACTION_CORE_INFO = "V2RAY_CONNECTION_INFO"

    /**
     * How long a toggle keeps showing what was asked for before giving up and
     * showing what actually happened. Long enough for a slow handshake, short
     * enough that a start which never got off the ground does not leave
     * "Connecting…" on the home screen.
     */
    private const val PENDING_TIMEOUT_MS = 30_000L

    // ── Live state ────────────────────────────────────────────────────────────
    //
    // The state to read is V2rayCoreManager's own field, which the core sets as
    // it changes. AppConfigs.V2RAY_STATE — what getConnectionState() returns —
    // is a copy kept up to date by a broadcast receiver, so it still holds the
    // previous value for as long as the broadcast takes to arrive. Reading that
    // copy immediately after asking the core to start is what made the widget
    // and the tile draw the state they were leaving.

    private fun coreState(): AppConfigs.V2RAY_STATES =
        try {
            V2rayCoreManager.getInstance().V2RAY_STATE
        } catch (_: Throwable) {
            AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
        }

    fun isRunning(): Boolean =
        coreState() == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED

    /**
     * What the user last asked for, while the core has yet to answer.
     *
     * Even the core's own state is behind the tap: starting a tunnel means
     * starting a service, and the service does not run until the system gets
     * round to it. Without something to show in between, a tap produced no
     * visible change at all until the *next* tap repainted it — one step behind
     * for as long as the widget was used.
     */
    @Volatile private var pendingTarget: Boolean? = null
    @Volatile private var pendingSince = 0L

    /** The last (active, busy) pair drawn, so a repaint only happens on a change. */
    @Volatile private var lastRendered: Pair<Boolean, Boolean>? = null

    @Volatile private var watching = false

    private val handler = Handler(Looper.getMainLooper())

    private fun markPending(target: Boolean) {
        pendingTarget = target
        pendingSince = SystemClock.elapsedRealtime()
    }

    /** Drops the pending state once the core has settled on an answer. */
    private fun settle() {
        if (pendingTarget == null) return
        when (coreState()) {
            // Either one is an answer. A start that failed reports
            // DISCONNECTED, and holding "Connecting…" over the top of that
            // would be showing the user something that is not happening.
            AppConfigs.V2RAY_STATES.V2RAY_CONNECTED,
            AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED -> pendingTarget = null
            AppConfigs.V2RAY_STATES.V2RAY_CONNECTING ->
                if (SystemClock.elapsedRealtime() - pendingSince > PENDING_TIMEOUT_MS) {
                    pendingTarget = null
                }
        }
    }

    private fun pending(): Boolean? {
        val target = pendingTarget ?: return null
        if (SystemClock.elapsedRealtime() - pendingSince > PENDING_TIMEOUT_MS) {
            pendingTarget = null
            return null
        }
        return target
    }

    /** What the widget and the tile should draw as their on/off state. */
    fun displayActive(): Boolean = pending() ?: isRunning()

    fun isBusy(): Boolean {
        val target = pending()
        if (target != null) return target != isRunning()
        return coreState() == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
    }

    private fun renderKey(): Pair<Boolean, Boolean> = displayActive() to isBusy()

    // ── Actions ───────────────────────────────────────────────────────────────

    /**
     * True when the last stop was asked for rather than suffered, clearing the
     * flag as it answers.
     *
     * The core sets it on every STOP_SERVICE — the notification's DISCONNECT
     * button, this object's own [stop], and the app's engine all send that
     * command. Dart's kill switch otherwise sees an unexplained
     * "disconnected" while the user still wants a tunnel, engages, and
     * reconnects a few seconds later: tapping DISCONNECT looked like it turned
     * the VPN back on, and toggling from the widget or the tile fought the app.
     */
    fun consumeUserRequestedStop(): Boolean {
        val asked = AppConfigs.USER_REQUESTED_STOP
        AppConfigs.USER_REQUESTED_STOP = false
        return asked
    }

    /** True when there is a remembered connection we could start on our own. */
    fun hasSavedConnection(context: Context): Boolean = savedConfig(context) != null

    private fun savedConfig(context: Context): String? {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val config = prefs.getString(KEY_CONFIG, null)
        return if (config.isNullOrBlank()) null else config
    }

    /**
     * Starts or stops the tunnel.
     *
     * Returns false when it could not be done without the user — no remembered
     * connection, or the VPN permission has never been granted. The caller is
     * expected to open the app in that case rather than fail silently.
     */
    fun toggle(context: Context): Boolean {
        // Off what is on screen, not off the core: a second tap while a tunnel
        // is still coming up means "no, stop".
        if (displayActive() || coreState() == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING) {
            stop(context)
            return true
        }
        return start(context)
    }

    fun stop(context: Context) {
        markPending(false)
        ensureStateWatcher(context)
        V2rayController.StopV2ray(context)
        notifyStateChanged(context)
        scheduleSettleChecks(context)
    }

    fun start(context: Context): Boolean {
        val config = savedConfig(context) ?: return false
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val remark = prefs.getString(KEY_REMARK, "") ?: ""
        val proxyOnly = prefs.getBoolean(KEY_PROXY_ONLY, false)

        // A full tunnel needs a consent dialog the first time, and only an
        // Activity can show it. Proxy-only needs nothing.
        if (!proxyOnly && VpnService.prepare(context) != null) return false

        markPending(true)
        ensureStateWatcher(context)

        V2rayController.init(context, R.mipmap.ic_launcher, "Sentinelle")
        // setConnectionMode rather than changeConnectionMode: the latter is
        // ignored unless the core is already stopped, which would start this
        // connection in whichever mode the last one used.
        V2rayController.setConnectionMode(
            context,
            if (proxyOnly) AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
            else AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN
        )
        V2rayController.StartV2ray(context, remark, config, null, null)
        notifyStateChanged(context)
        scheduleSettleChecks(context)
        return true
    }

    /** Opens the app so the user can do what we could not. */
    fun openApp(context: Context): Intent =
        Intent(context, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP)
        }

    // ── Keeping the two surfaces honest ───────────────────────────────────────

    /**
     * Repaints the widget and the tile whenever the core reports a state.
     *
     * Nothing used to be watching. A toggle repainted once, straight away,
     * while the core was still starting — and then never heard that the tunnel
     * had come up, so the face went stale until the next tap repainted it with
     * the *previous* result.
     *
     * Registered at runtime rather than in the manifest deliberately: since
     * Android 8 a manifest-declared receiver is not delivered implicit
     * broadcasts, and this is one. The process is alive for as long as the
     * foreground service is, which is exactly as long as there is anything to
     * watch.
     */
    fun ensureStateWatcher(context: Context) {
        if (watching) return
        val app = context.applicationContext
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                settle()
                // The core talks once a second while connected; only a change
                // is worth the trip out to the launcher and SystemUI.
                if (renderKey() != lastRendered) notifyStateChanged(app)
            }
        }
        val filter = IntentFilter(ACTION_CORE_INFO)
        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                app.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                app.registerReceiver(receiver, filter)
            }
            watching = true
        } catch (_: Exception) {
            // Without the watcher the delayed checks below still converge.
            watching = false
        }
    }

    /**
     * Backstop for the case where the core never speaks at all — a start that
     * failed before the service got going broadcasts nothing, and the face
     * would otherwise sit on "Connecting…" until something else repainted it.
     */
    private fun scheduleSettleChecks(context: Context) {
        val app = context.applicationContext
        for (delay in longArrayOf(1_500, 5_000, 12_000, PENDING_TIMEOUT_MS + 1_000)) {
            handler.postDelayed({
                settle()
                if (renderKey() != lastRendered) notifyStateChanged(app)
            }, delay)
        }
    }

    /** The tunnel was driven from somewhere else — the app, most likely. */
    fun onExternalStateChange(context: Context) {
        pendingTarget = null
        ensureStateWatcher(context)
        notifyStateChanged(context)
    }

    /**
     * Nudges both faces to repaint.
     *
     * The widget gets an explicitly targeted broadcast: since Android 8 a
     * manifest receiver will not get an implicit one. The tile cannot be
     * pushed to at all, so the system is asked to start listening to it, which
     * is what makes it call onStartListening and re-read the state.
     */
    fun notifyStateChanged(context: Context) {
        lastRendered = renderKey()
        val app = context.applicationContext

        app.sendBroadcast(
            Intent(app, VeilWidgetProvider::class.java).apply {
                action = ACTION_STATE_CHANGED
            }
        )

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                TileService.requestListeningState(
                    app, ComponentName(app, VeilTileService::class.java)
                )
            } catch (_: Exception) {
                // No tile placed, or the OEM shade does not support it.
            }
        }
    }
}
