#!/usr/bin/env python3
"""Bundle licence texts for the locked Rust dependency graph, across targets.

Build-only and development-only dependency edges are omitted. Conditional
normal dependencies are retained so the same asset covers all platforms.
Flutter collects Dart/plugin licences separately.
"""

import hashlib
import json
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parent.parent
ASSETS = ROOT / "app/assets/licenses"


def main():
    metadata = json.loads(subprocess.check_output([
        "cargo", "metadata", "--locked", "--format-version", "1",
        "--manifest-path", str(ROOT / "app/rust/Cargo.toml"),
    ]))
    nodes = {node["id"]: node for node in metadata["resolve"]["nodes"]}
    visited = set()

    def visit(package_id):
        if package_id in visited:
            return
        visited.add(package_id)
        for dependency in nodes[package_id]["deps"]:
            if any(kind["kind"] is None for kind in dependency["dep_kinds"]):
                visit(dependency["pkg"])

    visit(metadata["resolve"]["root"])
    overrides = {
        "dart-sys": ASSETS / "upstream/dart-sys-LICENSE-MIT.txt",
        "flutter_rust_bridge": ASSETS / "upstream/flutter_rust_bridge-LICENSE.txt",
        "flutter_rust_bridge_macros": ASSETS / "upstream/flutter_rust_bridge-LICENSE.txt",
    }
    groups = {}
    for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
        if package["id"] not in visited or package["source"] is None:
            continue
        directory = Path(package["manifest_path"]).parent
        files = sorted(path for path in directory.iterdir() if path.is_file()
                       and path.name.upper().startswith(("LICENSE", "COPYING", "NOTICE", "COPYRIGHT")))
        if not files and package["name"] in overrides:
            files = [overrides[package["name"]]]
        if not files:
            raise RuntimeError(f"No licence text found for {package['name']}")
        text = "\n\n".join(path.read_text().strip() for path in files)
        groups.setdefault(text, []).append(f"{package['name']} {package['version']} (Rust)")
    result = {
        "cargo_lock_sha256": hashlib.sha256((ROOT / "app/rust/Cargo.lock").read_bytes()).hexdigest(),
        "entries": [{"packages": packages, "text": text} for text, packages in groups.items()],
    }
    (ASSETS / "rust_licenses.json").write_text(json.dumps(result, indent=2) + "\n")
    print(f"Bundled {sum(len(packages) for packages in groups.values())} Rust dependency notices")


if __name__ == "__main__":
    main()
