package app.veil.veil_client

import android.app.ActivityManager
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
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayProxyOnlyService
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayVPNService
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

    /** Extras on that broadcast. Both are written by the core's own process. */
    private const val EXTRA_STATE = "STATE"
    private const val EXTRA_USER_STOP = "USER_STOP"

    /**
     * How long a toggle keeps showing what was asked for before giving up and
     * showing what actually happened. Long enough for a slow handshake, short
     * enough that a start which never got off the ground does not leave
     * "Connecting…" on the home screen.
     */
    private const val PENDING_TIMEOUT_MS = 30_000L

    // ── Live state ────────────────────────────────────────────────────────────
    //
    // **The core does not run in this process.** flutter_v2ray declares both of
    // its services with `android:process=":RunSoLibV2RayDaemon"`, so every
    // static it keeps — V2rayCoreManager.V2RAY_STATE, AppConfigs.V2RAY_STATE,
    // AppConfigs.USER_REQUESTED_STOP — exists twice: the copy the core writes,
    // and the copy this process reads. Ours is never written, so it answered
    // "disconnected" for the entire life of a working tunnel. That is why a tap
    // on the widget lit it up and then dropped it again a second and a half
    // later while the VPN was plainly running, and why the app's startup sweep
    // could not tell a live tunnel from a crashed one and killed it.
    //
    // Two sources that do cross the process boundary:
    //
    //  1. the core's own V2RAY_CONNECTION_INFO broadcast, once a second while it
    //     is up and once more as it goes down — authoritative, but only while
    //     something in this process is listening;
    //  2. whether the service is in the running list, which is answerable at any
    //     moment, including in a process the launcher has just woken up.

    /** Last state the core told us about, and when. */
    @Volatile private var observed: AppConfigs.V2RAY_STATES? = null
    @Volatile private var observedAt = 0L

    /**
     * How long a broadcast stays the better answer.
     *
     * The core talks once a second, so anything older than a few ticks means it
     * has stopped talking — at which point the service list is the truth.
     */
    private const val OBSERVED_FRESH_MS = 4_000L

    /** Held so a state can be read from calls that have no context of their own. */
    @Volatile private var appContext: Context? = null

    private fun coreState(context: Context? = null): AppConfigs.V2RAY_STATES {
        val seen = observed
        if (seen != null &&
            SystemClock.elapsedRealtime() - observedAt <= OBSERVED_FRESH_MS
        ) {
            return seen
        }
        val ctx = context?.applicationContext ?: appContext
        if (ctx != null && tunnelServiceRunning(ctx)) {
            // The service is alive but silent. Either it is still coming up —
            // which the last broadcast would have said — or it is up and we
            // started listening too late to have heard a tick yet.
            return if (seen == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING) seen
            else AppConfigs.V2RAY_STATES.V2RAY_CONNECTED
        }
        return AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED
    }

    /**
     * True when one of the core's services is running, whichever process it is
     * in.
     *
     * `getRunningServices` stopped reporting other apps' services in Android 8
     * and is deprecated for that reason, but it still answers for the caller's
     * own — which is the whole question here.
     */
    @Suppress("DEPRECATION")
    private fun runningTunnelService(context: Context): String? = try {
        val manager =
            context.getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        val vpn = V2rayVPNService::class.java.name
        val proxy = V2rayProxyOnlyService::class.java.name
        manager.getRunningServices(Int.MAX_VALUE)
            .map { it.service.className }
            .firstOrNull { it == vpn || it == proxy }
    } catch (_: Throwable) {
        null
    }

    private fun tunnelServiceRunning(context: Context): Boolean =
        runningTunnelService(context) != null

    /**
     * Points `AppConfigs.V2RAY_CONNECTION_MODE` at the service that is really
     * running.
     *
     * Stopping the tunnel means sending an intent, and which service it is
     * addressed to is decided by that static — in *this* process, where it is
     * whatever the last connection set it to, or the compiled-in default in a
     * process that has not connected yet. Swipe the app away while a proxy-mode
     * tunnel is running and the core survives (it is a foreground service in
     * its own process) while this static resets: the next stop is then
     * addressed to the VPN service, which is not the one holding the
     * connection, and the tunnel stays up. The running service is the honest
     * answer and it can be read at any time.
     */
    fun syncConnectionMode(context: Context) {
        when (runningTunnelService(context)) {
            V2rayVPNService::class.java.name ->
                AppConfigs.V2RAY_CONNECTION_MODE =
                    AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN
            V2rayProxyOnlyService::class.java.name ->
                AppConfigs.V2RAY_CONNECTION_MODE =
                    AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY
        }
    }

    fun isRunning(): Boolean =
        coreState() == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED

    /** Connected *or* on its way there — "is there a tunnel to stop". */
    fun isActive(): Boolean =
        coreState() != AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED

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
    private fun settle(context: Context? = null) {
        if (pendingTarget == null) return
        when (coreState(context)) {
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
    fun displayActive(context: Context? = null): Boolean =
        pending() ?: (coreState(context) == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED)

    fun isBusy(context: Context? = null): Boolean {
        val state = coreState(context)
        val target = pending()
        if (target != null) {
            return target != (state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTED)
        }
        return state == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
    }

    private fun renderKey(context: Context? = null): Pair<Boolean, Boolean> =
        displayActive(context) to isBusy(context)

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
        val asked = userStopSeen || AppConfigs.USER_REQUESTED_STOP
        userStopSeen = false
        AppConfigs.USER_REQUESTED_STOP = false
        return asked
    }

    /**
     * The cross-process half of the same answer.
     *
     * `AppConfigs.USER_REQUESTED_STOP` is set by whichever service handled the
     * STOP_SERVICE — in the daemon process, where nothing this class can read
     * ever sees it. So the daemon puts the same flag on the broadcast it sends
     * as it goes down, and the watcher below latches it here.
     */
    @Volatile private var userStopSeen = false

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
        // The watcher is what keeps the reading below honest, and this may be
        // the first code to run in a process the launcher just woke up.
        ensureStateWatcher(context)
        // Off what is on screen, not off the core: a second tap while a tunnel
        // is still coming up means "no, stop".
        if (displayActive(context) ||
            coreState(context) == AppConfigs.V2RAY_STATES.V2RAY_CONNECTING
        ) {
            stop(context)
            return true
        }
        return start(context)
    }

    fun stop(context: Context) {
        markPending(false)
        ensureStateWatcher(context)
        // The tile and the widget can both be tapped in a process that has
        // never started a tunnel, where the mode static is only a default.
        syncConnectionMode(context)
        // Nobody stops a tunnel from a widget or a tile by accident, and the
        // app must not treat it as a drop worth recovering from.
        userStopSeen = true
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
        userStopSeen = false
        ensureStateWatcher(context)

        // The notification's action label is read out of this static when the
        // config is parsed. Dart sets it on its own starts; started from here
        // it was null, and an action with no title is a button the shade draws
        // as an empty strip — "the notification has no disconnect button",
        // except on the runs where the app had already set it.
        AppConfigs.NOTIFICATION_DISCONNECT_BUTTON_NAME = "DISCONNECT"
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
        val app = context.applicationContext
        appContext = app
        if (watching) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(c: Context?, intent: Intent?) {
                if (intent != null) record(intent)
                settle(app)
                // The core talks once a second while connected; only a change
                // is worth the trip out to the launcher and SystemUI.
                if (renderKey(app) != lastRendered) notifyStateChanged(app)
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
                settle(app)
                if (renderKey(app) != lastRendered) notifyStateChanged(app)
            }, delay)
        }
    }

    /**
     * Takes what the core just said out of its broadcast.
     *
     * This is the only channel that crosses out of the daemon process, so it
     * carries both halves: what the state is, and whether the stop that is
     * about to follow was asked for by a person.
     */
    private fun record(intent: Intent) {
        val state = try {
            @Suppress("DEPRECATION")
            intent.getSerializableExtra(EXTRA_STATE) as? AppConfigs.V2RAY_STATES
        } catch (_: Throwable) {
            null
        }
        if (state != null) {
            observed = state
            observedAt = SystemClock.elapsedRealtime()
        }
        if (intent.getBooleanExtra(EXTRA_USER_STOP, false)) userStopSeen = true
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
        val app = context.applicationContext
        appContext = app
        lastRendered = renderKey(app)

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
