"""Check that the standalone EXE can reconstruct its complete release payload."""

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import struct

import brotli


parser = argparse.ArgumentParser()
parser.add_argument("dist", type=Path)
parser.add_argument("executable")
args = parser.parse_args()
bundles = [args.dist / name for name in ("DogShare-1.5.1-windows-x64", "TomDesk-1.5.1-windows-x64")]
bundles = [folder for folder in bundles if folder.is_dir()]
if len(bundles) != 1:
    raise ValueError("Expected one complete DogShare or legacy TomDesk bundle")
bundle = bundles[0]
entry = "DogShare.exe" if (bundle / "DogShare.exe").is_file() else "TomDesk.exe"
if not (bundle / entry).is_file():
    raise ValueError("Missing embedded application entry point")
expected = {
    item.relative_to(bundle).as_posix().lower(): item
    for item in bundle.rglob("*")
    if item.is_file()
}
wrapper = (args.dist / args.executable).read_bytes()
magic = b"rustdesk"


def record_name_at(offset):
    length = struct.unpack_from(">I", wrapper, offset)[0]
    if not 1 <= length <= 1024:
        raise ValueError("Invalid package path length")
    start = offset + 4
    name = wrapper[start : start + length].decode().replace("\\", "/")
    return PurePosixPath(name).as_posix().lower(), start + length


cursor = 0
while True:
    start = wrapper.find(magic, cursor)
    if start < 0:
        raise ValueError("No portable payload")
    cursor = start + len(magic)
    try:
        first, _ = record_name_at(cursor)
    except (ValueError, struct.error):
        continue
    if first in expected:
        break

verified = set()
while wrapper[cursor : cursor + len(magic)] != magic:
    name, cursor = record_name_at(cursor)
    if name in verified or name not in expected:
        raise ValueError(f"Invalid portable payload path: {name}")
    length = struct.unpack_from(">I", wrapper, cursor)[0]
    cursor += 4
    if length > len(wrapper) - cursor - 32:
        raise ValueError("Truncated portable payload")
    raw = brotli.decompress(wrapper[cursor : cursor + length])
    cursor += length
    stored_md5 = wrapper[cursor : cursor + 32].decode("ascii")
    cursor += 32
    assert hashlib.md5(raw).hexdigest() == stored_md5, name
    assert hashlib.sha256(raw).digest() == hashlib.sha256(expected[name].read_bytes()).digest(), name
    verified.add(name)

assert verified == set(expected), "Standalone package missing distribution files"
assert wrapper[cursor + len(magic) :].startswith((".\\" + entry).encode()), "Wrong embedded entry point"
print(f"{args.executable}: decoded and matched all {len(verified)} embedded files")
