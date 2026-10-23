package com.godot.game;

import android.app.Activity;
import android.app.AlertDialog;
import android.content.DialogInterface;
import android.text.InputType;
import android.view.KeyEvent;
import android.view.WindowManager;
import android.widget.TextView;
import android.content.Context;
import android.os.IBinder;
import android.view.View;
import android.view.ViewGroup;
import android.view.inputmethod.EditorInfo;
import android.view.inputmethod.InputMethodManager;
import android.widget.EditText;

// The phone keyboard for the chat (R3). In landscape a keyboard like Gboard goes "full screen" over the game and greys
// it out - and now and then that grey layer stayed after the message was sent (the whole game darker until the next
// chat). setup(): never full screen for the game's text box. hide(): close the keyboard for sure (and once more a moment
// later, in case it was still opening).
public class LoG2Keyboard {
    public static void setup(final Activity a) {
        if (a == null) return;
        a.runOnUiThread(new Runnable() {
            @Override public void run() { noFullscreen(a.getWindow().getDecorView(), a); }
        });
    }

    private static void noFullscreen(View v, Activity a) {
        if (v instanceof EditText) {
            EditText e = (EditText) v;
            int o = e.getImeOptions() | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN;
            if (o != e.getImeOptions()) {
                e.setImeOptions(o);
                InputMethodManager imm = (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm != null) imm.restartInput(e);
            }
        }
        if (v instanceof ViewGroup) {
            ViewGroup g = (ViewGroup) v;
            for (int i = 0; i < g.getChildCount(); i++) noFullscreen(g.getChildAt(i), a);
        }
    }

    public static void hide(final Activity a) {
        if (a == null) return;
        final Runnable h = new Runnable() {
            @Override public void run() {
                InputMethodManager imm = (InputMethodManager) a.getSystemService(Context.INPUT_METHOD_SERVICE);
                if (imm == null) return;
                View f = a.getCurrentFocus();
                IBinder t = (f != null ? f : a.getWindow().getDecorView()).getWindowToken();
                if (t != null) imm.hideSoftInputFromWindow(t, 0);
            }
        };
        a.runOnUiThread(h);
        a.getWindow().getDecorView().postDelayed(h, 400);
    }

    // CHAT on a phone (R3): a small box of its own - one line, the keyboard at once, Enter sends, B / R3 / back cancel.
    // The answer waits in "result" for the game to take(): "S:" + the words (send) or "C:" (cancelled).
    private static volatile String result = null;

    public static void ask(final Activity a, final String title) {
        if (a == null) return;
        result = null;
        a.runOnUiThread(new Runnable() {
            @Override public void run() {
                final EditText e = new EditText(a);
                e.setSingleLine(true);
                e.setInputType(InputType.TYPE_CLASS_TEXT);
                e.setImeOptions(EditorInfo.IME_ACTION_SEND | EditorInfo.IME_FLAG_NO_EXTRACT_UI | EditorInfo.IME_FLAG_NO_FULLSCREEN);
                final AlertDialog d = new AlertDialog.Builder(a).setTitle(title).setView(e)
                    .setPositiveButton("SEND", new DialogInterface.OnClickListener() {
                        @Override public void onClick(DialogInterface di, int w) { result = "S:" + e.getText().toString(); }
                    })
                    .setNegativeButton("CANCEL", new DialogInterface.OnClickListener() {
                        @Override public void onClick(DialogInterface di, int w) { result = "C:"; }
                    }).create();
                e.setOnEditorActionListener(new TextView.OnEditorActionListener() {
                    @Override public boolean onEditorAction(TextView v, int id, KeyEvent ev) {
                        result = "S:" + e.getText().toString();
                        d.dismiss();
                        return true;
                    }
                });
                // (only a press made while the box is open closes it: the release of the R3 that opened it closed it at once)
                final boolean[] pressed = {false};
                d.setOnKeyListener(new DialogInterface.OnKeyListener() {
                    @Override public boolean onKey(DialogInterface di, int code, KeyEvent ev) {
                        boolean ours = code == KeyEvent.KEYCODE_BUTTON_B || code == KeyEvent.KEYCODE_BUTTON_THUMBR || code == KeyEvent.KEYCODE_BACK;
                        if (!ours) return false;
                        if (ev.getAction() == KeyEvent.ACTION_DOWN) {
                            pressed[0] = true;
                            return true;
                        }
                        if (ev.getAction() == KeyEvent.ACTION_UP && pressed[0]) {
                            result = "C:";
                            d.dismiss();
                            return true;
                        }
                        return false;
                    }
                });
                d.setOnDismissListener(new DialogInterface.OnDismissListener() {
                    @Override public void onDismiss(DialogInterface di) { if (result == null) result = "C:"; }
                });
                d.getWindow().setSoftInputMode(WindowManager.LayoutParams.SOFT_INPUT_STATE_ALWAYS_VISIBLE);
                d.show();
                e.requestFocus();
            }
        });
    }

    public static String take() {
        String r = result;
        if (r != null) result = null;
        return r == null ? "" : r;
    }
}
