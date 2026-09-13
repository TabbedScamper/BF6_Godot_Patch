@tool
extends EditorPlugin

const MapPanel = preload("map_panel.gd")
const Catalog = preload("map_catalog.gd")
const Store = preload("creator_project_store.gd")
const PANEL_ID := "bf6.map_selection"
var _panel: Control
var _workspace_dialog: EditorFileDialog
var _import_dialog: EditorFileDialog
var _create_dialog: ConfirmationDialog
var _project_name: LineEdit
var _base_map: OptionButton
var _dialog_status: Label
var _companion_dialog: EditorFileDialog
var _companion_rows: VBoxContainer
var _companion_labels: Dictionary = {}
var _companions: Dictionary = {}
var _companion_kind := ""
var _reviewed := false
var _pending: Dictionary = {}
var _workspace_root := ""
var _startup_home_pending := true
var _chrome_active := false
var _prior_distraction_free := false
var _chrome_controls: Array[Dictionary] = []
var _chrome_windows: Array[Dictionary] = []
var _chrome_hosts: Array[WeakRef] = []
var _legacy_chrome_hosts: Array[Dictionary] = []
var _prior_dock_widths: Dictionary = {}

func _has_main_screen() -> bool:
	return true

func _get_plugin_name() -> String:
	return "BF6 Home"

func _get_plugin_icon() -> Texture2D:
	return EditorInterface.get_base_control().get_theme_icon("FileDialog", "EditorIcons")

func _make_visible(value: bool) -> void:
	if is_instance_valid(_panel):
		_panel.visible = value
		if value:
			_capture_editor_chrome()
			_apply_home_chrome.call_deferred()
			_panel.refresh()
		else:
			_restore_editor_chrome.call_deferred()

func _capture_editor_chrome() -> void:
	if _chrome_active:
		return
	_chrome_active = true
	_prior_distraction_free = EditorInterface.distraction_free_mode
	_capture_dock_widths()
	# The supported distraction-free API preserves dock positions and tabs.
	# Godot excludes the bottom dock from that API and exposes no getter for
	# it. Locate only its exact engine class, never a guessed child index/path.
	var base := EditorInterface.get_base_control()
	for bottom in base.find_children("*", "EditorBottomPanel", true, false):
		_remember_chrome_control(bottom)
	# Optional workspace drawers are not native docks. Preserve their existing
	# visibility through the established discovery group; do not unregister them.
	for host in get_tree().get_nodes_in_group("bf6_workspace_panels_v1"):
		if host.has_method("get_api_version") and host.get_api_version() == 1 and host.has_method("set_visibility_suppressed"):
			_chrome_hosts.append(weakref(host))
		elif host is Control:
			# Older API v1 hosts follow the editor every process tick. Pause only
			# that host while Home owns it, then restore its exact process flag.
			_legacy_chrome_hosts.append({"host": weakref(host), "processing": host.is_processing()})
			_remember_chrome_control(host)
			for child in host.get_children(true):
				if child is Window:
					_chrome_windows.append({"window": weakref(child), "visible": child.visible})
	# Detached editor docks are excluded from distraction-free mode too. Only
	# dock-owned windows qualify; import/confirmation dialogs remain available.
	var seen_windows: Dictionary = {}
	for dock in base.find_children("*", "EditorDock", true, false):
		var window: Window = dock.get_window()
		if window != base.get_window() and not seen_windows.has(window.get_instance_id()):
			seen_windows[window.get_instance_id()] = true
			_chrome_windows.append({"window": weakref(window), "visible": window.visible, "minimize": true, "mode": window.mode})

func _remember_chrome_control(control: Control) -> void:
	_chrome_controls.append({"control": weakref(control), "visible": control.visible})

func _capture_dock_widths() -> void:
	_prior_dock_widths.clear()
	if _prior_distraction_free:
		return
	# Godot's dock serializer writes zero widths for distraction-free docks.
	# Read the live public split offsets before hiding them. The engine-authored
	# main splitter and dock_slot metadata map these to its four saved fields.
	var split := EditorInterface.get_base_control().find_child("DockHSplitMain", true, false) as SplitContainer
	if split == null:
		return
	var offsets := split.get_split_offsets()
	var index := 0
	var scale := EditorInterface.get_editor_scale()
	for column in split.get_children():
		if not column is SplitContainer or not column.visible:
			continue
		var slot := -1
		for tab in column.get_children():
			if tab is TabContainer and tab.has_meta("dock_slot"):
				slot = int(tab.get_meta("dock_slot"))
				break
		if slot < 0 or slot >= 8:
			continue
		if index < offsets.size():
			_prior_dock_widths["dock_hsplit_" + str(slot / 2 + 1)] = int(float(offsets[index]) / scale)
		index += 1

func _get_window_layout(configuration: ConfigFile) -> void:
	# Called after the engine serializes its docks, including on normal quit.
	# Correct only widths hidden by this Home visit; all other fields stay native.
	if _chrome_active:
		for key in _prior_dock_widths:
			configuration.set_value("docks", key, _prior_dock_widths[key])

func _apply_home_chrome() -> void:
	if not _chrome_active or not is_instance_valid(_panel) or not _panel.visible:
		return
	# Main-screen changes apply Godot's per-screen distraction preference after
	# _make_visible. Defer this override until that native dispatch is complete.
	EditorInterface.distraction_free_mode = true
	for entry in _legacy_chrome_hosts:
		var host: Node = entry.host.get_ref()
		if is_instance_valid(host):
			host.set_process(false)
	for reference in _chrome_hosts:
		var host: Object = reference.get_ref()
		if is_instance_valid(host):
			host.set_visibility_suppressed(self, true)
	for entry in _chrome_controls:
		var control: Control = entry.control.get_ref()
		if is_instance_valid(control):
			control.hide()
	for entry in _chrome_windows:
		var window: Window = entry.window.get_ref()
		if is_instance_valid(window):
			if entry.get("minimize", false):
				# Godot's WindowWrapper cannot serialize an invisible dock Window.
				# Minimize keeps its registered layout valid and off the workspace.
				if window.visible:
					window.mode = Window.MODE_MINIMIZED
			else:
				window.hide()

func _restore_editor_chrome(force: bool = false) -> void:
	if not _chrome_active or (not force and is_instance_valid(_panel) and _panel.visible):
		return
	_chrome_active = false
	EditorInterface.distraction_free_mode = _prior_distraction_free
	for reference in _chrome_hosts:
		var host: Object = reference.get_ref()
		if is_instance_valid(host):
			host.set_visibility_suppressed(self, false)
	for entry in _chrome_controls:
		var control: Control = entry.control.get_ref()
		if is_instance_valid(control):
			control.visible = bool(entry.visible)
	for entry in _chrome_windows:
		var window: Window = entry.window.get_ref()
		if is_instance_valid(window):
			if entry.get("minimize", false):
				window.mode = int(entry.mode)
			window.visible = bool(entry.visible)
	for entry in _legacy_chrome_hosts:
		var host: Node = entry.host.get_ref()
		if is_instance_valid(host):
			host.set_process(bool(entry.processing))
	_chrome_controls.clear()
	_chrome_hosts.clear()
	_legacy_chrome_hosts.clear()
	_prior_dock_widths.clear()
	_chrome_windows.clear()

func _enter_tree() -> void:
	_panel = MapPanel.new()
	EditorInterface.get_editor_main_screen().add_child(_panel)
	_panel.hide()
	# Browser IPC and modal button handlers must finish their native dispatch
	# before we change editor windows, scene tabs or native child visibility.
	_panel.open_requested.connect(_open_scene, CONNECT_DEFERRED)
	_panel.create_requested.connect(_request_create, CONNECT_DEFERRED)
	_panel.import_requested.connect(_choose_import, CONNECT_DEFERRED)
	_panel.workspace_requested.connect(func(): _workspace_dialog.popup_centered_ratio(0.65), CONNECT_DEFERRED)
	_panel.workspace_cleared.connect(_default_workspace, CONNECT_DEFERRED)
	_panel.saves_requested.connect(_open_saves, CONNECT_DEFERRED)
	_workspace_dialog = EditorFileDialog.new()
	_workspace_dialog.title = "Choose BF6 creator workspace"
	_workspace_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_DIR
	_workspace_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_workspace_dialog.dir_selected.connect(_workspace_chosen, CONNECT_DEFERRED)
	EditorInterface.get_base_control().add_child(_workspace_dialog)
	_import_dialog = EditorFileDialog.new()
	_import_dialog.title = "Import a saved map"
	_import_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_import_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_import_dialog.add_filter("*.tscn", "Godot map save")
	_import_dialog.file_selected.connect(_import_chosen, CONNECT_DEFERRED)
	EditorInterface.get_base_control().add_child(_import_dialog)
	_create_dialog = ConfirmationDialog.new()
	_create_dialog.title = "Create project"
	_create_dialog.ok_button_text = "Create and open"
	_create_dialog.dialog_hide_on_ok = false
	_create_dialog.confirmed.connect(_confirm_project, CONNECT_DEFERRED)
	var form := VBoxContainer.new()
	form.custom_minimum_size = Vector2(500, 0)
	_create_dialog.add_child(form)
	var caption := Label.new()
	caption.text = "Project name"
	form.add_child(caption)
	_project_name = LineEdit.new()
	_project_name.max_length = 80
	_project_name.text_changed.connect(func(_text: String): _reviewed = false)
	form.add_child(_project_name)
	_project_name.text_submitted.connect(func(_value: String): _confirm_project(), CONNECT_DEFERRED)
	_base_map = OptionButton.new()
	_base_map.add_item("Choose the base map...")
	for record in Catalog.official_maps().maps:
		_base_map.add_item(record.name)
		_base_map.set_item_metadata(_base_map.item_count - 1, record.id)
	form.add_child(_base_map)
	_base_map.item_selected.connect(func(_index: int): _reviewed = false)
	_companion_rows = VBoxContainer.new()
	form.add_child(_companion_rows)
	for kind in ["script", "strings", "blocks", "ui"]:
		var row := HBoxContainer.new()
		_companion_rows.add_child(row)
		var choose := Button.new()
		choose.text = "Add " + str(kind) + "..."
		choose.custom_minimum_size.x = 135
		choose.pressed.connect(func(): _choose_companion(kind))
		row.add_child(choose)
		var label := Label.new()
		label.text = "Optional"
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		label.clip_text = true
		row.add_child(label)
		_companion_labels[kind] = label
		var clear := Button.new()
		clear.text = "Clear"
		clear.pressed.connect(func():
			_companions.erase(kind)
			label.text = "Optional"
			label.tooltip_text = ""
			_reviewed = false)
		row.add_child(clear)
	_companion_dialog = EditorFileDialog.new()
	_companion_dialog.access = EditorFileDialog.ACCESS_FILESYSTEM
	_companion_dialog.file_mode = EditorFileDialog.FILE_MODE_OPEN_FILE
	_companion_dialog.file_selected.connect(_companion_chosen, CONNECT_DEFERRED)
	# A chooser opened from a modal creator form is its child window, not a
	# competing exclusive sibling of that form under the editor root window.
	_create_dialog.add_child(_companion_dialog)
	_dialog_status = Label.new()
	_dialog_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	form.add_child(_dialog_status)
	EditorInterface.get_base_control().add_child(_create_dialog)
	var saved: String = EditorInterface.get_editor_settings().get_project_metadata("bf6_map_selection", "workspace_root", "")
	if saved.is_empty():
		_default_workspace()
	else:
		_workspace_chosen(saved)
	# The initial filesystem scan restores scene tabs and the selected editor
	# after _enter_tree. Show Home once that restore has finished, including a
	# first launch without an editor_layout.cfg. Never take focus on later scans.
	EditorInterface.get_resource_filesystem().sources_changed.connect(_startup_sources_changed, CONNECT_DEFERRED)

func _set_window_layout(_configuration: ConfigFile) -> void:
	# Godot calls this after restoring its scenes and central editor layout.
	_finish_startup_home.call_deferred()

func _enable_plugin() -> void:
	# This callback is for an explicit enable, not normal startup restoration.
	# If a scan is running, its completion takes the same one-shot path instead.
	if not EditorInterface.get_resource_filesystem().is_scanning():
		_finish_startup_home.call_deferred()

func _startup_sources_changed(_exist: bool) -> void:
	_finish_startup_home()

func _finish_startup_home() -> void:
	if not _startup_home_pending or not is_inside_tree():
		return
	_startup_home_pending = false
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.sources_changed.is_connected(_startup_sources_changed):
		filesystem.sources_changed.disconnect(_startup_sources_changed)
	_show_home()

func _show_home() -> void:
	if is_instance_valid(_panel):
		EditorInterface.set_main_screen_editor("BF6 Home")

func _exit_tree() -> void:
	_restore_editor_chrome(true)
	_startup_home_pending = false
	var filesystem := EditorInterface.get_resource_filesystem()
	if filesystem.sources_changed.is_connected(_startup_sources_changed):
		filesystem.sources_changed.disconnect(_startup_sources_changed)
	# The companion chooser is owned and freed by the creator dialog.
	for control in [_panel, _workspace_dialog, _import_dialog, _create_dialog]:
		if is_instance_valid(control):
			control.queue_free()

func _default_workspace() -> void:
	if _panel._locked:
		return
	var result := Store.ensure_workspace()
	if not str(result.get("error", "")).is_empty():
		_workspace_root = ""
		_panel.show_status(result.error)
		return
	_workspace_chosen(Store.DEFAULT_WORKSPACE)

func _workspace_chosen(path: String) -> void:
	if _panel._locked:
		return
	var result: Dictionary = _panel.set_workspace(path)
	_workspace_root = str(result.get("root", ""))
	EditorInterface.get_editor_settings().set_project_metadata("bf6_map_selection", "workspace_root", path)

func _open_saves() -> void:
	if not _panel.workspace_projects.is_empty():
		var folder: String = _panel.workspace_projects if DirAccess.dir_exists_absolute(_panel.workspace_projects) else _workspace_root
		OS.shell_open(ProjectSettings.globalize_path(folder))

func _reset_companions() -> void:
	_companions.clear()
	_reviewed = false
	for label in _companion_labels.values():
		label.text = "Optional"
		label.tooltip_text = ""

func _choose_companion(kind: String) -> void:
	_companion_kind = kind
	_companion_dialog.title = "Choose your " + kind + " file"
	_companion_dialog.clear_filters()
	_companion_dialog.add_filter("*.ts" if kind == "script" else "*.json", kind.capitalize())
	_companion_dialog.popup_centered_ratio(0.65)

func _companion_chosen(path: String) -> void:
	_companions[_companion_kind] = path
	_companion_labels[_companion_kind].text = path.get_file()
	_companion_labels[_companion_kind].tooltip_text = path
	_reviewed = false

func _choose_import() -> void:
	if not _panel._locked:
		_import_dialog.popup_centered_ratio(0.7)

func _request_create(record: Dictionary) -> void:
	if _panel._locked:
		return
	_pending = {"path": record.path, "stock": true, "level": record.level}
	_reset_companions()
	_companion_rows.hide()
	_project_name.text = "My " + str(record.name)
	_base_map.hide()
	_dialog_status.text = "A new creator copy and script project will be saved in your workspace. The SDK template stays untouched."
	_create_dialog.title = "New project: " + str(record.name)
	_create_dialog.ok_button_text = "Create and open"
	_create_dialog.popup_centered()
	_project_name.grab_focus()
	_project_name.select_all()

func _import_chosen(path: String) -> void:
	if _panel._locked:
		return
	_pending = {"path": path, "stock": false, "level": ""}
	_reset_companions()
	_companion_rows.show()
	_project_name.text = path.get_file().get_basename()
	_base_map.select(0)
	_base_map.show()
	_dialog_status.text = "The base map is detected from the scene. Select it only if detection fails. Add companion files from wherever you saved them, then review their project destinations. Originals stay untouched."
	_create_dialog.title = "Import map as a creator project"
	_create_dialog.ok_button_text = "Review import"
	_create_dialog.popup_centered()
	_project_name.grab_focus()
	_project_name.select_all()

func _confirm_project() -> void:
	if _panel._locked or _pending.is_empty():
		return
	if _workspace_root.is_empty():
		_dialog_status.text = "Choose a valid creator workspace on the home page first."
		return
	if _project_name.text.strip_edges().is_empty():
		_dialog_status.text = "Give your project a name."
		return
	var result: Dictionary
	if _pending.stock:
		result = Store.create_from_stock(_pending.path, _project_name.text, _workspace_root)
	else:
		var hint := str(_base_map.get_selected_metadata()) if _base_map.selected > 0 else ""
		if not _reviewed:
			var preview := Store.preview_import(_pending.path, _project_name.text, _workspace_root, hint, _companions)
			if not str(preview.get("error", "")).is_empty():
				_dialog_status.text = preview.error
				return
			var destinations: Array[String] = []
			for file in preview.get("files", []):
				if str(file.get("kind", "")) != "template":
					destinations.append(str(file.get("destination", "")))
			_dialog_status.text = "New project: " + _project_name.text + "\n" + "\n".join(destinations.slice(0, 12)) + "\nPlus the standard scripting template and project folders. Your original files stay untouched."
			_create_dialog.ok_button_text = "Import and open"
			_reviewed = true
			return
		result = Store.import_scene(_pending.path, _project_name.text, _workspace_root, hint, _companions)
	if not str(result.get("error", "")).is_empty():
		_dialog_status.text = result.error
		return
	_create_dialog.hide()
	_pending.clear()
	_panel.refresh()
	_open_scene.call_deferred(result.scene_path)

func _open_scene(path: String) -> void:
	if _panel._locked or not Catalog.resource_error(path, true).is_empty():
		return
	# Every stock entry goes through project creation, even a stale caller.
	if path.get_base_dir() == "res://levels":
		for record in Catalog.official_maps().maps:
			if record.path == path:
				_request_create(record)
				return
		_panel.show_status("Import this scene as a creator project before editing it.")
		return
	# Older loose saves are adopted instead of continuing a second save layout.
	if not path.begins_with(_panel.workspace_projects + "/") or _panel.workspace_projects.is_empty():
		_import_chosen(path)
		return
	EditorInterface.open_scene_from_path(path)
	EditorInterface.set_main_screen_editor("3D")
