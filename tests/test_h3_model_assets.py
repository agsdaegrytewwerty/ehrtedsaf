import hashlib
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('model_assets', Path(__file__).resolve().parents[1] / 'h3/model_assets.py')
assets = importlib.util.module_from_spec(spec)
spec.loader.exec_module(assets)


class H3ModelAssetsTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.parts = Path(self.root.name) / 'parts'
        self.models = Path(self.root.name) / 'models'
        self.data = b'0123456789abcdef'
        self.plan = {'repo': 'example/model', 'revision': 'a' * 40, 'file': 'model.safetensors', 'folder': 'diffusion_models', 'bytes': len(self.data), 'sha256': hashlib.sha256(self.data).hexdigest()}

    def download(self):
        with patch.object(assets, 'PART_BYTES', 6), patch.object(assets.urllib.request, 'urlopen', return_value=io.BytesIO(self.data)):
            assets.fetch_model(self.plan, self.parts, split=True)

    def test_streaming_chunks_reassemble_byte_exact_and_reuse_verified_output(self):
        self.download()
        plan = json.loads((self.parts / 'parts.json').read_text())
        self.assertEqual([p['bytes'] for p in plan['parts']], [6, 6, 4])
        assets.assemble(self.parts, self.models)
        target = self.models / self.plan['folder'] / self.plan['file']
        self.assertEqual(target.read_bytes(), self.data)
        before = target.stat().st_mtime_ns
        assets.assemble(self.parts, self.models)
        self.assertEqual(target.stat().st_mtime_ns, before)
        target.write_bytes(b'changed')
        assets.assemble(self.parts, self.models)
        self.assertEqual(target.read_bytes(), self.data)

    def test_corrupt_part_keeps_previous_target_and_cleans_partial(self):
        self.download()
        target = self.models / self.plan['folder'] / self.plan['file']
        target.parent.mkdir(parents=True)
        target.write_bytes(b'previous')
        part = self.parts / (self.plan['file'] + '.part01')
        part.write_bytes(b'xxxxxx')
        with self.assertRaisesRegex(RuntimeError, 'Wrong part hash'):
            assets.assemble(self.parts, self.models)
        self.assertEqual(target.read_bytes(), b'previous')
        self.assertFalse(target.with_suffix(target.suffix + '.partial').exists())

    def test_truncated_and_wrong_model_downloads_cannot_write_valid_descriptor(self):
        for data in (self.data[:-1], b'x' * len(self.data), self.data + b'extra'):
            with patch.object(assets, 'PART_BYTES', 6), patch.object(assets.urllib.request, 'urlopen', return_value=io.BytesIO(data)):
                with self.assertRaises(RuntimeError):
                    assets.fetch_model(self.plan, self.parts, split=True)
            self.assertFalse((self.parts / 'parts.json').exists())


if __name__ == '__main__':
    unittest.main()
