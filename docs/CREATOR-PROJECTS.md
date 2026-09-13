# Creator project storage

`creator_project_store.gd` copies authored scenes into a **new** project under
`res://User_Created/workspaces/Creators/saves/<name>/`. Existing names get a unique
suffix; existing projects are never merged or overwritten by these operations.
The workspace uses the parent's `bf6-workspace.json` version 1 contract.

The authored scene lives at `unreal/tscn/<MP_Level>.tscn`. Its root name stays
unchanged. The copied scene receives canonical root `metadata/bf6_base_level`;
conflicting existing metadata is rejected. Copied root and external-resource UIDs
are removed so verified paths determine resource identity. Relative external
references are rebased to installed `res://` resources, or rejected when they
cannot be preserved. Source scenes and referenced assets are never rewritten.

New projects use the installed `_template*` under `User_Created/projects`, with
the same installed-first ordering as the parent's SDK discovery. Without one,
they use the parent's bundled scripting starter mapped to
`addons/bf6_map_selection/template`. That starter uses Michael De Luca's bundler;
it is identified separately from the full community template.

The copy includes `src`, `scripts`, sample spatials and the supported package,
lockfile, TypeScript, lint, formatting, README and license files. Plain boilerplate
becomes `src/index.ts`, matching the parent's initializer. Template sample spatials
go in `spatials/template-samples`; deployment scripts/commands, credentials,
dependency installations and build products are omitted. No template scripts or
package commands execute during creation. Auxiliary template websites, editor
extensions and generated context directories are not project source inputs.

The parent's folders are created: `maps`, `spatials`, `unreal/tscn`,
`unreal/blockly`, `unreal/ui`, `unreal/bindings`, `unreal/settings`, and `dist`.

Optional explicitly chosen companions preserve their original bytes:

| Companion | Destination |
| --- | --- |
| Standalone TypeScript | `src/index.ts` |
| Strings JSON | `src/strings.json` |
| Blockly JSON | `unreal/blockly/workspace.json` |
| UI JSON | `unreal/ui/<original filename>.json` |

JSON receives syntax/object validation, not conversion or claims of runtime
compatibility. Unknown Blockly fields, unsupported block types and large IDs
remain byte-for-byte intact, even without the Blockly addon installed. Missing
block documents stay missing. A single TypeScript file with module dependencies
is refused explicitly; importing an entire source project is a separate operation.
The conservative module detector can also refuse import-like text in comments.

`preview_import(scene, name, workspace, level_hint, companions)` validates inputs
and lists normalized destinations without creating folders. `import_scene` has
the same arguments. `create_from_stock(scene, name, workspace)` creates from a
stock map. `ensure_workspace(workspace)` establishes only the root and its manifest.
Every result carries an `error` string, empty on success.

`project.json` uses the parent's actual manifest contract and indexes existing
artefacts only. Its hashes describe creation time; later Godot saves do not
silently rewrite this index. Unreal refreshes it through its manifest writer.
The TSCN remains authored source. No Unreal session, Portal spatial export, or
lossless cross-editor scene conversion is fabricated.

Input reads are bounded (64 MiB per scene/companion; 128 MiB template snapshot),
linked paths are refused, originals are checked again before writing, and a
cooperative workspace lock prevents simultaneous creators from sharing a folder.
This is not a sandbox against a separate process maliciously replacing filesystem
parents mid-operation. Incomplete new project folders are retained with an error;
another operation's lock or existing creator files are never automatically deleted.

Run `tests/run_creator_store_tests.py --godot <executable> --output <new-folder>`
for the disposable fixture checks. The runner refuses an existing output folder.
