package com.github.blueboytm.flutter_v2ray.v2ray;

import android.content.BroadcastReceiver;
import android.content.Context;
import android.content.Intent;
import android.util.Log;

import java.util.ArrayList;

import io.flutter.plugin.common.EventChannel;

public class V2rayReceiver extends BroadcastReceiver {
    public static EventChannel.EventSink vpnStatusSink;

    @Override
    public void onReceive(Context context, Intent intent) {
        try {
            ArrayList<String> list = new ArrayList<>();
            list.add(intent.getExtras().getString("DURATION"));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_SPEED", 0)));
            list.add(String.valueOf(intent.getLongExtra("UPLOAD_TRAFFIC", 0)));
            list.add(String.valueOf(intent.getLongExtra("DOWNLOAD_TRAFFIC", 0)));
            list.add(intent.getExtras().getSerializable("STATE").toString().substring(6));
            // Veil: whether the stop this reports was asked for by a person.
            //
            // It rides the same broadcast as the state so Dart learns both in
            // one event. Asking the native side separately — which is what the
            // app used to do — raced two receivers registered in the same
            // process for the same intent, and Android does not order those.
            // When the question lost, a tap on the notification's DISCONNECT
            // looked like an unexplained drop and the kill switch reconnected
            // the tunnel a few seconds later.
            list.add(String.valueOf(intent.getBooleanExtra("USER_STOP", false)));
            vpnStatusSink.success(list);
        } catch (Exception e) {
            Log.e("V2rayReceiver", "onReceive failed", e);
        }
    }

}
