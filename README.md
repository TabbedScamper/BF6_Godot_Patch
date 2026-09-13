# BF6 Godot Patch

BF6 Home brings the Unreal SDK's map browser to the official Battlefield 6 Godot SDK. It uses the same HTML, styles, fonts and map thumbnails as Unreal, with a Godot adapter for opening scenes and creating projects. Updates to the shared frontend are distributed to both editors from the Unreal parent repository.

This is a **development preview for Windows and Godot 4.6.3**. It includes the Home addon and an SDK setup launcher foundation. Automatic SDK downloading and optional plugin installation/update are still in development.

## Install the Home addon

Close Godot after saving your work. Copy **both folders** from this repository's `addons` directory into your official SDK's `GodotProject/addons` directory, then restart Godot and enable **BF6 Godot Patch** under Project Settings > Plugins. The bundled `bf6_editor_web_host` provides the native browser; it is shared with the optional Blockly addon. Use matching package versions when both are installed.

The addon folder remains `bf6_map_selection` for compatibility with earlier installations. Enable that single plugin; there is no second Map Selection plugin to install. **BF6 Home** becomes a main editor screen and opens at startup. Windows WebView2 Runtime is required by the browser helper.

Home hides the editor's side docks, bottom panel and optional workspace drawers while you choose a map. Returning to editing restores their previous layout and visibility.

## Maps and creator projects

Home shows the same 25 map identities, names and paid/free grouping as Unreal. Only maps present in the installed SDK can be opened. Choosing a stock map asks for a project name and creates a creator copy. Home does not save over the original SDK map.

Saved maps appear in each map's **Resume** menu. The area below the maps is reserved for linked Portal experiences. Godot's Portal connection addon is still in development, so this preview leaves that area empty rather than treating local saves as linked experiences.

**Import Map** accepts an existing `.tscn`, previews its destination and base map, then creates a standard creator project. The source file stays untouched. Optional companion files can include a TypeScript script, strings, a native Blockly workspace and UI data. Import reports unsupported inputs instead of silently discarding them.

The default shared workspace is `GodotProject/User_Created/workspaces/Creators`. Projects use this structure:

```text
bf6-workspace.json
saves/<project>/
  project.json
  src/index.ts
  src/strings.json
  unreal/tscn/MP_<map>.tscn
  unreal/blockly/workspace.json
  unreal/ui/
```

Script, strings, blocks and UI files are present when supplied or provided by the selected starter template. A missing Blockly workspace is not fabricated. An imported native workspace is preserved byte for byte even when the Blockly addon is absent, including unknown metadata and extended block types. Editing those blocks requires a compatible editor.

New projects use the installed SDK's creator template when available, with the parent SDK's starter as a fallback. See [Creator projects](docs/CREATOR-PROJECTS.md) for the complete format and import boundaries. Existing workspaces must be inside the open Godot project's resource tree.

Godot and Unreal can use this common project layout. This does **not** yet guarantee lossless scene round trips: some Godot node types, properties and signals are not represented by Unreal's importer. Inherited scene roots must be made standalone in Godot before opening in Unreal. Arbitrary TypeScript dependency trees are also not imported by the single-script companion picker.

## High Poly integration

When a compatible High Poly preparation service is installed, Home exposes preparation controls and honors its editing lock. The High Poly addon owns preparation, game-install detection and cached content. No extracted game assets are included here.

## SDK setup launcher

The Python launcher is under `addons/bf6_map_selection/launcher`. It requires Python 3.12 with Tk and can inspect an official `PortalSDK.zip`, compare SDK archives, check the official latest-version index and install into a new folder. It preserves existing SDK installations and creator work. It is not yet a standalone executable or complete updater.

See the launcher's [README](addons/bf6_map_selection/launcher/README.md) for usage, cancellation and current limits. Comparing file changes does not yet provide the full semantic SDK report available in Unreal.

## Development and validation

The authoritative source is `Shared/Godot/BF6_Godot_Patch` in [BF6 Unreal SDK](https://github.com/TabbedScamper/BF6_Unreal_SDK). Its distribution tools copy the shared Home frontend, templates and native helper into this repository and reject stale generated resource lists. Change the parent source to keep both editors synchronized.

Validation includes 61 creator-storage checks, 32 Home model checks, 21 actual Windows browser checks, 14 startup checks, dock visibility/restoration checks, 12 visible-editor create/import workflow checks, and separate shared-frontend browser tests. These cover preserved sources and native block bytes, rejected unsafe imports, map creation/resume, modal and non-modal windows, fonts and thumbnails. Ten Unreal automation tests also cover importing, saving and reopening shared projects, unavailable models, failed saves and recovery conflicts. Broader creator testing remains a release gate. An intermittent native-helper crash in headless editor import remains under investigation; the visible native-browser checks exit successfully.
