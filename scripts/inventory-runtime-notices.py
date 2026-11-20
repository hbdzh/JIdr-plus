#!/usr/bin/env python3
"""Inventory pinned emulator Mach-O files and filename matches in NOTICE.csv.

Filename matches are leads for review, not verified source or license coverage.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[1]
CORE = 'emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless'


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sdk', required=True, type=Path, help='prepared Miko SDK root')
    args = parser.parse_args()
    root = args.sdk.resolve(strict=True)
    emulator = root / 'emulator'
    records = ROOT / 'packaging/runtime-source/runtime-sha256.txt'
    expected = {}
    for line in records.read_text().splitlines():
        digest, path = line.split('  ', 1)
        expected[path] = digest
    notice = emulator / 'NOTICE.csv'
    with notice.open('rb') as file:
        if hashlib.file_digest(file, 'sha256').hexdigest() != expected['emulator/NOTICE.csv']:
            raise SystemExit('NOTICE.csv differs from the pinned runtime')
    with notice.open(newline='', encoding='utf-8') as file:
        notices = [{key.strip(): value.strip() for key, value in row.items()}
                   for row in csv.DictReader(file)]
    inventory = []
    for path in sorted(emulator.rglob('*')):
        if not path.is_file() or path.is_symlink():
            continue
        kind = subprocess.check_output(['file', '-b', str(path)], text=True)
        if 'Mach-O' not in kind:
            continue
        name = path.relative_to(root).as_posix()
        with path.open('rb') as file:
            digest = hashlib.file_digest(file, 'sha256').hexdigest()
        if expected.get(name) != digest:
            raise SystemExit(f'unknown or modified executable: {name}')
        rel = path.relative_to(emulator).as_posix()
        names = {rel, './' + rel, path.name, path.name.removeprefix('lib')}
        matches = [i for i, item in enumerate(notices)
                   if names.intersection(item['Binaries using the license'].split())]
        inventory.append({'path': name, 'sha256': digest,
                          'modified_core': name == CORE,
                          'notice_entry_indexes': matches})
    if not any(item['path'] == CORE for item in inventory):
        raise SystemExit('pinned headless core is missing')
    print(json.dumps({'status': 'review leads only; source and licence correspondence not established',
                      'notices': notices, 'executables': inventory}, indent=2, ensure_ascii=False))


if __name__ == '__main__':
    main()
