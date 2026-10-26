"""Summarize isolated GPU timestamp intervals without external dependencies."""

import argparse
import csv
import json
from collections import defaultdict
from pathlib import Path
from statistics import mean


def summarize(path):
    """Aggregate repeated program visits per frame and retain queue idle time."""
    frames = defaultdict(lambda: defaultdict(lambda: [0.0, 0.0]))
    with path.open(newline="") as source:
        for row in csv.DictReader(source):
            entry = frames[int(row["frame"])][row["program"]]
            entry[0] += float(row["gpu_ms"])
            entry[1] += float(row["cpu_ms"])
    # The final outside interval has no following frame timestamp.
    complete = [value for value in frames.values() if "frame.outside" in value]
    if not complete:
        raise ValueError("No complete GPU timing frames")
    totals = [sum(value[0] for value in frame.values()) for frame in complete]
    programs = []
    for name in {name for frame in complete for name in frame}:
        gpu = [frame.get(name, [0.0, 0.0])[0] for frame in complete]
        cpu = [frame.get(name, [0.0, 0.0])[1] for frame in complete]
        programs.append({"name": name, "gpu_ms_per_frame": mean(gpu),
                         "cpu_ms_per_frame": mean(cpu)})
    return {
        "source": str(path), "frames": len(complete),
        "gpu_frame_ms_mean": mean(totals),
        "gpu_frame_ms_p50": sorted(totals)[len(totals) // 2],
        "gpu_frame_ms_p95": sorted(totals)[int((len(totals) - 1) * 0.95)],
        "timeline_fps": 1000.0 / mean(totals),
        "note": "GPU timestamp intervals include queue idle/submission gaps; CPU intervals accompany them.",
        "programs": sorted(programs, key=lambda value: -value["gpu_ms_per_frame"]),
    }


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("csv", type=Path)
    arguments = parser.parse_args()
    result = summarize(arguments.csv)
    output = arguments.csv.with_suffix(".json")
    output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({key: value for key, value in result.items() if key != "programs"}, indent=2))
    for program in result["programs"][:15]:
        print(f"{program['name']:25} GPU {program['gpu_ms_per_frame']:9.3f} ms"
              f" CPU {program['cpu_ms_per_frame']:9.3f} ms")
