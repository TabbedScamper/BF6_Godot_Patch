@tool
extends RefCounted

# Catalogs files without loading PackedScenes, their scripts, models, or textures.
# Display names and ordering come from Unreal's authored editor map manifest.
# Installed files remain the authority for whether a map can actually be opened.
const DISPLAY_CATALOG := "res://addons/bf6_map_selection/data/map_catalog.json"
const HEADER_LIMIT := 262144
const FILE_LIMIT := 20000
const DIRECTORY_LIMIT := 2000

static func display_catalog() -> Dictionary:
	var value: Variant = JSON.parse_string(FileAccess.get_file_as_string(DISPLAY_CATALOG)) if FileAccess.file_exists(DISPLAY_CATALOG) else null
	if value is Dictionary and value.get("maps") is Array and value.get("groups") is Array:
		return value
	return {"maps": [], "groups": [], "error": "The shared map catalog is missing or invalid. Reinstall Map Selection."}

static func official_maps() -> Dictionary:
	var display := display_catalog()
	var records: Array[Dictionary] = []
	var errors: Array[String] = []
	if display.has("error"):
		errors.append(display.error)
	for entry in display.maps:
		var record: Dictionary = entry.duplicate(true)
		record.path = "res://levels/" + str(entry.id) + ".tscn"
		record.level = str(entry.id).to_lower()
		record.kind = "SDK map"
		record.available = resource_error(record.path, true).is_empty()
		record.modified = 0
		records.append(record)
	return {"maps": records, "groups": display.groups, "errors": errors}

static func map_entry(level: String) -> Dictionary:
	for entry in display_catalog().maps:
		if str(entry.id).to_lower() == level.to_lower():
			return entry
	return {}

static func relative_error(path: String) -> String:
	if path.is_empty() or path.length() > 200 or path.begins_with("/") or path.contains("\\") or path.contains(":"):
		return "Use a relative folder with forward slashes."
	for component in path.split("/", true):
		if component in ["", ".", ".."] or component.ends_with(".") or component.ends_with(" "):
			return "Empty, parent, and ambiguous path components are not supported."
		for character in component:
			if character.unicode_at(0) < 32 or character in '<>"|?*':
				return "The folder contains an invalid path character."
		var device := component.get_slice(".", 0).to_upper()
		if device in ["CON", "PRN", "AUX", "NUL"] or (device.length() == 4 and device.left(3) in ["COM", "LPT"] and device.right(1) in "123456789"):
			return "Windows device names cannot be used as folders."
	return ""

static func resource_error(path: String, scene := false) -> String:
	if not path.begins_with("res://"):
		return "This folder is outside the open Godot project. Open a Godot project containing the workspace; no folders are copied or mounted automatically."
	var relative := path.trim_prefix("res://").trim_suffix("/")
	if not relative.is_empty():
		var error := relative_error(relative)
		if not error.is_empty():
			return error
		var cursor := "res://"
		for component in relative.split("/"):
			var directory := DirAccess.open(cursor)
			if directory != null and directory.is_link(component):
				return "Linked folders/files are not supported by the safe map selector."
			cursor = cursor.path_join(component)
	if scene and (path.get_extension().to_lower() != "tscn" or not FileAccess.file_exists(path)):
		return "Select an existing .tscn scene in this Godot project."
	return ""

static func workspace(root: String) -> Dictionary:
	var localized := ProjectSettings.localize_path(root)
	if localized != "res://":
		localized = localized.trim_suffix("/")
	var error := resource_error(localized)
	if not error.is_empty():
		return {"error": error}
	if not DirAccess.dir_exists_absolute(localized):
		return {"error": "The selected workspace folder does not exist."}
	var manifest_path := localized.path_join("bf6-workspace.json")
	error = resource_error(manifest_path)
	if not error.is_empty():
		return {"error": error}
	var file := FileAccess.open(manifest_path, FileAccess.READ)
	if file == null or file.get_length() > 1048576:
		return {"error": "Choose a folder containing a readable bf6-workspace.json (maximum 1 MB)."}
	var parser := JSON.new()
	if parser.parse(file.get_as_text()) != OK:
		return {"error": "The workspace manifest is not valid JSON."}
	var manifest: Variant = parser.data
	if not manifest is Dictionary or manifest.get("format") != "bf6-creator-workspace" or typeof(manifest.get("formatVersion")) not in [TYPE_INT, TYPE_FLOAT] or manifest.get("formatVersion") != 1 or manifest.get("layout") != "bf6-unreal-project/1":
		return {"error": "Unsupported workspace format. Expected bf6-creator-workspace version 1, layout bf6-unreal-project/1."}
	var uuid := RegEx.new()
	uuid.compile("^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
	var identity: Variant = manifest.get("workspaceId", "")
	if not identity is String or uuid.search(identity) == null or identity.replace("-", "").replace("0", "").is_empty():
		return {"error": "The workspace needs a nonzero, hyphenated UUID."}
	var roots: Variant = manifest.get("roots")
	if not roots is Dictionary:
		return {"error": "The workspace is missing its roots object."}
	for key in ["projects", "experiences"]:
		if not roots.get(key) is String:
			return {"error": "The workspace is missing its %s folder." % key}
		error = relative_error(roots[key])
		if not error.is_empty():
			return {"error": "%s: %s" % [key, error]}
		error = resource_error(localized.path_join(roots[key]))
		if not error.is_empty():
			return {"error": "%s: %s" % [key, error]}
	if roots.experiences != roots.projects + "/experiences":
		return {"error": "This workspace layout requires experiences inside projects/experiences."}
	return {"error": "", "root": localized, "projects": localized.path_join(roots.projects), "experiences": localized.path_join(roots.experiences), "workspace_id": identity}

static func scene_info(path: String) -> Dictionary:
	var error := resource_error(path, true)
	if not error.is_empty():
		return {"error": error}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"error": "Could not read scene header."}
	var first := file.get_line()
	if not first.begins_with("[gd_scene"):
		return {"error": "The file does not have a Godot scene header."}
	var attribute := RegEx.new()
	attribute.compile('(?:path|name)="([^"]+)"')
	var level := ""
	var ambiguous := false
	var friendly := ""
	var root_seen := false
	var declared_level := ""
	while not file.eof_reached() and file.get_position() < HEADER_LIMIT:
		var line := file.get_line()
		if line.begins_with("[node "):
			if root_seen:
				break
			root_seen = true
		if line.begins_with("[ext_resource") and line.contains('type="PackedScene"'):
			for match_ in attribute.search_all(line):
				var value: String = match_.get_string(1)
				if value.begins_with("res://static/") or value.begins_with("res://levels/"):
					var candidate := value.get_file().get_basename().trim_suffix("_Terrain").trim_suffix("_Assets")
					if candidate.to_lower().begins_with("mp_"):
						if not level.is_empty() and level.to_lower() != candidate.to_lower():
							ambiguous = true
						level = candidate
		if root_seen and line.begins_with("metadata/bf6_map_name = "):
			var name_value: Variant = JSON.parse_string(line.trim_prefix("metadata/bf6_map_name = "))
			if name_value is String and name_value.length() <= 160:
				friendly = name_value.strip_edges()
		if root_seen and line.begins_with("metadata/bf6_base_level = "):
			var base_value: Variant = JSON.parse_string(line.trim_prefix("metadata/bf6_base_level = "))
			if base_value is String and not map_entry(base_value).is_empty():
				declared_level = base_value
	var basename := path.get_file().get_basename()
	if not declared_level.is_empty():
		if not level.is_empty() and level.to_lower() != declared_level.to_lower():
			ambiguous = true
		elif not ambiguous:
			level = declared_level
	if ambiguous:
		level = ""
	if not ambiguous and level.is_empty() and path.get_base_dir() == "res://levels" and basename.to_lower().begins_with("mp_"):
		level = basename
	if friendly.is_empty():
		friendly = basename.trim_prefix("MP_").replace("_", " ").capitalize()
	return {"error": "", "path": path, "name": friendly, "level": level.to_lower(), "modified": FileAccess.get_modified_time(path)}

static func scan(extra_root := "") -> Dictionary:
	var result: Array[Dictionary] = []
	var errors: Array[String] = []
	var queue: Array[Dictionary] = [
		{"path": "res://levels", "kind": "SDK map", "recursive": false},
		{"path": "res://User_Created/levels", "kind": "Saved scene", "recursive": true},
		{"path": "res://levels/Custom_Maps", "kind": "Saved scene", "recursive": true}]
	if not extra_root.is_empty():
		queue.append({"path": extra_root, "kind": "Workspace scene", "recursive": true})
	var seen := {}
	var directories := 0
	var files := 0
	while not queue.is_empty():
		var entry: Dictionary = queue.pop_front()
		var path: String = entry.path
		if seen.has(path) or not resource_error(path).is_empty():
			continue
		seen[path] = true
		var directory := DirAccess.open(path)
		if directory == null:
			continue
		directories += 1
		if directories > DIRECTORY_LIMIT:
			errors.append("Scene scan reached its directory limit. Narrow the selected workspace.")
			break
		if entry.recursive:
			for folder in directory.get_directories():
				if not folder.begins_with(".") and not directory.is_link(folder):
					queue.append({"path": path.path_join(folder), "kind": entry.kind, "recursive": true})
		for name in directory.get_files():
			if name.get_extension().to_lower() != "tscn" or directory.is_link(name):
				continue
			files += 1
			if files > FILE_LIMIT:
				break
			var info := scene_info(path.path_join(name))
			if not info.error.is_empty():
				errors.append("%s: %s" % [name, info.error])
				continue
			info.kind = entry.kind
			result.append(info)
		if files > FILE_LIMIT:
			errors.append("Scene scan reached its file limit. Narrow the selected workspace.")
			break
	result.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		if a.kind != b.kind:
			return a.kind < b.kind
		if a.kind != "SDK map" and a.modified != b.modified:
			return a.modified > b.modified
		return a.name.naturalnocasecmp_to(b.name) < 0)
	return {"scenes": result, "errors": errors}
