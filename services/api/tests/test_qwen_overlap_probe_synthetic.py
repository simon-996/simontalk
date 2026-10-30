"""Exercise local speech generation without microphone or vendor network I/O."""

import importlib.util
from pathlib import Path


def test_synthetic_pcm_is_bounded_and_leaves_no_audio_files(tmp_path):
    script = Path(__file__).resolve().parents[3] / "scripts" / "qwen_overlap_probe_synthetic.py"
    assert script.is_file(), "Synthetic input helper is missing"
    spec = importlib.util.spec_from_file_location("synthetic_input", script)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    pcm = module.make_synthetic_pcm(parent=tmp_path)
    assert isinstance(pcm, bytes)
    assert 32_000 < len(pcm) <= 320_000 and len(pcm) % 2 == 0
    assert pcm[-64000:] == b"\0" * 64000
    assert any(pcm[:-64000])
    assert list(tmp_path.iterdir()) == []
