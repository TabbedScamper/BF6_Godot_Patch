"""Run storage checks in a fresh disposable SDK, never the installed project."""
from __future__ import annotations
import argparse
import json
from pathlib import Path
import shutil
import subprocess


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    fixture = args.output.resolve()
    # An existing fixture might contain authored files. Refuse reuse or cleanup.
    fixture.mkdir(parents=True, exist_ok=False)
    package = Path(__file__).resolve().parents[1]
    addon = fixture / "addons/bf6_map_selection"
    addon.mkdir(parents=True)
    for name in ("creator_project_store.gd", "map_catalog.gd"):
        shutil.copyfile(package / "addons/bf6_map_selection" / name, addon / name)
    shipped = package.parents[2] / "Resources/script/template"
    if not shipped.is_dir():
        shipped = package / "addons/bf6_map_selection/template"
    shutil.copytree(shipped, addon / "template")
    (fixture / "tests").mkdir()
    shutil.copyfile(Path(__file__).with_name("creator_project_store_tests.gd"), fixture / "tests/creator_project_store_tests.gd")
    (fixture / "project.godot").write_text("config_version=5\n", encoding="utf-8")
    (fixture / "CREATOR_STORE_TEST_FIXTURE").write_text("disposable fixture\n", encoding="utf-8")
    (fixture / "static").mkdir()
    if __import__("os").name == "nt":
        # No shell-built path interpolation; literal arguments stay data in PowerShell.
        ps = "$p=$args[0]; $t=$args[1]; New-Item -ItemType Junction -Path $p -Target $t | Out-Null"
        # -File supports ordinary argv reliably (unlike powershell -Command).
        script = fixture / "make-junction.ps1"
        script.write_text(ps, encoding="utf-8")
        subprocess.run(["powershell", "-NoProfile", "-File", str(script), str(fixture / "linked-static"), str(fixture / "static")], check=True)
    else:
        (fixture / "linked-static").symlink_to(fixture / "static", target_is_directory=True)
    result = subprocess.run([str(args.godot.resolve()), "--headless", "--path", str(fixture), "--script", "res://tests/creator_project_store_tests.gd", "--log-file", str(fixture / "test.log")], capture_output=True, text=True, timeout=120)
    (fixture / "process.log").write_text(result.stdout + result.stderr, encoding="utf-8")
    log = (fixture / "test.log").read_text(encoding="utf-8")
    lines = [line for line in log.splitlines() if line.startswith("CREATOR_STORE_RESULT ")]
    summary = json.loads(lines[-1].split(" ", 1)[1]) if lines else {"failures": 1, "error": "No completion marker"}
    summary["exit_code"] = result.returncode
    (fixture / "result.json").write_text(json.dumps(summary, indent=2), encoding="utf-8")
    print(json.dumps(summary))
    return int(result.returncode != 0 or summary["failures"] != 0)


if __name__ == "__main__":
    raise SystemExit(main())
