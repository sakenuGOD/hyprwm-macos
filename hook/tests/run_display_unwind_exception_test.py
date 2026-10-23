#!/usr/bin/env python3
"""Build and run the headless arm64e product C/C++ exception regression."""
import argparse
import hashlib
import json
import platform
import re
import subprocess
import tempfile
from pathlib import Path

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument("--fixture-root", type=Path)
    parser.add_argument("--build-dir", type=Path)
    args = parser.parse_args()
    if platform.system() != "Darwin" or platform.machine() not in ("arm64", "arm64e"):
        print("SKIP: requires Darwin arm64e tooling and execution")
        return 77

    repo = args.repo.resolve()
    fixture_root = (args.fixture_root or repo).resolve()
    fixture = fixture_root / "hook/tests/fixtures/display_unwind"
    build = args.build_dir.resolve() if args.build_dir else Path(tempfile.mkdtemp(prefix="display-unwind-test-"))
    if args.build_dir:
        build.mkdir(parents=True, exist_ok=False)
    source = repo / "hook/src"
    commands = []

    def run(argv):
        commands.append(argv)
        subprocess.run(argv, check=True)

    common = [
        "-arch", "arm64e", "-O2", "-fexceptions",
        "-fno-omit-frame-pointer", "-fno-optimize-sibling-calls",
        "-funwind-tables", "-fasynchronous-unwind-tables",
        "-I", str(source),
    ]
    inputs = [
        ("fixture", "clang", fixture / "fixture.c", [
            "-ffreestanding", "-fno-builtin", "-fno-math-errno",
            "-fno-stack-protector", "-fno-stack-check",
            '-DDISPLAY_UNWIND_TEST_PRODUCT_C="anim4.c"',
            "-include", str(source / "display_unwind_check.h"),
        ]),
        ("entries", "clang++", source / "display_unwind.cpp", [
            "-fno-rtti", "-ffreestanding", "-fno-builtin",
            "-fno-stack-protector", "-fno-stack-check",
        ]),
        ("driver", "clang++", fixture_root / "hook/tests/display_unwind_exception_test.cpp", [
            "-std=c++17",
        ]),
    ]
    objects = []
    for name, compiler, path, extra in inputs:
        assembly = build / (name + ".s")
        run(["xcrun", compiler, *common, *extra, "-S", str(path), "-o", str(assembly)])
        # Match the product's explicit B-key DWARF convention. No body or
        # landing-pad instruction is replaced; the fixture remains host-linked.
        parts = re.split(r"(\t\.cfi_startproc\n.*?\t\.cfi_endproc)", assembly.read_text(), flags=re.S)
        for index, proc in enumerate(parts):
            if ".cfi_startproc" in proc:
                if re.search(r"^\s*pacibsp\s*$", proc, re.M):
                    proc = proc.replace("\t.cfi_startproc\n", "\t.cfi_startproc\n\t.cfi_b_key_frame\n", 1)
                proc = proc.replace("\t.cfi_startproc\n", "\t.cfi_startproc\n\tbti c\n", 1)
            parts[index] = proc
        assembly.write_text("".join(parts))
        obj = build / (name + ".o")
        run(["xcrun", "clang", "-arch", "arm64e", "-femit-dwarf-unwind=always",
             "-c", str(assembly), "-o", str(obj)])
        objects.append(str(obj))

    for name in ("Frames", "PairMirror", "SourceMirror"):
        obj = build / (name + ".o")
        run(["xcrun", "clang", "-arch", "arm64e", "-femit-dwarf-unwind=always",
             "-c", str(fixture / (name + ".S")), "-o", str(obj)])
        objects.append(str(obj))
    binary = build / "display-unwind-exception-test"
    run(["xcrun", "clang++", "-arch", "arm64e", *objects,
         "-Wl,-no_compact_unwind", "-Wl,-export_dynamic", "-o", str(binary)])
    result = subprocess.run([str(binary)], text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    (build / "result.txt").write_text(result.stdout + "\nexit=" + str(result.returncode) + "\n")
    # Keep review evidence portable; no machine-specific command paths.
    def portable(value):
        return str(value).replace(str(build), "<build>").replace(str(fixture_root), "<fixtures>").replace(str(repo), "<repo>")
    (build / "commands.json").write_text(json.dumps([[portable(v) for v in row] for row in commands], indent=2) + "\n")
    hashes = {path.relative_to(repo).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
              for path in sorted(source.glob("display_unwind*")) if path.is_file()}
    (build / "result.json").write_text(json.dumps({
        "status": "PASS" if result.returncode == 0 else "FAIL",
        "exit_code": result.returncode,
        "product_source_hashes": hashes,
        "binary_sha256": hashlib.sha256(binary.read_bytes()).hexdigest(),
        "scope": "headless synthetic data; actual product C bodies and C++ entries",
    }, indent=2) + "\n")
    print(result.stdout, end="")
    return result.returncode

if __name__ == "__main__":
    raise SystemExit(main())
