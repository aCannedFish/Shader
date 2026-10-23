#!/usr/bin/env python3
"""Export and verify immutable discrete offset profiles without a client or save."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

from preview.minecraft import classpath, load_version

ROOT = Path(__file__).resolve().parents[1]


def load_profiles(states, source=None):
    """Map exact exported values to shader aliases without using world positions."""
    source = source or ROOT/'local-docs/migration/registry/offset-profiles-v2/offsets.json'
    rows = json.loads(source.read_text())
    aliases = {(state['block'],json.dumps(state['properties'],sort_keys=True)):state for state in states}
    profiles = [[[0.0],[0.0],[0.0]]]
    identities = {json.dumps(profiles[0]):0}
    state_profiles = {state['id']:0 for state in states}
    matched = set()
    for row in rows:
        state = aliases[(row['block'],json.dumps(row['properties'],sort_keys=True))]
        axes = [axis['values'] for axis in row['axes']]
        if any(not 1 <= len(values) <= 16 for values in axes) or row['holdout_unknown']:
            raise ValueError('Unverified offset profile: '+row['block'])
        key = json.dumps(axes)
        if key not in identities:
            identities[key] = len(profiles)
            profiles.append(axes)
        state_profiles[state['id']] = identities[key]
        matched.add(state['id'])
    expected = {state['id'] for state in states if state['flags'] & 2048}
    if matched != expected:
        raise ValueError('Offset profiles do not match registry state flags')
    return profiles, state_profiles


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output',type=Path,default=ROOT/'local-docs/migration/registry/offset-profiles-v2')
    parser.add_argument('--instance',type=Path,default=Path.home()/'minecraft/versions/1.21.11-Forge-OptiFine')
    args = parser.parse_args()
    folder = args.output.resolve()
    folder.mkdir(parents=True,exist_ok=True)
    instance = args.instance.expanduser().resolve()
    version = load_version(instance)
    cp = classpath(instance.parent.parent,version)
    jdk = Path(subprocess.check_output(['/usr/libexec/java_home','-v','25'],text=True).strip())/'bin'
    sources = [ROOT/'tools/metadata'/name for name in ('PrepareRegistryApi.java','ExportOffsetProfiles.java')]
    subprocess.run([str(jdk/'javac'),'--release','21','-proc:none','-cp',cp,'-d',str(folder),*map(str,sources)],check=True)
    client = next(file for file in cp.split(':') if file.endswith('-client.jar') and '/forge/' in file)
    overlay = folder/'registry-api.jar'
    with (folder/'bootstrap.log').open('w') as log:
        subprocess.run([str(jdk/'java'),'-cp',str(folder)+':'+cp,'local.simpleshader.metadata.PrepareRegistryApi',
                        client,str(overlay)],check=True,stdout=log,stderr=subprocess.STDOUT,cwd=folder)
    with (folder/'export.log').open('w') as log:
        subprocess.run([str(jdk/'java'),'-Djava.awt.headless=true','-cp',str(overlay)+':'+str(folder)+':'+cp,
                        'local.simpleshader.metadata.ExportOffsetProfiles',str(folder/'offsets.json')],
                       check=True,stdout=log,stderr=subprocess.STDOUT,cwd=folder,timeout=180)
    rows = json.loads((folder/'offsets.json').read_text())
    profiles = {json.dumps(row['axes'],sort_keys=True) for row in rows}
    finite = all(all(abs(value) <= .5 for value in axis['values']) for row in rows for axis in row['axes'])
    unknown = sum(row['holdout_unknown'] for row in rows)
    maximum = max(axis['count'] for row in rows for axis in row['axes'])
    # Clamped profiles are deliberately kept as discrete lookup values; a
    # nonzero affine-grid error is not a failed or silently approximated state.
    report = {'passed':finite and unknown == 0 and maximum <= 16,'states':len(rows),
              'profiles':len(profiles),'maximum_axis_levels':maximum,
              'holdout_samples':sum(row['holdout_samples'] for row in rows),'holdout_unknown':unknown,
              'non_affine_state_axes':sum(axis['affine_grid_error']>1e-7 for row in rows for axis in row['axes']),
              'source_sha256':{file.name:hashlib.sha256(file.read_bytes()).hexdigest() for file in sources},
              'data_sha256':hashlib.sha256((folder/'offsets.json').read_bytes()).hexdigest(),
              'client_jar_sha256':hashlib.sha256(Path(client).read_bytes()).hexdigest(),
              'scope':'Build-time exact value tables and independent synthetic positions; no target runtime JAR or world data'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()
