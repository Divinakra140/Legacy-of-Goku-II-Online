package com.godot.game;

import android.content.Context;
import java.io.File;

// The app's own folder in Android/data (Android/data/com.log2coop.game/files): the saves live there, so they can be
// copied off with a cable (or by a file manager) - the app's private storage can't be reached from outside.
public class LoG2Storage {
    public static String externalFilesDir() {
        try {
            Object app = Class.forName("android.app.ActivityThread").getMethod("currentApplication").invoke(null);
            File d = ((Context) app).getExternalFilesDir(null);
            if (d != null) {
                d.mkdirs();
                return d.getAbsolutePath();
            }
        } catch (Throwable t) {
            // no external storage: the saves stay in the private folder
        }
        return "";
    }
}
