"""Synthetic file input for model unit tests, not a built website collection."""
from pathlib import Path
import tempfile


def model_assets(test_case, guidelines=b"Synthetic guidelines"):
    folder = tempfile.TemporaryDirectory()
    test_case.addCleanup(folder.cleanup)
    assets = Path(folder.name)
    (assets / "MODERATION_GUIDELINES.md").write_bytes(guidelines)
    return assets
