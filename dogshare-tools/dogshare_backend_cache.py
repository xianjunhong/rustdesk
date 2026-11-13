"""Validate role-specific DogShare backend caches without compiling anything."""

import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import struct
import subprocess
import sys


SCHEMA = 1
APP = "DogShare"
TARGET = "x86_64-pc-windows-msvc"
ROLES = {"controller": (False, True), "receiver": (True, False)}
DLLS = {
    "librustdesk.dll": "target/release/librustdesk.dll",
    "dylib_virtual_display.dll": "target/release/deps/dylib_virtual_display.dll",
}
LOCAL_LIBS = (
    "hbb_common", "base", "scrap", "enigo", "clipboard", "virtual_display",
    "remote_printer", "libxdo-sys-stub",
)
REPO_FILES = (
    "Cargo.toml", "Cargo.lock", "build.rs", ".cargo/config.toml",
    "src/bridge_generated.rs", "src/bridge_generated.io.rs",
    "flutter/lib/generated_bridge.dart", "flutter/lib/generated_bridge.freezed.dart",
    "res/tray-icon.ico", "res/icon.ico", "res/manifest.xml",
    "flutter/windows/runner/service_control.h",
)
TOOL_FILES = (
    "cargo-task.ps1", "dogshare-env.ps1", "native-env.cmd", "native-environment.json",
    "bridge-assets/bridge-provenance.json", "dogshare_backend_cache.py",
)
FLAG_ENV = ("RUSTFLAGS", "CARGO_ENCODED_RUSTFLAGS", "CARGO_BUILD_TARGET")
SKIP_DIRS = {".git", "target", "__pycache__", ".idea", ".vscode"}
SHA256 = re.compile(r"[0-9a-f]{64}\Z")


class CacheError(RuntimeError):
    pass


def build_command_for(role):
    if role not in ROLES:
        raise CacheError(f"Unsupported backend role: {role}")
    return f"cargo build --locked --offline --release --lib --features flutter,hwcodec,dogshare-{role}"


def _root(path, *, must_exist=True):
    path = Path(path)
    if ".." in path.parts:
        raise CacheError(f"Parent traversal is not allowed: {path}")
    resolved = path.resolve(strict=must_exist)
    if must_exist and not resolved.is_dir():
        raise CacheError(f"Expected a directory: {path}")
    return resolved


def _relative_name(name):
    if not isinstance(name, str) or "\\" in name or ":" in name:
        raise CacheError(f"Invalid relative cache path: {name!r}")
    path = PurePosixPath(name)
    if path.is_absolute() or not path.parts or any(x in (".", "..") for x in path.parts):
        raise CacheError(f"Invalid relative cache path: {name!r}")
    if path.as_posix() != name:
        raise CacheError(f"Noncanonical relative cache path: {name!r}")
    return name


def _contained_file(root, relative):
    relative = _relative_name(relative)
    path = root / relative
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root) or not resolved.is_file() or path.is_symlink():
        raise CacheError(f"File escapes its root or is not a regular file: {path}")
    return path


def _digest(path):
    digest = hashlib.sha256()
    before = path.stat()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    after = path.stat()
    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
        raise CacheError(f"File changed while hashing: {path}")
    return digest.hexdigest()


def _walk(root, relative):
    directory = root / relative
    if not directory.is_dir():
        raise CacheError(f"Required source directory is missing: {directory}")
    for base, dirs, files in os.walk(directory, followlinks=False):
        base = Path(base)
        dirs[:] = sorted(name for name in dirs if name not in SKIP_DIRS)
        if base == root / "libs/scrap":
            dirs[:] = [name for name in dirs if name != "generated"]
        for name in dirs:
            child = base / name
            if child.is_symlink() or not child.resolve().is_relative_to(root):
                raise CacheError(f"Source directory escapes its root: {child}")
        for name in sorted(files):
            path = base / name
            relative_path = path.relative_to(root).as_posix()
            if (name == ".git" or name.endswith((".bak", ".rs.bk", ".pyc"))
                    or relative_path == "src/version.rs"):
                continue
            yield relative_path


def _input_paths(repo, tools):
    names = set(REPO_FILES)
    names.update(_walk(repo, "src"))
    for library in LOCAL_LIBS:
        names.update(_walk(repo, f"libs/{library}"))
    for optional in (".cargo/config", "rust-toolchain", "rust-toolchain.toml",
                     "res/mac-tray-dark-x2.png"):
        if (repo / optional).is_file():
            names.add(optional)
    entries = [("repo/" + name, _contained_file(repo, name)) for name in sorted(names)]
    entries.extend(("tools/" + name, _contained_file(tools, name)) for name in TOOL_FILES)
    folded = [name.casefold() for name, _ in entries]
    if len(folded) != len(set(folded)):
        raise CacheError("Duplicate input paths after Windows path normalization")
    return sorted(entries)


def _rustc_version(tools):
    rustc = shutil.which("rustc.exe") or shutil.which("rustc")
    if rustc is None:
        fallback = tools / "cargo/bin/rustc.exe"
        if not fallback.is_file():
            raise CacheError("rustc was not found in PATH or the selected tool directory")
        rustc = str(fallback)
    result = subprocess.run([rustc, "--version"], capture_output=True, text=True,
                            check=True, timeout=30)
    version = result.stdout.strip()
    if not version.startswith("rustc "):
        raise CacheError("rustc --version returned an unexpected response")
    return version


def snapshot(repo, tools):
    """Hash real backend inputs, including ignored bridge and native source files."""
    repo, tools = _root(repo), _root(tools)
    entries = _input_paths(repo, tools)
    context = {"schema": SCHEMA, "target": TARGET, "rustc": _rustc_version(tools),
               "environment": {name: os.environ.get(name) for name in FLAG_ENV}}
    digest = hashlib.sha256(json.dumps(context, sort_keys=True).encode("utf-8"))
    for name, path in entries:
        key = name.encode("utf-8")
        digest.update(len(key).to_bytes(8, "big"))
        digest.update(key)
        digest.update(bytes.fromhex(_digest(path)))
    return {"fingerprint": digest.hexdigest(), "count": len(entries),
            "rustc": context["rustc"]}


def _version(repo):
    text = (repo / "Cargo.toml").read_text(encoding="utf-8-sig")
    package = text.split("[package]", 1)[1].split("\n[", 1)[0]
    match = re.search(r'^version\s*=\s*"([^"\r\n]+)"', package, re.MULTILINE)
    if match is None:
        raise CacheError("Cannot determine the root Cargo package version")
    return match.group(1)


def _pe_x64(path):
    with path.open("rb") as source:
        header = source.read(64)
        if len(header) != 64 or header[:2] != b"MZ":
            raise CacheError(f"Not a PE image: {path}")
        offset = struct.unpack_from("<I", header, 0x3C)[0]
        if offset > path.stat().st_size - 26:
            raise CacheError(f"Invalid PE header offset: {path}")
        source.seek(offset)
        pe = source.read(26)
    if (pe[:4] != b"PE\0\0" or struct.unpack_from("<H", pe, 4)[0] != 0x8664
            or struct.unpack_from("<H", pe, 24)[0] != 0x20B
            or not struct.unpack_from("<H", pe, 22)[0] & 0x2000):
        raise CacheError(f"Expected a Windows x64 DLL: {path}")


def _dogshare_marker(path):
    with path.open("rb") as source:
        previous = b""
        for block in iter(lambda: source.read(1024 * 1024), b""):
            data = previous + block
            if b"DogShare" in data:
                return
            previous = data[-7:]
    raise CacheError("Backend does not contain the DogShare display brand; rebuild this role")


def _probe_role(backend):
    command = [sys.executable, "-B", str(Path(__file__).resolve()),
               "_probe-role", "--backend", str(backend)]
    options = {"creationflags": subprocess.CREATE_NO_WINDOW} if os.name == "nt" else {}
    result = subprocess.run(command, capture_output=True, text=True, timeout=30, **options)
    if result.returncode:
        raise CacheError("Role probe failed: " + (result.stderr.strip() or str(result.returncode)))
    try:
        flags = json.loads(result.stdout)
    except json.JSONDecodeError as error:
        raise CacheError("Role probe returned invalid JSON") from error
    if (not isinstance(flags, dict) or set(flags) != {"incoming_only", "outgoing_only"}
            or any(type(value) is not bool for value in flags.values())):
        raise CacheError("Role probe returned invalid flags")
    return flags


def _assert_role(backend, role):
    expected = dict(zip(("incoming_only", "outgoing_only"), ROLES[role]))
    actual = _probe_role(backend)
    if actual != expected:
        raise CacheError(f"Backend role mismatch: expected {role}, got {actual}")
    return actual


def _json_pairs(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise CacheError(f"Duplicate metadata key: {key}")
        result[key] = value
    return result


def _read_record(cache):
    manifest = _contained_file(cache, "backend.json")
    if manifest.stat().st_size > 64 * 1024:
        raise CacheError("Backend manifest is unexpectedly large")
    result = json.loads(manifest.read_text(encoding="utf-8"), object_pairs_hook=_json_pairs)
    if not isinstance(result, dict):
        raise CacheError("Backend manifest must be an object")
    return result


def load_cache(repo, tools, cache, role, build_command):
    """Return the two validated DLL paths and metadata for the packager."""
    expected_command = build_command_for(role)
    if build_command != expected_command:
        raise CacheError("Build command does not match the selected role")
    repo, tools, cache = _root(repo), _root(tools), _root(cache)
    metadata = _read_record(cache)
    current = snapshot(repo, tools)
    for key, expected in {"schema": SCHEMA, "app": APP, "version": _version(repo),
                          "target": TARGET, "role": role, "build_command": build_command,
                          "fingerprint": current["fingerprint"],
                          "input_count": current["count"]}.items():
        if metadata.get(key) != expected:
            raise CacheError(f"Backend cache {key} does not match current inputs; rebuild {role}")
    entries = metadata.get("files")
    if not isinstance(entries, list) or len(entries) != len(DLLS):
        raise CacheError("Backend manifest must contain exactly the two expected DLLs")
    verified = {}
    for entry in entries:
        if not isinstance(entry, dict) or set(entry) != {"path", "sha256"}:
            raise CacheError("Invalid backend file metadata")
        name = _relative_name(entry["path"])
        if name not in DLLS or name.casefold() in verified:
            raise CacheError(f"Unexpected or duplicate backend file: {name}")
        checksum = entry["sha256"]
        if not isinstance(checksum, str) or not SHA256.fullmatch(checksum):
            raise CacheError(f"Invalid backend SHA256: {name}")
        path = _contained_file(cache, name)
        if _digest(path) != checksum:
            raise CacheError(f"Backend DLL hash mismatch: {name}")
        _pe_x64(path)
        verified[name.casefold()] = path
    if {p.name for p in cache.iterdir()} != set(DLLS) | {"backend.json"}:
        raise CacheError("Unexpected cache contents; use an untouched role cache")
    backend, display = (verified[name] for name in DLLS)
    _dogshare_marker(backend)
    flags = _assert_role(backend, role)
    if metadata.get("role_probe") != flags:
        raise CacheError("Recorded role flags do not match the DLL")
    if snapshot(repo, tools)["fingerprint"] != current["fingerprint"]:
        raise CacheError("Sources changed while checking the backend cache")
    return backend, display, metadata


def record_cache(repo, tools, cache, role, expected_fingerprint):
    """Record freshly built DLLs in a new directory, publishing the manifest last."""
    build_command = build_command_for(role)
    if not isinstance(expected_fingerprint, str) or not SHA256.fullmatch(expected_fingerprint):
        raise CacheError("Expected fingerprint must be a lowercase SHA256")
    repo, tools = _root(repo), _root(tools)
    before = snapshot(repo, tools)
    if before["fingerprint"] != expected_fingerprint:
        raise CacheError("Sources changed during compilation; refusing to record the backend")
    cache_path = Path(cache)
    cache = _root(cache_path, must_exist=False)
    if cache.exists():
        raise CacheError(f"Cache already exists; nothing was overwritten: {cache}")
    sources = {name: _contained_file(repo, relative) for name, relative in DLLS.items()}
    hashes = {name: _digest(path) for name, path in sources.items()}
    for path in sources.values():
        _pe_x64(path)
    _dogshare_marker(sources["librustdesk.dll"])
    cache.mkdir(parents=True, exist_ok=False)
    entries = []
    for name, source in sources.items():
        destination = cache / name
        shutil.copy2(source, destination)
        if _digest(destination) != hashes[name] or _digest(source) != hashes[name]:
            raise CacheError("Build outputs changed while copying; no valid cache was published")
        entries.append({"path": name, "sha256": hashes[name]})
    flags = _assert_role(cache / "librustdesk.dll", role)
    after = snapshot(repo, tools)
    if after["fingerprint"] != expected_fingerprint:
        raise CacheError("Sources changed while recording; no valid cache was published")
    metadata = {"schema": SCHEMA, "app": APP, "version": _version(repo),
                "target": TARGET, "role": role, "build_command": build_command,
                "fingerprint": expected_fingerprint, "input_count": before["count"],
                "rustc": after["rustc"], "files": entries, "role_probe": flags,
                "created_utc": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    temporary = cache / "backend.json.tmp"
    temporary.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
    temporary.replace(cache / "backend.json")
    return metadata


def _native_flags(backend):
    # Identical Dart_CObject layout and wire checks to verify_dogshare_role.py.
    if os.name != "nt" or struct.calcsize("P") != 8:
        raise CacheError("Backend role probing requires the current Windows x64 Python")
    class DartObject(ctypes.Structure):
        pass
    class DartArray(ctypes.Structure):
        _fields_ = [("length", ctypes.c_ssize_t),
                    ("values", ctypes.POINTER(ctypes.POINTER(DartObject)))]
    class DartValue(ctypes.Union):
        _fields_ = [("as_bool", ctypes.c_bool), ("as_array", DartArray)]
    DartObject._fields_ = [("type", ctypes.c_int), ("value", DartValue)]
    with os.add_dll_directory(str(backend.parent)):
        library = ctypes.CDLL(str(backend))
        release = library.free_WireSyncReturn
        release.argtypes = [ctypes.POINTER(DartObject)]
        release.restype = None
        result = {}
        for key in ("incoming_only", "outgoing_only"):
            wire = getattr(library, "wire_is_" + key)
            wire.argtypes = []
            wire.restype = ctypes.POINTER(DartObject)
            pointer = wire()
            if not pointer:
                raise CacheError("Backend returned a null role object")
            try:
                if pointer.contents.type != 6:
                    raise CacheError("Expected a Dart_CObject_kArray role result")
                array = pointer.contents.value.as_array
                if array.length != 2 or not array.values:
                    raise CacheError("Invalid role result array")
                if not array.values[0] or not array.values[1]:
                    raise CacheError("Null value in role result")
                value, success = (array.values[i].contents for i in range(2))
                if value.type != 1 or success.type != 1 or not success.value.as_bool:
                    raise CacheError("Backend could not report its role")
                result[key] = bool(value.value.as_bool)
            finally:
                release(pointer)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("snapshot", "record", "check"):
        command = commands.add_parser(name)
        command.add_argument("--repo", type=Path, required=True)
        command.add_argument("--tools", type=Path, required=True)
        if name != "snapshot":
            command.add_argument("--role", choices=ROLES, required=True)
            command.add_argument("--cache", type=Path, required=True)
        if name == "record":
            command.add_argument("--expected-fingerprint", required=True)
    probe = commands.add_parser("_probe-role", help=argparse.SUPPRESS)
    probe.add_argument("--backend", type=Path, required=True)
    args = parser.parse_args()
    if args.command == "snapshot":
        result = snapshot(args.repo, args.tools)
    elif args.command == "record":
        result = record_cache(args.repo, args.tools, args.cache, args.role,
                              args.expected_fingerprint)
    elif args.command == "check":
        backend, display, metadata = load_cache(
            args.repo, args.tools, args.cache, args.role, build_command_for(args.role))
        result = {"ok": True, "role": args.role, "cache": str(args.cache.resolve()),
                  "fingerprint": metadata["fingerprint"], "backend": str(backend),
                  "display": str(display)}
    else:
        result = _native_flags(args.backend.resolve(strict=True))
    print(json.dumps(result, ensure_ascii=False, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except (CacheError, OSError, ValueError, KeyError, IndexError,
            subprocess.SubprocessError) as error:
        print("ERROR: " + str(error), file=sys.stderr)
        raise SystemExit(1)
