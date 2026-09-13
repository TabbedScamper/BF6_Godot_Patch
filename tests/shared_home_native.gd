extends SceneTree
const HomePanel = preload("../addons/bf6_map_selection/map_panel.gd")
var checks := 0
var failures := 0
var created: Array = []
var opened: Array = []
var imported := 0
var dom: Dictionary = {}
var panel: Control

func _initialize() -> void:
	run.call_deferred()

func expect(value: bool, label: String) -> void:
	checks += 1
	if not value:
		failures += 1
		push_error(label)

func wait_frames(seconds := 0.3) -> void:
	await create_timer(seconds).timeout

func run() -> void:
	if ProjectSettings.get_setting("application/config/name", "") != "BF6MapSelectorTests":
		quit(2)
		return
	if not ClassDB.class_exists("BF6OfflineWebView"):
		push_error("Native helper did not load; refusing a false success")
		quit(2)
		return
	root.size = Vector2i(1280, 900)
	panel = HomePanel.new()
	root.add_child(panel)
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.create_requested.connect(func(record: Dictionary): created.append(record.path))
	panel.open_requested.connect(func(path: String): opened.append(path))
	panel.import_requested.connect(func(): imported += 1)
	var deadline := Time.get_ticks_msec() + 20000
	while not panel._browser_ready and Time.get_ticks_msec() < deadline:
		await process_frame
	expect(panel._browser_ready, "Actual shared Home page must send ready through native IPC")
	if not panel._browser_ready:
		finish()
		return
	panel.web.connect("ipc_message", func(text: String):
		var envelope: Variant = JSON.parse_string(text)
		if envelope is Dictionary:
			var message: Variant = envelope.get("payload", {}).get("home", {})
			if message is Dictionary and message.get("action") == "fixture_result": dom = message)
	panel.web.call("eval", "window.bf6HomeHostPost(JSON.stringify({channel:'bf6-home',action:'fixture_result',cards:document.querySelectorAll('.map-card').length,enabled:document.querySelectorAll('.map-open:not(:disabled)').length,images:document.querySelectorAll('.map-card img').length,title:document.getElementById('title').textContent,brand:document.getElementById('eyebrow').textContent}))")
	await wait_frames()
	expect(dom.get("cards") == 25, "Local saves do not create extra cards below the 25 official maps")
	expect(dom.get("enabled") == 1, "Only the installed stock map is enabled; saves belong in Resume")
	expect(dom.get("images") == 25 and dom.get("title") == "CHOOSE MAPS" and dom.get("brand") == "B F 6   G O D O T   S D K", "Shared page renders parent thumbnails, heading and Godot branding")
	panel.web.call("eval", "document.querySelector('[data-focus-key=\"map:MP_Abbasid\"]').click();document.querySelector('[data-focus-key=\"map:MP_Aftermath\"]').click();document.querySelector('[data-focus-key=\"tool:import\"]').click()")
	await wait_frames()
	expect(created == ["res://levels/MP_Abbasid.tscn"], "Installed map triggers creator-copy flow; unavailable card cannot open")
	expect(imported == 1, "Actual toolbar click invokes host import")
	var state: Dictionary = panel.home_state()
	var save_id := ""
	for map in state.maps:
		if map.id == "MP_Abbasid": save_id = str(map.saves[0].id)
	panel.web.call("eval", "document.querySelector('[data-focus-key=\"resume:MP_Abbasid:" + save_id + "\"]').click()")
	await wait_frames()
	expect(opened == ["res://User_Created/levels/Creator_Save.tscn"], "Resume opaque ID resolves only the host-listed creator file")
	panel._handle_home({"action": "open_project", "id": "res://outside.tscn"})
	panel._handle_home({"action": "open_experience", "id": save_id})
	panel._handle_home({"action": "resume", "id": "MP_Aftermath", "saveId": save_id})
	expect(opened.size() == 1, "Forged path and wrong-map save IDs are refused")
	panel._set_locked(true)
	panel.web.call("eval", "window.bf6HomeHostPost(JSON.stringify({channel:'bf6-home',action:'open_map',id:'MP_Abbasid'}))")
	await wait_frames()
	expect(created.size() == 1, "Direct browser event cannot bypass host preparation lock")
	panel._set_locked(false)
	var modal := Window.new()
	modal.visible = false
	modal.transient = true
	modal.exclusive = true
	root.add_child(modal)
	modal.show()
	await wait_frames()
	expect(not panel.web.visible, "Native control hides while an exclusive dialog is visible")
	panel._handle_home({"action": "open_map", "id": "MP_Abbasid"})
	expect(created.size() == 1, "Queued browser events cannot open a map behind a visible dialog")
	modal.hide()
	await wait_frames()
	expect(panel.web.visible, "Native control restores after modal closure")
	modal.queue_free()
	await process_frame
	var tool_window := Window.new()
	tool_window.visible = false
	tool_window.force_native = true
	tool_window.exclusive = false
	tool_window.title = "Non-modal preparation window control"
	root.add_child(tool_window)
	tool_window.show()
	await wait_frames()
	expect(not tool_window.is_embedded() and panel.web.visible, "A real non-modal native tool window leaves Home visible")
	panel.web.call("eval", "document.querySelector('[data-focus-key=\"tool:import\"]').click()")
	await wait_frames()
	expect(imported == 2, "Home remains interactive while a non-modal native tool window is open")
	tool_window.hide()
	tool_window.queue_free()
	await process_frame
	root.gui_embed_subwindows = true
	panel.offset_top = 120
	var embedded := Window.new()
	embedded.visible = false
	embedded.size = Vector2i(160, 40)
	embedded.position = Vector2i(150, 200)
	root.add_child(embedded)
	embedded.show()
	await wait_frames()
	expect(embedded.is_embedded() and not panel.web.visible, "An overlapping embedded window can draw above the native browser")
	embedded.position = Vector2i(150, 10)
	await wait_frames()
	expect(panel.web.visible, "Moving an embedded window outside Home restores the browser without closing it")
	embedded.hide()
	embedded.queue_free()
	await process_frame
	root.gui_embed_subwindows = false
	panel.offset_top = 0
	panel.hide()
	await wait_frames()
	expect(not panel.web.visible, "Hiding Home hides its native child")
	panel.show()
	await wait_frames()
	expect(panel.web.visible, "Reopening Home restores its native child")
	var diagnostics: Dictionary = panel.web.call("diagnostics")
	panel.web.call("eval", "window.bf6HomeHostPost(JSON.stringify({channel:'bf6-home',action:'fixture_result',resources:performance.getEntriesByType('resource').map(r=>({name:r.name,status:r.responseStatus})),font:document.fonts.check('16px BF6Roboto'),image:document.querySelector('.map-card img').naturalWidth}))")
	await wait_frames()
	print("HOME_NATIVE_DIAGNOSTICS " + JSON.stringify(diagnostics) + " " + JSON.stringify(dom))
	expect(dom.get("font") == true and dom.get("image", 0) > 0, "Actual WebView loaded the parent font and thumbnail pixels")
	expect(diagnostics.created and diagnostics.blocked_resources == 0, "Page loads only listed resources with zero blocked resource requests")
	var original := FileAccess.get_file_as_string("res://User_Created/levels/Creator_Save.tscn")
	expect(original.contains("9,8,7"), "Authored scene transform remains unchanged")
	finish()

func finish() -> void:
	if is_instance_valid(panel): panel.free()
	print("SHARED_HOME_NATIVE_RESULT " + JSON.stringify({"checks": checks, "failures": failures, "dom": dom}))
	quit(0 if failures == 0 else 1)
