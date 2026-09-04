#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: %s WINDOWS_DRIVER_VERSION OUTPUT_DIRECTORY\n' "$0" >&2
  exit 2
fi

driver_version="$1"
output_root="$2"
[[ "$driver_version" =~ ^[0-9]{3}\.[0-9]{2}$ ]] || {
  printf 'Invalid Windows NVIDIA driver version: %s\n' "$driver_version" >&2
  exit 2
}

for command_name in curl unzip 7z sha256sum python3 tar xz; do
  command -v "$command_name" >/dev/null
done

d3d12_version="1.611.1-81528511"
dxcore_version="10.0.26100.1-240331-1435.ge-release"
feed_base="https://pkgs.dev.azure.com/shine-oss/13eb32df-d33f-470f-b930-499535a958b4/_packaging/7925a3a1-b93c-4977-8a97-5b877bf2068b/nuget/v3/flat2"
d3d12_url="${feed_base}/microsoft.direct3d.linux/${d3d12_version}/microsoft.direct3d.linux.${d3d12_version}.nupkg"
dxcore_url="${feed_base}/microsoft.dxcore.linux.amd64fre/${dxcore_version}/microsoft.dxcore.linux.amd64fre.${dxcore_version}.nupkg"
d3d12_package_sha256="2a0e23e4b1755f1a9c639a5115063db123ad172120d36520ff2aa962c50973f4"
dxcore_package_sha256="a79ac04e0e81ddd4fb8a85ec679a08572b889c4553ec2552c3d0b646b950e9d4"
installer_url="https://uk.download.nvidia.com/Windows/${driver_version}/${driver_version}-desktop-win10-win11-64bit-international-dch-whql.exe"

work_root="$(mktemp -d /tmp/renderboost-eevee-wsl-d3d12-package.XXXXXX)"
cleanup() {
  rm -rf "$work_root"
}
trap cleanup EXIT

mkdir -p "$output_root"

download_checked() {
  local url="$1"
  local destination="$2"
  local expected_sha256="$3"
  curl -fL --retry 8 --retry-all-errors --retry-delay 3 "$url" -o "$destination"
  printf '%s  %s\n' "$expected_sha256" "$destination" | sha256sum -c -
}

download_checked "$d3d12_url" "$work_root/d3d12.nupkg" "$d3d12_package_sha256"
download_checked "$dxcore_url" "$work_root/dxcore.nupkg" "$dxcore_package_sha256"
curl -fL --retry 8 --retry-all-errors --retry-delay 3 "$installer_url" -o "$work_root/nvidia.exe"
installer_sha256="$(sha256sum "$work_root/nvidia.exe" | awk '{print $1}')"

mkdir -p "$work_root/extracted"
7z x -y -o"$work_root/extracted" "$work_root/nvidia.exe" \
  Display.Driver/libcuda.so.1.1 \
  Display.Driver/libnvidia-gpucomp.so \
  Display.Driver/libnvwgf2umx.so \
  Display.Driver/license.txt \
  EULA.txt >/dev/null

for required in \
  "$work_root/extracted/Display.Driver/libcuda.so.1.1" \
  "$work_root/extracted/Display.Driver/libnvidia-gpucomp.so" \
  "$work_root/extracted/Display.Driver/libnvwgf2umx.so" \
  "$work_root/extracted/Display.Driver/license.txt" \
  "$work_root/extracted/EULA.txt"; do
  test -s "$required"
done

package_name="renderboost-eevee-wsl-d3d12-runtime-${driver_version}"
stage_root="$work_root/stage/$package_name"
mkdir -p "$stage_root/lib" "$stage_root/driver" "$stage_root/licenses" "$stage_root/provenance"

unzip -p "$work_root/d3d12.nupkg" build/native/lib/x64/libd3d12.so >"$stage_root/lib/libd3d12.so"
unzip -p "$work_root/d3d12.nupkg" build/native/lib/x64/libd3d12core.so >"$stage_root/lib/libd3d12core.so"
unzip -p "$work_root/dxcore.nupkg" build/native/lib/libDXCore.so >"$stage_root/lib/libdxcore.so"
printf '%s  %s\n' "b3d78d409a4dbbe8612551fc0c0d746d3e58d7997ee7eba78ce1064d77cfa8c3" "$stage_root/lib/libd3d12.so" | sha256sum -c -
printf '%s  %s\n' "a4104a2022932d8e6c714f103ebd89db1c5bdbf36fe92151c88d3d93d4e3894d" "$stage_root/lib/libd3d12core.so" | sha256sum -c -
printf '%s  %s\n' "83d1671a839bcf71709349e77cd68341515df2e63080765618876996a0f4190c" "$stage_root/lib/libdxcore.so" | sha256sum -c -

cp "$work_root/extracted/Display.Driver/libnvidia-gpucomp.so" "$stage_root/driver/"
cp "$work_root/extracted/Display.Driver/libnvwgf2umx.so" "$stage_root/driver/"
cp "$work_root/extracted/EULA.txt" "$stage_root/licenses/NVIDIA-EULA.txt"
cp "$work_root/extracted/Display.Driver/license.txt" "$stage_root/licenses/NVIDIA-Display.Driver-license.txt"
unzip -p "$work_root/d3d12.nupkg" Microsoft.Direct3D.Linux.nuspec >"$stage_root/provenance/Microsoft.Direct3D.Linux.nuspec"
unzip -p "$work_root/dxcore.nupkg" Microsoft.DXCore.Linux.amd64fre.nuspec >"$stage_root/provenance/Microsoft.DXCore.Linux.amd64fre.nuspec"

host_libcuda_sha256="$(sha256sum "$work_root/extracted/Display.Driver/libcuda.so.1.1" | awk '{print $1}')"

DRIVER_VERSION="$driver_version" \
INSTALLER_URL="$installer_url" \
INSTALLER_SHA256="$installer_sha256" \
HOST_LIBCUDA_SHA256="$host_libcuda_sha256" \
D3D12_VERSION="$d3d12_version" \
D3D12_URL="$d3d12_url" \
D3D12_PACKAGE_SHA256="$d3d12_package_sha256" \
DXCORE_VERSION="$dxcore_version" \
DXCORE_URL="$dxcore_url" \
DXCORE_PACKAGE_SHA256="$dxcore_package_sha256" \
STAGE_ROOT="$stage_root" \
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

root = Path(os.environ["STAGE_ROOT"])
files = {}
for path in sorted(p for p in root.rglob("*") if p.is_file()):
    relative = path.relative_to(root).as_posix()
    files[relative] = {
        "bytes": path.stat().st_size,
        "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
    }

metadata = {
    "schema_version": 1,
    "artifact_kind": "renderboost-eevee-wsl-d3d12-runtime",
    "host_driver_version": os.environ["DRIVER_VERSION"],
    "compatibility_policy": "exact-host-driver-only",
    "host_libcuda_sha256": os.environ["HOST_LIBCUDA_SHA256"],
    "nvidia_installer": {
        "url": os.environ["INSTALLER_URL"],
        "sha256": os.environ["INSTALLER_SHA256"],
    },
    "microsoft_direct3d_linux": {
        "version": os.environ["D3D12_VERSION"],
        "url": os.environ["D3D12_URL"],
        "package_sha256": os.environ["D3D12_PACKAGE_SHA256"],
    },
    "microsoft_dxcore_linux": {
        "version": os.environ["DXCORE_VERSION"],
        "url": os.environ["DXCORE_URL"],
        "package_sha256": os.environ["DXCORE_PACKAGE_SHA256"],
    },
    "layout": {
        "lib": "Add this directory to the front of LD_LIBRARY_PATH.",
        "driver/libnvidia-gpucomp.so": "Install as /usr/lib/wsl/lib/libnvidia-gpucomp.so; NVIDIA's WSL loader does not discover it from LD_LIBRARY_PATH alone.",
        "driver/libnvwgf2umx.so": "Copy beside the mounted host libcuda.so.1.1 in the matching /usr/lib/wsl/drivers directory.",
    },
    "files": files,
}
(root / "METADATA.json").write_text(json.dumps(metadata, indent=2, sort_keys=True) + "\n")
PY

(
  cd "$stage_root"
  find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum >SHA256SUMS
  sha256sum -c SHA256SUMS
)

archive="$output_root/${package_name}.tar.xz"
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -C "$work_root/stage" -cf - "$package_name" | xz -T0 -6 -c >"$archive"
sha256sum "$archive" >"${archive}.sha256"
stat -c '%s' "$archive" >"${archive}.bytes"

mkdir -p "$work_root/verify"
tar -xJf "$archive" -C "$work_root/verify"
(
  cd "$work_root/verify/$package_name"
  sha256sum -c SHA256SUMS
)
printf 'Packaged %s (%s bytes)\n' "$archive" "$(cat "${archive}.bytes")"
