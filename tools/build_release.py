#!/usr/bin/env python3
"""Build versioned install packages and SHA-256 checksums."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import zipfile

from configuration import configuration, documents

ROOT = Path(__file__).resolve().parents[1]


def archive(path, files):
    """Use stable ordering, permissions and timestamps for deterministic ZIP output."""
    with zipfile.ZipFile(path, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as output:
        for name, data in sorted(files.items()):
            info = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            info.compress_type = zipfile.ZIP_DEFLATED
            info.external_attr = 0o100644 << 16
            output.writestr(info, data)
    with zipfile.ZipFile(path) as output:
        if output.testzip() is not None:
            raise RuntimeError(f'Archive checksum error: {path.name}')


def digest(path):
    """Hash complete artifact bytes for download verification."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def git_state():
    """Record the source revision and dirtiness without bundling local Git metadata."""
    commit = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip()
    changes = subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True)
    return {'commit': commit, 'dirty': bool(changes.strip())}


def build(shader_only=False):
    """Validate source metadata and package only the explicit release file set."""
    data = configuration()
    version = data['version']
    if not re.fullmatch(r'\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?', version):
        raise RuntimeError(f'Invalid release version: {version}')
    for path, expected in documents(data).items():
        if not path.exists() or path.read_text() != expected:
            raise RuntimeError(f'Stale configuration document: {path.name}')
    changelog = (ROOT / 'CHANGELOG.md').read_text()
    release_entry = re.search(r'^## ' + re.escape(version) + r'\s*\n(.*?)(?=^## |\Z)',
                              changelog, re.MULTILINE | re.DOTALL)
    if release_entry is None:
        raise RuntimeError(f'Missing changelog entry for {version}')
    output = ROOT / 'dist/releases' / version
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True)

    shader_files = {
        path.relative_to(ROOT).as_posix(): path.read_bytes()
        for path in sorted((ROOT / 'shaders').rglob('*'))
        if path.is_file() and path.name != '.DS_Store'
    }
    shader_sources = {name: hashlib.sha256(content).hexdigest()
                      for name, content in shader_files.items()}
    for name in ('LICENSE', 'THIRD_PARTY.md', 'VERSION'):
        shader_files[name] = (ROOT / name).read_bytes()
    shader_files['README.md'] = (
        f'# SimpleShader {version}\n\n'
        'Place this ZIP in the active Minecraft instance shaderpacks directory.\n'
        'Select SimpleShader in the OptiFine shader menu.\n\n'
        'Verified: Minecraft 1.21.11, OptiFine HD U J9, Forge 61.0.8.\n'
        f'Optional local shadows and GI: SimpleShaderLighting-{version}.jar in mods/.\n'
        'Restart Minecraft after installing or replacing the companion Mod.\n\n'
        f'Full configuration: https://github.com/aCannedFish/Shader/blob/v{version}/docs/configuration.md\n'
    ).encode()
    shader_zip = output / f'SimpleShader-{version}.zip'
    archive(shader_zip, shader_files)

    assets = [shader_zip]
    if not shader_only:
        source = ROOT / f'dist/SimpleShaderLighting-{version}.jar'
        if not source.exists():
            raise RuntimeError('Build the companion first, or use --shader-only')
        with zipfile.ZipFile(source) as jar:
            metadata = jar.read('META-INF/mods.toml').decode()
            if f'version="{version}"' not in metadata:
                raise RuntimeError('Companion JAR version does not match VERSION')
            if jar.testzip() is not None:
                raise RuntimeError('Companion JAR checksum error')
        companion = output / source.name
        shutil.copy2(source, companion)
        assets.append(companion)

    manifest = output / 'manifest.json'
    manifest.write_text(json.dumps({
        'project': 'SimpleShader', 'version': version, 'source': git_state(),
        'verified_runtime': {'minecraft': '1.21.11', 'forge': '61.0.8', 'optifine': 'HD_U_J9',
                             'platform': 'Apple Silicon macOS', 'opengl': '4.1'},
        'companion_included': not shader_only,
        'option_count': sum(len(page['options']) for page in data['pages']),
        'files': {path.name: {'sha256': digest(path), 'bytes': path.stat().st_size} for path in assets},
        'shader_sources': shader_sources,
    }, ensure_ascii=False, indent=2) + '\n')
    assets.append(manifest)
    (output / 'SHA256SUMS.txt').write_text(''.join(
        f'{digest(path)}  {path.name}\n' for path in sorted(assets)
    ))
    # GitHub already displays the release title and date; match recent release bodies.
    release_notes = re.sub(r'^发布日期：[^\n]*\n\s*', '', release_entry[1].strip(), count=1)
    (output / 'RELEASE.md').write_text(
        release_notes + '\n\n'
        '已验证组合：Minecraft 1.21.11、OptiFine HD U J9、Forge 61.0.8；'
        '实际平台为 Apple M3 / macOS / OpenGL 4.1。其他平台与加载器尚未专项验证。\n\n'
        f'- 光影：`SimpleShader-{version}.zip`，放入当前实例 `shaderpacks/`。\n'
        f'- 可选 Mod：`SimpleShaderLighting-{version}.jar`，放入同一实例 `mods/` 并重启游戏。\n'
        '- 校验：`SHA256SUMS.txt`；`manifest.json` 记录版本、源码提交及发布文件哈希。\n\n'
        f'[安装说明](https://github.com/aCannedFish/Shader/blob/v{version}/docs/installation.md)、'
        f'[配置说明](https://github.com/aCannedFish/Shader/blob/v{version}/docs/configuration.md)、'
        f'[实现说明](https://github.com/aCannedFish/Shader/blob/v{version}/docs/architecture.md)。\n'
    )
    print(f'Built SimpleShader {version}: {output}')
    for path in sorted(assets):
        print(f'  {path.name}: {path.stat().st_size:,} bytes')
    return output


def main():
    """Build a complete release or a standalone Shader package."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--shader-only', action='store_true')
    arguments = parser.parse_args()
    build(arguments.shader_only)


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, ValueError, FileNotFoundError) as error:
        print(f'Release build failed: {error}', file=sys.stderr)
        raise SystemExit(1)
