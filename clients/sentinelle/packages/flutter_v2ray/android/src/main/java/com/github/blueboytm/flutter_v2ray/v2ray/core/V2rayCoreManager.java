package com.github.blueboytm.flutter_v2ray.v2ray.core;

import static com.github.blueboytm.flutter_v2ray.v2ray.utils.Utilities.getUserAssetsPath;

import android.Manifest;
import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationManager;
import android.app.PendingIntent;
import android.app.Service;
import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.graphics.Color;
import android.os.Build;
import android.os.CountDownTimer;
import android.util.Log;

import androidx.annotation.RequiresApi;
import androidx.core.app.ActivityCompat;
import androidx.core.app.NotificationCompat;

import com.github.blueboytm.flutter_v2ray.v2ray.interfaces.V2rayServicesListener;
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayProxyOnlyService;
import com.github.blueboytm.flutter_v2ray.v2ray.services.V2rayVPNService;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.AppConfigs;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.Utilities;
import com.github.blueboytm.flutter_v2ray.v2ray.utils.V2rayConfig;

import org.json.JSONObject;

import libv2ray.Libv2ray;
import libv2ray.V2RayPoint;
import libv2ray.V2RayVPNServiceSupportsSet;

public final class V2rayCoreManager {
    private static final int NOTIFICATION_ID = 1;
    private volatile static V2rayCoreManager INSTANCE;
    public V2rayServicesListener v2rayServicesListener = null;
    public final V2RayPoint v2RayPoint = Libv2ray.newV2RayPoint(new V2RayVPNServiceSupportsSet() {
        @Override
        public long shutdown() {
            if (v2rayServicesListener == null) {
                Log.e(V2rayCoreManager.class.getSimpleName(), "shutdown failed => can`t find initial service.");
                return -1;
            }
            try {
                v2rayServicesListener.stopService();
                v2rayServicesListener = null;
                return 0;
            } catch (Exception e) {
                Log.e(V2rayCoreManager.class.getSimpleName(), "shutdown failed =>", e);
                return -1;
            }
        }

        @Override
        public long prepare() {
            return 0;
        }

        @Override
        public boolean protect(long l) {
            if (v2rayServicesListener != null)
                return v2rayServicesListener.onProtect((int) l);
            return true;
        }

        @Override
        public long onEmitStatus(long l, String s) {
            return 0;
        }

        @Override
        public long setup(String s) {
            if (v2rayServicesListener != null) {
                try {
                    v2rayServicesListener.startService();
                } catch (Exception e) {
                    Log.e(V2rayCoreManager.class.getSimpleName(), "setup failed => ", e);
                    return -1;
                }
            }
            return 0;
        }
    }, Build.VERSION.SDK_INT >= Build.VERSION_CODES.N_MR1);
    public AppConfigs.V2RAY_STATES V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
    private boolean isLibV2rayCoreInitialized = false;
    private CountDownTimer countDownTimer;
    private int seconds, minutes, hours;
    private long totalDownload, totalUpload, uploadSpeed, downloadSpeed;
    private String SERVICE_DURATION = "00:00:00";

    // Veil: the notification is rebuilt every second with live traffic, so the
    // builder and the remark it was created with are kept around. Upstream
    // posted a static notification once and never touched it again, which meant
    // the only place the user could see throughput was inside the app.
    private NotificationCompat.Builder notificationBuilder;
    private String notificationRemark = "";

    public static V2rayCoreManager getInstance() {
        if (INSTANCE == null) {
            synchronized (V2rayCoreManager.class) {
                if (INSTANCE == null) {
                    INSTANCE = new V2rayCoreManager();
                }
            }
        }
        return INSTANCE;
    }

    private void makeDurationTimer(final Context context, final boolean enable_traffic_statics) {
        countDownTimer = new CountDownTimer(7200, 1000) {
            @RequiresApi(api = Build.VERSION_CODES.M)
            public void onTick(long millisUntilFinished) {
                seconds++;
                if (seconds == 59) {
                    minutes++;
                    seconds = 0;
                }
                if (minutes == 59) {
                    minutes = 0;
                    hours++;
                }
                if (hours == 23) {
                    hours = 0;
                }
                if (enable_traffic_statics) {
                    downloadSpeed = v2RayPoint.queryStats("block", "downlink") + v2RayPoint.queryStats("proxy", "downlink");
                    uploadSpeed = v2RayPoint.queryStats("block", "uplink") + v2RayPoint.queryStats("proxy", "uplink");
                    totalDownload = totalDownload + downloadSpeed;
                    totalUpload = totalUpload + uploadSpeed;
                }
                SERVICE_DURATION = Utilities.convertIntToTwoDigit(hours) + ":" + Utilities.convertIntToTwoDigit(minutes) + ":" + Utilities.convertIntToTwoDigit(seconds);
                Intent connection_info_intent = new Intent("V2RAY_CONNECTION_INFO");
                connection_info_intent.putExtra("STATE", V2rayCoreManager.getInstance().V2RAY_STATE);
                connection_info_intent.putExtra("DURATION", SERVICE_DURATION);
                connection_info_intent.putExtra("UPLOAD_SPEED", uploadSpeed);
                connection_info_intent.putExtra("DOWNLOAD_SPEED", downloadSpeed);
                connection_info_intent.putExtra("UPLOAD_TRAFFIC", totalUpload);
                connection_info_intent.putExtra("DOWNLOAD_TRAFFIC", totalDownload);
                // Veil: addressed to ourselves. Two flavours of this app now
                // exist under different applicationIds (the sideload build and
                // the Play build), and an unqualified broadcast would let one
                // of them drive the other's speed readout and widget.
                connection_info_intent.setPackage(context.getPackageName());
                context.sendBroadcast(connection_info_intent);
                if (enable_traffic_statics) {
                    updateNotification();
                }
            }

            public void onFinish() {
                countDownTimer.cancel();
                if (V2rayCoreManager.getInstance().isV2rayCoreRunning())
                    makeDurationTimer(context, enable_traffic_statics);
            }
        }.start();
    }

    public void setUpListener(Service targetService) {
        try {
            v2rayServicesListener = (V2rayServicesListener) targetService;
            Libv2ray.initV2Env(getUserAssetsPath(targetService.getApplicationContext()), "");
            isLibV2rayCoreInitialized = true;
            SERVICE_DURATION = "00:00:00";
            seconds = 0;
            minutes = 0;
            hours = 0;
            uploadSpeed = 0;
            downloadSpeed = 0;
            totalDownload = 0;
            totalUpload = 0;
            Log.e(V2rayCoreManager.class.getSimpleName(), "setUpListener => new initialize from " + v2rayServicesListener.getService().getClass().getSimpleName());
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "setUpListener failed => ", e);
            isLibV2rayCoreInitialized = false;
        }
    }

    public boolean startCore(final V2rayConfig v2rayConfig) {
        makeDurationTimer(v2rayServicesListener.getService().getApplicationContext(),
                v2rayConfig.ENABLE_TRAFFIC_STATICS);
        V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTING;
        if (!isLibV2rayCoreInitialized) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "startCore failed => LibV2rayCore should be initialize before start.");
            return false;
        }
        if (isV2rayCoreRunning()) {
            stopCore();
        }
        try {
            v2RayPoint.setConfigureFileContent(v2rayConfig.V2RAY_FULL_JSON_CONFIG);
            v2RayPoint.setDomainName(v2rayConfig.CONNECTED_V2RAY_SERVER_ADDRESS + ":" + v2rayConfig.CONNECTED_V2RAY_SERVER_PORT);
            v2RayPoint.runLoop(false);
            V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_CONNECTED;
            if (isV2rayCoreRunning()) {
                showNotification(v2rayConfig);
            }
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "startCore failed =>", e);
            return false;
        }
        return true;
    }

    public void stopCore() {
        try {
            NotificationManager notificationManager = (NotificationManager) v2rayServicesListener.getService().getSystemService(Context.NOTIFICATION_SERVICE);
            if (notificationManager != null) {
                notificationManager.cancel(NOTIFICATION_ID);
            }
            notificationBuilder = null;
            lastNotificationText = null;
            if (isV2rayCoreRunning()) {
                v2RayPoint.stopLoop();
                v2rayServicesListener.stopService();
                Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore success => v2ray core stopped.");
            } else {
                Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore failed => v2ray core not running.");
            }
            sendDisconnectedBroadCast();
        } catch (Exception e) {
            Log.e(V2rayCoreManager.class.getSimpleName(), "stopCore failed =>", e);
        }
    }

    private void sendDisconnectedBroadCast() {
        V2RAY_STATE = AppConfigs.V2RAY_STATES.V2RAY_DISCONNECTED;
        SERVICE_DURATION = "00:00:00";
        seconds = 0;
        minutes = 0;
        hours = 0;
        uploadSpeed = 0;
        downloadSpeed = 0;
        if (v2rayServicesListener != null) {
            Intent connection_info_intent = new Intent("V2RAY_CONNECTION_INFO");
            connection_info_intent.putExtra("STATE", V2rayCoreManager.getInstance().V2RAY_STATE);
            connection_info_intent.putExtra("DURATION", SERVICE_DURATION);
            connection_info_intent.putExtra("UPLOAD_SPEED", uploadSpeed);
            connection_info_intent.putExtra("DOWNLOAD_SPEED", uploadSpeed);
            connection_info_intent.putExtra("UPLOAD_TRAFFIC", uploadSpeed);
            connection_info_intent.putExtra("DOWNLOAD_TRAFFIC", uploadSpeed);
            try {
                // Veil: kept to our own package, like the tick above.
                connection_info_intent.setPackage(
                        v2rayServicesListener.getService().getPackageName());
                v2rayServicesListener.getService().getApplicationContext().sendBroadcast(connection_info_intent);
            } catch (Exception e) {
                //ignore
            }
        }
        if (countDownTimer != null) {
            countDownTimer.cancel();
        }
    }

    /** Upstream's channel. Left behind so it can be deleted, never posted to. */
    private static final String LEGACY_CHANNEL_ID = "A_FLUTTER_V2RAY_SERVICE_CH_ID";

    /**
     * Veil: a *new* channel id, deliberately.
     *
     * The old one was created with {@code IMPORTANCE_DEFAULT}, and on Android 8+
     * the channel's importance overrides the notification's own priority. That
     * made the ongoing tunnel notification an alerting one — and because it is
     * repainted every second with live speeds, OEM notification effects fired
     * every second with it. On Samsung that is Edge lighting: with the screen
     * off, a blue outline swept around the display, faded, and came back a
     * second later, all night.
     *
     * An existing channel's importance cannot reliably be lowered in place —
     * the system ignores the change once the user has touched the channel — so
     * the fix has to arrive under a name the device has not seen before.
     */
    private static final String CHANNEL_ID = "VEIL_VPN_STATUS_CH_V2";

    private String createNotificationChannelID(String appName) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            NotificationManager notificationManager =
                    (NotificationManager) v2rayServicesListener.getService().getSystemService(Context.NOTIFICATION_SERVICE);
            if (notificationManager == null) {
                return CHANNEL_ID;
            }

            // Nothing posts to it any more, and leaving it would show the user
            // two entries for one notification in the system settings.
            try {
                notificationManager.deleteNotificationChannel(LEGACY_CHANNEL_ID);
            } catch (Exception ignored) {
                // A channel that was never created is not an error.
            }

            String channelName = appName + " VPN status";
            // IMPORTANCE_LOW is the right level for a foreground-service
            // notification: always visible, never announced.
            NotificationChannel channel = new NotificationChannel(
                    CHANNEL_ID, channelName, NotificationManager.IMPORTANCE_LOW);
            channel.setDescription("Shows the tunnel while it is running.");
            // Every one of these is a way for a repaint to reach the screen or
            // the user's attention, which is exactly what has to stop.
            channel.enableLights(false);
            channel.setLightColor(Color.TRANSPARENT);
            channel.enableVibration(false);
            channel.setVibrationPattern(null);
            channel.setSound(null, null);
            channel.setShowBadge(false);
            channel.setLockscreenVisibility(Notification.VISIBILITY_PRIVATE);
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
                // Keeps the repaints out of the notification history bubble-up
                // on the phones that support it.
                channel.setAllowBubbles(false);
            }

            notificationManager.createNotificationChannel(channel);
            return CHANNEL_ID;
        }
        return "";
    }

    private void showNotification(final V2rayConfig v2rayConfig) {
        Service context = v2rayServicesListener.getService();
        if (context == null) {
            return;
        }

        // Check notification permission for Android 13+
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            if (ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
                    != PackageManager.PERMISSION_GRANTED) {
                return;
            }
        }

        Intent launchIntent = context.getPackageManager().getLaunchIntentForPackage(context.getPackageName());
        if (launchIntent != null) {
            launchIntent.setAction("FROM_DISCONNECT_BTN");
            launchIntent.setFlags(Intent.FLAG_ACTIVITY_NEW_TASK | Intent.FLAG_ACTIVITY_CLEAR_TASK);
        }
        final int flags;
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            flags = PendingIntent.FLAG_IMMUTABLE | PendingIntent.FLAG_UPDATE_CURRENT;
        } else {
            flags = PendingIntent.FLAG_UPDATE_CURRENT;
        }
        PendingIntent notificationContentPendingIntent = PendingIntent.getActivity(
                context, 0, launchIntent, flags);

        String notificationChannelID = createNotificationChannelID(v2rayConfig.APPLICATION_NAME);

        Intent stopIntent;
        if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.PROXY_ONLY) {
            stopIntent = new Intent(context, V2rayProxyOnlyService.class);
        } else if (AppConfigs.V2RAY_CONNECTION_MODE == AppConfigs.V2RAY_CONNECTION_MODES.VPN_TUN) {
            stopIntent = new Intent(context, V2rayVPNService.class);
        } else {
            return;
        }
        stopIntent.putExtra("COMMAND", AppConfigs.V2RAY_SERVICE_COMMANDS.STOP_SERVICE);

        PendingIntent pendingIntent = PendingIntent.getService(
                context, 0, stopIntent, flags);

        // Build the notification
        notificationRemark = v2rayConfig.REMARK;
        lastNotificationText = null;
        notificationBuilder = new NotificationCompat.Builder(context, notificationChannelID)
                .setSmallIcon(v2rayConfig.APPLICATION_ICON)
                .setContentTitle(v2rayConfig.REMARK)
                .setContentText(buildTrafficLine())
                // The one-line form is what shows on the lock screen; the
                // expanded form has room for the session totals as well.
                .setStyle(new NotificationCompat.BigTextStyle().bigText(buildTrafficDetail()))
                .addAction(0, v2rayConfig.NOTIFICATION_DISCONNECT_BUTTON_NAME, pendingIntent)
                .setPriority(NotificationCompat.PRIORITY_MIN)
                .setShowWhen(false)
                .setOnlyAlertOnce(true)
                // Belt and braces alongside the low-importance channel: these
                // are what stop a repaint from alerting on Android 7 and
                // earlier, where the channel does not exist.
                .setSilent(true)
                .setDefaults(0)
                .setCategory(NotificationCompat.CATEGORY_SERVICE)
                // A paired watch lighting up once a second is the same bug
                // wearing a different screen.
                .setLocalOnly(true)
                .setContentIntent(notificationContentPendingIntent)
                .setOngoing(true);

        context.startForeground(NOTIFICATION_ID, notificationBuilder.build());
    }

    /** The last line posted, so an unchanged one is not posted again. */
    private String lastNotificationText = null;

    /**
     * True when the screen is on, so the notification is worth repainting.
     *
     * A dark screen cannot show anyone a speed reading, but the OEM effects
     * that run on a notification post — Samsung's Edge lighting, always-on
     * display wake-ups — very much still fire. Repainting once a second into a
     * screen nobody is looking at was the whole of that bug.
     */
    private boolean screenIsOn(Context context) {
        try {
            android.os.PowerManager pm =
                    (android.os.PowerManager) context.getSystemService(Context.POWER_SERVICE);
            if (pm == null) return true;
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.KITKAT_WATCH) {
                return pm.isInteractive();
            }
            return true;
        } catch (Exception e) {
            // If we cannot tell, behave as before rather than going silent.
            return true;
        }
    }

    /**
     * Veil: repaints the ongoing notification with the current speeds and the
     * data moved so far.
     *
     * Three guards, all of them about *not* posting:
     *  - nothing while the screen is off, which is when a post is invisible to
     *    the user but still visible to the launcher's notification effects;
     *  - nothing when the text has not changed, so an idle tunnel settles down
     *    to no posts at all rather than one a second;
     *  - the channel is IMPORTANCE_LOW and {@code setOnlyAlertOnce} is set, so
     *    the posts that do happen update in place silently.
     */
    private void updateNotification() {
        if (notificationBuilder == null || v2rayServicesListener == null) {
            return;
        }
        Service context = v2rayServicesListener.getService();
        if (context == null) {
            return;
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU
                && ActivityCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS)
                != PackageManager.PERMISSION_GRANTED) {
            return;
        }
        if (!screenIsOn(context)) {
            // Forces one repaint on the tick after the screen comes back, so
            // the user never reads a stale figure.
            lastNotificationText = null;
            return;
        }
        try {
            final String detail = buildTrafficDetail();
            if (detail.equals(lastNotificationText)) {
                return;
            }
            lastNotificationText = detail;
            notificationBuilder
                    .setContentTitle(notificationRemark)
                    .setContentText(buildTrafficLine())
                    .setStyle(new NotificationCompat.BigTextStyle().bigText(detail));
            NotificationManager manager =
                    (NotificationManager) context.getSystemService(Context.NOTIFICATION_SERVICE);
            if (manager != null) {
                manager.notify(NOTIFICATION_ID, notificationBuilder.build());
            }
        } catch (Exception e) {
            // A notification that failed to repaint must never take the tunnel
            // down with it.
            Log.e(V2rayCoreManager.class.getSimpleName(), "updateNotification failed => ", e);
        }
    }

    // Escaped rather than literal arrows: this file is compiled with whatever
    // encoding the toolchain picks, and a mangled glyph in a notification is a
    // silly way to lose a release.
    private static final String DOWN = "\u2193";
    private static final String UP = "\u2191";

    /** "down 1.4 MB/s   up 210 KB/s" */
    private String buildTrafficLine() {
        return DOWN + " " + formatBytes(downloadSpeed) + "/s   "
                + UP + " " + formatBytes(uploadSpeed) + "/s";
    }

    /** The expanded form: speeds, session totals and how long it has been up. */
    private String buildTrafficDetail() {
        return buildTrafficLine()
                + "\nTotal  " + DOWN + " " + formatBytes(totalDownload)
                + "   " + UP + " " + formatBytes(totalUpload)
                + "\nConnected " + SERVICE_DURATION;
    }

    private static String formatBytes(long bytes) {
        if (bytes >= 1073741824L) {
            return String.format(java.util.Locale.US, "%.2f GB", bytes / 1073741824.0);
        }
        if (bytes >= 1048576L) {
            return String.format(java.util.Locale.US, "%.1f MB", bytes / 1048576.0);
        }
        if (bytes >= 1024L) {
            return String.format(java.util.Locale.US, "%.1f KB", bytes / 1024.0);
        }
        return bytes + " B";
    }


    public boolean isV2rayCoreRunning() {
        if (v2RayPoint != null) {
            return v2RayPoint.getIsRunning();
        }
        return false;
    }

    public Long getConnectedV2rayServerDelay() {
        try {
            return v2RayPoint.measureDelay(AppConfigs.DELAY_URL);
        } catch (Exception e) {
            return -1L;
        }
    }

    public Long getV2rayServerDelay(final String config, final String url) {
        try {
            try {
                JSONObject config_json = new JSONObject(config);
                JSONObject new_routing_json = config_json.getJSONObject("routing");
                new_routing_json.remove("rules");
                config_json.remove("routing");
                config_json.put("routing", new_routing_json);
                return Libv2ray.measureOutboundDelay(config_json.toString(), url);
            } catch (Exception json_error) {
                Log.e("getV2rayServerDelay", json_error.toString());
                return Libv2ray.measureOutboundDelay(config, url);
            }
        } catch (Exception e) {
            Log.e("getV2rayServerDelayCore", e.toString());
            return -1L;
        }
    }

}
