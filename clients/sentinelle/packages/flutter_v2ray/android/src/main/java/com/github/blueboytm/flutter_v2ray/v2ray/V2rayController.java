package com.github.blueboytm.flutter_v2ray.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.Build;

import com.github.blueboytm.flutter_v2ray.v2ray.core.V2rayCoreManager;
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayProxyOnlyService;
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayVPNService;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.Utilities;

import java.util.ArrayList;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;

import libv2ray.Libv2ray;

public class V2rayController {

    /**
     * Veil: registered once per process.
     *
     * init() is called from the plugin *and* from the app's own widget and tile
     * path, and upstream registered a fresh receiver on every call — one more
     * leaked receiver, and one more redundant delivery of a broadcast that
     * arrives once a second, for every connection made.
     */
    private static boolean stateReceiverRegistered = false;

    public static void init(final Context context, final int app_icon, final String app_name) {
        Utilities.copyAssets(context);
        AppConfigs.APPLICATION_ICON = app_icon;
        AppConfigs.APPLICATION_NAME = app_name;

        if (stateReceiverRegistered) {
            return;
        }
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                if (arg1 == null || arg1.getExtras() == null) {
                    return;
                }
                Object state = arg1.getExtras().getSerializable("STATE");
                if (state instanceof AppConfigs.V2RAY_STATES) {
                    AppConfigs.V2RAY_STATE = (AppConfigs.V2RAY_STATES) state;
                }
            }
        };
        try {
            Context app = context.getApplicationContext();
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                app.registerReceiver(receiver, new IntentFilter("V2RAY_CONNECTION_INFO"), Context.RECEIVER_EXPORTED);
            } else {
                app.registerReceiver(receiver, new IntentFilter("V2RAY_CONNECTION_INFO"));
            }
            stateReceiverRegistered = true;
        } catch (Exception ignored) {
            // Without it getConnectionState() is stale, which the app's own
            // watcher already covers.
        }
    }

    public static void changeConnectionMode(final AppConfigs.V2RAY_CONNECTION_MODES connection_mode) {
        if (getConnectionState() == AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
            AppConfigs.V2RAY_CONNECTION_MODE = connection_mode;
        }
    }

    /**
     * Switches the mode even when something is already running.
     *
     * {@link #changeConnectionMode} refuses while a tunnel is up, which is
     * right for a stray call but wrong for "start this connection in this
     * mode": the request would be dropped and the new connection would come up
     * in the old mode. Whichever service is running belongs to the old mode, so
     * it is stopped first — otherwise it would be orphaned, with StopV2ray
     * looking for it under the new mode and never finding it.
     */
    public static void setConnectionMode(final Context context, final AppConfigs.V2RAY_CONNECTION_MODES connection_mode) {
        if (AppConfigs.V2RAY_CONNECTION_MODE == connection_mode) {
            return;
        }
        if (getConnectionState() != AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED) {
            StopV2ray(context);
        }
        AppConfigs.V2RAY_CONNECTION_MODE = connection_mode;
    }

    public static void StartV2ray(final Context context, final String remark, final String config, final ArrayList<String> blocked_apps, final ArrayList<String> bypass_subnets) {
        AppConfigs.V2RAY_CONFIG = Utilities.parseV2rayJsonFile(remark, config, blocked_apps, bypass_subnets);
        if (AppConfigs.V2RAY_CONFIG == null) {
            return;
        }
        Intent start_intent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            start_intent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            start_intent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        start_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.START_SERVICE);
        start_intent.putExtra("V2RAY_CONFIG", AppConfigs.V2RAY_CONFIG);
        if (Build.VERSION.SDK_INT > Build.VERSION_CODES.N_MR1) {
            context.startForegroundService(start_intent);
        } else {
            context.startService(start_intent);
        }
    }

    public static void StopV2ray(final Context context) {
        Intent stop_intent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            stop_intent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            stop_intent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        stop_intent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE);
        context.startService(stop_intent);
        AppConfigs.V2RAY_CONFIG = null;
    }

    public static long getConnectedV2rayServerDelay(Context context) {
        if (V2rayController.getConnectionState() != AppConfigs.V2RAY_STATES.V2RAY_CONNECTED) {
            return -1;
        }
        Intent check_delay;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            check_delay = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            check_delay = new Intent(context, V2rayVPNService.class);
        } else {
            return -1;
        }
        final long[] delay = {-1};

        final CountDownLatch latch = new CountDownLatch(1);
        check_delay.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.MEASURE_DELAY);
        context.startService(check_delay);
        BroadcastReceiver receiver = new BroadcastReceiver() {
            @Override
            public void onReceive(Context arg0, Intent arg1) {
                String delayString = arg1.getExtras().getString("DELAY");
                delay[0] = Long.parseLong(delayString);
                context.unregisterReceiver(this);
                latch.countDown();
            }
        };

        IntentFilter delayIntentFilter = new IntentFilter("CONNECTED_V2RAY_SERVER_DELAY");
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.registerReceiver(receiver, delayIntentFilter, Context.RECEIVER_EXPORTED);
        }else{
            context.registerReceiver(receiver, delayIntentFilter);
        }

        try {
            boolean received = latch.await(3000, TimeUnit.MILLISECONDS);
            if (!received) {
                return -1;
            }
        } catch (InterruptedException e) {
            e.printStackTrace();
        }
        return delay[0];
    }

    public static long getV2rayServerDelay(final String config, final String url) {
        return V2rayCoreManager.getInstance().getV2rayServerDelay(config, url);
    }

    public static AppConfigs.V2RAY_CONNECTION_MODES getConnectionMode() {
        return AppConfigs.V2RAY_CONNECTION_MODE;
    }

    public static AppConfigs.V2RAY_STATES getConnectionState() {
        return AppConfigs.V2RAY_STATE;
    }

    public static String getCoreVersion() {
        return Libv2ray.checkVersionX();
    }


}
