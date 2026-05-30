package com.inotadev.adbtoggler;

import android.content.ContentResolver;
import android.content.Context;
import android.database.ContentObserver;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.provider.Settings;
import android.util.Log;

/**
 * Observes Settings.Global.ADB_ENABLED changes from ANY source
 * (AutoToggle daemon, manual toggle, other apps) and notifies listeners.
 * This keeps the Quick Settings Tile in sync with reality.
 */
public class AdbStateObserver extends ContentObserver {

    private static final String TAG = "AdbStateObserver";
    private static final Uri ADB_URI = Settings.Global.getUriFor(Settings.Global.ADB_ENABLED);

    public interface OnAdbStateChanged {
        void onAdbStateChanged(boolean enabled);
    }

    private final ContentResolver resolver;
    private final OnAdbStateChanged listener;
    private final Handler mainHandler;

    public AdbStateObserver(ContentResolver resolver, OnAdbStateChanged listener) {
        super(new Handler(Looper.getMainLooper()));
        this.resolver = resolver;
        this.listener = listener;
        this.mainHandler = new Handler(Looper.getMainLooper());
    }

    @Override
    public void onChange(boolean selfChange, Uri uri) {
        if (uri == null || ADB_URI.equals(uri)) {
            boolean enabled = getAdbEnabled();
            Log.d(TAG, "ADB state changed: " + enabled);
            if (listener != null) {
                mainHandler.post(() -> listener.onAdbStateChanged(enabled));
            }
        }
    }

    public void register() {
        if (resolver != null) {
            resolver.registerContentObserver(ADB_URI, false, this);
            Log.d(TAG, "Observer registered");
        }
    }

    public void unregister() {
        if (resolver != null) {
            try {
                resolver.unregisterContentObserver(this);
            } catch (Exception ignored) {}
        }
    }

    public static boolean getAdbEnabled(ContentResolver resolver) {
        if (resolver == null) return false;
        try {
            return Settings.Global.getInt(resolver, Settings.Global.ADB_ENABLED, 0) == 1;
        } catch (Exception e) {
            return false;
        }
    }

    public boolean getAdbEnabled() {
        return getAdbEnabled(resolver);
    }
}
