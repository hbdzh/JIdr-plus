#!/usr/bin/env python3
"""Build a macOS icon from the approved 1024-pixel PNG using macOS sips."""
import pathlib
import struct
import subprocess
import sys
import tempfile

source, output = map(pathlib.Path, sys.argv[1:])
types = [('icp4', 16), ('icp5', 32), ('icp6', 64), ('ic07', 128),
         ('ic08', 256), ('ic09', 512), ('ic10', 1024), ('ic11', 32),
         ('ic12', 64), ('ic13', 256), ('ic14', 512)]
with tempfile.TemporaryDirectory() as directory:
    chunks = []
    for size in sorted({size for _, size in types}):
        dest = pathlib.Path(directory) / f'{size}.png'
        # sips converts 16-bit source pixels to 8-bit when resizing.
        if size == 1024:
            temp = pathlib.Path(directory) / 'temp.png'
            subprocess.run(['sips', '-z', '1023', '1023', str(source), '--out', str(temp)], check=True, stdout=subprocess.DEVNULL)
            src = temp
        else:
            src = source
        subprocess.run(['sips', '-z', str(size), str(size), str(src), '--out', str(dest)], check=True, stdout=subprocess.DEVNULL)
    for kind, size in types:
        data = (pathlib.Path(directory) / f'{size}.png').read_bytes()
        chunks.append(kind.encode('ascii') + struct.pack('>I', len(data) + 8) + data)
    payload = b''.join(chunks)
    output.write_bytes(b'icns' + struct.pack('>I', len(payload) + 8) + payload)
