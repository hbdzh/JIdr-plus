#!/usr/bin/env bash
# Builds a tiny test app with the SDK's build tools (used read-only).
# Usage: build-hello-apk.sh <out.apk> [hello|locprobe|idprobe]
#   hello     ly.miko.hello: shows "Hello from Miko"
#   locprobe  ly.miko.locprobe: requests GPS updates and logs each fix as
#             "MikoLocProbe: <lat>,<lon>" (install with -g to grant location)
#   idprobe   ly.miko.idprobe: logs the Android ID it reads at each start as
#             "MikoIdProbe: <id>" (Settings.Secure.ANDROID_ID, its SSAID)
# Env: MIKO_TEST_SDK (default ~/Library/Android/sdk). Never shipped.
set -euo pipefail
out="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
variant="${2:-hello}"
sdk="${MIKO_TEST_SDK:-$HOME/Library/Android/sdk}"
bt="$(ls -d "$sdk"/build-tools/* | sort -V | tail -1)"
jar="$(ls -d "$sdk"/platforms/android-* | sort -V | tail -1)/android.jar"
javac="${JAVAC:-$(command -v javac || echo "/Applications/Android Studio.app/Contents/jbr/Contents/Home/bin/javac")}"
keytool="$(dirname "$javac")/keytool"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
pkg="ly.miko.$variant"
mkdir -p "$work/src/ly/miko/$variant" "$work/classes" "$work/dex"
if [ "$variant" = locprobe ]; then
  perm='<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>'
  cat > "$work/src/ly/miko/$variant/MainActivity.java" <<'JAVA'
package ly.miko.locprobe;
public class MainActivity extends android.app.Activity implements android.location.LocationListener {
    @Override protected void onCreate(android.os.Bundle b) {
        super.onCreate(b);
        android.widget.TextView t = new android.widget.TextView(this);
        t.setText("Miko location probe");
        setContentView(t);
        android.location.LocationManager lm =
            (android.location.LocationManager) getSystemService(LOCATION_SERVICE);
        lm.requestLocationUpdates(android.location.LocationManager.GPS_PROVIDER, 0L, 0f, this);
    }
    @Override public void onLocationChanged(android.location.Location l) {
        android.util.Log.i("MikoLocProbe", String.format(java.util.Locale.US, "%.5f,%.5f", l.getLatitude(), l.getLongitude()));
    }
}
JAVA
elif [ "$variant" = idprobe ]; then
  perm=''
  cat > "$work/src/ly/miko/$variant/MainActivity.java" <<'JAVA'
package ly.miko.idprobe;
public class MainActivity extends android.app.Activity {
    @Override protected void onCreate(android.os.Bundle b) {
        super.onCreate(b);
        String id = android.provider.Settings.Secure.getString(
            getContentResolver(), android.provider.Settings.Secure.ANDROID_ID);
        android.util.Log.i("MikoIdProbe", String.valueOf(id));
        android.widget.TextView t = new android.widget.TextView(this);
        t.setText("Android ID: " + id);
        setContentView(t);
    }
}
JAVA
else
  perm=''
  cat > "$work/src/ly/miko/$variant/MainActivity.java" <<'JAVA'
package ly.miko.hello;
public class MainActivity extends android.app.Activity {
    @Override protected void onCreate(android.os.Bundle b) {
        super.onCreate(b);
        android.widget.TextView t = new android.widget.TextView(this);
        t.setText("Hello from Miko");
        t.setTextSize(28);
        setContentView(t);
    }
}
JAVA
fi
cat > "$work/AndroidManifest.xml" <<XML
<manifest xmlns:android="http://schemas.android.com/apk/res/android" package="$pkg">
  $perm
  <application android:label="Miko $variant">
    <activity android:name=".MainActivity" android:exported="true">
      <intent-filter>
        <action android:name="android.intent.action.MAIN"/>
        <category android:name="android.intent.category.LAUNCHER"/>
      </intent-filter>
    </activity>
  </application>
</manifest>
XML
"$javac" --release 11 -nowarn -classpath "$jar" -d "$work/classes" "$work/src/ly/miko/$variant/MainActivity.java"
"$bt/d8" --lib "$jar" --min-api 29 --output "$work/dex" $(find "$work/classes" -name '*.class')
"$bt/aapt2" link -o "$work/unsigned.apk" -I "$jar" --manifest "$work/AndroidManifest.xml" \
  --min-sdk-version 29 --target-sdk-version 31
(cd "$work/dex" && zip -q -u "$work/unsigned.apk" classes.dex)
"$bt/zipalign" -f 4 "$work/unsigned.apk" "$work/aligned.apk"
"$keytool" -genkeypair -keystore "$work/ks" -storepass mikotest -keypass mikotest -alias t \
  -keyalg RSA -keysize 2048 -validity 1 -dname "CN=Miko test" >/dev/null 2>&1
"$bt/apksigner" sign --ks "$work/ks" --ks-pass pass:mikotest --key-pass pass:mikotest --out "$out" "$work/aligned.apk"
echo "$out"
