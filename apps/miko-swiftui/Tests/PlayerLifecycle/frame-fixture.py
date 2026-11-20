#!/usr/bin/env python3
"""Emit changing JFR1 frames; never accesses a device or user data."""
import struct
import sys
import time
try:
    for index in range(250):
        width, height = 48, 64
        pixels = bytes([index % 256, 30, 80, 255]) * (width * height)
        sys.stdout.buffer.write(b'JFR1' + struct.pack('>IIII', width, height, 0, len(pixels)) + pixels)
        sys.stdout.buffer.flush()
        time.sleep(0.02)
except BrokenPipeError:
    pass
