import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("mesa_manifest", Path(__file__).resolve().parents[1] / "scripts/write_eevee_mesa_manifest.py")
manifest = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manifest)


class MesaManifestTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name).resolve()
        (self.root / "lib").mkdir()
        self.files = ["libEGL_mesa.so.0", "libgallium-26.2.3.so", "libgbm.so.1"]
        for name in self.files:
            (self.root / "lib" / name).write_bytes(b"test " + name.encode())

    def test_manifest_hashes_soname_links_and_selects_absolute_private_egl(self):
        target = self.root / "lib/libgbm.so.1"
        target.rename(target.with_name("libgbm.so.1.0.0"))
        target.symlink_to("libgbm.so.1.0.0")
        manifest.write_manifest(self.root, "a" * 128, "b" * 64)
        data = json.loads((self.root / "METADATA.json").read_text())
        self.assertEqual(data["fix_id"], manifest.FIX_ID)
        self.assertEqual(data["patch_sha256"], "b" * 64)
        for relative, expected in data["files"].items():
            content = (self.root / relative).read_bytes()
            self.assertEqual(expected, {"bytes": len(content), "sha256": hashlib.sha256(content).hexdigest()})
        egl = json.loads((self.root / "share/glvnd/egl_vendor.d/50_mesa.json").read_text())
        self.assertEqual(egl["ICD"]["library_path"], str(self.root / "lib/libEGL_mesa.so.0"))

    def test_missing_or_external_component_cannot_produce_ready_metadata(self):
        target = self.root / "lib/libgallium-26.2.3.so"
        target.unlink()
        with self.assertRaises(ValueError):
            manifest.write_manifest(self.root, "a" * 128, "b" * 64)
        target.symlink_to("/etc/hosts")
        with self.assertRaises(ValueError):
            manifest.write_manifest(self.root, "a" * 128, "b" * 64)
        self.assertFalse((self.root / "METADATA.json").exists())


if __name__ == "__main__":
    unittest.main()
