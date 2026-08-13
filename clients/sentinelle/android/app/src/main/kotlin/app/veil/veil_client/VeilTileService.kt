package app.veil.veil_client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.drawable.Icon
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import androidx.annotation.RequiresApi

/**
 * The quick settings tile — the toggle in the shade next to wi-fi and torch.
 *
 * Deliberately does the work itself rather than opening the app: pulling the
 * shade down, tapping, and being dumped into a launching app would be slower
 * than just opening the app in the first place. It only falls back to opening
 * the app when it genuinely cannot proceed — nothing has ever been connected,
 * or the VPN consent dialog has not been accepted, which only an Activity can
 * show.
 */
@RequiresApi(Build.VERSION_CODES.N)
class VeilTileService : TileService() {

    /**
     * The core broadcasts progress once a second while connected. Listening
     * only while the shade is open keeps the tile honest without keeping a
     * receiver alive for nothing.
     */
    private val stateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) = refresh()
    }
    private var listening = false

    override fun onStartListening() {
        super.onStartListening()
        // Also keeps the widget in step when the shade is the only thing open.
        VpnToggle.ensureStateWatcher(this)
        if (!listening) {
            val filter = IntentFilter("V2RAY_CONNECTION_INFO")
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                registerReceiver(stateReceiver, filter, Context.RECEIVER_EXPORTED)
            } else {
                @Suppress("UnspecifiedRegisterReceiverFlag")
                registerReceiver(stateReceiver, filter)
            }
            listening = true
        }
        refresh()
    }

    override fun onStopListening() {
        if (listening) {
            runCatching { unregisterReceiver(stateReceiver) }
            listening = false
        }
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        if (!VpnToggle.toggle(this)) {
            openTheApp()
            return
        }
        // toggle() records what was asked for, so this draws the new state
        // rather than the one being left. Repainting from the core's own state
        // here is what made the tile lag a tap behind: a service takes a moment
        // to start, and nothing repainted once it had.
        refresh()
    }

    private fun openTheApp() {
        val intent = VpnToggle.openApp(this)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pending = android.app.PendingIntent.getActivity(
                this,
                0,
                intent,
                android.app.PendingIntent.FLAG_IMMUTABLE or
                    android.app.PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pending)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private fun refresh() = setTile(
        active = VpnToggle.displayActive(this),
        busy = VpnToggle.isBusy(this),
    )

    private fun setTile(active: Boolean, busy: Boolean) {
        val tile = qsTile ?: return
        // Deliberately still tappable with nothing saved: the tap opens the app,
        // which is where the user has to go to pick a location anyway. An
        // unavailable tile would swallow that.
        tile.state = if (active) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = "Sentinelle"
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_shield)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            tile.subtitle = when {
                busy && active -> "Connecting…"
                busy -> "Disconnecting…"
                active -> "Protected"
                !VpnToggle.hasSavedConnection(this) -> "Tap to set up"
                else -> "Off"
            }
        }
        tile.updateTile()
    }
}
