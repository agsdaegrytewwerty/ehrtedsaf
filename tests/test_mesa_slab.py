"""Native regression: apply the shipping patch to pinned upstream Mesa C."""
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / "tests/mesa/upstream/pb_bufmgr_slab.c"
SOURCE_SHA256 = "5e898404ad499f194de0199e9c3959a80aa8c65dba5da5b027ea747f33fe4386"
PATCH = ROOT / "patches/mesa/0001-pb-slab-avoid-provider-callbacks-under-lock.patch"


class MesaSlabRegression(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="mesa-slab-")
        cls.addClassCleanup(cls.temp.cleanup)
        cls.work = Path(cls.temp.name)
        assert hashlib.sha256(FIXTURE.read_bytes()).hexdigest() == SOURCE_SHA256
        include = cls.work / "include"
        for header in ["util/compiler.h", "util/u_debug.h", "util/u_thread.h",
                       "pipe/p_defines.h", "util/u_memory.h", "util/list.h",
                       "pb_buffer.h", "pb_bufmgr.h"]:
            target = include / header
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('#include "mesa_test_shim.h"\n')
        for variant in ["stock", "patched"]:
            tree = cls.work / variant
            source = tree / "src/gallium/auxiliary/pipebuffer/pb_bufmgr_slab.c"
            source.parent.mkdir(parents=True)
            shutil.copyfile(FIXTURE, source)
            if variant == "patched":
                subprocess.run(["patch", "--batch", "--fuzz=0", "-p1", "-i", str(PATCH)], cwd=tree, check=True)
            subprocess.run([os.environ.get("CC", "cc"), "-std=c11", "-D_XOPEN_SOURCE=700",
                            "-Wall", "-Wextra", "-Wno-unused-parameter", "-Werror", "-pthread",
                            "-g", "-fsanitize=" + ("undefined" if platform.system() == "Darwin" else "address,undefined"),
                            "-fno-omit-frame-pointer",
                            "-I", str(include), "-I", str(ROOT / "tests/mesa/include"),
                            "-I", str(source.parent), str(ROOT / "tests/mesa/slab_regression.c"),
                            "-o", str(tree / "regression")], check=True)

    def run_case(self, variant, case):
        return subprocess.run([str(self.work / variant / "regression"), case],
                              capture_output=True, text=True, timeout=30,
                              env={**os.environ, "UBSAN_OPTIONS": "halt_on_error=1",
                                   # Stock deliberately exits mid-allocation at the self-lock.
                                   "ASAN_OPTIONS": "detect_leaks=" + ("0" if variant == "stock" else "1")})

    def test_stock_reproduces_exact_same_manager_reentry(self):
        for case in ["reclaim-create", "reclaim-destroy", "reclaim-oom", "reclaim-empty"]:
            with self.subTest(case=case):
                result = self.run_case("stock", case)
                self.assertEqual(result.returncode, 86, result.stdout + result.stderr)
                self.assertIn("same-manager mutex re-entry", result.stderr)

    def test_patched_allocator_reentry_oom_cleanup_and_concurrent_publication(self):
        for case in ["reclaim-create", "reclaim-destroy", "reclaim-oom", "reclaim-empty", "oom", "concurrent"]:
            with self.subTest(case=case):
                result = self.run_case("patched", case)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertIn("PASS", result.stdout)


if __name__ == "__main__":
    unittest.main()
