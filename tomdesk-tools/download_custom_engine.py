from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import shutil
import urllib.request
import zipfile

root = Path(__file__).parent / 'bridge-assets'
asset = json.loads((root / 'custom-engine-asset.json').read_text(encoding='utf8'))
url = asset['browser_download_url']
archive = root / asset['name']
total = asset['size']
count = 8
step = (total + count - 1) // count
ranges = [(first, min(first + step, total) - 1) for first in range(0, total, step)]

def download(bounds):
    first, last = bounds
    part = root / f'engine-{first}-{last}.part'
    current = part.stat().st_size if part.exists() else 0
    if current == last - first + 1:
        return part
    if current > last - first + 1:
        raise RuntimeError('Partial segment exceeds expected size')
    resumed = first + current
    request = urllib.request.Request(url, headers={'User-Agent':'TomDesk-build-setup', 'Range': f'bytes={resumed}-{last}'})
    with urllib.request.urlopen(request, timeout=90) as response:
        expected = f'bytes {resumed}-{last}/{total}'
        if response.status != 206 or response.headers.get('Content-Range') != expected:
            raise RuntimeError(f'Unexpected range response: {response.status} {response.headers.get("Content-Range")}')
        with part.open('ab') as output:
            shutil.copyfileobj(response, output, 1024 * 1024)
    if part.stat().st_size != last - first + 1:
        raise RuntimeError('Incomplete segment')
    print(f'Completed engine range {first}-{last}', flush=True)
    return part

with ThreadPoolExecutor(max_workers=count) as executor:
    parts = list(executor.map(download, ranges))
with archive.open('wb') as output:
    for part in parts:
        with part.open('rb') as source:
            shutil.copyfileobj(source, output)
assert archive.stat().st_size == total
digest = hashlib.sha256(archive.read_bytes()).hexdigest()
if asset.get('digest'):
    assert 'sha256:' + digest == asset['digest']
destination = root / 'custom-engine'
with zipfile.ZipFile(archive) as engine_zip:
    assert engine_zip.testzip() is None
    for name in engine_zip.namelist():
        assert (destination / name).resolve().is_relative_to(destination.resolve())
    engine_zip.extractall(destination)
print(f'Custom engine extracted. SHA256 {digest}; size {total}; all ZIP CRCs verified.', flush=True)
