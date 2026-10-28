#!/usr/bin/env python3
"""Build independent LabPBR maps from the material pack's recipes and client art.

Only normal/specular maps are emitted. Vanilla colour textures remain supplied
by Minecraft. No generated material values are embedded into GLSL.
"""
import argparse
import fnmatch
import hashlib
import io
import json
from pathlib import Path
import shutil
import zipfile

import numpy as np
from PIL import Image

ROOT = Path(__file__).resolve().parents[1]


def smoothstep(low, high, value):
    """Use a continuous mask for mineral edges in the generated asset."""
    value = np.clip((value - low) / (high - low), 0, 1)
    return value * value * (3 - 2 * value)


def ore_mask(name, colour):
    """Keep mineral selection in resource authoring, independent of shader code."""
    r, g, b = colour[..., 0], colour[..., 1], colour[..., 2]
    contrast = colour.max(axis=-1) - colour.min(axis=-1)
    if "coal" in name:
        return np.zeros_like(r)
    if "iron" in name:
        return smoothstep(0.04, 0.11, r - b)
    if "copper" in name:
        return smoothstep(0.06, 0.15, contrast)
    if "gold" in name:
        return smoothstep(0.08, 0.18, np.minimum(r, g) - b)
    if "redstone" in name:
        return smoothstep(0.08, 0.18, r - np.maximum(g, b))
    if "lapis" in name:
        return smoothstep(0.08, 0.18, b - r)
    if "emerald" in name:
        return smoothstep(0.08, 0.18, g - np.maximum(r, b))
    if "diamond" in name:
        return smoothstep(0.06, 0.16, np.minimum(g, b) - r)
    return smoothstep(0.30, 0.55, np.minimum(g, b)) * (1 - smoothstep(0.15, 0.35, contrast))


def material_maps(colour, recipe, settings, emission=None):
    """Encode LabPBR channels directly as bytes without gamma conversion."""
    height, width = colour.shape[:2]
    specular = np.zeros((height, width, 4), dtype="u1")
    specular[..., 0] = round(recipe.get("smoothness", 0) * 255)
    specular[..., 1] = recipe.get("reflectance", 10)
    specular[..., 2] = recipe.get("porosity", 0)
    specular[..., 3] = round(recipe.get("emission", 0) * 254)
    if emission is not None:
        specular[..., 3] = np.rint(emission * 254).astype("u1")
    normal = np.empty_like(specular)
    normal[...] = (128, 128, 255, 255)
    return specular, normal


def build(client, output):
    """Create a new reviewable pack without replacing any existing artifact."""
    if output.exists():
        raise ValueError("Use a new output directory")
    output.mkdir(parents=True)
    settings = json.loads((ROOT / "resourcepack/materials.json").read_text(encoding="utf-8"))
    shutil.copy2(ROOT / "resourcepack/pack.mcmeta", output / "pack.mcmeta")
    destination = output / "assets/minecraft/textures/block"
    destination.mkdir(parents=True)
    properties = output / "assets/minecraft/optifine/texture.properties"
    properties.parent.mkdir(parents=True)
    shutil.copy2(ROOT / "resourcepack/assets/minecraft/optifine/texture.properties", properties)
    records = []
    with zipfile.ZipFile(client) as archive:
        prefix = "assets/minecraft/textures/block/"
        textures = {Path(name).stem: name for name in archive.namelist()
            if name.startswith(prefix) and name.endswith(".png")}
        recipes = {}
        for recipe in settings["materials"]:
            for name in textures:
                selected = name in recipe.get("textures", []) or any(
                    fnmatch.fnmatchcase(name, pattern) for pattern in recipe.get("patterns", []))
                if selected and not any(part in name for part in recipe.get("exclude", [])):
                    recipes[name] = recipe
        ores = [name for name in textures if name.endswith("_ore")]
        for name in sorted(set(recipes) | set(ores)):
            colour = np.asarray(Image.open(io.BytesIO(archive.read(textures[name]))).convert("RGBA")) / 255.0
            emission = None
            if name in ores:
                emission = ore_mask(name, colour[..., :3]) * settings["ore_emission"]["strength"]
            specular, normal = material_maps(colour, recipes.get(name, {}), settings, emission)
            for suffix, array in [("s", specular), ("n", normal)]:
                target = destination / (name + "_" + suffix + ".png")
                Image.fromarray(array).save(target)
                metadata = textures[name] + ".mcmeta"
                if metadata in archive.namelist():
                    (target.parent / (target.name + ".mcmeta")).write_bytes(archive.read(metadata))
            records.append({"texture": name, "size": list(colour.shape[:2][::-1]),
                "emissive_pixels": int(np.count_nonzero(specular[..., 3]))})
    zip_path = output.with_suffix(".zip")
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        for path in sorted(output.rglob("*")):
            if path.is_file():
                info = zipfile.ZipInfo(path.relative_to(output).as_posix(), date_time=(1980, 1, 1, 0, 0, 0))
                info.compress_type = zipfile.ZIP_DEFLATED
                info.external_attr = 0o100644 << 16
                archive.writestr(info, path.read_bytes())
    report = {"standard": "lab-pbr/1.3", "pack": str(zip_path), "textures": records,
        "sha256": hashlib.sha256(zip_path.read_bytes()).hexdigest(),
        "status": "Asset build only; generic shader integration and native acceptance pending"}
    output.with_suffix(".json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in report.items() if key != "textures"}, indent=2))
    print("Material textures:", len(records))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--minecraft-jar", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    build(args.minecraft_jar, args.output)
