#!/usr/bin/env python3
"""Rebuild the pinned local arm64 emulator core in a new output directory.

This is an experimental local build, not evidence of complete corresponding
source or approval to redistribute the resulting binary.
"""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--aosp-root', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path, help='new output directory; never overwritten')
    parser.add_argument('--jobs', type=int, default=4)
    parser.add_argument('--verify-only', action='store_true', help='check inputs and toolchain without building')
    args = parser.parse_args()
    if platform.system() != 'Darwin' or platform.machine() != 'arm64':
        raise SystemExit('the pinned core build requires an Apple Silicon Mac')
    if args.jobs < 1 or args.jobs > 32:
        raise SystemExit('--jobs must be between 1 and 32')
    source = args.aosp_root.resolve(strict=True)
    raw_output = args.output.expanduser().absolute()
    output = raw_output.parent.resolve(strict=True) / raw_output.name
    if output.exists() or output.is_symlink():
        raise SystemExit(f'output already exists: {output}')
    if not output.parent.is_dir():
        raise SystemExit(f'output parent does not exist: {output.parent}')
    if output == source or source in output.parents:
        raise SystemExit('output must be outside the source checkout')
    subprocess.run(['python3', str(ROOT / 'scripts/collect-runtime-source.py'),
                    '--aosp-root', str(source), '--verify-only'], check=True)
    revisions = {}
    for line in (ROOT / 'packaging/runtime-source/checkout-revisions.txt').read_text().splitlines():
        if not line.startswith('MISSING '):
            name, revision = line.split()
            revisions[name] = revision
    prebuilt_projects = [
        'prebuilts/android-emulator-build/common',
        'prebuilts/android-emulator-build/qemu-android-deps',
        'prebuilts/android-emulator-build/qt',
        'prebuilts/clang/host/darwin-x86',
        'prebuilts/cmake/darwin-x86',
        'prebuilts/ninja/darwin-x86',
        'prebuilts/python/darwin-x86',
    ]
    for name in prebuilt_projects:
        repo = source / name
        actual = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
        if actual != revisions.get(name):
            raise SystemExit(f'prebuilt revision mismatch: {name}')
        if name.endswith('/qt'):
            # The original checkout may intentionally omit other host platforms.
            # Use an isolated index and compare only the two macOS arm64 trees.
            with tempfile.TemporaryDirectory(prefix='miko-qt-index-') as temporary:
                env = os.environ.copy()
                env['GIT_INDEX_FILE'] = str(Path(temporary) / 'index')
                subprocess.run(['git', '-C', str(repo), 'read-tree', 'HEAD'], env=env, check=True)
                status = subprocess.check_output(
                    ['git', '-C', str(repo), 'status', '--porcelain', '--untracked-files=no', '--',
                     'darwin-aarch64', 'darwin-aarch64-nowebengine'], env=env, text=True)
                if status.strip():
                    raise SystemExit(f'arm64 Qt prebuilt files differ from the pinned checkout: {name}')
        else:
            result = subprocess.run(['git', '-C', str(repo), 'diff', '--quiet', 'HEAD', '--'])
            if result.returncode:
                raise SystemExit(f'prebuilt files differ from the pinned checkout: {name}')
    print('Pinned tracked macOS build prerequisites verified', flush=True)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-version'], text=True).strip()
    if sdk != '27.2':
        raise SystemExit(f'pinned build used macOS SDK 27.2; selected SDK is {sdk}')
    linker = subprocess.check_output(['xcrun', '--find', 'ld'], text=True).strip()
    if linker != '/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/ld':
        raise SystemExit(f'pinned patch requires the recorded Xcode linker path: {linker}')
    ninja = source / 'prebuilts/ninja/darwin-x86/ninja'
    python = source / 'prebuilts/python/darwin-x86/bin/python3'
    cmake = source / 'external/qemu/android/build/python/cmake.py'
    for path in [ninja, python, cmake]:
        if not path.is_file():
            raise SystemExit(f'missing build prerequisite: {path}')
    if args.verify_only:
        print('Build prerequisites verified; no compilation performed')
        return
    output.mkdir()
    env = os.environ.copy()
    env['PATH'] = str(ninja.parent) + os.pathsep + env.get('PATH', '')
    configure = [str(python), str(cmake), '--target', 'darwin-aarch64', '--out', str(output),
                 '--task', 'Configure', '--ccache', 'none']
    for key in ['CMAKE_EXE_LINKER_FLAGS', 'CMAKE_SHARED_LINKER_FLAGS', 'CMAKE_MODULE_LINKER_FLAGS']:
        configure += ['--cmake_option', f'{key}=-fuse-ld={linker}']
    subprocess.run(configure, cwd=ROOT, env=env, check=True)
    subprocess.run([str(ninja), '-C', str(output), '-j', str(args.jobs),
                    'qemu-system-aarch64-headless'], cwd=ROOT, env=env, check=True)
    core = output / 'qemu/darwin-aarch64/qemu-system-aarch64-headless'
    subprocess.run(['codesign', '--verify', '--strict', str(core)], check=True)
    with core.open('rb') as f:
        actual = hashlib.file_digest(f, 'sha256').hexdigest()
    entries = (ROOT / 'packaging/runtime-source/runtime-sha256.txt').read_text().splitlines()
    name = 'emulator/qemu/darwin-aarch64/qemu-system-aarch64-headless'
    pinned = next((line.split('  ', 1)[0] for line in entries if line.endswith('  ' + name)), None)
    print(f'Rebuilt core: {core}\nSHA-256: {actual}\nPinned core SHA-256: {pinned}', flush=True)
    if actual != pinned:
        raise SystemExit('rebuilt core is not byte-identical to the pinned release input; do not publish it')
    print('Pinned core hash matched. Source/licence review is still required.')

if __name__ == '__main__':
    main()
