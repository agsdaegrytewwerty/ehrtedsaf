#!/usr/bin/env bash
set -euo pipefail

comfy_dir=/opt/ComfyUI
support=/opt/projectswift-h3
python="$comfy_dir/venv/bin/python"
port="${PROJECTSWIFT_H3_PORT:-8188}"
status_pid=""
cleanup() { if [ -n "$status_pid" ]; then kill "$status_pid" 2>/dev/null || true; wait "$status_pid" 2>/dev/null || true; fi; }
trap cleanup EXIT

# A boot responder keeps dispatch closed while locally assembling the large
# model. No pip, git, package manager or model download runs in this container.
H3_PORT="$port" python3.12 - <<'PY' &
import http.server, json, os, socket
class Server(http.server.ThreadingHTTPServer):
    address_family = socket.AF_INET6
class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.split('?')[0] != '/startup_status':
            self.send_error(503); return
        data = json.dumps({'label':'launch','ready':False,'detail':'Assembling verified H3 model from installed image layers'}).encode()
        self.send_response(200); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(data)
    def log_message(self, *args): pass
Server(('::', int(os.environ['H3_PORT'])), Handler).serve_forever()
PY
status_pid="$!"
"$python" "$support/model_assets.py" assemble --parts-dir "$support/model-parts" --models-dir "$comfy_dir/models"
"$python" - <<'PY'
import json
from pathlib import Path
import torch
assert torch.__version__ == '2.10.0+cu130.sm86.projectswift1', torch.__version__
assert torch.cuda.is_available(), 'H3 image requires a CUDA 13 compatible NVIDIA driver'
assert torch.cuda.get_device_capability(0) == (8, 6), 'H3 image requires an SM86 GPU'
assert torch.cuda.get_device_properties(0).total_memory >= 23 * 1024**3, 'H3 worker requires a GPU with at least 24 GB nominal VRAM'
plan = json.loads(Path('/opt/projectswift-h3/h3_runtime.json').read_text())
role = Path('/opt/projectswift-h3/role').read_text().strip()
for model in plan['models']:
    if role == 'worker' and 'worker' in model['roles'] or role == 'conditioning' and 'local' in model['roles']:
        path = Path('/opt/ComfyUI/models') / model['folder'] / Path(model['file']).name
        assert path.stat().st_size == model['bytes'], str(path)
print(f'Using baked H3 {role} runtime on {torch.cuda.get_device_name(0)}', flush=True)
PY
cleanup
status_pid=""
if [ -n "${PROJECTSWIFT_OUTPUT_BUFFER_URL:-}" ] \
    && [ -n "${PROJECTSWIFT_OUTPUT_BUFFER_WRITER_TOKEN:-}" ] \
    && [ -n "${PROJECTSWIFT_OUTPUT_BUFFER_CLIENT_ID:-}" ]; then
    "$python" "$support/projectswift_output_buffer.py" \
        --comfy-url "http://127.0.0.1:$port" --output-root "$comfy_dir/output" \
        --state "$comfy_dir/projectswift-output-spool.sqlite" &
fi
cd "$comfy_dir"
export PROJECTSWIFT_H3_PORT="$port"
exec "$python" - "$@" <<'PY'
import json, os, sys
defaults = ['--lowvram', '--reserve-vram', '1.0', '--disable-auto-launch', '--disable-api-nodes']
settings_file = os.environ.get('PROJECTSWIFT_COMFY_ARGS_FILE')
if settings_file:
    with open(settings_file) as source:
        args = json.load(source)
else:
    args = json.loads(os.environ['PROJECTSWIFT_COMFY_ARGS_JSON']) if 'PROJECTSWIFT_COMFY_ARGS_JSON' in os.environ else defaults
if not isinstance(args, list) or not all(isinstance(arg, str) and '\0' not in arg for arg in args):
    raise SystemExit('Comfy launch settings must be a JSON array of strings')
if any(arg.split('=', 1)[0] in ('--listen', '--port', '--cuda-device') for arg in args):
    raise SystemExit('Use PROJECTSWIFT_H3_PORT for the port; network binding and selected GPU are owned by the worker')
command = [sys.executable, 'main.py', '--listen', '::', '--port', os.environ['PROJECTSWIFT_H3_PORT'], '--cuda-device', '0', *args, *sys.argv[1:]]
os.execv(sys.executable, command)
PY
