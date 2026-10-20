#!/usr/bin/env python3
"""Verify unchanged companion meshes and summarize optional native-client measurements."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

from preview.minecraft import classpath, load_version

ROOT = Path(__file__).resolve().parents[1]


def mesh_probe(instance, java_home, jar, output):
    """Compile a package-local probe against the actual production companion JAR."""
    javac = str(java_home / 'bin/javac') if java_home else shutil.which('javac')
    java = str(java_home / 'bin/java') if java_home else shutil.which('java')
    if not java or not javac:
        raise RuntimeError('JDK not found; provide --java-home')
    dependencies = classpath(instance.parent.parent, load_version(instance))
    cp = str(jar) + ':' + dependencies
    classes = output / 'classes'
    classes.mkdir(parents=True, exist_ok=True)
    subprocess.run([javac, '--release', '21', '-proc:none', '-cp', cp, '-d', str(classes),
                    str(ROOT / 'tools/preview/CompanionMeshProbe.java')], check=True)
    result = subprocess.check_output([java, '-cp', str(classes) + ':' + cp,
                                      'local.simpleshader.lighting.CompanionMeshProbe'], text=True)
    return [json.loads(line) for line in result.splitlines()]


def native_comparison(before, after, scenes):
    """Compare equal capped workloads and normalize CPU/allocation by real frames."""
    results = {}
    for scene in scenes:
        baseline = json.loads((before / (scene + '-performance.json')).read_text())
        optimized = json.loads((after / (scene + '-performance.json')).read_text())
        assert baseline['capture_fps_limit'] == optimized['capture_fps_limit'], scene + ': FPS cap changed'
        for sample in (baseline, optimized):
            if sample['capture_fps_limit'] > 30:
                assert sample.get('effective_fps_limit') == sample['capture_fps_limit'], scene + ': active FPS throttle'
                assert sample.get('inactivity_fps_limit') == 'minimized', scene + ': AFK throttle was enabled'
                assert sample.get('throttle_reason') == 'NONE', scene + ': inactive window'
        assert baseline['lights'] == optimized['lights'] == 64, scene + ': light budget changed'
        assert min(baseline['seconds'], optimized['seconds']) >= 15, scene + ': insufficient warm sample'
        assert optimized['refreshChecks'] > 0 and optimized['skippedMeshBuilds'] > 0, scene
        report = {'baseline': baseline, 'optimized': optimized}
        for sample in (baseline, optimized):
            fps = sample['rendered_frames'] / sample['seconds']
            sample['observed_fps'] = fps
            sample['render_thread_allocated_mib_per_frame'] = sample['render_thread_allocated_mib_per_second'] / fps
            sample['render_thread_cpu_ms_per_frame'] = sample['render_thread_cpu_ms_per_second'] / fps
        for metric in ('render_thread_allocated_mib_per_second', 'render_thread_cpu_ms_per_second'):
            report[metric + '_reduction_percent'] = 100 * (1 - optimized[metric] / baseline[metric])
        if 'snapshot_fixture' in baseline or 'snapshot_fixture' in optimized:
            assert baseline.get('snapshot_fixture') == optimized.get('snapshot_fixture'), 'Snapshot fixtures differ'
            for key in ('origin_x', 'origin_y', 'origin_z', 'voxels_crc', 'absorption_crc', 'mesh_crc'):
                assert baseline['snapshot_' + key] == optimized['snapshot_' + key], 'Snapshot differs: ' + key
            assert optimized['snapshot_allocated_bytes'] < baseline['snapshot_allocated_bytes']
            report['snapshot_bytes_equal'] = True
            report['snapshot_allocation_reduction_percent'] = 100 * (
                1 - optimized['snapshot_allocated_bytes'] / baseline['snapshot_allocated_bytes'])
            report['snapshot_cpu_reduction_percent'] = 100 * (
                1 - optimized['snapshot_cpu_ms'] / baseline['snapshot_cpu_ms'])
        results[scene] = report
    # An edit's phase within a periodic sweep differs between processes. Compare
    # the sweep bound, not a lucky near-zero baseline latency. At the 10 FPS cap,
    # the old one-light-per-frame sweep can take 6.4 seconds for 64 lights.
    if 'perf_edits' in results:
        optimized = results['perf_edits']['optimized']
        for key in ('remote_wall_add_ms', 'remote_wall_remove_ms'):
            assert 0 <= optimized[key] <= 7000, key + ': remote update exceeded its sweep bound'
        assert 0 <= optimized['local_light_mapped_ms'] <= 1500, 'Local light response regressed'
    return results


def shader_hashes(folder):
    """Record all shader inputs to prove the optimization did not change visual settings."""
    return {path.relative_to(folder).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in folder.rglob('*') if path.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--instance', type=Path,
                        default=Path.home() / 'minecraft/versions/1.21.11-Forge-OptiFine')
    parser.add_argument('--java-home', type=Path)
    parser.add_argument('--companion-jar', type=Path)
    parser.add_argument('--baseline-dir', type=Path)
    parser.add_argument('--optimized-dir', type=Path)
    parser.add_argument('--baseline-shaders', type=Path)
    parser.add_argument('--scene', action='append', choices=('perf_static', 'perf_walk', 'perf_edits'),
                        help='Explicit native checks; defaults to all three scenes')
    parser.add_argument('--output', type=Path, default=ROOT / '.preview/performance-verification')
    args = parser.parse_args()
    if bool(args.baseline_dir) != bool(args.optimized_dir):
        parser.error('--baseline-dir and --optimized-dir must be provided together')
    version = (ROOT / 'VERSION').read_text().strip()
    jar = (args.companion_jar or ROOT / f'dist/SimpleShaderLighting-{version}.jar').resolve()
    if not jar.is_file():
        raise RuntimeError('Build the companion JAR before running this check')
    args.output.mkdir(parents=True, exist_ok=True)
    report = {'mesh_fixtures': mesh_probe(args.instance.resolve(), args.java_home, jar, args.output),
              'scope': 'Production Java meshes; native snapshots use the reported FPS caps. '
                       'CPU and allocations are also normalized per real frame. '
                       'No GPU timings or long-session stability claim.'}
    if args.baseline_dir:
        scenes = args.scene or ['perf_static', 'perf_walk', 'perf_edits']
        report['native'] = native_comparison(args.baseline_dir, args.optimized_dir, scenes)
    if args.baseline_shaders:
        assert shader_hashes(args.baseline_shaders) == shader_hashes(ROOT / 'shaders'), 'Shader inputs changed'
        report['shader_files_unchanged'] = len(shader_hashes(ROOT / 'shaders'))
    (args.output / 'verification.json').write_text(json.dumps(report, indent=2) + '\n')
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
