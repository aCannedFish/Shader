#!/usr/bin/env python3
"""Verify Mod isolation and geometry/link checks without launching Minecraft."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import zipfile

from preview.minecraft import companion_mods, configure_companion
from check_glsl import discover_programs

ROOT = Path(__file__).resolve().parents[1]


def jar(path, mod_id):
    """Minimal real Mod metadata tests identification beyond filenames."""
    path.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('META-INF/mods.toml', f'[[mods]]\nmodId="{mod_id}"\n')


def main():
    """Both unsafe launch inputs and invalid graphics interfaces must be rejected."""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        (root / 'VERSION').write_text('0.2.4\n')
        game = root / '.preview/game-target'
        jar(game / 'mods/unrelated-name.jar', 'simpleshader_lighting')
        jar(game / 'mods/simpleshader-preview.jar', 'simpleshader_preview')
        configure_companion(root, game, None, True)
        assert not companion_mods(game / 'mods')
        assert (game / 'mods/simpleshader-preview.jar').exists()
        source = root / 'reference.jar'
        jar(source, 'simpleshader_lighting')
        configure_companion(root, game, source, False)
        assert len(companion_mods(game / 'mods')) == 1
        configure_companion(root, game, None, True)
        assert not companion_mods(game / 'mods')
        try:
            configure_companion(root, root / 'personal-instance', None, True)
        except ValueError:
            pass
        else:
            raise AssertionError('Personal instance mutation was allowed')
        shader = root / 'shaders'
        shader.mkdir()
        vertex = '#version 330 core\nvoid main(){gl_Position=vec4(0,0,0,1);}\n'
        geometry = '''#version 330 core
layout(triangles) in;
layout(triangle_strip,max_vertices=3) out;
out vec3 observed;
void main(){for(int i=0;i<3;i++){observed=vec3(1);gl_Position=gl_in[i].gl_Position;EmitVertex();}EndPrimitive();}
'''
        fragment = '#version 330 core\nin vec3 observed;out vec4 result;void main(){result=vec4(observed,1);}\n'
        for dimension in ['', 'world-1', 'world1']:
            folder = shader / dimension
            folder.mkdir(exist_ok=True)
            for suffix, text in [('vsh', vertex), ('gsh', geometry), ('fsh', fragment)]:
                (folder / ('shadow.' + suffix)).write_text(text)
        assert len(discover_programs(shader)) == 9
        command = [sys.executable, str(ROOT / 'tools/check_glsl.py'), '--shader-dir', str(shader), '--output', str(root / 'compiled')]
        valid = subprocess.run(command, capture_output=True, text=True)
        assert valid.returncode == 0, valid.stdout + valid.stderr
        (shader / 'shadow.fsh').write_text(fragment.replace('in vec3 observed;', 'in vec4 observed;').replace('vec4(observed,1)', 'observed'))
        invalid = subprocess.run(command, capture_output=True, text=True)
        assert invalid.returncode != 0 and 'link' in invalid.stdout, 'A mismatched geometry interface was accepted'
    result = {'renamed_companion_removed': True, 'helper_retained': True,
              'reference_install_verified': True, 'personal_instance_protected': True,
              'geometry_stages_discovered': 9, 'valid_links_accepted': True,
              'invalid_link_rejected': True}
    output = ROOT / 'local-docs/migration/harness-verification.json'
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
