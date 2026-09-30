#!/usr/bin/env python3
"""Build a deterministic, bounded effect pack from the project's local assets.

Format: RMPACK01, little-endian uint32 manifest size, UTF-8 JSON, zlib payloads.
Paths, sizes, offsets and SHA-256 hashes are recorded per file. No download step.
"""
import argparse
import hashlib
import json
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[2]


def build(output: Path):
    entries, chunks, offset = [], [], 0
    roots = [(ROOT / 'Effects', 'Shaders'), (ROOT / 'Presets', 'Presets')]
    for root, prefix in roots:
        for path in sorted(root.rglob('*')):
            if not path.is_file() or path.name.startswith('.') or path.is_symlink():
                continue
            raw = path.read_bytes()
            if len(raw) > 32 * 1024 * 1024:
                raise ValueError(f'File exceeds pack limit: {path}')
            compressed = zlib.compress(raw, 9)
            relative = path.relative_to(root).as_posix()
            # Textures must be a sibling of Shaders for the runtime's resolver.
            name = relative if prefix == 'Shaders' and relative.startswith('Textures/') else f'{prefix}/{relative}'
            entries.append(dict(path=name, offset=offset, length=len(compressed), size=len(raw),
                                sha256=hashlib.sha256(raw).hexdigest()))
            chunks.append(compressed)
            offset += len(compressed)
    if not entries or len(entries) > 4096:
        raise ValueError('Unexpected effect pack file count')
    manifest = dict(schema=1, name='RoMacShade effect library', files=entries,
                    attribution='Third-party shaders and presets retain their authors and embedded notices.')
    encoded = json.dumps(manifest, sort_keys=True, separators=(',', ':')).encode()
    data = b'RMPACK01' + struct.pack('<I', len(encoded)) + encoded + b''.join(chunks)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_bytes(data)
    # A human-readable index accompanies release assets, rather than fetching
    # third-party download indexes at runtime.
    output.with_suffix('.json').write_text(json.dumps(manifest, indent=2) + '\n')
    output.with_name('RMPackConfig.h').write_text(
        '#pragma once\n#define RM_PACK_SHA256 @"' + hashlib.sha256(data).hexdigest() + '"\n'
        '#define RM_EFFECT_REPOSITORY @"https://github.com/hesm4tt/RoMacShade-Effects"\n'
        '#define RM_EFFECT_PACK_URL RM_EFFECT_REPOSITORY @"/releases/download/ios-effects-v1/RoMacShade-effects.rmpack"\n')
    print(f'Packed {len(entries)} files, {len(data):,} bytes -> {output}')


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    build(parser.parse_args().output)
