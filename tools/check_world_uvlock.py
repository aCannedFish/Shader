#!/usr/bin/env python3
"""Compare UV lock, cropped rectangles and cardinal geometry with engine APIs."""
import hashlib
import json
from pathlib import Path
import subprocess

import numpy as np
from preview.minecraft import classpath, load_version
from world_assets import rotation
from world_surfaces import CORNERS, face_uv, locked_uv

ROOT = Path(__file__).resolve().parents[1]


def main():
    folder = ROOT/'local-docs/migration/registry/uvlock-v2'
    folder.mkdir(parents=True,exist_ok=True)
    instance = Path.home()/'minecraft/versions/1.21.11-Forge-OptiFine'
    cp = classpath(instance.parent.parent,load_version(instance))
    jdk = Path(subprocess.check_output(['/usr/libexec/java_home','-v','25'],text=True).strip())/'bin'
    source = ROOT/'tools/metadata/ExportUvLock.java'
    subprocess.run([str(jdk/'javac'),'--release','21','-proc:none','-cp',cp,'-d',str(folder),str(source)],check=True)
    with (folder/'export.log').open('w') as log:
        subprocess.run([str(jdk/'java'),'-Djava.awt.headless=true','-cp',str(folder)+':'+cp,
                        'local.simpleshader.metadata.ExportUvLock',str(folder/'transforms.json')],
                       cwd=folder,stdout=log,stderr=subprocess.STDOUT,check=True)
    rows = json.loads((folder/'transforms.json').read_text())
    corners = np.array(((0,0),(0,1),(1,1),(1,0)),float)
    samples = np.r_[corners,[[.2,.7],[.8,.3]]]
    failures = []
    cases = 0
    rectangles = ((0,0,1,1),(.125,.5,.75,1),(.75,.875,.25,.125),(-.25,.25,1.25,.75))
    for row in rows:
        transform = rotation(1,-row['y']) @ rotation(0,-row['x'])
        geometry = (np.array(CORNERS[row['face']],float)-.5) @ transform.T + .5
        reference_matrix = np.linalg.solve(np.column_stack((corners[:3],np.ones(3))),np.array(row['uv'])[:3])
        error = float(np.max(abs(locked_uv(samples,row['face'],transform)-row['uv'])))
        error = max(error,float(np.max(abs(geometry-row['positions']))))
        for rectangle in rectangles:
            for angle in (0,90,180,270):
                uv = face_uv(rectangle,angle)
                expected = np.column_stack((uv,np.ones(4))) @ reference_matrix
                error = max(error,float(np.max(abs(locked_uv(uv,row['face'],transform)-expected))))
                cases += 1
        if error>1e-6:
            failures.append({'x':row['x'],'y':row['y'],'face':row['face'],'error':error})
    report = {'passed':not failures,'engine_transforms':len(rows),'cropped_rectangle_cases':cases,
              'failures':failures,'source_sha256':hashlib.sha256(source.read_bytes()).hexdigest(),
              'scope':'Immutable engine UV lock; exact coordinate transforms rather than corner permutation'}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    if not report['passed']:
        raise SystemExit(1)


if __name__=='__main__':
    main()
