extends SceneTree

const Catalog = preload("../addons/bf6_map_selection/map_catalog.gd")
const MapPanel = preload("../addons/bf6_map_selection/map_panel.gd")
const PluginAdapter = preload("../addons/bf6_map_selection/plugin.gd")
var failures := 0
var checks := 0

class Preparation extends Node:
	const API_VERSION := 1
	signal editing_lock_changed(locked: bool)
	var calls: Array = []
	func open_preparation() -> void:
		calls.append("open")
	func prepare_levels(levels: Array, force: bool) -> bool:
		calls.append([levels, force])
		return levels == ["mp_fixture"] and not force

class UnsupportedPreparation extends Node:
	const API_VERSION := 2
	func open_preparation() -> void:
		assert(false, "Incompatible service must never be called")
	func prepare_levels(_levels: Array, _force: bool) -> bool:
		assert(false, "Incompatible service must never be called")
		return false

func _initialize() -> void:
	run.call_deferred()

func expect(condition: bool, description: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		push_error(description)

func write(path: String, content: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(content)

func manifest() -> Dictionary:
	return {"format": "bf6-creator-workspace", "formatVersion": 1, "workspaceId": "12345678-1234-5678-1234-567812345678", "layout": "bf6-unreal-project/1", "roots": {"projects": "saves", "experiences": "saves/experiences"}, "futureField": {"keep": true}}

func run() -> void:
	# These fixtures belong only in a disposable project, never the creator SDK.
	if ProjectSettings.get_setting("application/config/name", "") != "BF6MapSelectorTests":
		push_error("Run this suite in an isolated project named BF6MapSelectorTests.")
		quit(2)
		return
	var scene := '[gd_scene format=3]\n[node name="Fixture" type="Node3D"]\nmetadata/bf6_map_name = "Fixture Friendly Name"\n'
	write("res://levels/MP_Fixture.tscn", scene)
	write("res://User_Created/levels/Creator_Save.tscn", '[gd_scene format=3]\n[ext_resource type="PackedScene" path="res://static/MP_Fixture_Assets.tscn" id="1"]\n[node name="Authored" type="Node3D"]\ntransform = Transform3D(1,0,0,0,1,0,0,0,1,9,8,7)\n')
	write("res://levels/Bad.tscn", "not a scene")
	write("res://workspace/bf6-workspace.json", JSON.stringify(manifest()))
	write("res://workspace/saves/example/map.tscn", scene)
	var original := FileAccess.get_file_as_string("res://User_Created/levels/Creator_Save.tscn")
	var original_manifest := FileAccess.get_file_as_string("res://workspace/bf6-workspace.json")
	write("res://bf6-workspace.json", JSON.stringify(manifest()))
	expect(Catalog.workspace("res://").error.is_empty(), "The Godot project root itself can be a workspace")
	var stock := Catalog.scene_info("res://levels/MP_Fixture.tscn")
	expect(stock.name == "Fixture Friendly Name" and stock.level == "mp_fixture", "Metadata name and exact SDK identity are preserved")
	var authored := Catalog.scene_info("res://User_Created/levels/Creator_Save.tscn")
	expect(authored.level == "mp_fixture", "Authored scene map identity comes from its PackedScene reference")
	write("res://tests/ambiguous.tscn", '[gd_scene format=3]\n[ext_resource type="PackedScene" path="res://static/MP_Fixture_Assets.tscn" id="1"]\n[ext_resource type="PackedScene" path="res://static/MP_Other_Assets.tscn" id="2"]\n[node name="Mixed" type="Node3D"]\n')
	var mixed := Catalog.scene_info("res://tests/ambiguous.tscn")
	expect(mixed.error.is_empty() and mixed.level.is_empty(), "Ambiguous creator scenes retain an unknown map identity")
	expect(not Catalog.scene_info("res://levels/Bad.tscn").error.is_empty(), "Malformed scene header is rejected")
	for invalid in ["res://../outside.tscn", "user://map.tscn", "C:/outside/map.tscn", "res://a\\b.tscn", "res://NUL.tscn"]:
		expect(not Catalog.resource_error(invalid, true).is_empty(), "Reject unsafe scene path: " + invalid)
	var valid := Catalog.workspace(ProjectSettings.globalize_path("res://workspace"))
	expect(valid.error.is_empty() and valid.projects == "res://workspace/saves", "An existing in-project workspace uses the v1 contract")
	expect(not Catalog.workspace("C:/").error.is_empty(), "External workspace cannot silently mount or copy")
	var invalid_manifest := manifest()
	invalid_manifest.roots.projects = "../escape"
	write("res://invalid/bf6-workspace.json", JSON.stringify(invalid_manifest))
	expect(not Catalog.workspace("res://invalid").error.is_empty(), "Workspace traversal is rejected")
	invalid_manifest = manifest()
	invalid_manifest.godotMount = "res://workspace"
	invalid_manifest.roots.experiences = "somewhere_else"
	write("res://invalid/bf6-workspace.json", JSON.stringify(invalid_manifest))
	expect(not Catalog.workspace("res://invalid").error.is_empty(), "godotMount cannot override invalid contract roots")
	invalid_manifest = manifest()
	invalid_manifest.workspaceId = "00000000-0000-0000-0000-000000000000"
	write("res://invalid/bf6-workspace.json", JSON.stringify(invalid_manifest))
	expect(not Catalog.workspace("res://invalid").error.is_empty(), "Zero UUID is rejected")
	invalid_manifest = manifest()
	invalid_manifest.formatVersion = true
	write("res://invalid/bf6-workspace.json", JSON.stringify(invalid_manifest))
	expect(not Catalog.workspace("res://invalid").error.is_empty(), "Boolean format version cannot impersonate version 1")
	var catalog := Catalog.scan(valid.projects)
	expect(catalog.scenes.size() == 3, "Catalog finds SDK, creator, and workspace scenes without loading them")
	expect(catalog.errors.size() == 1, "Malformed scene is visible as a scan diagnostic")
	var panel := MapPanel.new()
	root.add_child(panel)
	await process_frame
	expect(not panel.home_state().actions[-1].visible, "Standalone Home hides preparation when High Poly is absent")
	expect(panel._official.get("maps", []).size() > 0, "Home reads the shared official map card catalog")
	expect(panel.home_state().groups.size() == 2 and not panel.home_state().has("projects") and panel.home_state().experiences.is_empty(), "Home supplies map groups without presenting local saves as Portal experiences")
	var has_stock_in_projects := false
	for record in panel._records:
		if record.kind == "SDK map": has_stock_in_projects = true
	expect(not has_stock_in_projects, "Resume records do not mix stock map templates into creator saves")
	var bad := UnsupportedPreparation.new()
	root.add_child(bad)
	bad.add_to_group(MapPanel.PREPARATION_GROUP)
	panel._discover_preparation()
	expect(not panel.home_state().actions[-1].visible, "Version 2 service is rejected")
	var good := Preparation.new()
	root.add_child(good)
	good.add_to_group(MapPanel.PREPARATION_GROUP)
	panel._discover_preparation()
	expect(panel.home_state().actions[-1].visible, "Version 1 service is discovered")
	panel._open_preparation()
	expect(good.calls == ["open"], "Prepare maps calls only the documented entry point")
	var opened: Array = []
	var created: Array = []
	panel.open_requested.connect(func(path: String): opened.append(path))
	panel.create_requested.connect(func(record: Dictionary): created.append(record.path))
	stock.kind = "SDK map"
	authored.kind = "Saved scene"
	panel._request_open(stock)
	expect(created == ["res://levels/MP_Fixture.tscn"] and opened.is_empty(), "Stock map selection requests Create instead of opening the original")
	panel._request_open(authored)
	expect(opened == ["res://User_Created/levels/Creator_Save.tscn"], "Creator selection opens its authored scene path")
	good.editing_lock_changed.emit(true)
	panel._request_open(stock)
	panel._request_open(authored)
	expect(opened.size() == 1 and created.size() == 1 and panel.home_state().busy and not panel.home_state().actions[0].enabled, "Preparation lock prevents Create, Open and import actions")
	good.editing_lock_changed.emit(false)
	good.free()
	panel._discover_preparation()
	expect(not panel.home_state().actions[-1].visible and not panel.home_state().busy and panel.home_state().actions[0].enabled, "Removing optional service restores standalone editing")
	panel.set_workspace("res://workspace")
	panel.set_workspace("res://invalid")
	expect(panel.workspace_root.is_empty() and panel.workspace_projects.is_empty(), "Invalid chosen workspace cannot silently keep stale workspace roots")
	expect(FileAccess.get_file_as_string("res://User_Created/levels/Creator_Save.tscn") == original, "Scanning/selecting preserved authored transforms and bytes")
	expect(FileAccess.get_file_as_string("res://workspace/bf6-workspace.json") == original_manifest, "Unknown workspace manifest fields and bytes were preserved")
	panel.free()
	bad.free()
	print("Map Selection: %d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
