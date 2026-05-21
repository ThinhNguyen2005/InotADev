package com.inotadev.adbtoggler;

import android.content.ComponentName;
import android.provider.Settings;
import android.service.quicksettings.Tile;
import android.service.quicksettings.TileService;
import android.widget.Toast;
import java.io.DataOutputStream;

public class AdbTileService extends TileService {

    @Override
    public void onStartListening() {
        super.onStartListening();
        updateTile();
    }

    @Override
    public void onClick() {
        super.onClick();
        try {
            boolean isEnabled = Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
            boolean nextState = !isEnabled;
            
            String cmd = "settings put global adb_enabled " + (nextState ? "1" : "0");
            boolean success = runRoot(cmd);
            
            if (success) {
                updateTile();
                String msg = nextState ? "Gỡ lỗi USB: ĐÃ BẬT" : "Gỡ lỗi USB: ĐÃ TẮT";
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
            } else {
                Toast.makeText(this, "Lỗi: Không thể lấy quyền Root!", Toast.LENGTH_LONG).show();
            }
        } catch (Exception e) {
            Toast.makeText(this, "Lỗi: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
    }

    private void updateTile() {
        Tile tile = getQsTile();
        if (tile == null) return;
        
        boolean isEnabled = Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
        
        tile.setState(isEnabled ? Tile.STATE_ACTIVE : Tile.STATE_INACTIVE);
        tile.setLabel(isEnabled ? "ADB: BẬT" : "ADB: TẮT");
        tile.updateTile();
    }

    private boolean runRoot(String command) {
        Process process = null;
        DataOutputStream os = null;
        try {
            process = Runtime.getRuntime().exec("su");
            os = new DataOutputStream(process.getOutputStream());
            os.writeBytes(command + "\n");
            os.writeBytes("exit\n");
            os.flush();
            int exitVal = process.waitFor();
            return exitVal == 0;
        } catch (Exception e) {
            return false;
        } finally {
            try {
                if (os != null) os.close();
                if (process != null) process.destroy();
            } catch (Exception ignored) {}
        }
    }
}
