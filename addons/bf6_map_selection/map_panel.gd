@tool
extends PanelContainer
## The shared parent Home HTML owns presentation; host-owned IDs resolve paths.
signal open_requested(path: String)
signal create_requested(record: Dictionary)
signal import_requested
signal workspace_requested
signal workspace_cleared
signal saves_requested
const Catalog = preload("map_catalog.gd")
const PREPARATION_GROUP := "bf6_highpoly_preparation_v1"
const BRIDGE := """(()=>{const send=window.ipc&&window.ipc.postMessage.bind(window.ipc);if(!send)return;window.bf6HomeHostPost=(text)=>{try{const home=typeof text==='string'?JSON.parse(text):text;if(home&&home.channel==='bf6-home')send(JSON.stringify({channel:'bf6-offline-v1',payload:{op:'log',home}}));}catch(_){}};})();"""
var workspace_projects := ""
var workspace_root := ""
var _records: Array[Dictionary] = []
var _official: Dictionary = {}
var _service: Node
var _locked := false
var _status_text := ""
var _browser_ready := false
var _disposed := false
var _save_lookup: Dictionary = {}
var _windows: Array[Window] = []
var _native_visibility: Variant = null
var web: Control
var _failure: Label

func _ready() -> void:
	name = "BF6 Home"
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_failure = Label.new()
	_failure.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_failure.text = "Loading the shared BF6 Home..."
	add_child(_failure)
	visibility_changed.connect(_visibility_changed)
	for node in get_tree().root.find_children("*", "Window", true, false): _track_window(node)
	get_tree().node_added.connect(_track_window)
	get_tree().node_removed.connect(_untrack_window)
	var timer := Timer.new()
	timer.wait_time = 0.75
	timer.timeout.connect(_discover_preparation)
	add_child(timer)
	timer.start()
	refresh()
	_discover_preparation()
	_visibility_changed.call_deferred()

func _visibility_changed() -> void:
	if not is_node_ready() or _disposed: return
	if is_visible_in_tree(): _ensure_web()
	_sync_native_visibility()

func _track_window(node: Node) -> void:
	if node is Window and node != get_tree().root and not _windows.has(node):
		_windows.append(node)
		if not node.visibility_changed.is_connected(_sync_native_visibility):
			node.visibility_changed.connect(_sync_native_visibility)
		_sync_native_visibility.call_deferred()

func _untrack_window(node: Node) -> void:
	if node is Window: _windows.erase(node)
	_sync_native_visibility.call_deferred()

func _window_blocks_home(window: Window) -> bool:
	if not is_instance_valid(window) or not window.visible: return false
	if window.exclusive: return true
	# Native non-modal tools composite above the browser normally. Embedded
	# windows need room in the editor surface only when they overlap Home.
	if not window.is_embedded() or not is_instance_valid(web): return false
	var window_rect: Rect2 = window.get_screen_transform() * Rect2(Vector2.ZERO, Vector2(window.size))
	var web_rect: Rect2 = web.get_screen_transform() * Rect2(Vector2.ZERO, web.size)
	return window_rect.intersects(web_rect)

func _process(_delta: float) -> void:
	if not is_visible_in_tree(): return
	# Embedded windows have no position-changed signal. Recheck while one is
	# visible so moving a non-modal window off Home restores the browser.
	for window in _windows:
		if is_instance_valid(window) and window.visible and window.is_embedded():
			_sync_native_visibility()
			return

func _sync_native_visibility() -> void:
	if not is_instance_valid(web) or _disposed: return
	var shown := is_visible_in_tree()
	for window in _windows:
		if _window_blocks_home(window):
			shown = false
			break
	if _native_visibility == shown and web.visible == shown: return
	_native_visibility = shown
	web.visible = shown
	# Typed Control calls do not update the helper's separate native visibility.
	web.call("set_visible", shown)

func _ensure_web() -> void:
	if is_instance_valid(web) or _disposed: return
	if OS.get_name() != "Windows" or DisplayServer.get_name() == "headless":
		_failure.text = "BF6 Home requires the Windows editor and bundled BF6 Editor Web Host."
		return
	if not ClassDB.class_exists("BF6OfflineWebView"):
		_failure.text = "Bundled BF6 Editor Web Host unavailable. Install the complete BF6 Godot Patch package and restart Godot."
		return
	var root: String = get_script().resource_path.get_base_dir().path_join("web")
	if not FileAccess.file_exists(root.path_join("host-resources.json")):
		_failure.text = "Shared Home resources missing. Reinstall the complete matching BF6 Godot Patch package."
		return
	web = ClassDB.instantiate("BF6OfflineWebView")
	web.name = "SharedHome"
	web.size_flags_vertical = Control.SIZE_EXPAND_FILL
	web.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	web.set("url", "http://res.offline/home/index.html")
	web.set("resource_root", root)
	web.set("initialization_script", BRIDGE)
	web.set("data_directory", "user://bf6-offline-home")
	for option in ["forward_input_events", "devtools", "clipboard", "focused_when_created"]: web.set(option, false)
	web.set("incognito", true)
	web.connect("ipc_message", _ipc)
	web.connect("host_error", _host_error)
	web.connect("page_load_started", func(_url): _browser_ready = false)
	add_child(web)
	web.call("create_webview")
	_sync_native_visibility()

func _host_error(message: String) -> void:
	_browser_ready = false
	_failure.text = "Shared Home browser: " + message
	_failure.show()

func show_status(message: String) -> void:
	_status_text = message
	_send_state()

func refresh() -> void:
	if _locked or not is_node_ready(): return
	_official = Catalog.official_maps()
	var catalog := Catalog.scan(workspace_projects)
	_records.clear()
	for record in catalog.scenes:
		if record.kind != "SDK map" and not str(record.path).contains("/originals/"): _records.append(record)
	var errors: Array = _official.errors + catalog.errors
	_status_text = "%d maps installed. %d saved scene(s)." % [_installed_count(), _records.size()]
	if not errors.is_empty(): _status_text += " " + "; ".join(errors)
	_send_state()

func _installed_count() -> int:
	var count := 0
	for record in _official.get("maps", []):
		if record.available: count += 1
	return count

func set_workspace(root: String) -> Dictionary:
	var result := Catalog.workspace(root)
	workspace_root = str(result.get("root", ""))
	workspace_projects = str(result.get("projects", ""))
	if is_node_ready():
		refresh()
		if not str(result.error).is_empty(): show_status(result.error)
	return result

func _project_name(record: Dictionary) -> String:
	if record.kind == "Workspace scene":
		var relative := str(record.path).trim_prefix(workspace_projects + "/")
		return relative.get_slice("/", 1) if relative.begins_with("experiences/") else relative.get_slice("/", 0)
	return str(record.name)

func home_state() -> Dictionary:
	_save_lookup.clear()
	var maps: Array = []
	for record in _records:
		var ident: String = str(record.path).sha256_text()
		_save_lookup[ident] = record
	for record in _official.get("maps", []):
		var saves: Array = []
		for scene in _records:
			if scene.level == record.level:
				saves.append({"id": str(scene.path).sha256_text(), "name": _project_name(scene), "canLink": false, "canDelete": false})
		# Object/backup counts require actual readers; do not fabricate them.
		maps.append({"id": record.id, "name": record.name, "image": "../mapthumbs/" + str(record.image).get_file(),
			"size": record.size, "paid": record.paid, "available": record.available, "saves": saves})
	var actions: Array = []
	for item in [["import", "IMPORT MAP"], ["saves", "OPEN SAVES"], ["workspace", "CHOOSE WORKSPACE"], ["default_workspace", "DEFAULT WORKSPACE"], ["refresh", "REFRESH"]]:
		actions.append({"id": item[0], "label": item[1], "enabled": not _locked, "visible": true, "placement": "header"})
	actions.append({"id": "prepare", "label": "PREPARE HIGH POLY MAPS", "visible": is_instance_valid(_service), "enabled": true, "placement": "prepare"})
	# Local scenes belong only in their map's Resume menu. The lower section
	# requires authenticated Portal experience data, never a folder-name guess.
	return {"maps": maps, "groups": _official.get("groups", []), "actions": actions,
		"eyebrow": "B F 6   G O D O T   S D K", "experiences": [], "status": _status_text, "busy": _locked}

func _send_state() -> void:
	if _browser_ready and is_instance_valid(web) and not _disposed:
		web.call("eval", "window.bf6Home.setState(" + JSON.stringify(home_state()) + ")")

func _ipc(text: String) -> void:
	if text.to_utf8_buffer().size() > 16384 or _disposed: return
	var envelope: Variant = JSON.parse_string(text)
	if not envelope is Dictionary or envelope.get("channel") != "bf6-offline-v1": return
	var payload: Variant = envelope.get("payload")
	if not payload is Dictionary or payload.get("op") != "log": return
	var message: Variant = payload.get("home")
	if not message is Dictionary or message.get("channel") != "bf6-home": return
	_handle_home(message)

func _handle_home(message: Dictionary) -> void:
	var action: String = str(message.get("action", ""))
	if action == "ready":
		_browser_ready = true
		if is_instance_valid(_failure): _failure.hide()
		_send_state()
		return
	if not _browser_ready or not is_visible_in_tree(): return
	for window in _windows:
		if _window_blocks_home(window): return
	var ident: String = str(message.get("id", ""))
	if ident.length() > 256: return
	if action == "tool" and ident == "prepare":
		_open_preparation()
		return
	if _locked: return
	match action:
		"tool":
			match ident:
				"import": import_requested.emit()
				"workspace": workspace_requested.emit()
				"default_workspace": workspace_cleared.emit()
				"saves": saves_requested.emit()
				"refresh": refresh()
		"open_map":
			for record in _official.get("maps", []):
				if record.id == ident and record.available:
					_request_open(record)
					return
		"resume":
			var save_id: String = str(message.get("saveId", ""))
			if _save_lookup.has(save_id):
				var record: Dictionary = _save_lookup[save_id]
				if str(record.level).to_lower() == ident.to_lower(): _request_open(record)
		# Link/delete/backups have no advertised host capability.

func _request_open(record: Dictionary) -> void:
	if _locked: return
	var error := Catalog.resource_error(record.path, true)
	if not error.is_empty():
		show_status(error)
		return
	if record.kind == "SDK map": create_requested.emit(record)
	else: open_requested.emit(record.path)

static func compatible_preparation(node: Node) -> bool:
	if not is_instance_valid(node) or not node.has_method("open_preparation") or not node.has_method("prepare_levels"): return false
	var script: Script = node.get_script()
	return script != null and script.get_script_constant_map().get("API_VERSION", 0) == 1

func _discover_preparation() -> void:
	var found: Node = null
	for node in get_tree().get_nodes_in_group(PREPARATION_GROUP):
		if compatible_preparation(node):
			found = node
			break
	if found != _service:
		if is_instance_valid(_service) and _service.has_signal("editing_lock_changed") and _service.is_connected("editing_lock_changed", _set_locked):
			_service.disconnect("editing_lock_changed", _set_locked)
		_service = found
		_set_locked(false)
		if is_instance_valid(_service) and _service.has_signal("editing_lock_changed"): _service.connect("editing_lock_changed", _set_locked)
		_send_state()

func _set_locked(value: bool) -> void:
	_locked = value
	if value: show_status("High Poly preparation is running. Pause or finish preparation to open a project.")
	else: _send_state()

func _open_preparation() -> void:
	_discover_preparation()
	if is_instance_valid(_service): _service.call("open_preparation")

func _exit_tree() -> void:
	_disposed = true
	if is_instance_valid(web):
		web.visible = false
		web.call("set_visible", false)
		web.call("destroy_webview")
		web.queue_free()
	web = null
