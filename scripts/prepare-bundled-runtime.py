#!/usr/bin/env python3
"""Reconstruct the pinned local runtime from verified archives and a built core."""
import argparse
import hashlib
import os
from pathlib import Path, PurePosixPath
import shutil
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
RECORDS = ROOT / 'packaging/runtime-source'
ARCHIVE_SHA1 = {'emulator': '3ec739595d44092e835f006d806dd380bc8d6dd7',
                'platform-tools': 'd48920e2650321710b4d15d3acd9e277d59cd55b'}
CORE = 'emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless'

def digest(path, name):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, name).hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--emulator-zip', type=Path, required=True)
    parser.add_argument('--platform-tools-zip', type=Path, required=True)
    parser.add_argument('--core', type=Path, required=True, help='self-built, signed arm64 headless core')
    parser.add_argument('--output', type=Path, required=True, help='new directory; never overwritten')
    args = parser.parse_args()
    archives = {'emulator': args.emulator_zip, 'platform-tools': args.platform_tools_zip}
    for name, path in archives.items():
        if digest(path, 'sha1') != ARCHIVE_SHA1[name]:
            raise SystemExit(f'{name} archive checksum does not match the pinned release')
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise SystemExit(f'output already exists: {output}')
    if not output.parent.is_dir():
        raise SystemExit(f'output parent does not exist: {output.parent}')
    lines = (RECORDS / 'runtime-sha256.txt').read_text().splitlines()
    with zipfile.ZipFile(archives['emulator']) as emulator, zipfile.ZipFile(archives['platform-tools']) as platform:
        zips = {'emulator': emulator, 'platform-tools': platform}
        with tempfile.TemporaryDirectory(prefix='.miko-runtime-', dir=output.parent) as tmp:
            staging = Path(tmp) / 'sdk'
            for line in lines:
                wanted, name = line.split('  ', 1)
                relative = PurePosixPath(name)
                if relative.is_absolute() or '..' in relative.parts or relative.parts[0] not in zips:
                    raise SystemExit(f'unsafe manifest path: {name}')
                destination = staging.joinpath(*relative.parts)
                destination.parent.mkdir(parents=True, exist_ok=True)
                if name == CORE:
                    shutil.copyfile(args.core, destination)
                    destination.chmod(0o755)
                elif relative.name.startswith('.miko-'):
                    shutil.copyfile(RECORDS / 'metadata' / name, destination)
                    destination.chmod(0o644)
                else:
                    source = zips[relative.parts[0]]
                    info = source.getinfo(name)
                    with source.open(info) as src, destination.open('wb') as dst:
                        shutil.copyfileobj(src, dst, length=1024 * 1024)
                    destination.chmod((info.external_attr >> 16) & 0o777)
                if digest(destination, 'sha256') != wanted:
                    raise SystemExit(f'runtime file checksum mismatch: {name}')
            os.rename(staging, output)
    print(f'Pinned runtime prepared: {output}')
    print('Local candidate only: review distribution rights and corresponding source before publication.')

if __name__ == '__main__':
    main()
