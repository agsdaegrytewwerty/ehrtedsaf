#!/bin/sh
set -eu

printf '%s\n' 'Installing encoder runtime system libraries'
apt-get -o Acquire::Retries=3 update -qq
apt-get -o Acquire::Retries=3 install -y -qq --no-install-recommends \
    ca-certificates curl libgomp1 libsndfile1
rm -rf /var/lib/apt/lists/*

printf '%s\n' 'Installing pinned Blackwell PyTorch wheels'
python -m pip install --no-cache-dir --index-url https://download.pytorch.org/whl/cu130 \
    --extra-index-url https://pypi.org/simple -r /opt/h3/torch.constraints.txt
printf '%s\n' 'Installing pinned ComfyUI runtime dependencies'
python -m pip install --no-cache-dir -c /opt/h3/torch.constraints.txt \
    -r /opt/ComfyUI/requirements.txt soundfile==0.13.1
python -m pip check

exec python /opt/h3/start.py
