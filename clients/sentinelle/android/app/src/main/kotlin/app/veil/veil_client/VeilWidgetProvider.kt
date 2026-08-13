package app.veil.veil_client

import android.app.PendingIntent
import android.appwidget.AppWidgetManager
import android.appwidget.AppWidgetProvider
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.widget.RemoteViews

/**
 * Home screen widget: one tap to connect or disconnect, and a glance to see
 * which it is.
 *
 * Widgets are drawn by the launcher from a [RemoteViews] tree, so everything
 * here is "set this text, set this drawable" — there is no live Flutter view to
 * reuse. The styling therefore lives in `res/layout/widget_toggle.xml` and the
 * two state drawables beside it.
 */
class VeilWidgetProvider : AppWidgetProvider() {

    companion object {
        private const val ACTION_TOGGLE = "app.veil.veil_client.WIDGET_TOGGLE"

        /** Repaints every placed instance. */
        fun refreshAll(context: Context) {
            val manager = AppWidgetManager.getInstance(context)
            val ids = manager.getAppWidgetIds(
                ComponentName(context, VeilWidgetProvider::class.java)
            )
            if (ids.isEmpty()) return
            for (id in ids) render(context, manager, id)
        }

        private fun render(context: Context, manager: AppWidgetManager, id: Int) {
            // What the user asked for until the core answers, then what the core
            // says. Reading the core alone drew the state being left behind: a
            // service takes a moment to start, and nothing repainted afterwards.
            val on = VpnToggle.displayActive(context)
            val busy = VpnToggle.isBusy(context)
            // With nothing remembered the widget cannot start anything, and on
            // Android 10+ it cannot even open the app from here. Saying "tap to
            // connect" and then doing nothing is what made it look broken.
            val ready = on || busy || VpnToggle.hasSavedConnection(context)

            val views = RemoteViews(context.packageName, R.layout.widget_toggle)
            views.setTextViewText(R.id.widget_status, when {
                busy && on -> "Connecting…"
                busy -> "Disconnecting…"
                on -> "Protected"
                else -> "Not connected"
            })
            views.setTextViewText(R.id.widget_action, when {
                busy -> "Tap to cancel"
                on -> "Tap to stop"
                !ready -> "Open the app first"
                else -> "Tap to connect"
            })
            views.setInt(
                R.id.widget_orb,
                "setBackgroundResource",
                if (on) R.drawable.widget_orb_on else R.drawable.widget_orb_off,
            )
            views.setTextColor(
                R.id.widget_status,
                context.getColor(if (on) R.color.veil_accent else R.color.veil_text),
            )

            val toggle = Intent(context, VeilWidgetProvider::class.java).apply {
                action = ACTION_TOGGLE
            }
            views.setOnClickPendingIntent(
                R.id.widget_root,
                PendingIntent.getBroadcast(
                    context,
                    0,
                    toggle,
                    PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
                ),
            )
            manager.updateAppWidget(id, views)
        }
    }

    override fun onUpdate(
        context: Context,
        manager: AppWidgetManager,
        ids: IntArray,
    ) {
        // A widget being placed or restored is the first chance to start
        // watching the core in a process that was woken by the launcher.
        VpnToggle.ensureStateWatcher(context)
        for (id in ids) render(context, manager, id)
    }

    override fun onReceive(context: Context, intent: Intent) {
        super.onReceive(context, intent)
        // Whatever woke this receiver, the process may be brand new — start
        // listening to the core before reading anything out of it.
        VpnToggle.ensureStateWatcher(context)
        when (intent.action) {
            ACTION_TOGGLE -> {
                if (!VpnToggle.toggle(context)) {
                    // Nothing saved, or consent still needed — only the app can
                    // deal with either. Since Android 10 a receiver may not
                    // start an activity from the background at all, so this is
                    // allowed to fail; the widget face says "Open the app" in
                    // that state, which is the honest instruction either way.
                    try {
                        context.startActivity(VpnToggle.openApp(context))
                    } catch (_: Exception) {
                    }
                }
                // toggle() already repainted with what was asked for, and the
                // watcher repaints again once the core answers.
            }
            VpnToggle.ACTION_STATE_CHANGED -> refreshAll(context)
        }
    }
}
