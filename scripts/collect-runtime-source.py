#!/usr/bin/env python3
"""Collect pinned AOSP source candidates for the Miko runtime review.

This is not a certification that the output is complete corresponding source.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
RECORDS = ROOT / 'packaging/runtime-source'
SOURCE_ARCHIVE = 'prebuilts/android-emulator-build/archive'

def command(*args, cwd):
    return subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE).stdout

def digest(path):
    with path.open('rb') as source:
        return hashlib.file_digest(source, 'sha256').hexdigest()

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--aosp-root', required=True, type=Path)
    parser.add_argument('--output', type=Path, help='new directory; never overwritten')
    parser.add_argument('--verify-only', action='store_true', help='check revisions and tracked changes without archiving')
    args = parser.parse_args()
    root = args.aosp_root.resolve(strict=True)
    if not args.verify_only and args.output is None:
        parser.error('--output is required unless --verify-only is used')
    output = args.output.absolute() if args.output is not None else None
    if output is not None and (output.exists() or output.is_symlink()):
        raise SystemExit(f'output already exists: {output}')
    if output is not None and not output.parent.is_dir():
        raise SystemExit(f'output parent does not exist: {output.parent}')
    projects = []
    for row in (RECORDS / 'checkout-revisions.txt').read_text().splitlines():
        if row.startswith('MISSING '):
            continue
        name, revision = row.split()
        if name.startswith('prebuilts/') and name != SOURCE_ARCHIVE:
            continue
        path = root / name
        head = command('git', 'rev-parse', 'HEAD', cwd=path).decode().strip()
        if head != revision:
            raise SystemExit(f'wrong revision: {name}: {head} != {revision}')
        diff = command('git', 'diff', '--binary', 'HEAD', '--', cwd=path)
        if name == 'external/qemu':
            if diff != (RECORDS / 'qemu-local.patch').read_bytes():
                raise SystemExit('QEMU modifications differ from the recorded patch')
        elif diff:
            raise SystemExit(f'tracked source modifications must be recorded: {name}')
        projects.append((name, revision, path))
    if args.verify_only:
        print(f'Pinned tracked source verified: {len(projects)} projects')
        return
    assert output is not None
    with tempfile.TemporaryDirectory(prefix='.miko-source-review-', dir=output.parent) as tmp:
        stage = Path(tmp) / 'source-review'
        archives = stage / 'projects'
        archives.mkdir(parents=True)
        entries = []
        for name, revision, path in projects:
            filename = name.replace('/', '__') + '.tar.gz'
            target = archives / filename
            print(f'Archiving {name}', flush=True)
            with target.open('wb') as dest:
                subprocess.run(['git', 'archive', '--format=tar.gz', f'--prefix={name}/', revision],
                               cwd=path, stdout=dest, check=True)
            entries.append({'path': name, 'revision': revision, 'archive': f'projects/{filename}',
                            'sha256': digest(target)})
        for name in ['qemu-local.patch', 'aosp-checked-out.xml', 'checkout-revisions.txt',
                     'NOTICE-core.txt', 'NOTICE-core.csv', 'LICENSE-qemu.txt',
                     'COPYING-GPL-2.0', 'COPYING-LGPL-2.1', 'runtime-sha256.txt',
                     'NOTICE-build-addendum.txt', 'LICENSE-FFmpeg-4.4.2.md',
                     'COPYING-FFmpeg-GPLv2', 'COPYING-x264-GPLv2']:
            shutil.copyfile(RECORDS / name, stage / name)
        (stage / 'PROJECTS.json').write_text(json.dumps(entries, indent=2) + '\n')
        (stage / 'README.txt').write_text(
            'Source REVIEW CANDIDATE only; not verified complete corresponding source.\n'
            'Archives contain Git-tracked source at the recorded revisions; apply qemu-local.patch '
            'to external/qemu. The archive project contains dependency source candidates.\n'
            'Stock Google binary/source mapping, untracked build inputs, clean build, '\
            'licences, and public source distribution remain unverified.\n')
        checksum_lines = [f'{digest(file)}  {file.relative_to(stage).as_posix()}'
                          for file in sorted(stage.rglob('*')) if file.is_file()]
        (stage / 'SHA256SUMS.txt').write_text('\n'.join(checksum_lines) + '\n')
        os.rename(stage, output)
    print(f'Source review candidate: {output} ({len(entries)} projects)')

if __name__ == '__main__':
    main()
