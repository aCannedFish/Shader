#!/usr/bin/env python3
"""Validate native edit publication, origin changes, mesh/chunk unload and return."""
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]


def archive(run):
    source = ROOT / '.preview' / ('game-' + run)
    target = ROOT / 'local-docs/migration/runs' / ('P03-' + run)
    screenshots = target / 'screenshots'
    screenshots.mkdir(parents=True, exist_ok=True)
    for file in (source / 'screenshots').iterdir():
        if file.suffix in ('.json','.png') or file.name.endswith(('-header.raw','-near_optics.raw','-far_optics.raw')):
            shutil.copy2(file, screenshots / file.name)
    for name in ('capture.log','isolation.json'):
        shutil.copy2(ROOT / '.preview' / ('captures-' + run) / name, target / name)
    pack = source / 'shaderpacks/SimpleShader/shaders'
    shutil.copy2(pack / 'world-layout.json', target / 'world-layout.json')
    return screenshots,target


def main():
    first,folder = archive('world-edits')
    second,unload_folder = archive('world-unload-debug')
    reports = {}
    for name,desired in (('migration_edit_add',True),('migration_edit_remove',False)):
        samples = json.loads((first / (name+'-publication.json')).read_text())
        client = next(row for row in samples if row['client_gold']==desired)
        raw = next(row for row in samples if row['client_gold']==desired and row['raw_gold']==desired and row['covered'])
        published = next(row for row in samples if row['client_gold']==desired and row['published_gold']==desired and row['covered'])
        assert published['native_frame']-raw['native_frame'] <= 1
        assert any(row['changed'] for row in samples)
        assert all(row['published_gold']==desired for row in samples if row['native_frame']>=published['native_frame'])
        reports[name] = {'client_update_ms':client['since_commit_ms'],'geometry_available_ms':raw['since_commit_ms'],
                         'published_ms':published['since_commit_ms'],
                         'geometry_to_publication_frames':published['native_frame']-raw['native_frame']}
    rows = json.loads((first/'migration_edit_shift-publication.json').read_text())
    assert len({row['epoch'] for row in rows})==1
    assert not any(row['published_gold'] for row in rows)
    reports['ordinary_origin_shift'] = {'epoch_preserved':True,'no_removed_block_ghost':True}
    cases = {name:json.loads((second/('migration_edit_'+name+'-publication.json')).read_text())
             for name in ('hold','far','unload_kept','return_kept')}
    far = cases['far']
    assert far[-1]['far_covered'] and not far[-1]['mesh_available']
    assert not far[-1]['far_raw_gold'] and not far[-1]['far_published_gold']
    disappearance = next(row for row in far if not row['far_raw_gold'])
    cleared = next(row for row in far if not row['far_published_gold'])
    assert cleared['native_frame']-disappearance['native_frame']<=1
    assert not cases['unload_kept'][-1]['client_chunk_loaded']
    returned = cases['return_kept']
    assert returned[-1]['client_chunk_loaded'] and returned[-1]['mesh_available'] and returned[-1]['published_gold']
    assert cases['hold'][-1]['epoch'] < far[-1]['epoch'] < cases['unload_kept'][-1]['epoch'] < returned[-1]['epoch']
    reports['unload_and_return'] = {'in_range_mesh_unload_clears_record':True,
        'client_chunk_unload_verified':True,'return_recaptures_retained_gold':True,
        'clear_after_raw_disappearance_frames':cleared['native_frame']-disappearance['native_frame'],
        'epochs':[cases[key][-1]['epoch'] for key in ('hold','far','unload_kept','return_kept')]}
    report = {'passed':True,'results':reports,
              'scope':'World geometry publication only. Local-light shadows and GI are not migrated or timed here.',
              'timing_samples':2,'p95_claimed':False}
    (folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    (unload_folder/'verification.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))


if __name__=='__main__':
    main()
