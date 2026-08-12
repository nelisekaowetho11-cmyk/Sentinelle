package com.github.blueboytm.flutter_v2ray.v2ray.utils;

public class AppConfigs {

    public static V2RAY_CONNECTION_MODES V2RAY_CONNECTION_MODE = V2RAY_CONNECTION_MODES.VPN_TUN;
    public static String APPLICATION_NAME;
    public static int APPLICATION_ICON;
    public static V2rayConfig V2RAY_CONFIG = null;
    public static V2RAY_STATES V2RAY_STATE = V2RAY_STATES.V2RAY_DISCONNECTED;
    public static boolean ENABLE_TRAFFIC_AND_SPEED_STATICS = true;
    public static String DELAY_URL;
    public static String NOTIFICATION_DISCONNECT_BUTTON_NAME;

    /**
     * Veil: set whenever a STOP_SERVICE command reaches one of the services.
     *
     * That command has exactly two senders — the DISCONNECT action on the
     * ongoing notification, and the app's own stop — and both mean "the user
     * asked for this". Dart cannot otherwise tell the difference between that
     * and the core dying, so its kill switch treated a tap on DISCONNECT as a
     * dropped tunnel and reconnected a second later. Consumed (and cleared) by
     * the app over its widget method channel.
     */
    public static volatile boolean USER_REQUESTED_STOP = false;

    public enum V2RAY_SERVICE_COMMANDS {
        START_SERVICE,
        STOP_SERVICE,
        MEASURE_DELAY
    }

    public enum V2RAY_STATES {
        V2RAY_CONNECTED,
        V2RAY_DISCONNECTED,
        V2RAY_CONNECTING
    }

    public enum V2RAY_CONNECTION_MODES {
        VPN_TUN,
        PROXY_ONLY
    }
}
