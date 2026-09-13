@tool
extends RefCounted

# Creates a NEW authored TSCN in the parent's existing standalone project layout.
# No PackedScene loading, script execution, ResourceSaver rewriting, Unreal session
# fabrication, or source/asset modification. A cooperative workspace lock prevents
# two plugin operations from choosing the same destination. This is not a sandbox
# against another process changing filesystem parents during an operation.
const Catalog = preload("res://addons/bf6_map_selection/map_catalog.gd")
const DEFAULT_WORKSPACE := "res://User_Created/workspaces/Creators"
const MAX_SCENE_BYTES := 64 * 1024 * 1024
const MAX_REFERENCES := 20000
const BUNDLED_TEMPLATE := "res://addons/bf6_map_selection/template"
const PROJECT_FOLDERS := ["maps", "spatials", "unreal/tscn", "unreal/blockly", "unreal/ui", "unreal/bindings", "unreal/settings", "dist"]
const TEMPLATE_ROOT_FILES := ["package.json", "package-lock.json", "tsconfig.json", "eslint.config.mjs", ".prettierrc.json", ".gitignore", "LICENSE", "README.md"]

static func _template_root() -> String:
	var projects := "res://User_Created/projects"
	var directory := DirAccess.open(projects)
	var chosen := ""
	if directory != null:
		for name in directory.get_directories():
			var candidate := projects.path_join(name)
			if name.begins_with("_template") and FileAccess.file_exists(candidate.path_join("package.json")) and candidate > chosen:
				chosen = candidate
	return BUNDLED_TEMPLATE if chosen.is_empty() else chosen

static func _file_snapshot(path: String, maximum := 16 * 1024 * 1024) -> Dictionary:
	var error := _path_error(path, true)
	if not error.is_empty(): return _failure(error)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() > maximum: return _failure("Cannot read file, or file exceeds the import limit: " + path)
	var bytes := file.get_buffer(file.get_length())
	file.close()
	return {"error":"", "bytes":bytes, "source":path, "sha256":_hash(bytes)}

static func _prepare_template(name: String, companions: Dictionary) -> Dictionary:
	var root := _template_root()
	var error := _path_error(root)
	if not error.is_empty(): return _failure(error)
	if not FileAccess.file_exists(root.path_join("package.json")):
		return _failure("The scripting template is missing. Install the Godot Patch template files before creating a project.")
	var pending: Array[String] = [""]
	var files := {}
	var sources: Array[Dictionary] = []
	var total := 0
	while not pending.is_empty():
		var relative: String = pending.pop_front()
		var directory := DirAccess.open(root.path_join(relative))
		if directory == null: return _failure("Cannot inspect scripting template folder: " + relative)
		for folder in directory.get_directories():
			if folder in ["node_modules", ".git", "dist"] or folder.begins_with("."): continue
			if relative.is_empty() and folder not in ["src", "scripts", "spatials"]: continue
			var sub := relative.path_join(folder)
			error = _path_error(root.path_join(sub))
			if not error.is_empty(): return _failure(error)
			pending.append(sub)
		for filename in directory.get_files():
			if relative.is_empty() and filename not in TEMPLATE_ROOT_FILES: continue
			if filename.begins_with(".env") or filename == "deploy.js": continue
			var source_relative := relative.path_join(filename)
			var snapshot := _file_snapshot(root.path_join(source_relative))
			if not snapshot.error.is_empty(): return snapshot
			total += snapshot.bytes.size()
			if total > 128 * 1024 * 1024 or files.size() >= 10000: return _failure("The scripting template exceeds the safe copy limit.")
			var destination := source_relative
			if relative == "spatials": destination = "spatials/template-samples/" + filename
			files[destination] = snapshot.bytes
			sources.append({"source":snapshot.source,"sha256":snapshot.sha256,"destination":destination,"kind":"template"})
	for required in ["package.json", "package-lock.json", "tsconfig.json", "src/index.ts", "src/strings.json"]:
		if not files.has(required): return _failure("The scripting template is incomplete: " + required)
	var package: Variant = JSON.parse_string(files["package.json"].get_string_from_utf8())
	if not package is Dictionary or not package.get("scripts") is Dictionary or not package.scripts.get("build") is String:
		return _failure("The scripting template package has no supported build command.")
	var template_version: String = str(package.get("version", ""))
	package.templateVersion = template_version
	package.experienceName = name
	package.description = ""
	package.version = "1.0.0"
	var slug := RegEx.new()
	slug.compile("[^a-z0-9]+")
	package.name = slug.sub(name.to_lower(), "-", true).trim_prefix("-").trim_suffix("-")
	if package.name.is_empty(): package.name = "portal-experience"
	for field in ["repository", "bugs", "homepage"]: package.erase(field)
	for command in package.scripts.keys():
		if str(command).begins_with("deploy"): package.scripts.erase(command)
	files["package.json"] = (JSON.stringify(package, "  ") + "\n").to_utf8_buffer()
	if files.has("src/boilerplate.ts"):
		files["src/index.ts"] = files["src/boilerplate.ts"]
		files.erase("src/boilerplate.ts")
	var companion_files: Array[Dictionary] = []
	for kind in companions:
		if kind not in ["script", "strings", "blocks", "ui"] or not companions[kind] is String:
			return _failure("Choose explicit script, strings, blocks or UI companion files.")
		var path: String = companions[kind]
		if path.is_empty(): continue
		if path.get_extension().to_lower() != ("ts" if kind == "script" else "json"):
			return _failure("Wrong file type for companion: " + str(kind))
		var snapshot := _file_snapshot(path, MAX_SCENE_BYTES)
		if not snapshot.error.is_empty(): return snapshot
		var text: String = snapshot.bytes.get_string_from_utf8()
		if text.to_utf8_buffer() != snapshot.bytes: return _failure("Companions must contain valid UTF-8 text.")
		if kind == "script":
			# A standalone script can be preserved exactly. Module graphs need the
			# deliberate full-project importer; never silently drop dependencies.
			var imports := RegEx.new()
			imports.compile('\\b(?:import|require)\\s*(?:[({*"\']|[A-Za-z_$])|\\bexport\\b[^;\\n]*\\bfrom\\s*["\']')
			if imports.search(text) != null: return _failure("This TypeScript file imports dependencies. Import its complete source project instead; a single-file import would lose modules.")
		else:
			var parsed := JSON.new()
			if parsed.parse(text) != OK or not parsed.data is Dictionary: return _failure("The %s companion must be a JSON object; its contents were not imported." % kind)
		var destination: String = {"script":"src/index.ts", "strings":"src/strings.json", "blocks":"unreal/blockly/workspace.json", "ui":"unreal/ui/" + path.get_file()}[kind]
		error = Catalog.relative_error(destination)
		if not error.is_empty(): return _failure(error)
		files[destination] = snapshot.bytes
		var entry := {"source":path,"sha256":snapshot.sha256,"destination":destination,"kind":kind}
		sources.append(entry)
		companion_files.append(entry)
	return {"error":"", "root":root, "kind":"bundled starter" if root == BUNDLED_TEMPLATE else "installed community template",
		"version":template_version,"files":files,"sources":sources,"companions":companion_files}

static func _failure(message: String) -> Dictionary:
	return {"error": message}

static func _absolute(path: String) -> String:
	return ProjectSettings.globalize_path(path) if path.begins_with("res://") else path.replace("\\", "/")

static func _path_error(path: String, must_exist := false) -> String:
	var absolute := _absolute(path)
	if not absolute.is_absolute_path() or absolute.begins_with("//"):
		return "Choose a local absolute path or a res:// path in the open SDK."
	if absolute.simplify_path() != absolute.trim_suffix("/") and not absolute.ends_with(":/"):
		return "Use the real path without parent or duplicate path components."
	if absolute.to_utf8_buffer().has(0):
		return "Invalid path character."
	var current := absolute.trim_suffix("/")
	while not current.is_empty() and not current.ends_with(":") and current != "/":
		var parent := current.get_base_dir()
		if parent == current: break
		var directory := DirAccess.open(parent)
		if directory != null:
			var leaf := current.get_file()
			if directory.is_link(leaf):
				return "Linked files and folders are not supported. Choose the real path: " + current
			if FileAccess.file_exists(current) or DirAccess.dir_exists_absolute(current):
				var found := false
				for entry in directory.get_directories() + directory.get_files():
					if entry.nocasecmp_to(leaf) == 0:
						found = true
						break
				if not found: return "Path aliases are not supported: " + current
		current = parent
	if must_exist and not FileAccess.file_exists(absolute): return "The source file does not exist."
	return ""

static func _hash(bytes: PackedByteArray) -> String:
	var context := HashingContext.new()
	context.start(HashingContext.HASH_SHA256)
	context.update(bytes)
	return context.finish().hex_encode()

static func _read_scene(path: String) -> Dictionary:
	var error := _path_error(path, true)
	if not error.is_empty(): return _failure(error)
	if path.get_extension().to_lower() != "tscn": return _failure("Choose an authored .tscn scene.")
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null or file.get_length() == 0 or file.get_length() > MAX_SCENE_BYTES:
		return _failure("The scene must be readable and between 1 byte and 64 MiB.")
	var bytes := file.get_buffer(file.get_length())
	file.close()
	var text := bytes.get_string_from_utf8()
	if text.to_utf8_buffer() != bytes: return _failure("The scene must contain valid UTF-8 text.")
	if text.begins_with("\ufeff"): text = text.substr(1)
	var first := text.get_slice("\n", 0).trim_suffix("\r")
	if not first.begins_with("[gd_scene ") or not first.ends_with("]"):
		return _failure("The file does not contain a supported Godot scene header.")
	if not text.contains("\n[node "):
		return _failure("The scene does not contain an authored root node.")
	return {"error": "", "text": text, "sha256": _hash(bytes)}

static func _stock_level(candidate: String) -> String:
	if not candidate.to_lower().begins_with("mp_") or candidate.contains("/") or candidate.contains("\\"): return ""
	var directory := DirAccess.open("res://levels")
	if directory == null: return ""
	for name in directory.get_files():
		if name.get_extension().to_lower() == "tscn" and name.get_basename().nocasecmp_to(candidate) == 0 and not directory.is_link(name):
			return name.get_basename()
	return ""

static func inspect_scene(source_path: String, base_level_hint := "") -> Dictionary:
	var read := _read_scene(source_path)
	if not read.error.is_empty(): return read
	var lines: PackedStringArray = read.text.split("\n", true)
	var uid := RegEx.new()
	uid.compile('\\s+uid\\s*=\\s*"[^"\\r\\n]*"')
	var root_uid_removed := uid.search(lines[0]) != null
	lines[0] = uid.sub(lines[0], "", true)
	var path_attribute := RegEx.new()
	path_attribute.compile('\\bpath\\s*=\\s*("(?:[^"\\\\]|\\\\.)*")')
	var scene_type := RegEx.new()
	scene_type.compile('\\btype\\s*=\\s*"PackedScene"')
	var base_levels: Array[String] = []
	var references := 0
	var rebased := 0
	var quote_open := false
	var root_index := -1
	var in_root := false
	var metadata_level := ""
	var metadata_index := -1
	for i in range(1, lines.size()):
		var line := lines[i]
		if not quote_open:
			if line.begins_with("["):
				in_root = false
				if root_index < 0 and line.begins_with("[node "):
					root_index = i
					in_root = true
			if in_root and line.get_slice("=", 0).strip_edges() == "metadata/bf6_base_level":
				if metadata_index >= 0: return _failure("The root contains duplicate base level metadata.")
				var declaration := line.split("=", true, 1)
				if declaration.size() != 2 or declaration[0].strip_edges() != "metadata/bf6_base_level":
					return _failure("The root base level metadata is not supported.")
				var value: Variant = JSON.parse_string(declaration[1].strip_edges())
				if not value is String: return _failure("The root base level metadata must name an installed SDK map.")
				metadata_level = _stock_level(value)
				if metadata_level.is_empty(): return _failure("The root base level metadata names an unknown SDK map.")
				metadata_index = i
				if not base_levels.has(metadata_level): base_levels.append(metadata_level)
		# Ignore tag-like text inside quoted property strings.
		if not quote_open and line.begins_with("[ext_resource"):
			references += 1
			if references > MAX_REFERENCES: return _failure("The scene contains too many external resources.")
			if not line.strip_edges().ends_with("]"):
				return _failure("Multiline external resource declarations are not supported yet.")
			var match_ := path_attribute.search(line)
			if match_ == null: return _failure("Every external resource must have a readable path; UID-only resources cannot be copied safely.")
			if path_attribute.search_all(line).size() != 1: return _failure("An external resource has ambiguous path attributes.")
			var reference = JSON.parse_string(match_.get_string(1))
			if not reference is String or reference.is_empty(): return _failure("An external resource path cannot be decoded safely.")
			var resolved: String
			if reference.begins_with("res://"):
				resolved = reference
			elif reference.contains(":") or reference.begins_with("/") or reference.contains("\\"):
				return _failure("External resource paths must use res:// or relative paths: " + reference)
			else:
				resolved = ProjectSettings.localize_path(_absolute(source_path).get_base_dir().path_join(reference).simplify_path())
				if not resolved.begins_with("res://"):
					return _failure("Relative resource is outside the open SDK. Move/import that dependency deliberately first: " + reference)
				rebased += 1
			var error := Catalog.resource_error(resolved)
			if error.is_empty(): error = _path_error(resolved, true)
			if not error.is_empty(): return _failure("Cannot preserve external resource %s: %s" % [reference, error])
			if scene_type.search(line) != null and (resolved.begins_with("res://static/") or resolved.begins_with("res://levels/")):
				var candidate := resolved.get_file().get_basename().trim_suffix("_Terrain").trim_suffix("_Assets")
				var canonical := _stock_level(candidate)
				if not canonical.is_empty() and not base_levels.has(canonical): base_levels.append(canonical)
			# Bind verified paths, not copied UIDs that might resolve to a different resource in this SDK.
			line = line.substr(0, match_.get_start(1)) + JSON.stringify(resolved) + line.substr(match_.get_end(1))
			lines[i] = uid.sub(line, "", true)
		# Godot serializes quotes with backslash escaping. Track them without loading the scene.
		var escaped := false
		for character in lines[i]:
			if escaped: escaped = false
			elif character == "\\": escaped = true
			elif character == '"': quote_open = not quote_open
	if quote_open: return _failure("The scene contains an unterminated string.")
	var localized := ProjectSettings.localize_path(_absolute(source_path))
	if localized.get_base_dir() == "res://levels":
		var source_level := _stock_level(localized.get_file().get_basename())
		if not source_level.is_empty() and not base_levels.has(source_level): base_levels.append(source_level)
	if base_levels.size() > 1: return _failure("The scene refers to more than one base map; its level identity is ambiguous.")
	var hinted := _stock_level(base_level_hint)
	if not base_level_hint.is_empty() and hinted.is_empty(): return _failure("The selected base level is not an installed SDK map.")
	if not hinted.is_empty() and not base_levels.is_empty() and base_levels[0] != hinted:
		return _failure("The selected base level disagrees with the scene's map resources.")
	var level: String = base_levels[0] if not base_levels.is_empty() else hinted
	if level.is_empty(): return _failure("Could not identify the base map. Select its installed SDK level before importing.")
	if root_index < 0: return _failure("Could not identify the authored root node.")
	var metadata := "metadata/bf6_base_level = " + JSON.stringify(level)
	if metadata_index >= 0: lines[metadata_index] = metadata
	else: lines.insert(root_index + 1, metadata)
	return {"error": "", "source_path": _absolute(source_path), "source_sha256": read.sha256, "level": level,
		"suggested_name": source_path.get_file().get_basename(), "scene_bytes": "\n".join(lines).to_utf8_buffer(),
		"root_uid_removed": root_uid_removed, "references": references, "rebased_references": rebased}

static func _uuid() -> String:
	var bytes := Crypto.new().generate_random_bytes(16)
	bytes[6] = (bytes[6] & 15) | 64
	bytes[8] = (bytes[8] & 63) | 128
	var hex := bytes.hex_encode()
	return "%s-%s-%s-%s-%s" % [hex.substr(0,8), hex.substr(8,4), hex.substr(12,4), hex.substr(16,4), hex.substr(20,12)]

static func _write_new(path: String, bytes: PackedByteArray) -> String:
	var error := _path_error(path)
	if not error.is_empty(): return error
	if FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path): return "Refusing to overwrite " + path
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null: return "Cannot create " + path
	file.store_buffer(bytes)
	file.flush()
	var io_error := file.get_error()
	file.close()
	if io_error != OK or FileAccess.get_sha256(path) != _hash(bytes): return "New file could not be verified: " + path
	return ""

static func _name_error(name: String) -> String:
	if name.is_empty() or name.length() > 80 or name.contains("/") or name.to_lower() == "experiences":
		return "Choose a project name of 1 to 80 characters; 'experiences' is reserved."
	return Catalog.relative_error(name)

static func create_from_stock(source_path: String, project_name: String, workspace_root := DEFAULT_WORKSPACE) -> Dictionary:
	var localized := ProjectSettings.localize_path(_absolute(source_path))
	if localized.get_base_dir() != "res://levels": return _failure("New projects must start from a stock map in res://levels.")
	return import_scene(source_path, project_name, workspace_root)

static func preview_import(source_path: String, project_name := "", workspace_root := DEFAULT_WORKSPACE, base_level_hint := "", companions: Dictionary = {}) -> Dictionary:
	var prepared := inspect_scene(source_path, base_level_hint)
	if not prepared.error.is_empty(): return prepared
	var name: String = project_name if not project_name.is_empty() else prepared.suggested_name + " Project"
	var error := _name_error(name)
	if not error.is_empty(): return _failure(error)
	var root := ProjectSettings.localize_path(_absolute(workspace_root)).trim_suffix("/")
	if root == "res:" or not root.begins_with("res://"): return _failure("Choose a workspace folder inside the open Godot SDK.")
	error = Catalog.resource_error(root)
	if error.is_empty(): error = _path_error(root)
	if not error.is_empty(): return _failure(error)
	if FileAccess.file_exists(root.path_join("bf6-workspace.json")):
		var workspace := _validate_workspace(root)
		if not workspace.error.is_empty(): return workspace
	var template := _prepare_template(name, companions)
	if not template.error.is_empty(): return template
	var files: Array[Dictionary] = [{"source":source_path,"destination":"unreal/tscn/" + prepared.level + ".tscn","kind":"scene"}]
	for destination in template.files:
		files.append({"source":template.root,"destination":destination,"kind":"template"})
	for companion in template.companions:
		for entry in files:
			if entry.destination == companion.destination:
				entry.source = companion.source
				entry.kind = companion.kind
	return {"error":"", "level":prepared.level,"project_name":name,"workspace_root":root,
		"template_root":template.root,"template_kind":template.kind,"files":files,
		"note":"Files go into a new uniquely named project. Originals are preserved. JSON companions are checked for readable object syntax; runtime behavior still needs testing."}

# Startup may establish a workspace, but never creates a creator project or saves folder.
static func ensure_workspace(workspace_root := DEFAULT_WORKSPACE) -> Dictionary:
	var root := ProjectSettings.localize_path(_absolute(workspace_root)).trim_suffix("/")
	if root == "res:" or not root.begins_with("res://"):
		return _failure("Choose a workspace folder inside the open Godot SDK, not the project root.")
	var error := Catalog.resource_error(root)
	if error.is_empty(): error = _path_error(root)
	if not error.is_empty(): return _failure(error)
	var manifest_path := root.path_join("bf6-workspace.json")
	if FileAccess.file_exists(manifest_path): return _validate_workspace(root)
	if DirAccess.dir_exists_absolute(manifest_path): return _failure("The workspace manifest path is a folder.")
	if DirAccess.make_dir_recursive_absolute(root) != OK: return _failure("Cannot create workspace folder.")
	var lock_path := root.path_join(".bf6-create-lock")
	if DirAccess.make_dir_absolute(lock_path) != OK: return _failure("A workspace creation is already active. Nothing was overwritten.")
	var result := _ensure_locked(root)
	if _path_error(lock_path).is_empty(): DirAccess.remove_absolute(lock_path)
	return result

static func _validate_workspace(root: String) -> Dictionary:
	var error := _path_error(root.path_join("bf6-workspace.json"), true)
	if not error.is_empty(): return _failure(error)
	var workspace := Catalog.workspace(root)
	if not workspace.error.is_empty(): return workspace
	for path in [workspace.projects, workspace.experiences]:
		error = _path_error(path)
		if not error.is_empty(): return _failure(error)
	return workspace

static func _ensure_locked(root: String) -> Dictionary:
	if not FileAccess.file_exists(root.path_join("bf6-workspace.json")):
		var manifest := {"format":"bf6-creator-workspace", "formatVersion":1, "workspaceId":_uuid(),
			"layout":"bf6-unreal-project/1", "roots":{"projects":"saves", "experiences":"saves/experiences"}, "godotMount":root}
		var error := _write_new(root.path_join("bf6-workspace.json"), (JSON.stringify(manifest, "  ") + "\n").to_utf8_buffer())
		if not error.is_empty(): return _failure(error)
	return _validate_workspace(root)

static func import_scene(source_path: String, project_name := "", workspace_root := DEFAULT_WORKSPACE, base_level_hint := "", companions: Dictionary = {}) -> Dictionary:
	var prepared := inspect_scene(source_path, base_level_hint)
	if not prepared.error.is_empty(): return prepared
	var name: String = project_name if not project_name.is_empty() else prepared.suggested_name + " Project"
	var error := _name_error(name)
	if not error.is_empty(): return _failure(error)
	var template := _prepare_template(name, companions)
	if not template.error.is_empty(): return template
	prepared.template = template
	var root := ProjectSettings.localize_path(_absolute(workspace_root)).trim_suffix("/")
	if root == "res:" or not root.begins_with("res://"): return _failure("Choose a workspace folder inside the open Godot SDK, not the project root.")
	error = Catalog.resource_error(root)
	if error.is_empty(): error = _path_error(root)
	if not error.is_empty(): return _failure(error)
	var manifest_path := root.path_join("bf6-workspace.json")
	var workspace := {}
	var new_workspace := not FileAccess.file_exists(manifest_path)
	if DirAccess.dir_exists_absolute(manifest_path): return _failure("The workspace manifest path is a folder.")
	if not new_workspace:
		workspace = _validate_workspace(root)
		if not workspace.error.is_empty(): return workspace
		for path in [workspace.projects, workspace.experiences]:
			error = _path_error(path)
			if not error.is_empty(): return _failure(error)
	# Validate everything above before creating any folder.
	if DirAccess.make_dir_recursive_absolute(root) != OK: return _failure("Cannot create workspace folder.")
	error = _path_error(root)
	if not error.is_empty(): return _failure(error)
	var lock_path := root.path_join(".bf6-create-lock")
	if DirAccess.make_dir_absolute(lock_path) != OK:
		return _failure("Another creation may be active. The workspace creation lock already exists; nothing was overwritten.")
	var result := _create_locked(prepared, name, root, workspace, new_workspace)
	# Remove only our own empty lock, never creator files or an unknown staging directory.
	if _path_error(lock_path).is_empty(): DirAccess.remove_absolute(lock_path)
	return result

static func _create_locked(prepared: Dictionary, requested_name: String, root: String, workspace: Dictionary, new_workspace: bool) -> Dictionary:
	if FileAccess.get_sha256(prepared.source_path) != prepared.source_sha256:
		return _failure("The source scene changed during inspection. Try again; nothing was imported.")
	for source in prepared.template.sources:
		if not _path_error(source.source, true).is_empty() or FileAccess.get_sha256(source.source) != source.sha256:
			return _failure("A template or companion source changed during inspection. Try again; no project was imported.")
	var checked := _ensure_locked(root) if new_workspace else _validate_workspace(root)
	if not checked.error.is_empty(): return checked
	if not new_workspace and checked != workspace: return _failure("The workspace selection changed during creation. Try again.")
	workspace = checked
	var projects: String = workspace.projects
	if DirAccess.make_dir_recursive_absolute(projects) != OK: return _failure("Cannot create the projects folder.")
	var directory := DirAccess.open(projects)
	if directory == null: return _failure("Cannot inspect existing project names.")
	var names := {}
	for entry in directory.get_directories() + directory.get_files(): names[entry.to_lower()] = true
	var name := requested_name
	var suffix := 2
	while names.has(name.to_lower()):
		name = requested_name + " (" + str(suffix) + ")"
		suffix += 1
		if suffix > 10000: return _failure("Too many projects share that name. Choose another name.")
	var project_root := projects.path_join(name)
	var error := _path_error(project_root)
	if not error.is_empty(): return _failure(error)
	# Claim a new directory atomically. A collision fails rather than using an existing folder.
	if DirAccess.make_dir_absolute(project_root) != OK: return _failure("The chosen project folder appeared during creation. Try again.")
	for folder in PROJECT_FOLDERS:
		if DirAccess.make_dir_recursive_absolute(project_root.path_join(folder)) != OK:
			return _failure("Could not create a project folder. The incomplete project was retained: " + project_root)
	for relative in prepared.template.files:
		var destination := project_root.path_join(relative)
		if DirAccess.make_dir_recursive_absolute(destination.get_base_dir()) != OK:
			return _failure("Could not create a template folder. The incomplete project was retained: " + project_root)
		error = _write_new(destination, prepared.template.files[relative])
		if not error.is_empty(): return _failure(error + " The incomplete project was retained: " + project_root)
	var scene_dir := project_root.path_join("unreal/tscn")
	if DirAccess.make_dir_recursive_absolute(scene_dir) != OK:
		return _failure("Could not finish the new project folder. The incomplete folder was retained: " + project_root)
	var scene_path := scene_dir.path_join(prepared.level + ".tscn")
	error = _write_new(scene_path, prepared.scene_bytes)
	if not error.is_empty(): return _failure(error + " The incomplete project folder was retained: " + project_root)
	var now := Time.get_datetime_string_from_system(true) + "Z"
	var manifest := {"manifest":"bf6-unreal-project", "manifestVersion":1, "save":name,
		"levels":[prepared.level], "primaryLevel":prepared.level, "created":now, "modified":now,
		"artefacts":[{"path":"unreal/tscn/" + prepared.level + ".tscn", "kind":"tscn", "level":prepared.level,
			"bytes":prepared.scene_bytes.size(), "md5":FileAccess.get_md5(scene_path), "modified":now}],
		"template":{"name":prepared.template.kind,"version":prepared.template.version},
		"missing":["session: authored Godot scene only; no Unreal session has been generated", "spatial: no Portal export has been generated"]}
	if not prepared.template.files.has("unreal/blockly/workspace.json"):
		manifest.missing.append("workspace: no original editable Blockly document was supplied")
	for relative in prepared.template.files:
		var kind := ""
		if relative == "src/index.ts": kind = "script"
		elif relative == "src/strings.json": kind = "strings"
		elif relative == "unreal/blockly/workspace.json": kind = "workspace"
		elif relative.begins_with("unreal/ui/"): kind = "ui"
		if not kind.is_empty():
			manifest.artefacts.append({"path":relative,"kind":kind,"bytes":prepared.template.files[relative].size(),"md5":FileAccess.get_md5(project_root.path_join(relative)),"modified":now})
	error = _write_new(project_root.path_join("project.json"), (JSON.stringify(manifest, "  ") + "\n").to_utf8_buffer())
	if not error.is_empty(): return _failure(error + " The authored scene was retained: " + scene_path)
	return {"error":"", "scene_path":scene_path, "project_root":project_root, "workspace_root":root,
		"project_name":name, "level":prepared.level, "source_sha256":prepared.source_sha256,
		"root_uid_removed":prepared.root_uid_removed, "rebased_references":prepared.rebased_references,
		"template_root":prepared.template.root,"template_kind":prepared.template.kind,"companions":prepared.template.companions}
