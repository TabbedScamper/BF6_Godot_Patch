# Shared home map catalog

The authoritative menu metadata remains in the Unreal parent. Do not maintain a second map-name or theme table in this plugin. `Tools/generate_godot_map_catalog.py` generates `addons/bf6_map_selection/data/map_catalog.json` from these parent files:

| Metadata | Authority |
| --- | --- |
| Stable map IDs, display names, order, size, paid/free status and thumbnail filenames | `Source/BF6UnrealSDK/Private/BF6MapManifest.h`, `GBF6MapCards` |
| Group labels, group order and paid/free routing | `Source/BF6UnrealSDK/Private/BF6BuildMode.cpp`, `SBF6MapSelector` |
| Menu palette | `Source/BF6UnrealSDK/Private/BF6Theme.h` |
| Thumbnail bytes | `Resources/mapthumbs` |

Run the generator from the Unreal parent checkout:

```text
python Tools/generate_godot_map_catalog.py --check
python Tools/generate_godot_map_catalog.py --write
python Tools/generate_godot_map_catalog.py --self-test
python Tools/generate_godot_map_catalog.py --check --sdk-project PATH_TO_GODOT_PROJECT
```

Default operation is read-only. A stale or missing generated catalog returns exit code 1. Invalid or unsupported source metadata returns 2. Generation fails explicitly if the C++ declarations change beyond the supported parser instead of guessing or silently losing rows. `--write` updates only the generated JSON, never scenes, installed plugins or images.

## Consumer contract, format 1

- `groups`: ordered objects containing stable `id` (`paid` or `free`) and authored `label`.
- `maps`: ordered objects containing unchanged `id`, authored `name`, addon-relative `image`, `size` (`S`, `M`, `L`), boolean `paid`, `group_id`, and zero-based `order`.
- `theme_color_space`: `srgb`. `theme` contains `ink`, `panel`, `panel_light`, `accent`, `text`, `text_dim` and `line`. Each value is a normalized `[red, green, blue, alpha]` array, ready for Godot `Color(v[0], v[1], v[2], v[3])`. The parent opacity multiplier is retained, including the line color's 0.25 alpha.
- `source`: full parent Git repository relative authority paths and SHA-256 provenance. Group/theme hashes cover their extracted metadata, so unrelated C++ changes do not invalidate the catalog. The manifest hash covers its normalized text.

Resolve `image` against `res://addons/bf6_map_selection/`, not the `data/` directory. Load the JSON as data. Reject unsupported `format` values and malformed data rather than inventing a fallback official catalog.

Availability comes from the installed SDK. Intersect the authored IDs with actual direct `res://levels/MP_*.tscn` filenames, retain the canonical catalog ID and the real resource path, and preserve authored order inside each group. Missing stock scenes must not have enabled open buttons. Unknown installed IDs and ambiguous case aliases must be reported separately instead of receiving a guessed official title. Creator saves belong to the creator-project flow and are not additional stock-map catalog entries. The generator's `installed_selection()` is a reference implementation for this filtering and its diagnostics.

This differs deliberately from Unreal's fallback that lists all authored maps when no imported level catalog exists: a Godot installation must not offer to open nonexistent SDK scene paths. Scene opening, unsaved-change prompts, creator copies and migration remain the editor plugin's responsibility.

## Distribution

The parent registry can use this shared-asset overlay to distribute the same thumbnails without keeping a second source copy:

```json
{
  "source": "Resources/mapthumbs",
  "destination": "addons/bf6_map_selection/thumbnails"
}
```

At the initial audit there are 25 authored maps, all 25 thumbnail JPGs are referenced, and the directory totals 931,456 bytes. Keep distinct authored IDs and filenames even where image contents match. The generator verifies every referenced parent image exists; sync/archive tooling records and verifies the actual image hashes. Regenerate and check the catalog before syncing or packaging whenever the manifest, home grouping or palette changes. Generated metadata alone does not make a plugin release-ready.

Unreal's current card design uses a 300 by 169 image, uppercase display name, size badge, whole-card open action and saves dropdown. Group titles are taken from the home implementation, not reconstructed from paid/free flags. These are implementation observations for keeping both home screens familiar, not a second source of metadata.

## Verification

The generator tests parent name/group/theme changes, official-name controls, subset ordering, missing/unknown maps, duplicate aliases, malformed declarations, unsafe image paths and direct-stock-file discovery without changing scene bytes. The initial read-only inspection of the installed SDK found all 25 catalog maps with no missing, unsupported or ambiguous stock IDs. These checks verify metadata and availability; they do not claim scene roundtrip or UI acceptance.
