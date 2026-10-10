#!/usr/bin/env python3
"""Build the local-light companion against the installed Forge client libraries."""
import argparse
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'tools'))
from preview.minecraft import classpath, load_version


def build(instance=None, java_home=None):
    """Compile sources and package Forge metadata and GPU resources."""
    if instance is None:
        instance = Path.home() / 'minecraft/versions/1.21.11-Forge-OptiFine'
    instance = Path(instance).expanduser().resolve()
    version = load_version(instance)
    cp = classpath(instance.parent.parent, version)
    compiler = str(Path(java_home).expanduser() / 'bin/javac') if java_home else shutil.which('javac')
    if not compiler or not Path(compiler).exists():
        raise RuntimeError('JDK not found; provide --java-home or add javac to PATH')
    release = (ROOT / 'VERSION').read_text().strip()
    metadata = (ROOT / 'companion/src/main/resources/META-INF/mods.toml').read_text()
    if f'version="{release}"' not in metadata:
        raise RuntimeError('Companion metadata version differs from VERSION')
    classes = ROOT / '.preview/companion-classes'
    if classes.exists():
        shutil.rmtree(classes)
    classes.mkdir(parents=True, exist_ok=True)
    sources = sorted((ROOT / 'companion/src/main/java').rglob('*.java'))
    subprocess.run([
        compiler, '--release', '21', '-proc:none', '-cp', cp,
        '-d', str(classes), *map(str, sources),
    ], check=True)
    destination = ROOT / f'dist/SimpleShaderLighting-{release}.jar'
    destination.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(destination, 'w', zipfile.ZIP_DEFLATED) as jar:
        manifest = zipfile.ZipInfo('META-INF/MANIFEST.MF', date_time=(1980, 1, 1, 0, 0, 0))
        manifest.compress_type = zipfile.ZIP_DEFLATED
        manifest.external_attr = 0o100644 << 16
        jar.writestr(manifest,
                     'Manifest-Version: 1.0\nAutomatic-Module-Name: simpleshader.lighting\n'
                     f'Implementation-Version: {release}\n\n')
        for root in (classes, ROOT / 'companion/src/main/resources'):
            for file in sorted(root.rglob('*')):
                if file.is_file() and file.name != '.DS_Store':
                    entry = zipfile.ZipInfo(file.relative_to(root).as_posix(),
                                            date_time=(1980, 1, 1, 0, 0, 0))
                    entry.compress_type = zipfile.ZIP_DEFLATED
                    entry.external_attr = 0o100644 << 16
                    jar.writestr(entry, file.read_bytes())
    print(destination)
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance', type=Path, help='Installed Forge client used for compilation')
    parser.add_argument('--java-home', type=Path, help='JDK directory; defaults to javac in PATH')
    arguments = parser.parse_args()
    try:
        build(arguments.instance, arguments.java_home)
    except subprocess.CalledProcessError:
        raise SystemExit(1)
    except (RuntimeError, FileNotFoundError) as error:
        print(f'Companion build failed: {error}', file=sys.stderr)
        raise SystemExit(1)
