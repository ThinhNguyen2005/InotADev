package com.inotadev.adbtoggler;

import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.util.Log;

/**
 * Quick Settings Tile for ADB toggle.
 *
 * Features:
 * - Bật/tắt ADB trực tiếp từ Control Center
 * - Tự cập nhật khi AutoToggle daemon hoặc app khác thay đổi ADB
 * - Trạng thái tile đồng bộ với thực tế
 */
public class AdbTileService extends TileService implements AdbStateObserver.OnAdbStateChanged {

    private static final String TAG = "AdbTileService";
    private AdbStateObserver observer;

    @Override
    public void onStartListening() {
        super.onStartListening();
        updateTile();

        observer = new AdbStateObserver(getContentResolver(), this);
        observer.register();
    }

    @Override
    public void onStopListening() {
        super.onStopListening();
        if (observer != null) {
            observer.unregister();
            observer = null;
        }
    }

    @Override
    public void onAdbStateChanged(boolean enabled) {
        updateTile();
    }

    @Override
    public void onClick() {
        super.onClick();

        boolean currentEnabled = AdbStateObserver.getAdbEnabled(getContentResolver());
        boolean newState = !currentEnabled;

        Log.d(TAG, "Tile: " + currentEnabled + " -> " + newState);

        if (AdbUtil.setAdbEnabled(this, newState)) {
            updateTile();
        } else {
            Log.e(TAG, "Toggle failed");
        }
    }

    private void updateTile() {
        Tile tile = getQsTile();
        if (tile == null) return;

        boolean enabled = AdbStateObserver.getAdbEnabled(getContentResolver());
        tile.setState(enabled ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel(enabled ? "ADB: BẬT" : "ADB: TẮT");
        tile.updateTile();
    }
}
