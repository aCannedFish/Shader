#!/usr/bin/env python3
"""Rebuild immutable vanilla state metadata without a game client or companion Mod."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from preview.minecraft import classpath, load_version

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance', type=Path, default=Path.home()/'minecraft/versions/1.21.11-Forge-OptiFine')
    parser.add_argument('--java-home', type=Path)
    parser.add_argument('--output', type=Path, default=ROOT/'local-docs/migration/registry/runtime-v2')
    args = parser.parse_args()
    java_home = args.java_home or Path(subprocess.check_output(['/usr/libexec/java_home','-v','25'],text=True).strip())
    folder = args.output.resolve()
    folder.mkdir(parents=True,exist_ok=True)
    instance = args.instance.expanduser().resolve()
    version = load_version(instance)
    cp = classpath(instance.parent.parent, version)
    client = next(Path(file) for file in cp.split(':') if file.endswith('-client.jar') and '/forge/' in file)
    sources = [ROOT/'tools/metadata'/name for name in ('PrepareRegistryApi.java','ExportBlockDefinitions.java')]
    subprocess.run([str(java_home/'bin/javac'),'--release','21','-proc:none','-cp',cp,'-d',str(folder),*map(str,sources)],check=True)
    overlay = folder/'registry-api.jar'
    patch = subprocess.run([str(java_home/'bin/java'),'-cp',str(folder)+':'+cp,
        'local.simpleshader.metadata.PrepareRegistryApi',str(client),str(overlay)],capture_output=True,text=True,check=True)
    (folder/'bootstrap-access.log').write_text(patch.stdout)
    with (folder/'export.log').open('w') as output:
        subprocess.run([str(java_home/'bin/java'),'-Djava.awt.headless=true','-cp',str(overlay)+':'+str(folder)+':'+cp,
            'local.simpleshader.metadata.ExportBlockDefinitions',str(folder/'vanilla-blocks.json')],stdout=output,stderr=subprocess.STDOUT,timeout=180,check=True,cwd=folder)
    definitions = json.loads((folder/'vanilla-blocks.json').read_text())
    assert all(block['name'].startswith('minecraft:') for block in definitions['blocks'])
    digest = lambda file:hashlib.sha256(file.read_bytes()).hexdigest()
    report = {'passed':True,'minecraft_version':version['id'],'blocks':definitions['block_count'],
              'states':definitions['state_count'],'client_jar_sha256':digest(client),
              'definitions_sha256':digest(folder/'vanilla-blocks.json'),
              'source_sha256':{file.name:digest(file) for file in sources},
              'scope':'Build-time immutable registry definitions; no save/client/GPU and no target runtime JAR'}
    (folder/'provenance.json').write_text(json.dumps(report,indent=2)+'\n')
    print(f"{report['blocks']} blocks, {report['states']} states exported without a running game")


if __name__=='__main__':
    main()
