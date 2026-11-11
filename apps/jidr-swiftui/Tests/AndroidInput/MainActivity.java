// SPDX-License-Identifier: GPL-3.0-only
package local.jidr.inputprobe;

import android.app.Activity;
import android.os.Bundle;
import android.text.Editable;
import android.text.TextWatcher;
import android.view.KeyEvent;
import android.view.MotionEvent;
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
    private void write(String name, String value, boolean append) {
        try (FileOutputStream out = openFileOutput(name, append ? MODE_APPEND : MODE_PRIVATE)) {
            out.write(value.getBytes(StandardCharsets.UTF_8));
        } catch (Exception error) { throw new IllegalStateException(error); }
    }
    private void event(JSONObject value) { write("events.jsonl", value.toString()+"\n", true); }
    private JSONObject value(String kind) throws Exception { return new JSONObject().put("kind",kind); }
    @Override public void onCreate(Bundle state) {
        super.onCreate(state);
        write("events.jsonl","",false);
        LinearLayout layout = new LinearLayout(this);
        layout.setOrientation(LinearLayout.VERTICAL); layout.setPadding(32,32,32,32);
        layout.setClickable(true);
        TextView title = new TextView(this); title.setText("Jidr real input probe"); title.setTextSize(24);
        input = new EditText(this); input.setSingleLine(true); input.setHint("Input test");
        input.setShowSoftInputOnFocus(false);
        layout.addView(title); layout.addView(input,new LinearLayout.LayoutParams(-1,160));
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
    @Override public boolean dispatchKeyEvent(KeyEvent e) {
        try { event(value("key").put("action",e.getAction()).put("code",e.getKeyCode())
            .put("name",KeyEvent.keyCodeToString(e.getKeyCode())).put("meta",e.getMetaState())); }
        catch(Exception error) {throw new IllegalStateException(error);}
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
