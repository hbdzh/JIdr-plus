#!/usr/bin/env python3
"""Package the official Magisk v30.7 checkout, including pinned submodules."""
import argparse
import hashlib
from pathlib import Path
import subprocess
import tarfile

COMMIT = 'e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac'

def git(root, *args):
    return subprocess.check_output(['git', '-C', str(root), *args])

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    root = args.source.resolve(strict=True)
    if git(root, 'rev-parse', 'HEAD').decode().strip() != COMMIT:
        raise SystemExit('wrong Magisk source revision')
    if git(root, 'status', '--porcelain', '--untracked-files=no').strip():
        raise SystemExit('Magisk checkout has tracked modifications')
    modules = git(root, 'submodule', 'status', '--recursive').decode().splitlines()
    if len(modules) != 7 or any(not row.startswith(' ') for row in modules):
        raise SystemExit('Magisk submodules are missing or differ from pinned revisions')
    output = args.output.absolute()
    if output.exists() or output.is_symlink():
        raise SystemExit(f'output already exists: {output}')
    entries = git(root, 'ls-files', '--stage', '-z', '--recurse-submodules').split(b'\0')
    with tarfile.open(output, 'x', format=tarfile.PAX_FORMAT) as tar:
        for item in sorted(x for x in entries if x):
            metadata, name_bytes = item.split(b'\t', 1)
            mode, _, stage = metadata.split()
            if stage != b'0' or mode not in (b'100644', b'100755', b'120000'):
                raise SystemExit('unexpected tracked file mode or Git index stage')
            name = name_bytes.decode('utf-8')
            path = root / name
            info = tar.gettarinfo(str(path), arcname='Magisk-v30.7/' + name)
            info.uid = info.gid = info.mtime = 0
            info.uname = info.gname = ''
            info.mode = 0o755 if mode == b'100755' else (0o777 if mode == b'120000' else 0o644)
            if mode == b'120000':
                if not info.issym(): raise SystemExit(f'expected symlink: {name}')
                tar.addfile(info)
            else:
                if not info.isfile(): raise SystemExit(f'expected regular file: {name}')
                with path.open('rb') as file: tar.addfile(info, file)
    with output.open('rb') as file:
        print(f'{hashlib.file_digest(file, "sha256").hexdigest()}  {output}')

if __name__ == '__main__':
    main()
