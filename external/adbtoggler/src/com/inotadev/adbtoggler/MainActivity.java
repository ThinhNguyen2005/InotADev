package com.inotadev.adbtoggler;

import android.app.Activity;
import android.content.ComponentName;
import android.os.Bundle;
import android.service.quicksettings.TileService;
import android.util.Log;
import android.widget.Toast;

/**
 * Main activity — transparent launcher for ADB toggle.
 *
 * Dùng:
 * - Vuốt dài trên icon → "Remove" hoặc "Hide" để ẩn khỏi màn hình chính
 * - Tile vẫn hoạt động bình thường kể cả khi icon bị ẩn
 */
public class MainActivity extends Activity {

    private static final String TAG = "MainActivity";

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);

        Log.d(TAG, "Activity started");

        boolean currentEnabled = AdbUtil.isAdbEnabled(this);
        boolean newState = !currentEnabled;

        Log.d(TAG, "Toggle: " + currentEnabled + " -> " + newState);

        if (AdbUtil.setAdbEnabled(this, newState)) {
            Toast.makeText(this, AdbUtil.getToggleMessage(newState), Toast.LENGTH_SHORT).show();
        } else {
            Toast.makeText(this, AdbUtil.getErrorMessage(), Toast.LENGTH_LONG).show();
            Log.e(TAG, "Toggle failed");
        }

        try {
            TileService.requestListeningState(this, new ComponentName(this, AdbTileService.class));
        } catch (Exception e) {
            Log.e(TAG, "Tile refresh failed", e);
        }

        finish();
    }
}
