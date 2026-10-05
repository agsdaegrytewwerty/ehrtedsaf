"""Download pinned weights at build time; assemble large files locally at boot."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import urllib.request

PART_BYTES = 7_000_000_000
CHUNK_BYTES = 4 * 1024 * 1024


def fetch_model(model, destination, split=False):
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    filename = Path(model['file']).name
    url = f"https://huggingface.co/{model['repo']}/resolve/{model['revision']}/{model['file']}?download=true&build={time.time_ns()}"
    whole = hashlib.sha256()
    parts = []
    total = 0
    with urllib.request.urlopen(url, timeout=180) as response:
        while total < model['bytes']:
            name = f"{filename}.part{len(parts):02d}" if split else filename
            limit = min(PART_BYTES if split else model['bytes'], model['bytes'] - total)
            digest = hashlib.sha256()
            count = 0
            with (destination / name).open('wb') as target:
                while count < limit:
                    data = response.read(min(CHUNK_BYTES, limit - count))
                    if not data:
                        raise RuntimeError(f"Truncated model: {filename}")
                    target.write(data)
                    whole.update(data)
                    digest.update(data)
                    count += len(data)
                    total += len(data)
            parts.append({'file': name, 'bytes': count, 'sha256': digest.hexdigest()})
            print(f"Downloaded {name}: {count} bytes", flush=True)
        if response.read(1) or whole.hexdigest() != model['sha256']:
            raise RuntimeError(f"Size/hash mismatch: {filename}")
    if split:
        descriptor = {**model, 'filename': filename, 'parts': parts}
        (destination / 'parts.json').write_text(json.dumps(descriptor, indent=2) + '\n')


def assemble(parts_dir, models_dir):
    parts_dir, models_dir = Path(parts_dir), Path(models_dir)
    plan = json.loads((parts_dir / 'parts.json').read_text())
    target = models_dir / plan['folder'] / plan['filename']
    target.parent.mkdir(parents=True, exist_ok=True)
    marker = target.with_suffix(target.suffix + '.verified.json')
    if target.is_file() and marker.is_file():
        cached = json.loads(marker.read_text())
        stat = target.stat()
        if cached == {'sha256': plan['sha256'], 'bytes': stat.st_size, 'mtime_ns': stat.st_mtime_ns} and stat.st_size == plan['bytes']:
            print(f"Verified assembled {target.name}", flush=True)
            return
    temporary = target.with_suffix(target.suffix + '.partial')
    whole, total = hashlib.sha256(), 0
    try:
        with temporary.open('wb') as output:
            for part in plan['parts']:
                path = parts_dir / part['file']
                if path.stat().st_size != part['bytes']:
                    raise RuntimeError(f"Wrong part size: {path.name}")
                digest = hashlib.sha256()
                with path.open('rb') as source:
                    while data := source.read(CHUNK_BYTES):
                        output.write(data)
                        digest.update(data)
                        whole.update(data)
                        total += len(data)
                if digest.hexdigest() != part['sha256']:
                    raise RuntimeError(f"Wrong part hash: {path.name}")
                print(f"Assembled {path.name}", flush=True)
        if total != plan['bytes'] or whole.hexdigest() != plan['sha256']:
            raise RuntimeError('Assembled model failed size/hash verification')
        temporary.replace(target)
        stat = target.stat()
        marker.write_text(json.dumps({'sha256': plan['sha256'], 'bytes': stat.st_size, 'mtime_ns': stat.st_mtime_ns}) + '\n')
    finally:
        temporary.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest='mode', required=True)
    download = sub.add_parser('download')
    download.add_argument('--manifest', type=Path, required=True)
    download.add_argument('--folder', required=True)
    download.add_argument('--destination', type=Path, required=True)
    download.add_argument('--split', action='store_true')
    download.add_argument('--filename')
    unpack = sub.add_parser('assemble')
    unpack.add_argument('--parts-dir', type=Path, required=True)
    unpack.add_argument('--models-dir', type=Path, required=True)
    args = parser.parse_args()
    if args.mode == 'assemble':
        assemble(args.parts_dir, args.models_dir)
    else:
        models = json.loads(args.manifest.read_text())['models']
        selected = [m for m in models if m['folder'] == args.folder and (not args.filename or Path(m['file']).name == args.filename)]
        if len(selected) != 1:
            raise SystemExit('Download must select exactly one pinned model')
        fetch_model(selected[0], args.destination, args.split)


if __name__ == '__main__':
    main()
