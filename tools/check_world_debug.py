#!/usr/bin/env python3
"""Compare native debug pixels with GPU records and verify visible epoch bits."""
import json
from pathlib import Path

import numpy as np
from PIL import Image
from check_world_capture import decode_int

ROOT = Path(__file__).resolve().parents[1]


def main():
    folder = ROOT / 'local-docs/migration/runs/P03-world-unload-debug'
    screenshots = folder / 'screenshots'
    layout = json.loads((folder / 'world-layout.json').read_text())
    reports = {}
    for metadata in sorted(screenshots.glob('*-world.json')):
        name = metadata.name.removesuffix('-world.json')
        info = json.loads(metadata.read_text())
        header = np.fromfile(screenshots/(name+'-header.raw'),'<f4').reshape(-1,4)
        epoch = decode_int(header[8]) & 0xffffffff
        picture = np.asarray(Image.open(screenshots/(name+'.png')).convert('RGB'))
        height,width = picture.shape[:2]
        for bit in range(32):
            observed = picture[5,int((bit+.5)*width/32),0] > 180
            assert observed == bool((epoch >> bit) & 1), (name,bit,epoch)
        expected = np.empty_like(picture)
        yscreen,xscreen = np.mgrid[:height,:width]
        uvx = (xscreen+.5)/width
        uvz = 1-(yscreen+.5)/height
        for near in (True,False):
            key = 'near' if near else 'far'
            region = layout['persistent']['regions'][key+'_optics']
            optics = np.fromfile(screenshots/(name+'-'+key+'_optics.raw'),'<f4').reshape(region['height'],region['width'],4)
            shape = layout[key+'_shape']
            origin = [decode_int(header[index]) for index in (range(2,5) if near else range(5,8))]
            rate = 2 if near else 1
            cy = int(np.floor((info['actual_camera_readback_only'][1]-6)*rate))-origin[1]
            mask = uvx<.5 if near else uvx>=.5
            if not 0<=cy<shape[1]:
                expected[mask] = (204,0,0)
                continue
            cx = (np.mod(uvx*2,1)*shape[0]).astype(int)
            cz = (uvz*shape[2]).astype(int)
            pixelx = cx + (cz%8)*shape[0]
            pixely = cy + (cz//8)*shape[1]
            data = optics[pixely,pixelx]
            colours = np.empty_like(picture)
            colours[:] = (20,64,46)
            colours[data[...,3]<.5] = (51,9,69)
            colours[data[...,2]>=8] = (255,140,10)
            expected[mask] = colours[mask]
        body = uvz<=.97
        errors = body & np.any(abs(picture.astype(int)-expected.astype(int))>2,axis=-1)
        assert not np.any(errors), (name,int(errors.sum()))
        reports[name] = {'epoch':epoch,'checked_body_pixels':int(body.sum()),'pixel_errors':0,
                         'epoch_bits_verified':32}
    flashes = {}
    for filename in sorted(screenshots.glob('diagnostic-*-change.png')):
        picture = np.asarray(Image.open(filename).convert('RGB'))
        orange = (picture[...,0]>250)&(picture[...,1]>130)&(picture[...,1]<150)&(picture[...,2]<20)
        orange[:int(picture.shape[0]*.04)] = False
        assert np.count_nonzero(orange)>0
        flashes[filename.name] = int(orange.sum())
    assert len(reports)==4 and len(flashes)>=2
    report = {'passed':True,'views':reports,'changed_region_pixels':flashes,
              'scope':'Native mode 3 verifies knowledge, edits and exact generation bits; mode 1/2/4 share the same lookup'}
    (folder/'debug-verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print('Native debug colour/knowledge, change flashes and 128 epoch bits passed')


if __name__=='__main__':
    main()
