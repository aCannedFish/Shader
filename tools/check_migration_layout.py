#!/usr/bin/env python3
"""Validate atlas boundaries/precision and optionally allocate every preset on GPU."""
import argparse
import itertools
import json
from pathlib import Path
import subprocess

from migration_layout import build, emit_glsl

ROOT = Path(__file__).resolve().parents[1]


def validate(atlas):
    boxes = [region['allocation'] for region in atlas['regions'].values()]
    for x,y,w,h in boxes:
        assert x >= 0 and y >= 0 and x+w <= atlas['width'] and y+h <= atlas['height']
    for a,b in itertools.combinations(boxes,2):
        ax,ay,aw,ah = a
        bx,by,bw,bh = b
        assert ax+aw <= bx or bx+bw <= ax or ay+ah <= by or by+bh <= ay, (a,b)


def diagram(atlas, filename):
    """A source SVG preserves exact layout coordinates without bitmap editing."""
    w,h=atlas['width'],atlas['height']
    lines=[f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}">',
           f'<rect width="{w}" height="{h}" fill="#101722"/>']
    for index,(name,r) in enumerate(atlas['regions'].items()):
        colour=f'hsl({index*137%360},45%,40%)'
        lines.append(f'<rect x="{r["x"]}" y="{r["y"]}" width="{r["width"]}" height="{r["height"]}" fill="{colour}" stroke="white" stroke-width="2"><title>{name}: {r["purpose"]}</title></rect>')
        if r['height']>32:
            lines.append(f'<text x="{r["x"]+8}" y="{r["y"]+24}" font-size="20" fill="white">{name}</text>')
    filename.write_text('\n'.join(lines+['</svg>']))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--allocate',action='store_true')
    args=parser.parse_args()
    folder=ROOT/'local-docs/migration/layout'
    folder.mkdir(parents=True,exist_ok=True)
    results={}
    for width,height in [(1280,720),(1920,1080),(3840,2160)]:
        for preset in ('LOW','MEDIUM','HIGH','ULTRA'):
            data=build(preset,width,height)
            validate(data['capture'])
            validate(data['persistent'])
            key=f'{preset}-{width}x{height}'
            results[key]={'layout_valid':True,'bytes':data['allocated_bytes'],
                          'persistent_size':[data['persistent']['width'],data['persistent']['height']]}
            if width==1920:
                file=folder/preset.lower()
                header=emit_glsl(data)
                file.with_suffix('.glsl').write_text(header)
                fragment=file.with_suffix('.frag')
                fragment.write_text('#version 330 core\n'+header+'\nuniform sampler2D worldData;out vec4 result;void main(){ivec2 p=worldVoxelAddress(ivec3(0),WORLD_NEAR_SHAPE,0,0);result=texelFetch(worldData,worldAtlasPixel(WORLD_REGION_NEAR_MATERIAL,p),0); }\n')
                subprocess.run(['glslangValidator','-S','frag',str(fragment)],check=True,capture_output=True)
                file.with_suffix('.json').write_text(json.dumps(data,ensure_ascii=False,indent=2)+'\n')
                file.with_suffix('.alloc').write_text(''.join(f"{a['name']} {a['width']} {a['height']} {a['format']}\n" for a in data['allocations']))
                diagram(data['persistent'],file.with_suffix('.svg'))
    if args.allocate:
        binary=folder/'allocation-probe'
        subprocess.run(['clang','-O2','-Wno-deprecated-declarations','-framework','OpenGL',
                        str(ROOT/'tools/preview/migration_probe.c'),'-o',str(binary)],check=True)
        for preset in ('LOW','MEDIUM','HIGH','ULTRA'):
            output=subprocess.run([str(binary),'--allocate',str(folder/(preset.lower()+'.alloc'))],
                                  capture_output=True,text=True,timeout=180)
            (folder/(preset.lower()+'-allocation.log')).write_text(output.stdout+output.stderr)
            if output.returncode:
                raise RuntimeError(f'{preset} allocation failed: {output.stderr}')
            actual=json.loads(output.stdout.splitlines()[-1])
            expected=results[f'{preset}-1920x1080']['bytes']
            assert actual['texture_bytes']==expected
            results[f'{preset}-1920x1080']['gpu_allocation']=actual
            print(preset,round(expected/1048576,1),'MiB verified',flush=True)
    (folder/'verification.json').write_text(json.dumps(results,indent=2)+'\n')
    print('12 atlas configurations validated')


if __name__=='__main__':
    main()
