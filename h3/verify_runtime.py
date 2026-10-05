"""CPU/node contract verification. Run this with container networking disabled."""
import json
from pathlib import Path
import subprocess
import tempfile
import time
import urllib.request

ROOT = Path('/opt/ComfyUI')
plan = json.loads(Path('/opt/projectswift-h3/h3_runtime.json').read_text())
role = Path('/opt/projectswift-h3/role').read_text().strip()
parts = json.loads(Path('/opt/projectswift-h3/model-parts/parts.json').read_text())
assert sum(p['bytes'] for p in parts['parts']) == parts['bytes']
for part in parts['parts']:
    assert part['bytes'] <= 7_000_000_000
    assert (Path('/opt/projectswift-h3/model-parts') / part['file']).stat().st_size == part['bytes']
for model in plan['models']:
    if (role == 'worker' and 'worker' in model['roles'] or role == 'conditioning' and 'local' in model['roles']) and model['folder'] == 'vae':
        assert (ROOT / 'models/vae' / Path(model['file']).name).stat().st_size == model['bytes']
import torch
assert torch.__version__ == '2.10.0+cu130.sm86.projectswift1', torch.__version__
assert torch.version.cuda == '13.0', torch.version.cuda
assert torch._C._cuda_getArchFlags().split() == ['sm_86']
assert torch.backends.cudnn.version() is not None
assert torch.backends.cuda.is_flash_attention_available()
import torchaudio
import soundfile
import av
assert torchaudio.__version__.split('+')[0] == '2.10.0', torchaudio.__version__
# The image-only bundle drops audio dependencies; H3 must keep the separate
# torchaudio package and the decode/mux stack when reusing its PyTorch wheel.
wave = torch.sin(torch.arange(4800, dtype=torch.float32) * (2 * torch.pi * 440 / 48000)).unsqueeze(0)
resampled = torchaudio.functional.resample(wave, 48000, 24000)
assert resampled.shape == (1, 2400) and torch.isfinite(resampled).all()
assert torch.isfinite(torch.fft.rfft(wave)).all()
with tempfile.TemporaryDirectory(prefix='h3-audio-check-') as temporary:
    wav, mp4 = Path(temporary) / 'audio.wav', Path(temporary) / 'clip.mp4'
    soundfile.write(wav, wave.squeeze().numpy(), 48000, subtype='PCM_16')
    samples, rate = soundfile.read(wav)
    assert len(samples) == 4800 and rate == 48000
    subprocess.run(['ffmpeg', '-hide_banner', '-loglevel', 'error', '-f', 'lavfi', '-i', 'color=c=black:s=32x32:r=24', '-i', str(wav), '-t', '0.1', '-c:v', 'libx264', '-c:a', 'aac', str(mp4)], check=True)
    with av.open(str(mp4)) as container:
        assert len(container.streams.video) == 1 and len(container.streams.audio) == 1
        assert sum(frame.samples for frame in container.decode(audio=0)) > 0
print('Verified H3 audio: torchaudio resampling, FFT, WAV I/O and MP4 audio mux/decode', flush=True)
log = Path('/tmp/h3-cpu-verification.log')
with log.open('w') as output:
    process = subprocess.Popen([str(ROOT / 'venv/bin/python'), 'main.py', '--cpu', '--listen', '127.0.0.1', '--port', '8188', '--disable-auto-launch', '--disable-api-nodes'], cwd=ROOT, stdout=output, stderr=subprocess.STDOUT)
    try:
        deadline = time.monotonic() + 120
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(log.read_text())
            try:
                with urllib.request.urlopen('http://127.0.0.1:8188/object_info', timeout=2) as response:
                    nodes = json.load(response)
                break
            except OSError:
                time.sleep(1)
        else:
            raise RuntimeError(log.read_text())
        required = {'ProjectSwiftLoadH3Condition', 'ProjectSwiftSaveH3Condition', 'MiniMaxH3ImageToVideo', 'EmptyMiniMaxH3LatentAV', 'UNETLoader', 'BasicGuider', 'BasicScheduler', 'RandomNoise', 'KSamplerSelect', 'SamplerCustomAdvanced', 'VAELoader', 'VAEDecodeTiled', 'VAEDecodeAudio', 'CreateVideo', 'SaveVideo', 'SaveImage'}
        assert not required - nodes.keys(), sorted(required - nodes.keys())
        with urllib.request.urlopen('http://127.0.0.1:8188/projectswift/h3/profile', timeout=2) as response:
            assert json.load(response)['comfy_revision'] == plan['comfy_revision']
        print(f"Verified {role} H3 image: CPU imports, native node contract and status routes", flush=True)
    finally:
        process.terminate()
        try:
            process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
