#!/usr/bin/env python3
"""Check an AOSP emulator dependency archive against its PACKAGES.TXT.

This checks source inputs, not their correspondence to distributed binaries.
Only run on trusted AOSP checkouts: Git source archives are extracted locally.
"""
import argparse
import hashlib
import os
from pathlib import Path
import re
import subprocess
import tarfile
import tempfile
from urllib.parse import urlparse


def sha1_file(path):
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha1').hexdigest()


def git_archive_sha1(path):
    # Matches AOSP android/scripts/unix/utils/common.shi compute_archive_sha1:
    # hash the C-sorted list of openssl file hashes, including symlink paths.
    with tempfile.TemporaryDirectory(prefix='miko-dependency-audit-') as temp:
        with tarfile.open(path, 'r:*') as archive:
            archive.extractall(temp, filter='data')
        env = dict(os.environ, LANG='C', LC_ALL='C')
        output = subprocess.check_output(
            ['bash', '-o', 'pipefail', '-c',
             "find . -type f -o -type l | sort -u -s | xargs openssl sha1 | openssl sha1"],
            cwd=temp, env=env, text=True)
        return output.strip().split()[-1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive_dir', type=Path, help='AOSP prebuilts/android-emulator-build/archive')
    args = parser.parse_args()
    root = args.archive_dir.resolve(strict=True)
    rows = []
    for line in (root / 'PACKAGES.TXT').read_text().splitlines():
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        fields = dict(re.findall(r'(\w+)=([^\s]+)', line))
        if 'SHA1' not in fields:
            raise SystemExit(f'unsupported entry: {line}')
        rows.append(fields)
    failures = 0
    for fields in rows:
        if 'URL' in fields:
            name = Path(urlparse(fields['URL']).path).name
            checksum = sha1_file
        elif 'GIT' in fields and 'BRANCH' in fields:
            name = Path(urlparse(fields['GIT']).path.rstrip('/')).name.removesuffix('.git')
            name += '-' + fields['BRANCH'] + '.tar.xz'
            checksum = git_archive_sha1
        else:
            raise SystemExit(f'unsupported source entry: {fields}')
        if Path(name).name != name:
            raise SystemExit(f'invalid archive name: {name}')
        source = root / name
        if not source.is_file():
            print(f'MISSING archive {name}')
            failures += 1
        else:
            actual = checksum(source)
            if actual == fields['SHA1']:
                print(f'OK {name}')
            else:
                print(f'MISMATCH {name}: expected {fields["SHA1"]}, got {actual}')
                failures += 1
        patch = fields.get('PATCHES')
        if patch:
            if Path(patch).name != patch:
                raise SystemExit(f'invalid patch name: {patch}')
            if not (root / patch).is_file():
                print(f'MISSING patch {patch}')
                failures += 1
    print(f'Checked {len(rows)} entries; {failures} unresolved archive/patch checks')
    print('These checks do not establish which sources correspond to a distributed binary.')
    if failures:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
