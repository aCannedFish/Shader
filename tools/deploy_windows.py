"""Back up and install a checked complete migration pack in one Windows instance.

The fixed data atlas requires OptiFine's global shadow multiplier to be 1.0.
The old shader, options and named lighting companion are retained outside the
shader selection directory. Other Mods, worlds and shader packs are untouched.
"""

import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def shader_tree(directory):
    """Hash relative paths and exact file bytes for source/deployment comparison."""
    records = {}
    for path in sorted(directory.rglob("*")):
        if path.is_file():
            records[path.relative_to(directory).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    payload = "".join(f"{name}\0{digest}\n" for name, digest in sorted(records.items()))
    return {"files": records, "sha256": hashlib.sha256(payload.encode("utf-8")).hexdigest()}


def renderer_contract(source, source_tree, verification):
    """Validate the declared renderer before any existing game files are moved."""
    manifest = source / "conventional-build.json"
    if not manifest.is_file():
        layout = json.loads((source / "world-layout.json").read_text(encoding="utf-8"))
        if not (source / "prepare72.fsh").is_file() or not (source / "world1" / "shadow.gsh").is_file():
            raise ValueError("Expected the complete checked migration renderer")
        return {
            "architecture": "world-atlas",
            "preset": layout["preset"],
            "capture_size": layout["capture"]["width"],
        }

    contract = json.loads(manifest.read_text(encoding="utf-8"))
    if contract.get("architecture") != "conventional-2d" or contract.get("companion") is not False:
        raise ValueError("Expected the no-companion conventional renderer")
    for dimension in ("", "world-1", "world1"):
        folder = source / dimension
        for program in ("shadow", "gbuffers_terrain", "gbuffers_water", "deferred", "composite", "final"):
            for suffix in (".vsh", ".fsh"):
                if not (folder / (program + suffix)).is_file():
                    raise ValueError("Missing renderer entry: " + str(folder / (program + suffix)))
        if any(folder.glob("*.gsh")):
            raise ValueError("Unexpected geometry amplification in the conventional renderer")
    if verification is None:
        raise ValueError("Conventional deployment requires the checked checkpoint verification file")
    proof = json.loads(verification.read_text(encoding="utf-8"))
    if proof.get("checkpoint_ready") is not True or proof.get("shader_tree_sha256") != source_tree["sha256"]:
        raise ValueError("Checkpoint verification does not approve this exact shader tree")
    return {
        "architecture": contract["architecture"],
        "preset": contract["preset"],
        "capture_size": None,
        "verification": str(verification.resolve()),
        "scope": proof["scope"],
    }


def deploy(source, game, checkpoint, verification=None):
    """Install only the explicit shader target after preserving its previous state."""
    source = source.resolve(strict=True)
    game = game.resolve(strict=True)
    checkpoint = checkpoint.resolve()
    source_tree = shader_tree(source)
    contract = renderer_contract(source, source_tree, verification)
    target = (game / "shaderpacks" / "SimpleShader" / "shaders").resolve()
    backup = (game / ".simpleshader-backups" / datetime.now().strftime("%Y%m%d-%H%M%S")).resolve()
    if not target.is_relative_to(game) or not backup.is_relative_to(game):
        raise ValueError("Deployment paths must stay within the explicit game directory")
    if source == target or target.is_relative_to(source) or source.is_relative_to(target):
        raise ValueError("Source and target must be separate shader trees")
    backup.mkdir(parents=True, exist_ok=False)
    checkpoint.mkdir(parents=True, exist_ok=True)
    options = game / "optionsshaders.txt"
    if options.exists():
        shutil.copy2(options, backup / options.name)
    sidecar = game / "shaderpacks" / "SimpleShader.txt"
    if sidecar.exists():
        shutil.move(str(sidecar), backup / sidecar.name)
    if target.exists():
        shutil.move(str(target), backup / "shaders")
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copytree(source, target)
    installed_tree = shader_tree(target)
    if installed_tree != source_tree:
        raise RuntimeError(f"Installed tree differs; previous files remain in {backup}")
    lines = options.read_text(encoding="utf-8").splitlines() if options.exists() else []
    lines = [line for line in lines if not line.startswith(("shaderPack=", "shadowResMul="))]
    lines.extend(("shaderPack=SimpleShader", "shadowResMul=1.0"))
    options.write_text("\n".join(lines) + "\n", encoding="utf-8")
    companion = game / "mods" / "SimpleShaderLighting-0.2.4.jar"
    if companion.is_file():
        (backup / "mods").mkdir()
        shutil.move(str(companion), backup / "mods" / companion.name)
    root = Path(__file__).resolve().parents[1]
    commit = subprocess.check_output(["git", "-c", f"safe.directory={root.as_posix()}",
                                      "rev-parse", "HEAD"], cwd=root, text=True).strip()
    record = {
        "time": datetime.now().astimezone().isoformat(), "source_commit": commit,
        "source": str(source), "target": str(target), "backup": str(backup),
        "preset": contract["preset"], "shadow_multiplier": 1.0,
        "architecture": contract["architecture"],
        "capture_size": contract["capture_size"], "shader_tree": source_tree,
        "verification": contract.get("verification"),
        "scope": contract.get("scope",
            "Windows startup/configuration checkpoint; migration and performance remain incomplete"),
    }
    (checkpoint / "deployment.json").write_text(json.dumps(record, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in record.items() if key != "shader_tree"}, ensure_ascii=False, indent=2))
    print(f"Verified {len(source_tree['files'])} files, tree SHA-256 {source_tree['sha256']}")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--game", type=Path, required=True)
    parser.add_argument("--checkpoint", type=Path, required=True)
    parser.add_argument("--verification", type=Path)
    arguments = parser.parse_args()
    deploy(arguments.source, arguments.game, arguments.checkpoint, arguments.verification)
