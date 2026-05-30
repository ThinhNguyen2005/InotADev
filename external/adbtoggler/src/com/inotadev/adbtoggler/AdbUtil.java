package com.inotadev.adbtoggler;

import android.content.Context;
import android.content.Intent;
import android.content.pm.PackageManager;
import android.net.LocalSocket;
import android.net.LocalSocketAddress;
import android.os.Build;
import android.provider.Settings;
import android.util.Log;
import java.io.BufferedReader;
import java.io.DataOutputStream;
import java.io.File;
import java.io.InputStreamReader;

/**
 * Centralized ADB utility — handles all ADB state operations.
 * Works with KernelSU, APatch, Magisk, and other root solutions.
 *
 * Root detection strategy:
 * 1. KernelSU: check /data/adb/ksu/daemon_socket (native daemon)
 * 2. APatch: check /data/adb/apd/daemon_socket (native daemon)
 * 3. Magisk: use standard su binary with timeout
 * 4. Fallback: try all known su paths
 *
 * After root is granted once in the root app settings, subsequent calls
 * run silently (no dialog). The app persists this permission across sessions
 * until manually revoked by the user.
 */
public final class AdbUtil {

    private static final String TAG = "AdbUtil";
    private static final int SU_TIMEOUT_MS = 5000;

    private AdbUtil() {}

    // ─── Public API ───────────────────────────────────────────────────────────

    public static boolean isAdbEnabled(Context ctx) {
        if (ctx == null) return false;
        try {
            return Settings.Global.getInt(ctx.getContentResolver(), Settings.Global.ADB_ENABLED, 0) == 1;
        } catch (Exception e) {
            Log.e(TAG, "Failed to read ADB state", e);
            return false;
        }
    }

    public static boolean setAdbEnabled(Context ctx, boolean enable) {
        Log.d(TAG, "setAdbEnabled(" + enable + ")");

        boolean success = runRootCommand(ctx, enable ? buildEnableScript() : buildDisableScript());

        if (success) {
            Log.d(TAG, "ADB " + (enable ? "enabled" : "disabled") + " successfully");
        } else {
            Log.e(TAG, "ADB toggle failed");
        }

        return success;
    }

    public static boolean isRootAvailable(Context ctx) {
        return findRootMethod(ctx) != null;
    }

    public static String getRootMethod(Context ctx) {
        RootMethod method = findRootMethod(ctx);
        return method != null ? method.name : "none";
    }

    public static String getToggleMessage(boolean newState) {
        return newState ? "Gỡ lỗi USB đã bật" : "Gỡ lỗi USB đã tắt";
    }

    public static String getErrorMessage() {
        return "Lỗi: Không thể thay đổi ADB! Kiểm tra quyền Root.";
    }

    // ─── Root Method Detection ───────────────────────────────────────────────

    private enum RootMethod {
        KERNELSU("KernelSU"),
        APATCH("APatch"),
        MAGISK("Magisk"),
        GENERIC("su");

        final String name;
        RootMethod(String name) { this.name = name; }
    }

    private static RootMethod findRootMethod(Context ctx) {
        // KernelSU: has native daemon socket
        if (new File("/data/adb/ksud/daemon_socket").exists()
                || new File("/data/adb/ksu/daemon_socket").exists()) {
            return RootMethod.KERNELSU;
        }

        // APatch: has apd daemon socket
        if (new File("/data/adb/apd/daemon_socket").exists()
                || new File("/data/adb/apatch/daemon_socket").exists()) {
            return RootMethod.APATCH;
        }

        // Try to find su binary
        String[] suPaths = {
            "/sbin/su",
            "/system/bin/su",
            "/system/xbin/su",
            "/data/local/bin/su",
            "/data/adb/su"
        };

        for (String path : suPaths) {
            if (new File(path).exists()) {
                // Magisk su usually has .magisk alias in PATH
                try {
                    Process p = Runtime.getRuntime().exec(new String[]{path, "-v"});
                    BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()));
                    String line = br.readLine();
                    p.waitFor();
                    br.close();
                    if (line != null && (line.contains("Magisk") || line.contains("su v"))) {
                        return RootMethod.MAGISK;
                    }
                } catch (Exception ignored) {}
                return RootMethod.GENERIC;
            }
        }

        // Fallback: try PATH
        try {
            Process p = Runtime.getRuntime().exec("which su");
            BufferedReader br = new BufferedReader(new InputStreamReader(p.getInputStream()));
            String path = br.readLine();
            p.waitFor();
            br.close();
            if (path != null && !path.isEmpty()) {
                return RootMethod.GENERIC;
            }
        } catch (Exception ignored) {}

        return null;
    }

    // ─── Command Execution ──────────────────────────────────────────────────

    private static boolean runRootCommand(Context ctx, String script) {
        RootMethod method = findRootMethod(ctx);
        if (method == null) {
            Log.e(TAG, "No root solution found");
            return false;
        }
        Log.d(TAG, "Using root method: " + method.name);

        return executeWithRoot(script);
    }

    private static boolean executeWithRoot(String script) {
        DataOutputStream os = null;
        BufferedReader err = null;
        Process process = null;

        try {
            process = Runtime.getRuntime().exec("su");
            os = new DataOutputStream(process.getOutputStream());
            os.writeBytes(script);
            os.writeBytes("exit\n");
            os.flush();

            // Wait with timeout to prevent hanging
            final Process fp = process;
            Thread waiter = new Thread(() -> {
                try { fp.waitFor(); } catch (Exception ignored) {}
            });
            waiter.start();
            waiter.join(SU_TIMEOUT_MS);

            if (fp.isAlive()) {
                Log.w(TAG, "su timed out, destroying process");
                fp.destroy();
                return false;
            }

            int exitVal = fp.exitValue();
            if (exitVal != 0) {
                err = new BufferedReader(new InputStreamReader(fp.getErrorStream()));
                StringBuilder sb = new StringBuilder();
                String line;
                while ((line = err.readLine()) != null) {
                    sb.append(line).append("\n");
                }
                Log.e(TAG, "Root stderr: " + sb);
                return false;
            }
            return true;

        } catch (Exception e) {
            Log.e(TAG, "Root execution exception", e);
            return false;
        } finally {
            try { if (os != null) os.close(); } catch (Exception ignored) {}
            try { if (err != null) err.close(); } catch (Exception ignored) {}
            if (process != null && process.isAlive()) {
                process.destroy();
            }
        }
    }

    // ─── Scripts ───────────────────────────────────────────────────────────

    private static String buildEnableScript() {
        return "settings put global adb_enabled 1\n"
             + "settings put global development_settings_enabled 1\n"
             + "sleep 0.3\n"
             + "start adbd\n";
    }

    private static String buildDisableScript() {
        return "stop adbd\n"
             + "settings put global adb_enabled 0\n"
             + "settings put global development_settings_enabled 0\n";
    }
}
