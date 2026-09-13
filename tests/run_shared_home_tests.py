"""Isolated model + actual native Home acceptance; never touches installed SDKs."""
from __future__ import annotations
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--godot", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    package = Path(__file__).resolve().parents[1]
    parent = package.parents[2]
    fixture = args.output.resolve()
    fixture.mkdir(parents=True, exist_ok=False)
    addon = fixture / "addons/bf6_map_selection"
    addon.mkdir(parents=True)
    for name in ("map_panel.gd", "map_catalog.gd", "plugin.gd", "creator_project_store.gd", "home_session.gd"):
        shutil.copyfile(package / "addons/bf6_map_selection" / name, addon / name)
    shutil.copytree(package / "addons/bf6_map_selection/data", addon / "data")
    web = addon / "web"
    shutil.copytree(parent / "Resources/home", web / "home")
    shutil.copytree(parent / "Resources/mapthumbs", web / "mapthumbs")
    (web / ".gdignore").write_text("Browser fixture resources; do not import into Godot.\n")
    resources = sorted(path.relative_to(web).as_posix() for path in web.rglob("*") if path.is_file() and path.suffix in (".html", ".css", ".js", ".jpg", ".png", ".woff", ".woff2", ".ttf"))
    (web / "host-resources.json").write_text(json.dumps({"version": 1, "files": resources, "entryPoints": ["home/index.html"], "ipcOperations": ["log"]}), encoding="utf-8")
    (fixture / "tests").mkdir()
    for name in ("run_tests.gd", "shared_home_native.gd"):
        shutil.copyfile(package / "tests" / name, fixture / "tests" / name)
    (fixture / "project.godot").write_text('config_version=5\n[application]\nconfig/name="BF6MapSelectorTests"\n[rendering]\nrenderer/rendering_method="gl_compatibility"\n', encoding="utf-8")
    def run(name, arguments, marker=None):
        result = subprocess.run([str(args.godot.resolve()), "--path", str(fixture), *arguments], capture_output=True, text=True, timeout=70)
        output = result.stdout + result.stderr
        (fixture / (name + ".log")).write_text(output, encoding="utf-8")
        if result.returncode or "SCRIPT ERROR" in output or "Parse Error" in output or "ERROR:" in output or (marker and marker not in output):
            print(output)
            raise RuntimeError(name + " failed or did not report completion; exit=" + str(result.returncode))
        return output
    run("import", ["--headless", "--editor", "--import"])
    # Model tests create their own files and verify preservation. Native tests
    # use a separate project to avoid counting the model test's synthetic maps.
    run("model", ["--headless", "--script", "res://tests/run_tests.gd"], "failures")
    native_fixture = fixture.parent / (fixture.name + "-native")
    native_fixture.mkdir(exist_ok=False)
    shutil.copytree(fixture / "addons", native_fixture / "addons")
    shutil.copytree(fixture / ".godot", native_fixture / ".godot")
    shutil.copytree(fixture / "tests", native_fixture / "tests")
    shutil.copyfile(fixture / "project.godot", native_fixture / "project.godot")
    fixture = native_fixture
    shutil.copytree(parent / "Shared/Godot/_shared/bf6_editor_web_host", fixture / "addons/bf6_editor_web_host")
    # Native browser validation runs visibly. Avoid conflating its acceptance
    # with the separately observed extension/headless-editor shutdown crash.
    (fixture / ".godot/extension_list.cfg").write_text("res://addons/bf6_editor_web_host/bf6_editor_web_host.gdextension\n")
    (fixture / "levels").mkdir()
    (fixture / "levels/MP_Abbasid.tscn").write_text('[gd_scene format=3]\n[node name="Stock" type="Node3D"]\n')
    (fixture / "User_Created/levels").mkdir(parents=True)
    (fixture / "User_Created/levels/Creator_Save.tscn").write_text('[gd_scene format=3]\n[ext_resource type="PackedScene" path="res://static/MP_Abbasid_Assets.tscn" id="1"]\n[node name="Creator" type="Node3D"]\ntransform = Transform3D(1,0,0,0,1,0,0,0,1,9,8,7)\n')
    output = run("native", ["--script", "res://tests/shared_home_native.gd"], "SHARED_HOME_NATIVE_RESULT")
    result_line = next(line for line in output.splitlines() if line.startswith("SHARED_HOME_NATIVE_RESULT "))
    result = json.loads(result_line.split(" ", 1)[1])
    result["tested_sha256"] = {path.relative_to(fixture).as_posix(): hashlib.sha256(path.read_bytes()).hexdigest()
                              for path in (fixture / "addons").rglob("*") if path.is_file()
                              and (path.suffix in (".gd", ".html", ".css", ".js", ".dll", ".ttf", ".jpg", ".json") or path.name == ".gdignore")}
    (fixture / "result.json").write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(json.dumps({"checks": result["checks"], "failures": result["failures"], "evidence": str(fixture / "result.json")}))
    return int(result["failures"] != 0)


if __name__ == "__main__":
    sys.exit(main())
