#!/usr/bin/env python3
"""Build only our Android input fixture with already installed SDK/JDK tools."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--sdk', type=Path, required=True)
    p.add_argument('--out', type=Path, required=True)
    args = p.parse_args()
    java = Path(os.environ.get('JAVA_HOME', '/nonexistent')) / 'bin'
    sdk = args.sdk.resolve()
    candidates = sorted((sdk/'build-tools').glob('*'), key=lambda x: tuple(int(n) for n in x.name.split('.') if n.isdigit()))
    if not candidates:
        p.error('an already installed Android SDK with build-tools is required')
    tools = candidates[-1]
    android = sdk/'platforms/android-36/android.jar'
    for tool in [java/'javac', java/'keytool', android, tools/'aapt', tools/'d8', tools/'zipalign', tools/'apksigner']:
        if not tool.is_file():
            p.error(f'missing installed tool: {tool}; no SDK download or license acceptance is performed')
    out = args.out.resolve(); out.mkdir(parents=True, exist_ok=False)
    source = ROOT/'apps/jidr-swiftui/Tests/AndroidInput'
    shutil.copy2(source/'AndroidManifest.xml',out/'AndroidManifest.xml')
    classes=out/'classes'; classes.mkdir(); dex=out/'dex'; dex.mkdir()
    def run(*cmd): subprocess.run([str(x) for x in cmd],check=True)
    run(java/'javac','-source','8','-target','8','-bootclasspath',android,'-d',classes,source/'MainActivity.java')
    run(tools/'d8','--lib',android,'--output',dex,*sorted(classes.rglob('*.class')))
    unsigned=out/'unsigned.apk'; aligned=out/'aligned.apk'; apk=out/'input-probe.apk'
    run(tools/'aapt','package','-f','-M',out/'AndroidManifest.xml','-I',android,'-F',unsigned)
    with zipfile.ZipFile(unsigned,'a',zipfile.ZIP_DEFLATED) as archive:
        archive.write(dex/'classes.dex','classes.dex')
    run(tools/'zipalign','-f','4',unsigned,aligned)
    # Ephemeral debug key, used only for this throwaway test package.
    run(java/'keytool','-genkeypair','-keystore',out/'test.jks','-storepass','android','-keypass','android',
        '-alias','test','-keyalg','RSA','-validity','1','-dname','CN=Jidr input probe')
    run(tools/'apksigner','sign','--ks',out/'test.jks','--ks-pass','pass:android','--key-pass','pass:android','--out',apk,aligned)
    hashes={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in source.iterdir() if f.is_file()}
    (out/'build.json').write_text(json.dumps({'source_sha256':hashes,'apk_sha256':hashlib.sha256(apk.read_bytes()).hexdigest(),
                                          'build_sdk_read_only':str(sdk),'build_tools':tools.name},indent=2)+'\n')


if __name__=='__main__': main()
