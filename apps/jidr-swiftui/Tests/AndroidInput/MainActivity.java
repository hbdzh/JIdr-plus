// SPDX-License-Identifier: GPL-3.0-only
package local.jidr.inputprobe;

import android.app.Activity;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.widget.EditText;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.FileOutputStream;
import java.nio.charset.StandardCharsets;
import org.json.JSONArray;
import org.json.JSONObject;

/** Disposable integration fixture. Its private trace is read with adb run-as. */
public final class MainActivity extends Activity {
    private EditText input;
    private boolean tracing = true;
    private boolean noCopy = false;
    private void write(String name, String value, boolean append) {
        try (FileOutputStream out = openFileOutput(name, append ? MODE_APPEND : MODE_PRIVATE)) {
            out.write(value.getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) { throw new IllegalStateException(error); }
    }
    private void event(JSONObject value) { if (tracing) write("events.jsonl", value.toString()+"\n", true); }
    private JSONObject value(String kind) throws Exception { return new JSONObject().put("kind",kind); }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        tracing = getIntent().getBooleanExtra("trace",true);
        noCopy = getIntent().getBooleanExtra("no_copy",false);
        write("events.jsonl","",false);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(32,32,32,32);
        layout.setClickable(true);
        TextView title = new TextView(this); title.setText("Jidr real input probe"); title.setTextSize(24);
        input = new EditText(this); input.setSingleLine(true); input.setHint("Input test");
        input.setShowSoftInputOnFocus(false);
        layout.addView(title); layout.addView(input,new LinearLayout.LayoutParams(-1,160));
        // Continuous changing content keeps the emulator screenshot stream
        // active. The touch-probe patch at screen center stays dark/static.
        layout.addView(new View(this) {
            final Paint paint = new Paint();
            @Override protected void onDraw(Canvas canvas) {
                canvas.drawRGB(32,33,36);
                paint.setColor(0xff2684ff);
                float x = (System.nanoTime()/1000000L % 2000L)/2000f * Math.max(1,getWidth()-80);
                canvas.drawRect(x,getHeight()-100,x+80,getHeight()-40,paint);
                postInvalidateOnAnimation();
            }
            @Override public boolean onTouchEvent(MotionEvent event) { return true; }
        },new LinearLayout.LayoutParams(-1,0,1));
        setContentView(layout);
        input.addTextChangedListener(new TextWatcher() {
            public void beforeTextChanged(CharSequence s,int start,int count,int after) {}
            public void onTextChanged(CharSequence s,int start,int before,int count) {
                try { event(value("text").put("text",s.toString())); } catch(Exception e) {throw new IllegalStateException(e);}
                write("text.txt",s.toString(),false);
            }
            public void afterTextChanged(Editable e) {}
        });
        write("text.txt","",false);
        input.getViewTreeObserver().addOnGlobalLayoutListener(new android.view.ViewTreeObserver.OnGlobalLayoutListener() {
          @Override public void onGlobalLayout() {
            int[] xy = new int[2]; input.getLocationOnScreen(xy);
            try { write("layout.json",value("layout").put("x",xy[0]+input.getWidth()/2)
                .put("y",xy[1]+input.getHeight()/2).toString(),false); }
            catch(Exception e) {throw new IllegalStateException(e);}
          }
        });
    }
    @Override public void onWindowFocusChanged(boolean focused) {
        super.onWindowFocusChanged(focused);
        if (focused && input != null) {
            input.requestFocus();
            input.postDelayed(new Runnable() {
                @Override public void run() {
                    write("ready.txt",input.hasWindowFocus() && input.isFocused() ? "ready" : "not-focused",false);
                }
            },300);
        }
    }
    @Override public boolean dispatchKeyEvent(KeyEvent e) {
        try { event(value("key").put("action",e.getAction()).put("code",e.getKeyCode())
            .put("name",KeyEvent.keyCodeToString(e.getKeyCode())).put("meta",e.getMetaState())); }
        catch(Exception error) {throw new IllegalStateException(error);}
        // A controlled app that does not implement Copy must leave the
        // bridge awaiting a clipboard change. Native functional checks keep
        // this false, so actual copy/cut are still verified normally.
        if (noCopy && e.getKeyCode()==KeyEvent.KEYCODE_C) return true;
        return super.dispatchKeyEvent(e);
    }
    @Override public boolean dispatchTouchEvent(MotionEvent e) {
        try {
            JSONArray pointers = new JSONArray();
            for(int i=0;i<e.getPointerCount();i++) pointers.put(new JSONObject().put("id",e.getPointerId(i))
                .put("x",e.getX(i)).put("y",e.getY(i)));
            event(value("touch").put("action",e.getActionMasked()).put("pointers",pointers));
        } catch(Exception error) {throw new IllegalStateException(error);}
        return super.dispatchTouchEvent(e);
    }
}
