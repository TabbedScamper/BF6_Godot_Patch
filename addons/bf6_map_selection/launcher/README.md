# Godot Patch development launcher

`godot_patch_launcher.py` is a standalone Python/Tk setup foundation. It requires Python 3.12 or later with Tk, the adjacent `godot_patch_sdk.py`, and the parent-generated menu/feed data. It is not yet a packaged executable or a complete plugin manager.

It can inspect an existing official `PortalSDK.zip`, compare two SDK archives, explicitly check the latest official SDK version, install into a **new** folder, then open that folder or launch its verified bundled Windows Godot executable. Inspection, network requests, extraction and hashing run on a worker thread. The interface remains available for progress and cancellation. Closing during setup requests cancellation and waits for the worker to stop safely. No network request or program launch happens merely by opening the launcher.

Direct SDK downloading, optional plugin installation/update and semantic SDK reports are listed as planned. No existing SDK or installed addon is patched by this foundation. Creator workspaces and previous installs stay in place; a new SDK does not automatically migrate, mount or copy user work. Select a new sibling installation location, then use a reviewed creator-project migration flow separately.

## Running and distributing

From the authoritative Unreal parent source:

```text
python Tools/godot_patch_launcher.py
python Tools/godot_patch_launcher.py --self-test
python Tools/godot_patch_sdk.py --self-test
```

For a standalone distribution, place these files together:

```text
launcher/
  godot_patch_launcher.py
  godot_patch_sdk.py
  data/
    map_catalog.json
    sdk-feed.json
```

Distribute `map_catalog.json` from the parent-generated Home addon data. Palette bytes come from Unreal's `BF6Theme.h`; do not create another palette. The feed contract also comes from the existing Unreal downloader constants. Generate a new feed file using:

```text
python Tools/godot_patch_launcher.py --export-feed PATH_TO_NEW_sdk-feed.json --parent PATH_TO_UNREAL_PLUGIN_SOURCE
```

The output parent must exist. Feed publication is staged, fsynced and refuses replacement. For metadata updates, regenerate into a fresh staging location and use the parent distribution tooling. Installed launchers read `data/` beside their script; `--data-root` selects an explicit alternate data directory. Source runs resolve the Home package from the parent registry. No personal machine paths are shipped.

## SDK module contract

- `inspect_archive(path, limits=Limits())`: central directory and bounded `sdk.version.json`/`GodotProject/project.godot` reads. Returns version, file inventory with CRC/size hints, directories, source prefix and central metadata identity. It does not read or authenticate all archive payloads.
- `diff_archives(old, new, verify_content=False)`: added, removed and changed file lists. Default `comparison` is `crc32-and-size-hints`, `verified` is false, and equivalent entries are named `same_hint_unverified`. `verify_content=True` reads both archives' payloads and compares SHA-256, returning `unchanged` only for verified equal content.
- `install_new(archive, destination, write=False, expected_sha256=None, protected_roots=(), progress=None, limits=Limits(), cancel_check=None)`: read-only preflight by default. Explicit write extracts and verifies into a unique sibling stage, then atomically publishes a nonexistent destination. Pass known creator/previous SDK roots through `protected_roots` to reject overlap. Nothing is copied from those roots. The optional expected SHA-256 must come from an independently trusted source; the computed hash alone is not publisher authentication.
- Progress callbacks receive `{phase, done, total}` for archive hashing, extraction and verification. Verification is an indeterminate stage in this GUI. A separate cancellation predicate is checked immediately before publication, including cancellation during verification.
- `official_feed_contract(parent)`: reads the actual Unreal source constants; does not fetch network content.

Interrupted or failed installs retain an identifiable `.bf6-sdk-stage-*` directory for diagnosis and do not publish a partial final SDK. Retry uses a different stage. No automatic cleanup deletes unknown files or older SDKs. Installation needs room for the complete new SDK, preserves SDK empty directories and import-cache payloads, rejects linked/reparse paths and unsafe archives, and requires a supported atomic directory publication primitive. Windows is the launcher target. This assumes trusted local storage, not hostile concurrent replacement of filesystem parents.

## Updates and change reports

Latest-version checks fetch only the bounded official index, with the parent's User-Agent and HTTPS redirects restricted to the configured official host. Index archive sizes are advisory, as in Unreal; a later downloader must verify its own response length and payload. No community fallback is silently substituted.

File changes are not equivalent to gameplay/API capability changes. The existing parent `tools/sdk_history/build_sdk_history.py` already mines bounded archive files for asset types, level information, declarations and playable bounds. `BF6Capabilities.cpp` additionally tracks collector versions and scope completeness. Future launcher reports should share those semantics and preserve unavailable/partial scope distinctions instead of treating an unobserved item as removed. This foundation does not reimplement or claim that semantic coverage.

## Validation

Tests use disposable SDK fixtures. They exercise actual Tk controls and worker completion, safe new-root installation, preserved existing output, launch-input tampering, bounded network responses and rejected redirects, cancellation, and staged feed publication failure/retry. SDK tests additionally cover actual Windows junctions, abrupt child-process interruption, corruption, source mutation, extraction limits and a real same-size CRC32 collision that the strong content comparison detects. No fixture executable is launched and no installed user SDK or authored scene is changed.
