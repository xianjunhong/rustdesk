import argparse
import ctypes as c
import hashlib
import json
import os
from pathlib import Path
import subprocess


class DartObject(c.Structure):
    pass


class DartArray(c.Structure):
    _fields_ = [("length", c.c_ssize_t), ("values", c.POINTER(c.POINTER(DartObject)))]


class DartValue(c.Union):
    _fields_ = [("as_bool", c.c_bool), ("as_array", DartArray)]


DartObject._fields_ = [("type", c.c_int), ("value", DartValue)]


def read_flag(library, name):
    wire = getattr(library, name)
    wire.argtypes = []
    wire.restype = c.POINTER(DartObject)
    release = library.free_WireSyncReturn
    release.argtypes = [c.POINTER(DartObject)]
    release.restype = None
    pointer = wire()
    assert pointer and pointer.contents.type == 6, "Expected Dart_CObject_kArray"
    try:
        array = pointer.contents.value.as_array
        assert array.length == 2
        value, success = (array.values[i].contents for i in range(2))
        assert value.type == success.type == 1 and success.value.as_bool
        return bool(value.value.as_bool)
    finally:
        release(pointer)


parser = argparse.ArgumentParser()
parser.add_argument("role", choices=("standard", "controller", "receiver"))
parser.add_argument("--dist", type=Path)
parser.add_argument("--live-subtitles", action="store_true")
args = parser.parse_args()
variants = {
    "standard": ("dist-dogshare-accounts", "DogShare.exe", False, False),
    "controller": ("dist-dogshare-controller", "DogShare-Control.exe", False, True),
    "receiver": ("dist-dogshare-receiver", "DogShare-Receiver.exe", True, False),
}
folder, filename, incoming, outgoing = variants[args.role]
workspace = Path(os.environ.get('DOGSHARE_REPO', str(Path(__file__).resolve().parents[1])))
dist = args.dist or workspace / folder
bundle = dist / "DogShare-1.5.1-windows-x64"
legacy = not bundle.is_dir()
if legacy:
    bundle = dist / "DogShare-1.5.1-windows-x64"
    filename = filename.replace("DogShare", "DogShare")
elif not (dist / filename).is_file() and (dist / filename.replace("DogShare", "DogShare")).is_file():
    filename = filename.replace("DogShare", "DogShare")
entry = bundle / ("DogShare.exe" if legacy else "DogShare.exe")
with os.add_dll_directory(str(bundle)):
    library = c.CDLL(str(bundle / "librustdesk.dll"))
    got = (read_flag(library, "wire_is_incoming_only"), read_flag(library, "wire_is_outgoing_only"))
assert got == (incoming, outgoing), got
if args.role != "standard":
    backend = (bundle / "librustdesk.dll").read_bytes()
    for embedded in (
        b"https://phenoseed.com/dogshare-paired-account",
        b"phenoseed.com:21116",
        b"phenoseed.com:21117",
        b"qB3gToeF8XffSp+r8ShbZy2h8JCsWVaJAu9d3uWlmNc=",
    ):
        assert embedded in backend, f"Missing embedded server setting: {embedded!r}"
if args.live_subtitles:
    assert args.role != "standard"
    assert b"DogShareSubtitle" in backend
    assert b"pairedCard" in entry.read_bytes()
    assert b"dogshare-runtime-subtitle-frame" in (bundle / "data/app.so").read_bytes()
version = subprocess.run([str(entry), "--version"], cwd=bundle,
                         capture_output=True, timeout=20, check=True,
                         creationflags=subprocess.CREATE_NO_WINDOW).stdout.decode().strip()
assert version == "1.5.1", version
provenance_name = "DogShare-build-provenance.json" if legacy else "DogShare-build-provenance.json"
provenance = json.loads((dist / provenance_name).read_text(encoding="utf-8"))
assert provenance.get("build_role", "standard") == args.role
if not legacy:
    assert provenance["application"] == "DogShare"
    assert b"DogShare" in (bundle / "librustdesk.dll").read_bytes()
with (dist / filename).open("rb") as image:
    digest = hashlib.file_digest(image, "sha256").hexdigest()
assert digest == provenance["portable_executable_sha256"]
print(f"{args.role}: runner {version}; incoming-only={incoming}; outgoing-only={outgoing}; SHA256={digest}")
