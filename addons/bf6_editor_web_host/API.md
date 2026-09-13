# BF6OfflineWebView development API

Reusable helper directory: `addons/bf6_editor_web_host` (distributed from Unreal SDK `Shared/Godot/_shared/bf6_editor_web_host`). It contains the Windows DLL, GDExtension descriptor, license texts and dependency attribution. There is no EditorPlugin and it does not open a browser automatically. This is a tested development prototype, not an installed or published feature.

Use only `ClassDB.class_exists("BF6OfflineWebView")` and `ClassDB.instantiate("BF6OfflineWebView")`. Stock `WebView` may exist from another addon; do not use it as a fallback. The unique entry symbol is `bf6_offline_webview_init`. The fixture has tested both classes loaded simultaneously.

## Configuration before create

| Property | Value/meaning |
|---|---|
| `resource_root` | Godot `res://` directory containing staged shared parent resources and `host-resources.json`. It must resolve to a real directory in this Windows editor prototype. |
| `url` | `http://res.offline/blocks/editor.html`, or another entry explicitly named in the manifest. This is Wry's local custom protocol, not a listening HTTP server. |
| `initialization_script` | Host-owned bridge JavaScript, maximum 256 KiB UTF-8. Injected before the main page loads; parent HTML/JS files can remain byte-for-byte unchanged. |
| `data_directory` | Dedicated `user://` profile subdirectory, e.g. `user://bf6-offline-host`. |
| `forward_input_events`, `clipboard`, `devtools` | Must be false. Creation refuses unsupported capabilities rather than ignoring them. |
| `incognito` | Must be true. |
| `focused_when_created` | Usually false. |
| `html` | Must be empty; arbitrary HTML loading is refused. |
| `full_window_size` | Leave false; host owns the Control rectangle. |

Add the Control as an ordinary child of the host main-screen Control. Set its local position to zero and its size to the available host area. Do not apply desktop-position compensation or make it a top-level Control. The native fork uses its canvas transform relative to the editor client area.

Call `create_webview()` explicitly after layout. It is idempotent. Tool callbacks maintain bounds and visibility, while creation remains host-owned. `diagnostics().created` reports success; `host_error(String)` explains a refusal/failure. Creation does not assume WebView2 exists: the underlying creation error is returned through the signal.

Set the ordinary Control state with `web.visible = value`, then drive native visibility with `web.call("set_visible", value)`. A variable statically typed as `Control` can bind `web.set_visible(value)` to the base CanvasItem method, leaving the native browser hidden. The dynamic call reaches the extension method; confirm actual native window visibility in acceptance tests. Hide it while an editor popup/modal is shown, when changing editor screen, or before disposal. It additionally hides itself if the Control is not visible in the tree or belongs to a detached Window. Only main-window hosting is supported; do not expose floating docks in this first version. The isolated wrapper proves actual Project popup hiding, but a production host must connect its own editor/modal visibility lifecycle.

Other methods: `eval(String)`, `resize()`, `update_webview()`, `load_url(String)` (manifest-approved entries only), `focus()`, `destroy_webview()`. `load_html()` always refuses. `destroy_webview()` explicitly releases the child and resets resource state; exit_tree also calls it. It does not save application documents: the EditorPlugin must finish its document-close contract before disposing.

Signals: `ipc_message(String)`, `page_load_started(String)`, `page_load_finished(String)`, `host_error(String)`.

## Manifest

`resource_root/host-resources.json`:

```json
{
  "version": 1,
  "files": ["blocks/editor.html", "blocks/editor.js", "blocks/editor_ui.js"],
  "entryPoints": ["blocks/editor.html"],
  "ipcOperations": ["ready", "log", "autosave", "blockSelected", "updateWorkspace", "exportFile", "needExperience", "chunk"]
}
```

The example is deliberately abbreviated: production must list every real packaged HTML/JS/CSS/image/font/JSON resource used by the editor, including sibling converter/loot files. Files must exist inside the canonical package root. Missing/unsafe files, invalid versions, unlisted entry points, or unsupported operations refuse creation. Only listed files are served; the manifest itself is not implicitly served. There are 10,000-file, 16-entry/operation, 1 MiB manifest and 64 MiB per-resource limits. Reads and byte ranges are bounded; path traversal and malformed ranges return refusal responses.

Supported production operation vocabulary is exactly the eight operations shown. The descriptor selects a subset. An operation is only a data notification, never authority over a browser-supplied file path. The native host does no workspace writing or process execution. The product receiver must bind writes to the selected document and validated workspace, ignore browser paths, and implement explicit Save/Save As outside the browser. `fixtureResult` is only accepted if the local manifest explicitly sets `testMode:true` and includes that operation; omit both in production.

IPC envelope:

```json
{"channel":"bf6-offline-v1","payload":{"op":"ready"}}
```

The DLL validates the actual IPC request source URL against this instance's entry allowlist, the envelope, the operation and a 4 MiB UTF-8 cap before emitting a signal. Raw or wrapped `_key_*`/mouse messages cannot inject Godot input. Navigation, popups, downloads, browser permissions and remote resource requests are denied natively; CSP provides another layer. The signal handler still needs application-specific payload validation and document ownership checks.

## Parent chunks

The parent uses 256k JavaScript UTF-16 code-unit chunks. Those can split surrogate pairs. In the bootstrap, transform `payload.part` into base64-encoded UTF-16LE `payload.part_utf16` before native JSON parsing. See the Blockly adapter `addons/bf6_blockly_editor/host_bridge.js`. Do not rebuild a split emoji through separate Unicode decoders.

Reusable assembler: `addons/bf6_blockly_editor/chunk_assembler.gd`. It accepts ordinary String parts for compatibility or encoded parts, orders by `cid/i/n`, allows at most 256 chunks and four incomplete documents, bounds all incomplete data to 64 MiB and each decoded part to 2 MiB, rejects conflicts, expires incomplete data after 15 seconds, and decodes UTF-16 only on completion. Call `reset()` on navigation/project-host generation changes and disposal. After assembly, validate the inner operation again; do not permit recursive chunks. A partial or rejected document must never replace the active document.

Eleven helper tests pass. An actual two-part IPC transfer with a surrogate split at the exact parent boundary reconstructs 786,271 UTF-8 bytes exactly and releases its buffers.

## Scope for the first product adapter

Durable local Blocks JSON load/save, draft-only autosave, explicit Save As, correct unsaved-change prompts and path-free export messages can reuse this host. Preserve shared parent editor files, and disable unsupported Portal/scene/TS buttons clearly in the bootstrap until handlers exist.

`exportAsScript()` performs conversion in the existing page, then sends `exportScript` or `exportPortalScript`. Those operations are currently denied, since the first product adapter does not implement their safe writing/bundling contract. TypeScript compilation, import compiler loading, Portal upload, authenticated browsing, detached windows, other operating systems and multi-DPI monitor transitions are not certified by this proof.

Build source is Unreal SDK `Tools/native/bf6_editor_web_host`. Run its `build.py` with Python from a Rust/MSVC build environment; the locked build fetches dependencies if needed. Rebuild with `cargo build --release --locked --offline`; run `cargo test --release --locked --offline`. The local Wry 0.50.5 patch is included in `vendor/wry`; no other dependency version changed. `offline-host-fork.patch` is against the pinned upstream commit. The build helper reports the DLL path and hash. The accepted development DLL hash is `c8cd383dbaecf7a455e31cb07e600ed5aef079ef11cbab2628d1fef03e066098`; rebuilding with another compiler can change that hash. The package is not a whole-WebView security sandbox for arbitrary untrusted native plugins or files modified by another local process.
