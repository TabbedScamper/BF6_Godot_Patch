@tool
extends RefCounted

# Only this project's editor restore list changes. Authored scenes and the
# global scene-restore preference are never modified.
const SECTION := "BF6Home"
const VERSION := 1
const LIMIT := 1024 * 1024
const Catalog = preload("map_catalog.gd")

static func restore_tabs(previous: Dictionary) -> Dictionary:
	# EditorInterface refuses a new scene while the previous tab transition is
	# pending. Yield to the editor between opens, checking actual open tabs.
	var tree := EditorInterface.get_base_control().get_tree()
	var remaining := PackedStringArray()
	for path in scene_list(previous.get("scenes", PackedStringArray())):
		if not Catalog.resource_error(path).is_empty() or not FileAccess.file_exists(path):
			remaining.append(path)
			continue
		for attempt in 3:
			await tree.process_frame
			EditorInterface.open_scene_from_path(path)
			await tree.process_frame
			if path in EditorInterface.get_open_scenes():
				break
		if path not in EditorInterface.get_open_scenes():
			remaining.append(path)
	var current := str(previous.get("current", ""))
	if current in EditorInterface.get_open_scenes():
		await tree.process_frame
		EditorInterface.open_scene_from_path(current)
		await tree.process_frame
	return {"scenes": remaining, "current": current if current in remaining else ""}

static func restore_for_native(previous: Dictionary) -> void:
	# Static coroutine remains owned by the script/SceneTree when EditorPlugin
	# removal completes. It does not touch the removed plugin or its controls.
	await restore_tabs(previous)
	var issue := prepare_startup(true)
	if not issue.is_empty():
		push_warning(issue)

static func restore_for_home(owner: WeakRef, previous: Dictionary) -> void:
	var remaining := await restore_tabs(previous)
	var plugin: Object = owner.get_ref()
	if is_instance_valid(plugin):
		plugin._complete_tab_restore(previous, remaining)

static func enabled() -> bool:
	return bool(ProjectSettings.get_setting("bf6/home_first", true))

static func layout_path() -> String:
	return EditorInterface.get_editor_paths().get_project_settings_dir().path_join("editor_layout.cfg")

static func scene_list(value: Variant) -> PackedStringArray:
	var result := PackedStringArray()
	if not value is PackedStringArray and not value is Array:
		return result
	if value.size() > 256:
		return result
	for path in value:
		if not path is String or not path.begins_with("res://") or path.contains("\\") or path.trim_prefix("res://").split("/").has(".."):
			continue
		if path.get_extension().to_lower() not in ["tscn", "scn"] or path in result:
			continue
		result.append(path)
	return result

static func valid_list(value: Variant) -> bool:
	return (value is PackedStringArray or value is Array) and value.size() <= 256 and scene_list(value).size() == value.size()

static func stash(configuration: ConfigFile, allow_empty: bool = false, pending: Dictionary = {}) -> bool:
	var raw: Variant = configuration.get_value("EditorNode", "open_scenes", PackedStringArray())
	if not raw is PackedStringArray and not raw is Array:
		return false
	var scenes := scene_list(raw)
	if scenes.size() != raw.size():
		return false
	if configuration.has_section(SECTION) and int(configuration.get_value(SECTION, "format_version", VERSION)) != VERSION:
		return false
	var pending_raw: Variant = pending.get("scenes", PackedStringArray())
	if not valid_list(pending_raw) or not valid_list(configuration.get_value(SECTION, "deferred_scenes", PackedStringArray())):
		return false
	var combined := scene_list(pending_raw)
	for path in scenes:
		if path not in combined:
			combined.append(path)
	if combined.size() > 256:
		return false
	scenes = combined
	if not scenes.is_empty() or allow_empty:
		configuration.set_value(SECTION, "format_version", VERSION)
		configuration.set_value(SECTION, "deferred_scenes", scenes)
		var current: String = str(configuration.get_value("EditorNode", "current_scene", pending.get("current", "")))
		if current.is_empty():
			current = str(pending.get("current", ""))
		configuration.set_value(SECTION, "deferred_current_scene", current if current in scenes else "")
	configuration.set_value("EditorNode", "open_scenes", PackedStringArray())
	configuration.set_value("EditorNode", "current_scene", "")
	return true

static func release_native(configuration: ConfigFile, pending: Dictionary = {}) -> bool:
	if int(configuration.get_value(SECTION, "format_version", VERSION)) != VERSION:
		return false
	var pending_raw: Variant = pending.get("scenes", configuration.get_value(SECTION, "deferred_scenes", PackedStringArray()))
	if not valid_list(pending_raw) or not valid_list(configuration.get_value(SECTION, "deferred_scenes", PackedStringArray())):
		return false
	var scenes := scene_list(pending_raw)
	var raw: Variant = configuration.get_value("EditorNode", "open_scenes", PackedStringArray())
	if not raw is PackedStringArray and not raw is Array:
		return false
	var active := scene_list(raw)
	if active.size() != raw.size():
		return false
	for path in active:
		if path not in scenes:
			scenes.append(path)
	if scenes.size() > 256:
		return false
	var current := str(configuration.get_value("EditorNode", "current_scene", ""))
	if current not in scenes:
		current = str(pending.get("current", configuration.get_value(SECTION, "deferred_current_scene", "")))
	configuration.set_value("EditorNode", "open_scenes", scenes)
	configuration.set_value("EditorNode", "current_scene", current if current in scenes else "")
	for key in ["format_version", "deferred_scenes", "deferred_current_scene"]:
		if configuration.has_section_key(SECTION, key):
			configuration.erase_section_key(SECTION, key)
	return true

static func previous() -> Dictionary:
	var configuration := ConfigFile.new()
	if configuration.load(layout_path()) != OK or int(configuration.get_value(SECTION, "format_version", 0)) != VERSION:
		return {"scenes": PackedStringArray(), "current": ""}
	return {"scenes": scene_list(configuration.get_value(SECTION, "deferred_scenes", PackedStringArray())), "current": str(configuration.get_value(SECTION, "deferred_current_scene", ""))}

static func prepare_startup(releasing: bool = false) -> String:
	var path := layout_path()
	if not FileAccess.file_exists(path):
		return ""
	# The engine initializes FileAccess's safe-save policy before plugins. On
	# Windows that policy stages beside the target and publishes with ReplaceFileW.
	# Respect the user's existing preference; never enable a global setting here.
	var settings := EditorInterface.get_editor_settings()
	if not settings.get_setting("filesystem/on_save/safe_save_on_backup_then_rename"):
		return "Home-first startup needs Godot's existing safe-save option to preserve the editor layout safely. Previous tabs were left unchanged."
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > LIMIT:
		return "Previous scene tabs were left unchanged because their editor layout could not be read safely."
	var original := file.get_buffer(file.get_length())
	file.close()
	var configuration := ConfigFile.new()
	if configuration.parse(original.get_string_from_utf8()) != OK:
		return "Previous scene tabs were left unchanged because their editor layout is invalid."
	if releasing or not enabled():
		if not configuration.has_section_key(SECTION, "deferred_scenes"):
			return ""
		if not release_native(configuration):
			return "Previous scene tabs were left unchanged because their stored session format is unsupported."
	else:
		var raw: Variant = configuration.get_value("EditorNode", "open_scenes", PackedStringArray())
		var scenes := scene_list(raw)
		if scenes.is_empty():
			return ""
		if scenes.size() != raw.size():
			return "Previous scene tabs were left unchanged because their restore list contains unsupported paths."
		var pending := {"scenes": configuration.get_value(SECTION, "deferred_scenes", PackedStringArray()), "current": configuration.get_value(SECTION, "deferred_current_scene", "")}
		if not stash(configuration, false, pending):
			return "Previous scene tabs were left unchanged because their stored session format is unsupported."
	var digest := FileAccess.get_sha256(path)
	var backup := path + ".bf6-home." + digest + ".bak"
	if FileAccess.file_exists(backup):
		if FileAccess.get_sha256(backup) != digest:
			return "Previous scene tabs were left unchanged because their layout backup conflicts."
	else:
		var output := FileAccess.open(backup, FileAccess.WRITE)
		if output == null:
			return "Previous scene tabs were left unchanged because their layout backup could not be created."
		output.store_buffer(original)
		output.close()
		if FileAccess.get_sha256(backup) != digest:
			return "Previous scene tabs were left unchanged because their layout backup could not be verified."
	if FileAccess.get_sha256(path) != digest:
		return "Previous scene tabs were left unchanged because the editor layout changed during startup."
	if configuration.save(path) != OK:
		return "Home-first startup could not save the editor layout; its original backup was preserved."
	var verified := ConfigFile.new()
	if verified.load(path) != OK or verified.encode_to_text() != configuration.encode_to_text():
		return "Home-first startup could not verify the editor layout; its original backup was preserved."
	return ""
