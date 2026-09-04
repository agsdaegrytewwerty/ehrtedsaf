#!/usr/bin/env bash
set -euo pipefail

usage() {
  printf 'Usage: %s WINDOWS_DRIVER_VERSION DESTINATION HOST_LIBCUDA_SO\n' "$0" >&2
  exit 2
}

[[ $# -eq 3 ]] || usage
driver_version="$1"
destination="$2"
host_libcuda="$3"

[[ "$driver_version" =~ ^[0-9]{3}\.[0-9]{2}$ ]] || {
  printf 'Invalid Windows NVIDIA driver version: %s\n' "$driver_version" >&2
  exit 2
}
[[ -s "$host_libcuda" ]] || {
  printf 'Mounted host libcuda is missing: %s\n' "$host_libcuda" >&2
  exit 2
}

for command_name in curl unzip 7z sha256sum install mktemp; do
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

temp_root="$(mktemp -d /tmp/renderboost-eevee-wsl-d3d12-fallback.XXXXXX)"
cleanup() {
  rm -rf "$temp_root"
}
trap cleanup EXIT

download_checked() {
  local url="$1"
  local output="$2"
  local sha256="$3"
  curl -fL --retry 8 --retry-all-errors --retry-delay 3 "$url" -o "$output"
  printf '%s  %s\n' "$sha256" "$output" | sha256sum -c -
}

download_checked "$d3d12_url" "$temp_root/d3d12.nupkg" "$d3d12_package_sha256"
download_checked "$dxcore_url" "$temp_root/dxcore.nupkg" "$dxcore_package_sha256"
curl -fL --retry 8 --retry-all-errors --retry-delay 3 "$installer_url" -o "$temp_root/nvidia.exe"

mkdir -p "$temp_root/extracted"
7z x -y -o"$temp_root/extracted" "$temp_root/nvidia.exe" \
  Display.Driver/libcuda.so.1.1 \
  Display.Driver/libnvidia-gpucomp.so \
  Display.Driver/libnvwgf2umx.so \
  Display.Driver/license.txt \
  EULA.txt >/dev/null

packaged_libcuda="$temp_root/extracted/Display.Driver/libcuda.so.1.1"
[[ -s "$packaged_libcuda" ]] || {
  printf 'Official driver package did not contain the expected WSL libraries.\n' >&2
  exit 1
}
host_sha256="$(sha256sum "$host_libcuda" | awk '{print $1}')"
package_sha256="$(sha256sum "$packaged_libcuda" | awk '{print $1}')"
[[ "$host_sha256" == "$package_sha256" ]] || {
  printf 'Exact-driver safety check failed: mounted and downloaded libcuda hashes differ.\n' >&2
  exit 1
}

mkdir -p "$destination/lib" "$destination/driver" "$destination/licenses" "$destination/provenance"
unzip -p "$temp_root/d3d12.nupkg" build/native/lib/x64/libd3d12.so >"$destination/lib/libd3d12.so"
unzip -p "$temp_root/d3d12.nupkg" build/native/lib/x64/libd3d12core.so >"$destination/lib/libd3d12core.so"
unzip -p "$temp_root/dxcore.nupkg" build/native/lib/libDXCore.so >"$destination/lib/libdxcore.so"
install -m 0644 "$temp_root/extracted/Display.Driver/libnvidia-gpucomp.so" "$destination/driver/libnvidia-gpucomp.so"
install -m 0644 "$temp_root/extracted/Display.Driver/libnvwgf2umx.so" "$destination/driver/libnvwgf2umx.so"
install -m 0644 "$temp_root/extracted/EULA.txt" "$destination/licenses/NVIDIA-EULA.txt"
install -m 0644 "$temp_root/extracted/Display.Driver/license.txt" "$destination/licenses/NVIDIA-Display.Driver-license.txt"
unzip -p "$temp_root/d3d12.nupkg" Microsoft.Direct3D.Linux.nuspec >"$destination/provenance/Microsoft.Direct3D.Linux.nuspec"
unzip -p "$temp_root/dxcore.nupkg" Microsoft.DXCore.Linux.amd64fre.nuspec >"$destination/provenance/Microsoft.DXCore.Linux.amd64fre.nuspec"

printf '%s  %s\n' "b3d78d409a4dbbe8612551fc0c0d746d3e58d7997ee7eba78ce1064d77cfa8c3" "$destination/lib/libd3d12.so" | sha256sum -c -
printf '%s  %s\n' "a4104a2022932d8e6c714f103ebd89db1c5bdbf36fe92151c88d3d93d4e3894d" "$destination/lib/libd3d12core.so" | sha256sum -c -
printf '%s  %s\n' "83d1671a839bcf71709349e77cd68341515df2e63080765618876996a0f4190c" "$destination/lib/libdxcore.so" | sha256sum -c -

printf 'Prepared exact EEVEE WSL/D3D12 runtime for Windows NVIDIA driver %s at %s\n' "$driver_version" "$destination"
printf 'Install driver/libnvidia-gpucomp.so as /usr/lib/wsl/lib/libnvidia-gpucomp.so.\n'
printf 'Copy driver/libnvwgf2umx.so beside the mounted host libcuda.so.1.1 before starting Blender.\n'
