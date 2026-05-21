package com.inotadev.adbtoggler;

import android.app.Activity;
import android.content.ComponentName;
import android.os.Bundle;
import android.provider.Settings;
import android.service.quicksettings.TileService;
import android.widget.Toast;
import java.io.DataOutputStream;

public class MainActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        
        try {
            boolean isEnabled = Settings.Global.getInt(getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
            boolean nextState = !isEnabled;
            
            String cmd = "settings put global adb_enabled " + (nextState ? "1" : "0");
            boolean success = runRoot(cmd);
            
            if (success) {
                String msg = nextState ? "Gỡ lỗi USB: ĐÃ BẬT" : "Gỡ lỗi USB: ĐÃ TẮT";
                Toast.makeText(this, msg, Toast.LENGTH_SHORT).show();
                
                // Update Quick Settings Tile state immediately
                try {
                    TileService.requestListeningState(this, new ComponentName(this, AdbTileService.class));
                } catch (Exception ignored) {}
            } else {
                Toast.makeText(this, "Lỗi: Không thể lấy quyền Root!", Toast.LENGTH_LONG).show();
            }
        } catch (Exception e) {
            Toast.makeText(this, "Lỗi: " + e.getMessage(), Toast.LENGTH_LONG).show();
        }
        
        finish();
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
