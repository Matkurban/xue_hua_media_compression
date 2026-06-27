package com.flutter_rust_bridge.xue_hua_media_compression;

import android.content.Context;
import androidx.annotation.NonNull;
import io.flutter.embedding.engine.plugins.FlutterPlugin;

public class XueHuaMediaCompressionPlugin implements FlutterPlugin {
    static {
        System.loadLibrary("xue_hua_media_compression");
    }

    private static native void initAndroid(Context ctx);

    @Override
    public void onAttachedToEngine(@NonNull FlutterPluginBinding binding) {
        initAndroid(binding.getApplicationContext());
    }

    @Override
    public void onDetachedFromEngine(@NonNull FlutterPluginBinding binding) {}
}
