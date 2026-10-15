# EEVEE D3D12 slab allocator fix

`0001-pb-slab-avoid-provider-callbacks-under-lock.patch` fixes the live-confirmed
Mesa 26.2.3 self-deadlock in `pb_slab_manager_create_buffer`:

```
slab manager mutex held -> provider create_buffer -> d3d12_bo_new
 -> d3d12_screen_reclaim_completed -> pb_slab_buffer_destroy
 -> same slab manager mutex
```

Create/map a new slab privately without holding the manager mutex, then publish
it and reserve its first buffer under the mutex. Prefer the new slab so it cannot
be left unused if reclamation or another thread made an older slab partial in
the meantime. If backing allocation fails, recheck the partial list: reclamation
may have freed space there. Detach empty slabs under the mutex and perform
provider unmap/release after unlocking. On buffer-array allocation failure,
unmap the backing buffer before releasing it.

The ordinary nonrecursive mutex and D3D12's completed-BO reclamation remain in
place. This does not disable GPU rendering or suppress allocation failures.

The Docker build pins the [Mesa 26.2.3 source release](https://docs.mesa3d.org/relnotes/26.2.3.html)
with its published SHA-512 and the exact original C file with SHA-256. It verifies
the patch hash, applies it with zero fuzz, builds only Gallium D3D12, EGL and GBM,
and installs into `/opt/renderboost/mesa`. DirectX-Headers is pinned to commit
`9e393d6d8a3b30dcc6f2806ef604ec16a27b0d7e` (v1.619.1). The installed metadata
records source/patch identity and every private shared library's size/hash.
The EGL manifest selects the private library by absolute path. There is no
global loader-path change and no runtime Mesa download/build/update checker.

The application-side readiness validator and child environment live in the
adjacent RenderBoost repository. Ship a rebuilt worker image before the updated
worker bundle: that bundle rejects D3D12 readiness on an unpatched image. A
missing/corrupt private library must not fall back to the affected system Mesa.

Run the deterministic native regression locally:

```sh
python3 -m unittest discover -s tests -p 'test_mesa_*.py' -v
```

It compiles the actual pinned upstream allocator C file, both stock and patched,
against small utility/provider test doubles. The stock file must reproduce
same-manager lock re-entry (error-checking test mutex exits 86 instead of
hanging). The patched file must complete re-entrant allocation/destruction,
allocation failure with reclaimed space, OOM cleanup and concurrent publication.
Linux runs AddressSanitizer and UndefinedBehaviorSanitizer; macOS runs UBSan
because the local Apple ASan runtime hangs during startup. This checks allocator
behavior, not Mesa's full ABI or GPU driver correctness. The Docker build also
runs the regression before compiling the full Mesa source.

The fixture `tests/mesa/upstream/pb_bufmgr_slab.c` is unmodified upstream Mesa
26.2.3 from `src/gallium/auxiliary/pipebuffer/pb_bufmgr_slab.c`, SHA-256
`5e898404ad499f194de0199e9c3959a80aa8c65dba5da5b027ea747f33fe4386`.
Its VMware permission notice is preserved in the file.

Before fleet deployment, build `Dockerfile` for `linux/amd64`, then use a WSL
NVIDIA GPU canary to verify loaded graphics libraries are from the private
prefix, render the affected project frames repeatedly and confirm completed BOs
are still reclaimed. Follow with a Cycles frame on the same worker. Local tests
on the development Mac do not establish those GPU results.
