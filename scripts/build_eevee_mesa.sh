#!/usr/bin/env bash
# Run only during the worker image build. Never compile/update Mesa at readiness.
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mesa_version=26.2.3
source_sha512=ec621735ae4679762ea27b979a5314c7aecfdd4165afea19c8c55f933d79b40f01fa041a95874fc4347e732ac565786d9b616a9aa8856a422204d9ecc9a12ec4
patch_sha256=231a15c097a239c2ad85f573d8abf17aa87e2aa5aa892eb4b0f063a5dbfe272e
source_file_sha256=5e898404ad499f194de0199e9c3959a80aa8c65dba5da5b027ea747f33fe4386
prefix=/opt/renderboost/mesa
patch_file="$repo_dir/patches/mesa/0001-pb-slab-avoid-provider-callbacks-under-lock.patch"
work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
curl --fail --location --retry 3 --connect-timeout 20 --max-time 900 \
    "https://archive.mesa3d.org/mesa-${mesa_version}.tar.xz" -o "$work_dir/mesa.tar.xz"
printf '%s  %s\n' "$source_sha512" "$work_dir/mesa.tar.xz" | sha512sum -c -
printf '%s  %s\n' "$patch_sha256" "$patch_file" | sha256sum -c -
tar -xJf "$work_dir/mesa.tar.xz" -C "$work_dir"
mesa_dir="$work_dir/mesa-${mesa_version}"
printf '%s  %s\n' "$source_file_sha256" "$mesa_dir/src/gallium/auxiliary/pipebuffer/pb_bufmgr_slab.c" | sha256sum -c -
patch --batch --fuzz=0 -d "$mesa_dir" -p1 -i "$patch_file"

# Mesa's wrap names a tag. Pin the exact DirectX-Headers commit as well and
# disable all implicit Meson downloads after checking it out.
headers_dir="$mesa_dir/subprojects/DirectX-Headers-1.0"
git init "$headers_dir"
git -C "$headers_dir" remote add origin https://github.com/microsoft/DirectX-Headers.git
git -C "$headers_dir" fetch --depth=1 origin 9e393d6d8a3b30dcc6f2806ef604ec16a27b0d7e
git -C "$headers_dir" checkout --detach FETCH_HEAD
test "$(git -C "$headers_dir" rev-parse HEAD)" = 9e393d6d8a3b30dcc6f2806ef604ec16a27b0d7e

meson setup "$work_dir/build" "$mesa_dir" \
    --prefix="$prefix" --libdir=lib --buildtype=release --wrap-mode=nodownload \
    -Dgallium-drivers=d3d12 -Dvulkan-drivers=[] -Dplatforms=[] \
    -Degl-native-platform=surfaceless -Degl=enabled -Dgbm=enabled \
    -Dglvnd=enabled -Dglx=disabled -Dllvm=disabled \
    -Dgallium-d3d12-video=disabled -Dgallium-va=disabled \
    -Dbuild-tests=false -Dtools=[]
meson compile -C "$work_dir/build" -j "${MESA_BUILD_JOBS:-4}"
meson install -C "$work_dir/build" --tags runtime

# The GLVND manifest names an absolute private library. No ldconfig/global
# LD_LIBRARY_PATH change is needed; only D3D12 render children use this tree.
python3 "$repo_dir/scripts/write_eevee_mesa_manifest.py" "$prefix" "$source_sha512" "$patch_sha256"
for library in "$prefix"/lib/*.so*; do
    if LD_LIBRARY_PATH="$prefix/lib" ldd "$library" | grep -q 'not found'; then
        echo "Unresolved Mesa runtime dependency: $library" >&2
        exit 1
    fi
done
