"""Load versioned immutable build inputs independently of local capture folders.

These files describe vanilla states and model offsets. They contain no world
positions, chunks, live light sources or runtime helper uploads.
"""
import gzip
import json
from pathlib import Path


INPUTS = Path(__file__).resolve().parent / 'data/minecraft-1.21.11'


def load_input(name, source=None):
    """Allow explicit exports while keeping normal clones self-contained."""
    path = Path(source) if source is not None else INPUTS / (name + '.json.gz')
    if path.suffix == '.gz':
        with gzip.open(path, 'rt', encoding='utf-8') as stream:
            return json.load(stream)
    return json.loads(path.read_text(encoding='utf-8'))
