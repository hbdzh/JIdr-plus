#!/usr/bin/env python3
"""Exercise SDK job cancellation using only a throttled synthetic repository."""
import hashlib
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
import json
import os
from pathlib import Path
import selectors
import subprocess
import tempfile
import threading
import time
import zipfile


def main():
    with tempfile.TemporaryDirectory(prefix="jidr-sdk-cancel-") as temporary:
        root = Path(temporary)
        repository = root / "repo"
        repository.mkdir()
        archive = repository / "fixture.zip"
        with zipfile.ZipFile(archive, "w", compression=zipfile.ZIP_STORED) as zipped:
            zipped.writestr("emulator/emulator", b"synthetic" * 1024 * 512)
        digest = hashlib.sha1(archive.read_bytes()).hexdigest()
        (repository / "repository2-3.xml").write_text(
            '<r><license id="synthetic-license" type="text">Synthetic terms.</license>'
            '<remotePackage path="emulator"><revision><major>1</major></revision>'
            '<uses-license ref="synthetic-license"/><archives><archive><complete>'
            f'<size>{archive.stat().st_size}</size><checksum type="sha1">{digest}</checksum>'
            '<url>fixture.zip</url></complete></archive></archives></remotePackage></r>',
            encoding="utf-8")

        class Handler(SimpleHTTPRequestHandler):
            def __init__(self, *args, **kwargs):
                super().__init__(*args, directory=str(repository), **kwargs)

            def copyfile(self, source, output):
                try:
                    while chunk := source.read(32768):
                        output.write(chunk)
                        output.flush()
                        if self.path.endswith("fixture.zip"):
                            time.sleep(0.05)
                except (BrokenPipeError, ConnectionResetError):
                    pass

            def log_message(self, *args):
                pass

        server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        env = os.environ.copy()
        env.update(JIDR_HOME=str(root / "home"),
                   JIDR_DAEMON_BIN=env["JIDR_TEST_DAEMON_BIN"],
                   JIDR_SDK_REPO=f"http://127.0.0.1:{server.server_port}/")
        env.pop("ANDROID_HOME", None)
        env.pop("ANDROID_SDK_ROOT", None)
        process = subprocess.Popen([env["JIDR_TEST_CENTER_BRIDGE"]], stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, bufsize=0)
        selector = selectors.DefaultSelector()
        selector.register(process.stdout, selectors.EVENT_READ)
        pending = b""

        def send(identifier, method, params=None):
            process.stdin.write(json.dumps({"id":identifier,"method":method,"params":params or {}}).encode() + b"\n")

        def receive(predicate, timeout=30):
            nonlocal pending
            deadline = time.monotonic() + timeout
            while time.monotonic() < deadline:
                while b"\n" in pending:
                    line, pending = pending.split(b"\n", 1)
                    event = json.loads(line)
                    if predicate(event):
                        return event
                if selector.select(1):
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        raise RuntimeError("bridge exited")
                    pending += chunk
            raise TimeoutError("waiting for SDK job")

        def result(identifier):
            return receive(lambda event: event.get("id") == identifier and event.get("type") in ("result", "error"))

        try:
            send(1, "sdk.licenses", {"packages":["emulator"]})
            license_result = result(1)
            license_record, = license_result["result"]
            assert license_record["text"] == "Synthetic terms."
            send(2, "sdk.accept_license", {"id":license_record["id"],"sha256":license_record["sha256"]})
            assert result(2)["type"] == "result"
            marker = root / "home" / "data" / "unrelated-marker"
            marker.write_text("untouched", encoding="utf-8")
            send(3, "sdk.install", {"packages":["emulator"]})
            progress = receive(lambda event: event.get("id") == 3 and event.get("type") == "progress")
            assert progress.get("job"), progress
            send(4, "jobs.cancel", {"job":progress["job"]})
            cancelled = False
            cancel_ack = False
            while not (cancelled and cancel_ack):
                event = receive(lambda event: event.get("id") in (3, 4) and event.get("type") in ("result", "error"))
                if event["id"] == 3:
                    assert event["type"] == "error", event
                    cancelled = True
                else:
                    assert event["type"] == "result", event
                    cancel_ack = True
            assert marker.read_text(encoding="utf-8") == "untouched"
            assert not (root / "home" / "data" / "sdk" / "emulator" / "emulator").exists()
            print("Synthetic SDK cancellation integration passed")
        finally:
            try:
                send(5, "center.quit")
                result(5)
            finally:
                process.stdin.close()
                process.wait(timeout=20)
                server.shutdown()
                server.server_close()


if __name__ == "__main__":
    main()
