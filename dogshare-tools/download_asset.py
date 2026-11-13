import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
from pathlib import Path
import shutil
import time
import urllib.request

p = argparse.ArgumentParser()
p.add_argument('url')
p.add_argument('output')
p.add_argument('--sha256')
a = p.parse_args()
out = Path(a.output).resolve()
out.parent.mkdir(parents=True, exist_ok=True)
headers = {'User-Agent': 'DogShare-build-setup/1.0'}
for attempt in range(4):
    try:
        with urllib.request.urlopen(urllib.request.Request(a.url, method='HEAD', headers=headers), timeout=60) as response:
            size = int(response.headers['Content-Length'])
        break
    except Exception as error:
        if attempt == 3:
            raise
        print(f'Retrying download metadata: {type(error).__name__}', flush=True)
        time.sleep(2)
if out.exists() and out.stat().st_size == size:
    if not a.sha256 or hashlib.sha256(out.read_bytes()).hexdigest() == a.sha256:
        print(f'Reusing {out}: {size} bytes', flush=True)
        raise SystemExit(0)
chunk = (size + 7) // 8
parts = out.with_name(out.name + '.parts')
parts.mkdir(exist_ok=True)

def fetch(start):
    end = min(start + chunk, size) - 1
    file = parts / f'{start}-{end}'
    for attempt in range(4):
        present = file.stat().st_size if file.exists() else 0
        if present == end - start + 1:
            return file
        if present > end - start + 1:
            raise RuntimeError(f'Oversize part {file}')
        offset = start + present
        try:
            request = urllib.request.Request(a.url, headers={**headers, 'Range': f'bytes={offset}-{end}'})
            with urllib.request.urlopen(request, timeout=90) as response:
                if response.status != 206 or response.headers.get('Content-Range') != f'bytes {offset}-{end}/{size}':
                    raise RuntimeError(f'Invalid HTTP Range {offset}-{end}: {response.status}')
                with file.open('ab') as output:
                    shutil.copyfileobj(response, output, 1024 * 1024)
            if file.stat().st_size == end - start + 1:
                print(f'Completed {start}-{end}', flush=True)
                return file
        except Exception as e:
            if attempt == 3:
                raise
            print(f'Retry {start}-{end}: {type(e).__name__}', flush=True)
            time.sleep(2)
    raise RuntimeError(f'Incomplete {file}')

print(f'Downloading {a.url}: {size} bytes in 8 resumable segments', flush=True)
with ThreadPoolExecutor(max_workers=8) as pool:
    files = list(pool.map(fetch, range(0, size, chunk)))
temporary = out.with_name(out.name + '.download')
with temporary.open('wb') as output:
    for file in files:
        with file.open('rb') as source:
            shutil.copyfileobj(source, output)
digest = hashlib.sha256(temporary.read_bytes()).hexdigest()
if a.sha256 and digest != a.sha256:
    raise RuntimeError('SHA256 mismatch')
temporary.replace(out)
print(f'SHA256 {digest} {out}', flush=True)
