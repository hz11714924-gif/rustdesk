"""Package tracked source including initialized submodules and CI bridge files."""

from pathlib import Path
import subprocess
import sys
import zipfile


def main():
    root = Path(__file__).resolve().parents[2]
    output = Path(sys.argv[1]).resolve()
    submodules = subprocess.check_output(
        ["git", "submodule", "status", "--recursive"], cwd=root, text=True
    )
    if any(line.startswith(("-", "+", "U")) for line in submodules.splitlines()):
        sys.exit("Initialize submodules at their pinned commits before packaging source")
    paths = subprocess.check_output(
        ["git", "ls-files", "--recurse-submodules", "-z"], cwd=root
    ).decode("utf-8").split("\0")
    paths += [
        "src/bridge_generated.rs",
        "src/bridge_generated.io.rs",
        "flutter/lib/generated_bridge.dart",
        "flutter/lib/generated_bridge.freezed.dart",
        "flutter/macos/Runner/bridge_generated.h",
        "flutter/ios/Runner/bridge_generated.h",
    ]
    with zipfile.ZipFile(output, "w", zipfile.ZIP_DEFLATED) as archive:
        for name in sorted(set(paths)):
            path = root / name
            if path.name in {"screen-wall-private.json", "private-screen-wall-defaults.json"}:
                continue
            if name and path.is_file() and path != output:
                archive.write(path, "rustdesk-screen-wall/" + name)


if __name__ == "__main__":
    main()
