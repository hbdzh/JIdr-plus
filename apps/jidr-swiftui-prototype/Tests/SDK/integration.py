#!/usr/bin/env python3
"""End-to-end SDK consent and installation with synthetic local packages only."""
import hashlib
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import time
import zipfile


def main():
    daemon = os.environ["JIDR_TEST_DAEMON_BIN"]
    bridge = os.environ["JIDR_TEST_CENTER_BRIDGE"]
    with tempfile.TemporaryDirectory(prefix="jidr-sdk-preview-") as temporary:
        root = Path(temporary)
        repo = root / "repo"
        repo.mkdir()
        packages = []
        image_package = "system-images;android-99;default;arm64-v8a"
        fixtures = [("emulator", "emulator", "emulator"), ("platform-tools", "platform-tools", "adb"),
                    (image_package, "synthetic-image", "system.img")]
        for index, (package, archive_root, executable) in enumerate(fixtures):
            archive = repo / f"fixture-{index}.zip"
            with zipfile.ZipFile(archive, "w") as zipped:
                zipped.writestr(f"{archive_root}/{executable}", "synthetic test binary\n")
            data = archive.read_bytes()
            digest = hashlib.sha1(data).hexdigest()
            packages.append(f'<remotePackage path="{package}"><revision><major>1</major></revision>'
                            f'<uses-license ref="synthetic-license"/><archives><archive><complete>'
                            f'<size>{len(data)}</size><checksum type="sha1">{digest}</checksum>'
                            f'<url>{archive.name}</url></complete></archive></archives></remotePackage>')
        (repo / "repository2-3.xml").write_text(
            '<r><license id="synthetic-license" type="text">Synthetic test terms only.</license>'
            + "".join(packages) + "</r>", encoding="utf-8")
        env = os.environ.copy()
        env.update(JIDR_HOME=str(root / "home"), JIDR_DAEMON_BIN=daemon,
                   JIDR_SDK_REPO=repo.as_uri() + "/")
        env.pop("ANDROID_HOME", None)
        env.pop("ANDROID_SDK_ROOT", None)
        process = subprocess.Popen([bridge], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, env=env, bufsize=0)
        sequence = 0
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""

        def call(method, params=None):
            nonlocal sequence, pending
            sequence += 1
            request = {"id": sequence, "method": method, "params": params or {}}
            process.stdin.write(json.dumps(request).encode() + b"\n")
            deadline = time.monotonic() + 45
            while time.monotonic() < deadline:
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    event = json.loads(line)
                    if event.get("id") == sequence and event.get("type") in ("result", "error"):
                        return event
                if selector.select(1):
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("test bridge exited")
                    pending += chunk
            raise TimeoutError(method)

        try:
            # Existing SDK selection is validated and must remain read-only.
            external = root / "existing-sdk"
            for name in ("emulator/emulator", "platform-tools/adb"):
                item = external / name
                item.parent.mkdir(parents=True, exist_ok=True)
                item.write_text("existing SDK data", encoding="utf-8")
            selected = call("center.toolpath.set", {"kind":"sdk", "path":str(external)})
            assert selected["type"] == "result", selected
            status = call("sdk.status")
            assert status["result"]["tools_sdk"] == str(external), status
            invalid = call("center.toolpath.set", {"kind":"sdk", "path":str(root / "missing")})
            assert invalid["type"] == "error", invalid
            assert call("sdk.status")["result"]["tools_sdk"] == str(external)
            assert (external / "emulator/emulator").read_text() == "existing SDK data"
            assert call("center.toolpath.set", {"kind":"sdk", "path":None})["type"] == "result"
            requested = {"packages": ["emulator", "platform-tools"]}
            denied = call("sdk.install", requested)
            assert denied["type"] == "error", denied
            denied_image = call("image.install", {"image": image_package})
            assert denied_image["type"] == "error", denied_image
            pending_licenses = call("sdk.licenses", requested)
            assert pending_licenses["type"] == "result", pending_licenses
            license_record, = pending_licenses["result"]
            assert license_record["id"] == "synthetic-license"
            assert license_record["text"] == "Synthetic test terms only."
            accepted = call("sdk.accept_license", {"id": license_record["id"], "sha256": license_record["sha256"]})
            assert accepted["type"] == "result", accepted
            installed = call("sdk.install", requested)
            assert installed["type"] == "result", installed
            private_sdk = root / "home" / "data" / "sdk"
            assert (private_sdk / "emulator" / "emulator").read_text() == "synthetic test binary\n"
            assert (private_sdk / "platform-tools" / "adb").read_text() == "synthetic test binary\n"
            installed_image = call("image.install", {"image": image_package})
            assert installed_image["type"] == "result", installed_image
            assert (private_sdk / "system-images" / "android-99" / "default" / "arm64-v8a" / "system.img").read_text() == "synthetic test binary\n"
            print("Synthetic SDK consent and installation integration passed")
        finally:
            try:
                call("center.quit")
            finally:
                process.stdin.close()
                process.wait(timeout=20)


if __name__ == "__main__":
    main()
