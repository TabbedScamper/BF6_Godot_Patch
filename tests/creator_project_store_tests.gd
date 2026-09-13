extends SceneTree

const Store = preload("res://addons/bf6_map_selection/creator_project_store.gd")
var checks := 0
var failures := 0

func expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(label)
	print("CHECK %s %s" % ["PASS" if condition else "FAIL", label])

func write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)
	file.close()

func _initialize() -> void:
	if not FileAccess.file_exists("res://CREATOR_STORE_TEST_FIXTURE"):
		push_error("Refusing to run destructive fixture setup outside the disposable test project.")
		quit(2)
		return
	run.call_deferred()

func run() -> void:
	var stock := '[gd_scene load_steps=2 format=3 uid="uid://stock123"]\n\n[ext_resource type="PackedScene" uid="uid://asset123" path="res://static/MP_Fixture_Assets.tscn" id="1"]\n\n[node name="MP_Fixture" type="Node3D"]\n\n[node name="Assets" parent="." instance=ExtResource("1")]\n'
	write("res://levels/MP_Fixture.tscn", stock)
	write("res://levels/MP_Other.tscn", '[gd_scene format=3]\n[node name="Other" type="Node3D"]\n')
	write("res://static/MP_Fixture_Assets.tscn", '[gd_scene format=3]\n[node name="Assets" type="Node3D"]\n')
	var stock_hash := FileAccess.get_sha256("res://levels/MP_Fixture.tscn")
	var asset_hash := FileAccess.get_sha256("res://static/MP_Fixture_Assets.tscn")
	var ws := Store.ensure_workspace()
	expect(ws.error.is_empty(), "workspace created: " + str(ws))
	expect(not DirAccess.dir_exists_absolute(Store.DEFAULT_WORKSPACE + "/saves"), "startup creates no saves/project directory")
	var workspace_hash := FileAccess.get_sha256(Store.DEFAULT_WORKSPACE + "/bf6-workspace.json")
	expect(Store.ensure_workspace().error.is_empty() and FileAccess.get_sha256(Store.DEFAULT_WORKSPACE + "/bf6-workspace.json") == workspace_hash, "existing workspace identity preserved")
	var created := Store.create_from_stock("res://levels/MP_Fixture.tscn", "My Map")
	expect(created.error.is_empty(), "stock creator project created: " + str(created))
	if not created.error.is_empty():
		quit(1)
		return
	expect(created.scene_path == Store.DEFAULT_WORKSPACE + "/saves/My Map/unreal/tscn/MP_Fixture.tscn", "actual Unreal standalone TSCN path")
	var copy := FileAccess.get_file_as_string(created.scene_path)
	expect(not copy.contains('uid="'), "root and external UIDs removed")
	write("res://imports/spaced_uid.tscn", stock.replace('uid=', 'uid = '))
	var spaced_uid := Store.inspect_scene("res://imports/spaced_uid.tscn")
	expect(spaced_uid.error.is_empty() and not spaced_uid.scene_bytes.get_string_from_utf8().contains("uid ="), "hand-authored UID spacing cannot duplicate identities")
	expect(copy.contains('path="res://static/MP_Fixture_Assets.tscn"'), "shared external asset remains reference")
	expect(copy.contains('metadata/bf6_base_level = "MP_Fixture"'), "copied root stores canonical base level")
	write("res://imports/renamed.tscn", '[gd_scene format=3 uid="uid://renamed"]\n[node name="My Renamed Map" type="Node3D"]\nmetadata/custom = "keep"\n')
	var renamed := Store.import_scene("res://imports/renamed.tscn", "Renamed", Store.DEFAULT_WORKSPACE, "mp_fixture")
	expect(renamed.error.is_empty(), "renamed root imports with explicit installed base hint")
	var renamed_text := FileAccess.get_file_as_string(renamed.scene_path)
	expect(renamed_text.contains('name="My Renamed Map"') and renamed_text.contains('metadata/custom = "keep"') and renamed_text.contains('metadata/bf6_base_level = "MP_Fixture"'), "root name and unrelated metadata preserved")
	var again := Store.inspect_scene(renamed.scene_path)
	expect(again.error.is_empty() and again.scene_bytes.get_string_from_utf8().count("metadata/bf6_base_level") == 1, "repeat import uses metadata without duplication")
	write("res://imports/conflict.tscn", stock.replace('[node name="MP_Fixture" type="Node3D"]', '[node name="MP_Fixture" type="Node3D"]\nmetadata/bf6_base_level = "MP_Other"'))
	expect(not Store.inspect_scene("res://imports/conflict.tscn").error.is_empty(), "conflicting root metadata rejected")
	var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(created.project_root + "/project.json"))
	expect(manifest.manifest == "bf6-unreal-project" and manifest.manifestVersion == 1 and manifest.primaryLevel == "MP_Fixture", "real project manifest contract and level")
	expect(manifest.artefacts[0].md5 == FileAccess.get_md5(created.scene_path) and manifest.artefacts[0].kind == "tscn", "manifest hashes actual authored scene")
	expect(not FileAccess.file_exists(created.project_root + "/unreal/MP_Fixture.json"), "no fake Unreal session")
	expect(created.template_kind == "bundled starter" and FileAccess.file_exists(created.project_root + "/src/index.ts") and FileAccess.file_exists(created.project_root + "/package-lock.json"), "actual bundled scripting scaffold copied")
	for folder in Store.PROJECT_FOLDERS:
		expect(DirAccess.dir_exists_absolute(created.project_root.path_join(folder)), "parent project folder present: " + folder)
	write("res://companions/mode.ts", 'export function OnGameModeStarted(): void {}\n')
	write("res://companions/strings.json", '{"greeting":"Hello"}\n')
	write("res://companions/blocks.json", '{"blocks":{"languageVersion":0,"blocks":[{"type":"bf6x_future","id":"18446744073709551615","extraState":{"unknown":true}}]},"futureMetadata":{"numericId":18446744073709551615}}\n')
	write("res://companions/HUD.json", '{"canvas":{"width":1920,"height":1080}}\n')
	var companions := {"script":"res://companions/mode.ts","strings":"res://companions/strings.json","blocks":"res://companions/blocks.json","ui":"res://companions/HUD.json"}
	var preview := Store.preview_import("res://levels/MP_Fixture.tscn", "Complete", "res://PreviewWorkspace", "", companions)
	expect(preview.error.is_empty() and not DirAccess.dir_exists_absolute("res://PreviewWorkspace"), "preview validates normalized destinations without mutation")
	var imported := Store.import_scene("res://levels/MP_Fixture.tscn", "Complete", Store.DEFAULT_WORKSPACE, "", companions)
	expect(imported.error.is_empty() and imported.companions.size() == 4, "explicit companions normalized with scene and template")
	for entry in imported.companions:
		expect(FileAccess.get_sha256(entry.source) == entry.sha256 and FileAccess.get_sha256(imported.project_root.path_join(entry.destination)) == entry.sha256, "companion preserved byte-for-byte: " + entry.kind)
	expect(FileAccess.get_file_as_string(imported.project_root + "/unreal/blockly/workspace.json").contains('"numericId":18446744073709551615') and not DirAccess.dir_exists_absolute("res://addons/bf6_blockly"), "unknown blocks and large numeric IDs retained without Blockly addon")
	expect(not FileAccess.file_exists(created.project_root + "/unreal/blockly/workspace.json"), "missing original block document is not fabricated")
	write("res://companions/dependencies.ts", 'import {x} from "./missing";\nexport function OnGameModeStarted() { x(); }\n')
	expect(not Store.preview_import("res://levels/MP_Fixture.tscn", "MissingModules", Store.DEFAULT_WORKSPACE, "", {"script":"res://companions/dependencies.ts"}).error.is_empty(), "single-file TypeScript dependencies refused explicitly")
	write("res://companions/bad.json", '{this is not json}')
	expect(not Store.preview_import("res://levels/MP_Fixture.tscn", "BadJSON", Store.DEFAULT_WORKSPACE, "", {"blocks":"res://companions/bad.json"}).error.is_empty(), "malformed JSON companion refused")
	# Installed full-template route: preserve license and scripts, choose plain
	# boilerplate, park sample spatials, strip deploy and never copy credentials.
	var installed := "res://User_Created/projects/_template-v9.0.0"
	for relative in ["package-lock.json", "tsconfig.json", "src/index.ts", "src/strings.json"]:
		write(installed.path_join(relative), FileAccess.get_file_as_string(Store.BUNDLED_TEMPLATE.path_join(relative)))
	write(installed + "/package.json", '{"name":"community","version":"9.0.0","scripts":{"build":"bf6-portal-bundler --entrypoint ./src/index.ts --outDir ./dist","deploy":"node scripts/deploy.js"}}')
	write(installed + "/src/boilerplate.ts", 'export function OnGameModeStarted(): void { /* plain */ }\n')
	write(installed + "/scripts/deploy.js", 'throw new Error("never execute");')
	write(installed + "/scripts/utility.js", 'throw new Error("copy only, never execute");')
	write(installed + "/.env", "SESSION_ID=private-fixture-token")
	write(installed + "/LICENSE", "fixture license")
	write(installed + "/spatials/MP_Other.spatial.json", '{}')
	var full := Store.import_scene("res://levels/MP_Fixture.tscn", "Installed Template")
	expect(full.error.is_empty() and full.template_kind == "installed community template", "installed-first template routing")
	expect(FileAccess.get_file_as_string(full.project_root + "/src/index.ts").contains("/* plain */") and not FileAccess.file_exists(full.project_root + "/src/boilerplate.ts"), "plain initialization follows parent boilerplate behavior")
	expect(not FileAccess.file_exists(full.project_root + "/.env") and not FileAccess.file_exists(full.project_root + "/scripts/deploy.js"), "credentials and deploy script omitted")
	var full_package: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(full.project_root + "/package.json"))
	expect(not full_package.scripts.has("deploy") and full_package.templateVersion == "9.0.0", "deploy command removed and template version retained")
	expect(FileAccess.file_exists(full.project_root + "/spatials/template-samples/MP_Other.spatial.json") and not FileAccess.file_exists(full.project_root + "/spatials/MP_Other.spatial.json"), "sample spatial cannot masquerade as creator export")
	expect(FileAccess.file_exists(full.project_root + "/LICENSE") and FileAccess.file_exists(full.project_root + "/scripts/utility.js"), "template license and tooling preserved without execution")
	var second := Store.create_from_stock("res://levels/MP_Fixture.tscn", "my map")
	expect(second.error.is_empty() and second.project_name == "my map (2)", "case-insensitive collision creates unique folder")
	write(created.scene_path, copy + '\n[node name="UserEdit" type="Node3D" parent="."]\n')
	expect(FileAccess.get_sha256("res://levels/MP_Fixture.tscn") == stock_hash and FileAccess.get_sha256("res://static/MP_Fixture_Assets.tscn") == asset_hash, "creator edit preserves stock scene and referenced asset bytes")
	write("res://imports/relative.tscn", stock.replace("res://static/", "../static/"))
	var relative := Store.import_scene("res://imports/relative.tscn", "Relative")
	expect(relative.error.is_empty() and relative.rebased_references == 1, "relative references rebased safely")
	expect(FileAccess.get_file_as_string(relative.scene_path).contains('path="res://static/'), "copied reference points to installed resource")
	write("res://imports/missing.tscn", stock.replace("MP_Fixture_Assets", "Missing_Assets"))
	expect(not Store.import_scene("res://imports/missing.tscn", "Missing").error.is_empty(), "missing dependency rejected")
	write("res://imports/outside.tscn", stock.replace("res://static/MP_Fixture_Assets.tscn", "../../outside.tscn"))
	expect(not Store.inspect_scene("res://imports/outside.tscn").error.is_empty(), "relative escape outside SDK rejected")
	expect(not Store.inspect_scene("res://levels/MP_Fixture.tscn", "MP_Other").error.is_empty(), "conflicting base level rejected")
	expect(not Store.create_from_stock("res://imports/relative.tscn", "FakeStock").error.is_empty(), "nonstock create control rejected")
	for name in ["../escape", "CON", "Bad.", "experiences", "folder/name"]:
		expect(not Store.import_scene("res://levels/MP_Fixture.tscn", name).error.is_empty(), "unsafe project name rejected: " + name)
	write("res://bad/bf6-workspace.json", '{"formatVersion":99}')
	var bad_hash := FileAccess.get_sha256("res://bad/bf6-workspace.json")
	expect(not Store.import_scene("res://levels/MP_Fixture.tscn", "NoWrite", "res://bad").error.is_empty(), "unsupported workspace rejected")
	expect(FileAccess.get_sha256("res://bad/bf6-workspace.json") == bad_hash and not DirAccess.dir_exists_absolute("res://bad/saves"), "invalid workspace untouched and no fallback")
	expect(not Store.ensure_workspace("res://").error.is_empty(), "project root rejected")
	DirAccess.make_dir_absolute(Store.DEFAULT_WORKSPACE + "/.bf6-create-lock")
	expect(not Store.create_from_stock("res://levels/MP_Fixture.tscn", "Locked").error.is_empty(), "existing operation lock respected")
	expect(DirAccess.dir_exists_absolute(Store.DEFAULT_WORKSPACE + "/.bf6-create-lock"), "foreign lock retained")
	if DirAccess.dir_exists_absolute("res://linked-static"):
		write("res://imports/linked.tscn", stock.replace("res://static/", "res://linked-static/"))
		expect(not Store.inspect_scene("res://imports/linked.tscn").error.is_empty(), "junction dependency rejected")
		# Normal target still works, so rejection is attributable to the link.
		expect(Store.inspect_scene("res://levels/MP_Fixture.tscn").error.is_empty(), "real dependency control succeeds")
	print("CREATOR_STORE_RESULT " + JSON.stringify({"checks":checks,"failures":failures}))
	quit(1 if failures else 0)
