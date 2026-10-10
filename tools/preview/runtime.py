"""Build and verify a pinned apitrace runtime with local macOS compatibility fixes.

The fixes use dyld interposition rather than replacing a cached system framework.
They affect only the tool build in the user's cache, never system OpenGL files.
"""

import ctypes
import io
import json
import os
from pathlib import Path
import pickle
import platform
import subprocess
import sys
import venv

REVISION = "706f9d61190684cb3e710fdf14c8f2a5ff13d9a3"


class SafeUnpickler(pickle.Unpickler):
    """Read apitrace's data-only stream without allowing Python class loading."""

    def find_class(self, module, name):
        raise pickle.UnpicklingError("Unexpected executable object in trace dump")


def calls(runtime, trace, callset):
    """Read a bounded selection of typed GPU calls from apitrace's serializer."""
    data = subprocess.check_output([
        runtime["apitrace"], "pickle", f"--calls={callset}", str(trace),
    ])
    stream = io.BytesIO(data)
    result = []
    while stream.tell() < len(data):
        result.append(SafeUnpickler(stream).load())
    return result


def capture_environment(runtime, trace):
    """Inject the wrapper into a child process while preserving parent settings."""
    environment = os.environ.copy()
    environment.pop("DYLD_FRAMEWORK_PATH", None)
    environment["DYLD_INSERT_LIBRARIES"] = runtime["wrapper"]
    environment["TRACE_FILE"] = str(trace)
    return environment


def patch_macos(source, build):
    """Generate renamed wrappers, original-symbol lookup, and dyld hook tables."""
    # Read pristine pinned files so setup remains repeatable after a prior patch.
    def original(name):
        return subprocess.check_output(
            ["git", "show", f"{REVISION}:{name}"], cwd=source, text=True)

    sys.path.insert(0, str(source))
    from specs.cglapi import cglapi
    from specs.glapi import glapi

    environment = os.environ.copy()
    environment["PYTHONPATH"] = str(source)
    generated = subprocess.check_output([
        sys.executable, str(source / "wrappers" / "cgltrace.py"),
    ], cwd=source, env=environment, text=True)
    system = ctypes.CDLL("/System/Library/Frameworks/OpenGL.framework/Versions/A/OpenGL")
    active = []
    for function in (*cglapi.functions, *glapi.functions):
        signature = function.prototype() + " {"
        if signature in generated:
            generated = generated.replace(
                signature, function.prototype("apitrace_" + function.name) + " {", 1)
            if hasattr(system, function.name):
                active.append(function)
    generated += "\n// Local macOS dyld interposition, generated at setup.\n"
    for function in active:
        generated += 'extern "C" ' + function.prototype() + ";\n"
    generated += '__attribute__((used, section("__DATA,__interpose")))\n'
    generated += "static struct { const void *replacement; const void *original; } apitrace_interposers[] = {\n"
    for function in active:
        generated += f"    {{ (const void *)&apitrace_{function.name}, (const void *)&{function.name} }},\n"
    generated += "};\nstatic const char *apitrace_interpose_names[] = {\n"
    generated += "".join(f'    "{function.name}",\n' for function in active)
    generated += '''};
extern "C" void *apitrace_original_lookup(const char *name) {
    for (size_t i = 0; i < sizeof(apitrace_interpose_names) / sizeof(apitrace_interpose_names[0]); i++) {
        if (strcmp(name, apitrace_interpose_names[i]) == 0) {
            return const_cast<void *>(apitrace_interposers[i].original);
        }
    }
    return NULL;
}
'''
    (build / "wrappers" / "cgltrace.cpp").write_text(generated)

    resolver = original("wrappers/glproc_gl.cpp")
    apple = resolver.index("#elif defined(__APPLE__)")
    start = resolver.index("void * _libgl_sym", apple)
    end = resolver.index("\n\nvoid *\n_getPublicProcAddress", start)
    resolver = resolver[:start] + '''extern "C" void *apitrace_original_lookup(const char *name);
void * _libgl_sym(const char *symbol)
{
    return apitrace_original_lookup(symbol);
}
''' + resolver[end:]
    (source / "wrappers" / "glproc_gl.cpp").write_text(resolver)
    cmake = original("wrappers/CMakeLists.txt")
    cmake += '\nif (APPLE)\n    target_link_libraries(cgltrace "-framework OpenGL")\nendif ()\n'
    (source / "wrappers" / "CMakeLists.txt").write_text(cmake)

    serializer = original("cli/pickle.hpp")
    start = serializer.index("        if (length < 256)", serializer.index("inline void writeString(const char *s, size_t length)"))
    end = serializer.index("        os.put(BINPUT);", start)
    serializer = serializer[:start] + '''        // Shader sources are UTF-8; keep bytes intact for exact replacement.
        os.put(BINUNICODE);
        putInt32(length);
        os.write(s, length);

''' + serializer[end:]
    (source / "cli" / "pickle.hpp").write_text(serializer)

    cocoa = original("retrace/glws_cocoa.mm")
    cocoa = '#include "ws.hpp"\n' + cocoa
    cocoa = cocoa.replace("        [window setContentView:view];",
                          "        [view setWantsBestResolutionOpenGLSurface:NO];\n        [window setContentView:view];")
    cocoa = cocoa.replace("            [window makeKeyAndOrderFront:nil];",
                          "            if (!ws::headless) {\n                [window makeKeyAndOrderFront:nil];\n            }")
    cocoa = cocoa.replace("    [NSApp activateIgnoringOtherApps:YES];",
                          "    if (!ws::headless) {\n        [NSApp activateIgnoringOtherApps:YES];\n    }")
    (source / "retrace" / "glws_cocoa.mm").write_text(cocoa)
    return len(active)


def setup(root):
    """Build tools and isolated Python dependencies; save absolute runtime paths."""
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("The current bootstrap is validated for Apple Silicon macOS")
    work = root / ".preview"
    work.mkdir(exist_ok=True)
    cache = Path.home() / "Library" / "Caches" / "SimpleShader"
    source = cache / "apitrace-src"
    build = cache / "apitrace-build"
    cache.mkdir(parents=True, exist_ok=True)
    log = work / "setup.log"
    with log.open("w") as output:
        if not source.exists():
            subprocess.run(["git", "clone", "--depth", "1", "https://github.com/apitrace/apitrace.git", str(source)],
                           check=True, stdout=output, stderr=subprocess.STDOUT)
            fresh_revision = subprocess.check_output(
                ["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
            if fresh_revision != REVISION:
                subprocess.run(["git", "fetch", "--depth", "1", "origin", REVISION], cwd=source,
                               check=True, stdout=output, stderr=subprocess.STDOUT)
                subprocess.run(["git", "checkout", "--detach", REVISION], cwd=source,
                               check=True, stdout=output, stderr=subprocess.STDOUT)
        revision = subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=source, text=True).strip()
        if revision != REVISION:
            raise RuntimeError(f"Runtime source revision is {revision}; expected {REVISION}")
        subprocess.run(["git", "submodule", "update", "--init", "--depth", "1", "--recursive", "--jobs", "4"],
                       cwd=source, check=True, stdout=output, stderr=subprocess.STDOUT)
        for relative in ("wrappers/glproc_gl.cpp", "wrappers/CMakeLists.txt"):
            pristine = subprocess.check_output(
                ["git", "show", f"{REVISION}:{relative}"], cwd=source)
            (source / relative).write_bytes(pristine)
        print(f"Building apitrace; log: {log}", flush=True)
        subprocess.run([
            "cmake", "-S", str(source), "-B", str(build), "-G", "Ninja",
            "-DENABLE_GUI=OFF", "-DBUILD_TESTING=OFF", "-DCMAKE_BUILD_TYPE=Release",
            f"-DPython3_EXECUTABLE={sys.executable}",
        ], check=True, stdout=output, stderr=subprocess.STDOUT)
        generator_environment = os.environ.copy()
        generator_environment["PYTHONPATH"] = str(source)
        pristine_generated = subprocess.check_output([
            sys.executable, str(source / "wrappers" / "cgltrace.py"),
        ], cwd=source, env=generator_environment)
        (build / "wrappers" / "cgltrace.cpp").write_bytes(pristine_generated)
        subprocess.run(["cmake", "--build", str(build), "--target", "apitrace", "glretrace", "gltrim", "cgltrace", "--parallel", "4"],
                       check=True, stdout=output, stderr=subprocess.STDOUT)
        count = patch_macos(source, build)
        subprocess.run(["cmake", "--build", str(build), "--target", "cgltrace", "glretrace", "apitrace", "--parallel", "4"],
                       check=True, stdout=output, stderr=subprocess.STDOUT)
        environment = work / "venv"
        if not (environment / "bin" / "python").exists():
            venv.EnvBuilder(with_pip=True).create(environment)
        subprocess.run([str(environment / "bin" / "python"), "-m", "pip", "install", "Pillow>=10,<14"],
                       check=True, stdout=output, stderr=subprocess.STDOUT)
    runtime = {
        "apitrace": str(build / "apitrace"), "glretrace": str(build / "glretrace"),
        "gltrim": str(build / "gltrim"),
        "wrapper": str(build / "wrappers" / "OpenGL.framework" / "Versions" / "A" / "OpenGL"),
        "revision": REVISION, "interposed_functions": count,
    }
    (work / "runtime.json").write_text(json.dumps(runtime, indent=2))
    print(f"Runtime ready; {count} OpenGL/CGL functions instrumented")
    return runtime


def probe(root, runtime):
    """Verify capture, pixel-identical replay, and a real shader replacement."""
    from PIL import Image, ImageChops

    work = root / ".preview" / "probe"
    work.mkdir(parents=True, exist_ok=True)
    executable = work / "gl_probe"
    subprocess.run([
        "clang", "-Wno-deprecated-declarations", "-framework", "Cocoa",
        "-framework", "OpenGL", str(root / "tools" / "preview" / "gl_probe.m"),
        "-o", str(executable),
    ], check=True)
    trace = work / "verified.trace"
    subprocess.run([str(executable), str(work / "original.ppm")],
                   env=capture_environment(runtime, trace), check=True)
    dump = subprocess.check_output([
        runtime["apitrace"], "dump", "--color=never", "--multiline=no",
        "--grep=glShaderSource", str(trace),
    ], text=True)
    ids = ",".join(line.split()[0] for line in dump.splitlines() if "glShaderSource(" in line)
    selected = next(call for call in calls(runtime, trace, ids)
                    if "out vec4 color" in dict(call[3])["string"][0])
    source = dict(selected[3])["string"][0]
    (work / "before.glsl").write_text(source)
    (work / "after.glsl").write_text(source.replace("0.2, 0.7, 0.4", "0.8, 0.2, 0.1"))
    changed_trace = work / "changed.trace"
    subprocess.run([
        runtime["apitrace"], "sed", f"--calls={selected[0]}", "-e",
        f"s|@file({work / 'before.glsl'})|@file({work / 'after.glsl'})|",
        "-o", str(changed_trace), str(trace),
    ], check=True)
    for name, recording in (("replay", trace), ("changed", changed_trace)):
        for old in work.glob(f"{name}-*.png"):
            old.unlink()
        subprocess.run([runtime["glretrace"], "--singlethread", "--headless",
                        "-s", str(work / f"{name}-"), str(recording)], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    original = Image.open(work / "original.ppm").convert("RGB")
    replay = Image.open(next(work.glob("replay-*.png"))).convert("RGB")
    changed = Image.open(next(work.glob("changed-*.png"))).convert("RGB")
    if original.size != replay.size or ImageChops.difference(original, replay).getbbox():
        raise RuntimeError("Probe replay differs from original pixels")
    difference = ImageChops.difference(replay, changed)
    pixels = sum(pixel != (0, 0, 0) for pixel in difference.get_flattened_data())
    if pixels == 0:
        raise RuntimeError("Shader replacement did not affect the rendered image")
    report = {"original_replay_equal": True, "replacement_changed_pixels": pixels,
              "image_size": list(original.size)}
    (work / "verification.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report))
