"""Package the locally built DogShare app; never run the app or install drivers."""
import argparse
import datetime
import hashlib
import json
import mmap
import os
from pathlib import Path
import re
import shutil
import struct
import subprocess
import sys
import zipfile

TOOLS = Path(os.environ.get('DOGSHARE_TOOLS', str(Path(__file__).resolve().parent)))
REPO = Path(os.environ.get('DOGSHARE_REPO', str(TOOLS.parent)))
DIST = Path(os.environ.get('DOGSHARE_DIST_ROOT', str(REPO / 'dist')))
BUNDLE = DIST / 'DogShare-1.5.1-windows-x64'
# DogShare environment keys and role filenames.
PORTABLE_NAME = os.environ.get('DOGSHARE_PORTABLE_NAME', 'DogShare.exe')
BUILD_ROLES = {'DogShare.exe': 'standard', 'DogShare-Control.exe': 'controller',
               'DogShare-Receiver.exe': 'receiver'}
if PORTABLE_NAME not in BUILD_ROLES:
    raise RuntimeError('Unrecognized DogShare portable filename')
WRAPPER = DIST / PORTABLE_NAME
RELEASE = REPO / 'flutter/build/windows/x64/runner/Release'
ASSETS = Path(os.environ.get('DOGSHARE_ASSETS', str(TOOLS / 'bridge-assets')))
MANIFEST = DIST / 'SHA256SUMS.txt'
CRT_NAME = re.compile(r'^(msvcp140(?:_[a-z0-9]+)*|vcruntime140(?:_[a-z0-9]+)*|concrt140)\.dll$', re.I)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as source:
        for block in iter(lambda: source.read(1024 * 1024), b''):
            h.update(block)
    return h.hexdigest()


def run(args, cwd=None):
    return subprocess.run(args, cwd=cwd, check=True, stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, encoding='utf-8', errors='replace').stdout.strip()


def write_json(path, value):
    path.write_text(json.dumps(value, ensure_ascii=False, indent=2) + '\n', encoding='utf-8')


def require_file(path):
    if not path.is_file() or path.stat().st_size == 0:
        raise RuntimeError(f'Required build input is missing or empty: {path}')


def pe_x64(path):
    with path.open('rb') as image:
        if image.read(2) != b'MZ':
            raise RuntimeError(f'Expected PE image: {path}')
        image.seek(0x3c)
        offset = struct.unpack('<I', image.read(4))[0]
        image.seek(offset)
        if image.read(4) != b'PE\0\0' or struct.unpack('<H', image.read(2))[0] != 0x8664:
            raise RuntimeError(f'Expected x64 PE image: {path}')


def imports(path):
    pe_x64(path)
    output = run(['dumpbin.exe', '/nologo', '/dependents', str(path)])
    return sorted(set(re.findall(r'^\s+([A-Za-z0-9_.+-]+\.dll)\s*$', output, re.M | re.I)), key=str.lower)


def pe_files(folder):
    return sorted((p for p in folder.rglob('*') if p.is_file() and
                   p.suffix.lower() in ('.exe', '.dll')), key=lambda p: str(p).lower())


def runtime_inventory(paths, folder):
    inventory = []
    missing = []
    system32 = Path(os.environ['WINDIR']) / 'System32'
    for path in paths:
        dependencies = []
        for name in imports(path):
            if (folder / name).is_file():
                location = 'bundle'
            elif name.lower().startswith(('api-ms-', 'ext-ms-')):
                location = 'Windows API set'
            elif (system32 / name).is_file():
                location = 'Windows System32'
            else:
                location = 'missing'
                missing.append(f'{path.name} -> {name}')
            dependencies.append({'name': name, 'resolution_on_build_host': location})
        inventory.append({'file': path.relative_to(DIST).as_posix(),
                          'sha256': digest(path), 'architecture': 'x64',
                          'imports_and_delay_imports': dependencies})
    if missing:
        raise RuntimeError('Unresolved static DLL dependencies: ' + '; '.join(missing))
    return inventory


def official_injection():
    metadata = json.loads((ASSETS / 'artifacts.json').read_text(encoding='utf-8'))
    artifact = next(a for a in metadata['artifacts'] if a['name'] == 'topmostwindow-artifacts-x64')
    archive = ASSETS / 'topmostwindow-artifacts-x64.zip'
    dll = ASSETS / 'topmostwindow-artifacts-x64/WindowInjection.dll'
    require_file(archive)
    require_file(dll)
    if 'sha256:' + digest(archive) != artifact['digest']:
        raise RuntimeError('Official WindowInjection archive checksum does not match GitHub metadata')
    with zipfile.ZipFile(archive) as package:
        members = [n for n in package.namelist() if Path(n).name.lower() == 'windowinjection.dll']
        if len(members) != 1 or hashlib.sha256(package.read(members[0])).hexdigest() != digest(dll):
            raise RuntimeError('WindowInjection DLL does not match the verified official archive')
    return dll, {'artifact_id': artifact['id'], 'digest': artifact['digest'],
                 'workflow_run': artifact['workflow_run']}


def copy_needed_crt():
    redist_root = Path(os.environ['VSINSTALLDIR']) / 'VC/Redist/MSVC'
    candidates = list(redist_root.glob('*/x64/Microsoft.VC143.CRT'))
    if not candidates:
        raise RuntimeError('Official VS x64 CRT redistributables are unavailable')
    redist = max(candidates, key=lambda p: tuple(int(x) for x in p.parents[1].name.split('.')))
    copied = []
    queue = pe_files(BUNDLE)
    for binary in queue:
        for name in imports(binary):
            destination = BUNDLE / name
            if CRT_NAME.fullmatch(name) and not destination.exists():
                source = redist / name
                require_file(source)
                pe_x64(source)
                shutil.copy2(source, destination)
                copied.append({'file': name, 'source': str(source), 'sha256': digest(source)})
                queue.append(destination)
    return copied


def write_receiver_cleanup():
    if BUILD_ROLES[PORTABLE_NAME] != 'receiver':
        return None
    template = (TOOLS / 'Logout-DogShare-B.template.cmd').read_text(encoding='utf-8')
    identities = {
        '__DOGSHARE_RECEIVER_CORE__': digest(BUNDLE / 'librustdesk.dll').upper(),
        '__DOGSHARE_RUNNER__': digest(BUNDLE / 'DogShare.exe').upper(),
        '__DOGSHARE_WRAPPER__': digest(WRAPPER).upper(),
    }
    for marker, checksum in identities.items():
        if template.count(marker) != 1:
            raise RuntimeError(f'Unexpected cleanup template marker: {marker}')
        template = template.replace(marker, checksum)
    cleanup = DIST / 'Logout-DogShare-B.cmd'
    cleanup.write_bytes(template.replace('\r\n', '\n').replace('\n', '\r\n').encode('utf-8'))
    return {'file': cleanup.name, 'sha256': digest(cleanup)}


def reused_backend_files(previous, build_command):
    previous = previous.resolve()
    if previous == DIST.resolve() or previous.parent != DIST.parent.resolve():
        raise RuntimeError('Reused backend must come from a sibling DogShare release')
    metadata_path = previous / 'DogShare-build-provenance.json'
    if not metadata_path.is_file():
        raise RuntimeError('Backend provenance is missing; rebuild this role before reuse')
    metadata = json.loads(metadata_path.read_text(encoding='utf-8'))
    role = BUILD_ROLES[PORTABLE_NAME]
    if (metadata.get('application') != 'DogShare'
            or metadata['build_role'] != role or metadata['version'] != '1.5.1'
            or metadata['target'] != 'Windows x64'
            or metadata['source_commit'] != run(['git', 'rev-parse', 'HEAD'], cwd=REPO)
            or metadata['rust_backend_build_command'] != build_command):
        raise RuntimeError('Prior release does not match the selected backend build')
    wrapper_hash = digest(previous / PORTABLE_NAME)
    if wrapper_hash != metadata['portable_executable_sha256']:
        raise RuntimeError('Prior release wrapper hash mismatch')
    inputs = {Path(path).name: checksum for path, checksum in metadata['input_artifacts'].items()}
    files = [previous / BUNDLE.name / name for name in ('librustdesk.dll', 'dylib_virtual_display.dll')]
    for path in files:
        require_file(path)
        if not path.resolve().is_relative_to(previous) or digest(path) != inputs.get(path.name):
            raise RuntimeError(f'Prior release backend hash mismatch: {path.name}')
    return files[0], files[1], {'release': str(previous), 'portable_executable_sha256': wrapper_hash}


def package(build_command, reuse_backend_from=None, backend_cache=None):
    import brotli
    if any(p.exists() for p in (BUNDLE, WRAPPER, MANIFEST, DIST / 'DogShare-build-provenance.json')):
        raise RuntimeError('A DogShare distribution already exists. Inspect/archive it before a new package; nothing was overwritten.')
    backend = REPO / 'target/release/librustdesk.dll'
    display = REPO / 'target/release/deps/dylib_virtual_display.dll'
    reused_backend = None
    cached_backend = None
    if reuse_backend_from is not None and backend_cache is not None:
        raise RuntimeError('Choose either a previous release or a role backend cache')
    if reuse_backend_from is not None:
        backend, display, reused_backend = reused_backend_files(reuse_backend_from, build_command)
    elif backend_cache is not None:
        from dogshare_backend_cache import load_cache
        backend, display, cached_backend = load_cache(
            REPO, TOOLS, backend_cache, BUILD_ROLES[PORTABLE_NAME], build_command)
    required = [RELEASE / 'rustdesk.exe', RELEASE / 'flutter_windows.dll',
                RELEASE / 'data/app.so', RELEASE / 'data/icudtl.dat', backend, display,
                REPO / 'LICENCE', REPO / 'docs/DOGSHARE.md', REPO / 'libs/portable/generate.py']
    for path in required:
        require_file(path)
    if b'DogShare' not in backend.read_bytes():
        raise RuntimeError('Rebuild the Rust role library for DogShare before packaging')
    if not (RELEASE / 'data/flutter_assets').is_dir():
        raise RuntimeError('Flutter assets directory is absent')
    for path in RELEASE.rglob('*'):
        if not path.resolve().is_relative_to(RELEASE.resolve()):
            raise RuntimeError(f'Release entry escapes its build directory: {path}')
    for path in [RELEASE / 'rustdesk.exe', RELEASE / 'flutter_windows.dll', backend, display]:
        pe_x64(path)
    injection, injection_metadata = official_injection()
    bridge_provenance = json.loads((ASSETS / 'bridge-provenance.json').read_text(encoding='utf-8'))
    for relative in ('src/bridge_generated.rs', 'src/bridge_generated.io.rs',
                     'flutter/lib/generated_bridge.dart', 'flutter/lib/generated_bridge.freezed.dart'):
        if digest(REPO / relative) != bridge_provenance['files'][relative]:
            raise RuntimeError(f'Generated bridge differs from the recorded matching artifact: {relative}')
    target_dir = Path(os.environ.get('CARGO_TARGET_DIR', str(REPO / 'target')))
    if target_dir.resolve() != (REPO / 'target').resolve():
        raise RuntimeError('Unset CARGO_TARGET_DIR or point it to this repository target directory')
    source_commit = run(['git', 'rev-parse', 'HEAD'], cwd=REPO)
    source_status = run(['git', 'status', '--short'], cwd=REPO)
    source_diff = subprocess.run(['git', 'diff', '--binary', 'HEAD'], cwd=REPO,
                                 check=True, stdout=subprocess.PIPE).stdout
    print('Inputs verified; creating fresh DogShare distribution', flush=True)
    DIST.mkdir(parents=True, exist_ok=True)
    shutil.copytree(RELEASE, BUNDLE)
    (BUNDLE / 'rustdesk.exe').rename(BUNDLE / 'DogShare.exe')
    for source in (backend, display, injection):
        shutil.copy2(source, BUNDLE / source.name)
    shutil.copy2(REPO / 'LICENCE', BUNDLE / 'LICENCE')
    (BUNDLE / 'docs').mkdir(exist_ok=True)
    shutil.copy2(REPO / 'docs/DOGSHARE.md', BUNDLE / 'docs/DOGSHARE.md')
    account_guide = REPO / 'docs/DOGSHARE_ACCOUNTS.md'
    if account_guide.is_file():
        shutil.copy2(account_guide, BUNDLE / 'docs/DOGSHARE_ACCOUNTS.md')
    if BUILD_ROLES[PORTABLE_NAME] != 'standard':
        role_guide = REPO / 'docs/DOGSHARE_ROLES.md'
        require_file(role_guide)
        shutil.copy2(role_guide, BUNDLE / 'docs' / role_guide.name)
    crt_files = copy_needed_crt()
    inventory = runtime_inventory(pe_files(BUNDLE), BUNDLE)
    write_json(BUNDLE / 'runtime-dependencies.json', inventory)
    provenance = {
        'application': 'DogShare', 'version': '1.5.1', 'target': 'Windows x64',
        'build_role': BUILD_ROLES[PORTABLE_NAME],
        'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
        'source_repository': 'https://github.com/xianjunhong/rustdesk',
        'upstream_repository': 'https://github.com/rustdesk/rustdesk',
        'source_commit': source_commit, 'worktree_status': source_status,
        'tracked_diff_sha256': hashlib.sha256(source_diff).hexdigest(),
        'rust_backend_build_command': build_command,
        'input_artifacts': {str(p): digest(p) for p in required if p.suffix.lower() in ('.exe', '.dll', '.so')},
        'generated_bridge': bridge_provenance, 'window_injection': injection_metadata,
        'official_crt_files': crt_files,
        'cargo_version': run(['cargo.exe', '--version']), 'rustc_version': run(['rustc.exe', '--version']),
        'python_version': sys.version, 'brotli_version': brotli.__version__,
        'native_environment_reference': json.loads((TOOLS / 'native-environment.json').read_text(encoding='utf-8-sig')),
        'flutter_engine': json.loads((ASSETS / 'custom-engine-asset.json').read_text(encoding='utf-8')),
        'optional_resources_not_added': ['usbmmidd_v2 driver package', 'remote printer driver package'],
        'verification_scope': 'Static imports and hashes; application startup and remote-session behavior require separate checks.'
    }
    if reused_backend is not None:
        provenance['reused_rust_backend'] = reused_backend
    if cached_backend is not None:
        provenance['cached_rust_backend'] = cached_backend
    write_json(BUNDLE / 'build-provenance.json', provenance)
    command = [sys.executable, str(REPO / 'libs/portable/generate.py'), '-l', '8',
               '-f', str(BUNDLE), '-o', str(REPO / 'libs/portable'), '-e', str(BUNDLE / 'DogShare.exe')]
    print('Building upstream portable wrapper with Brotli level8', flush=True)
    subprocess.run(command, cwd=REPO, check=True)
    packed = REPO / 'target/release/rustdesk-portable-packer.exe'
    payload = REPO / 'libs/portable/data.bin'
    require_file(packed)
    pe_x64(packed)
    if any(CRT_NAME.fullmatch(name) for name in imports(packed)):
        raise RuntimeError('Portable wrapper requires external VC++ runtime DLLs; rebuild it with the static CRT')
    with packed.open('rb') as image, mmap.mmap(image.fileno(), 0, access=mmap.ACCESS_READ) as binary:
        if binary.find(payload.read_bytes()) < 0:
            raise RuntimeError('Wrapper does not embed this generated payload; refusing to deliver a stale executable')
    shutil.copy2(packed, WRAPPER)
    provenance['portable_generator_command'] = command
    provenance['portable_payload_sha256'] = digest(payload)
    provenance['portable_executable_sha256'] = digest(WRAPPER)
    provenance['portable_imports'] = runtime_inventory([WRAPPER], DIST)
    cleanup = write_receiver_cleanup()
    if cleanup is not None:
        provenance['receiver_cleanup'] = cleanup
    write_json(DIST / 'DogShare-build-provenance.json', provenance)
    files = sorted(p for p in DIST.rglob('*') if p.is_file() and p != MANIFEST)
    MANIFEST.write_text(''.join(f'{digest(p)}  {p.relative_to(DIST).as_posix()}\n' for p in files), encoding='utf-8')
    verify()
    print(f'Packaged {WRAPPER}', flush=True)


def verify():
    require_file(MANIFEST)
    expected = {}
    for line in MANIFEST.read_text(encoding='utf-8').splitlines():
        checksum, relative = line.split('  ', 1)
        path = DIST / relative
        if not path.resolve().is_relative_to(DIST.resolve()) or not re.fullmatch('[0-9a-f]{64}', checksum):
            raise RuntimeError('Invalid manifest entry')
        if relative in expected:
            raise RuntimeError('Duplicate manifest entry')
        require_file(path)
        if digest(path) != checksum:
            raise RuntimeError(f'Checksum mismatch: {relative}')
        expected[relative] = checksum
    actual = {p.relative_to(DIST).as_posix() for p in DIST.rglob('*') if p.is_file() and p != MANIFEST}
    if actual != set(expected):
        raise RuntimeError('Distribution file list differs from SHA256 manifest')
    # Historical releases remain verifiable after the display-brand change.
    bundles = [path for path in (BUNDLE,) if path.is_dir()]
    if len(bundles) != 1:
        raise RuntimeError('Expected one complete application bundle')
    bundle = bundles[0]
    entry = 'DogShare.exe'
    wrapper = WRAPPER
    if not wrapper.is_file():
        candidates = [DIST / name for name in BUILD_ROLES if (DIST / name).is_file()]
        if len(candidates) != 1:
            raise RuntimeError('Expected one portable executable')
        wrapper = candidates[0]
    require_file(bundle / entry)
    runtime_inventory(pe_files(bundle), bundle)
    runtime_inventory([wrapper], DIST)
    print(f'Verified {len(expected)} file hashes and x64 static DLL imports', flush=True)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='mode', required=True)
    commands.add_parser('verify')
    packaging = commands.add_parser('package')
    packaging.add_argument('--build-command', required=True)
    packaging.add_argument('--reuse-backend-from', type=Path)
    packaging.add_argument('--backend-cache', type=Path)
    args = parser.parse_args()
    try:
        if args.mode == 'package':
            package(args.build_command, args.reuse_backend_from, args.backend_cache)
        else:
            verify()
    except (OSError, ValueError, RuntimeError, subprocess.CalledProcessError) as error:
        print(f'Packaging/verification failed: {error}', file=sys.stderr)
        sys.exit(1)
