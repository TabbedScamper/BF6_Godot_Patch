#!/usr/bin/env python3
"""Inspect official SDK ZIPs and install verified baselines beside existing work.

Read-only by default. No downloading, program execution, deletion, plugin
installation, active-project switching or creator-workspace migration. Failed
installs retain their uniquely named staging folder for diagnosis; they never
publish a partial SDK. Use trusted local storage, not a folder whose parents
another process may maliciously replace between filesystem operations.

Public APIs: inspect_archive, diff_archives, install_new, official_feed_contract.
An inspection is central-directory metadata, not a payload integrity check or
proof of publisher authenticity. Default diffs explicitly contain CRC/size
hints. Installation hashes the archive and every extracted file, verifies the
staged tree, then atomically publishes a NEW directory without replacement.
"""
from __future__ import annotations

import argparse
import ctypes
from dataclasses import dataclass
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import stat
import struct
import subprocess
import sys
import tempfile
import unicodedata
import unittest
from unittest.mock import patch
import zipfile
import zlib


class SDKError(ValueError):
    pass


@dataclass(frozen=True)
class Limits:
    archive_bytes: int = 32 * 1024**3
    central_bytes: int = 128 * 1024**2
    entries: int = 300_000
    total_bytes: int = 96 * 1024**3
    file_bytes: int = 8 * 1024**3
    compression_ratio: int = 2000
    metadata_bytes: int = 128 * 1024


RECEIPT = "bf6-sdk-install.json"
REQUIRED = ("sdk.version.json", "GodotProject/project.godot",
            "FbExportData/asset_types.json", "code/types/mod/index.d.ts")
CHUNK = 1024 * 1024


def relative_path(value):
    if not isinstance(value, str) or not value or "\\" in value or ":" in value:
        raise SDKError(f"Invalid archive path: {value!r}")
    parts = value.split("/")
    if len(value) > 1024:
        raise SDKError("Archive path is too long")
    for part in parts:
        if (part in ("", ".", "..") or part.endswith((".", " ")) or len(part) > 255
                or any(ord(c) < 32 or c in '<>"|?*' for c in part)
                or re.fullmatch(r"CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³]", part.split(".")[0], re.I)):
            raise SDKError(f"Unsafe portable archive path: {value!r}")
    return value


def local_path(value, *, must_exist=False):
    path = Path(value)
    if not path.is_absolute() or ".." in path.parts:
        raise SDKError("Choose an absolute local path without parent traversal")
    for candidate in [path, *path.parents]:
        try:
            info = candidate.lstat()
        except FileNotFoundError:
            continue
        if stat.S_ISLNK(info.st_mode) or getattr(info, "st_file_attributes", 0) & 0x400:
            raise SDKError(f"Links and reparse points are unsupported: {candidate}")
    if must_exist and not path.exists():
        raise SDKError(f"Path does not exist: {path}")
    return path.absolute()


def signature(info):
    return (info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns)


def stable(path, opened):
    local_path(path, must_exist=True)
    if signature(path.stat()) != signature(os.fstat(opened.fileno())):
        raise SDKError("SDK archive was replaced during inspection/install")


def central_guard(stream, limits):
    """Bound the central-directory allocation BEFORE ZipFile constructs objects."""
    size = os.fstat(stream.fileno()).st_size
    if not 22 <= size <= limits.archive_bytes:
        raise SDKError("Archive size is outside the configured limit")
    stream.seek(max(0, size - 65557))
    tail = stream.read(65557)
    end = tail.rfind(b"PK\x05\x06")
    if end < 0 or len(tail) - end < 22:
        raise SDKError("Missing ZIP end record")
    record = struct.unpack_from("<4s4H2LH", tail, end)
    _, disk, cd_disk, disk_count, count, cd_size, cd_offset, comment = record
    eocd_offset = size - len(tail) + end
    if end + 22 + comment != len(tail) or disk != 0 or cd_disk != 0:
        raise SDKError("Split archives and trailing data are unsupported")
    if count == 65535 or disk_count == 65535 or cd_size == 0xffffffff or cd_offset == 0xffffffff:
        if eocd_offset < 20:
            raise SDKError("Missing ZIP64 locator")
        stream.seek(eocd_offset - 20)
        magic, disk64, offset64, disks = struct.unpack("<4sLQL", stream.read(20))
        if magic != b"PK\x06\x07" or disk64 or disks != 1:
            raise SDKError("Invalid ZIP64 locator")
        if not 0 <= offset64 <= eocd_offset - 76:
            raise SDKError("Invalid ZIP64 record offset")
        stream.seek(offset64)
        record64 = stream.read(56)
        magic, record_size, _, _, disk, cd_disk, disk_count, count, cd_size, cd_offset = struct.unpack("<4sQ2H2L4Q", record64)
        if magic != b"PK\x06\x06" or record_size < 44 or offset64 + record_size + 12 != eocd_offset - 20:
            raise SDKError("Invalid ZIP64 end record")
        eocd_offset = offset64
    if disk or cd_disk or disk_count != count or not 0 < count <= limits.entries:
        raise SDKError("Unsupported ZIP disk layout or entry count")
    if not 0 < cd_size <= limits.central_bytes or cd_offset + cd_size != eocd_offset:
        raise SDKError("Central directory size/offset is outside limits")
    stream.seek(0)
    return count


def json_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise SDKError(f"Duplicate metadata key: {key}")
        result[key] = value
    return result


def inspect_open(stream, limits):
    count = central_guard(stream, limits)
    with zipfile.ZipFile(stream) as archive:
        infos = archive.infolist()
        if len(infos) != count:
            raise SDKError("ZIP central entry count mismatch")
        paths, kinds, rows, total = {}, {}, {}, 0
        for info in infos:
            # ZipInfo truncates filenames at NUL; inspect the original too.
            if info.orig_filename != info.filename or "\0" in info.orig_filename:
                raise SDKError("NUL in ZIP filename")
            name = relative_path(info.filename[:-1] if info.is_dir() else info.filename)
            folded = unicodedata.normalize("NFC", name).casefold()
            if folded in paths:
                raise SDKError(f"Duplicate or aliased ZIP path: {name}")
            paths[folded] = name
            mode = (info.external_attr >> 16) & 0xffff
            file_type = stat.S_IFMT(mode)
            if file_type not in (0, stat.S_IFREG, stat.S_IFDIR) or (info.external_attr & 0x400):
                raise SDKError(f"Nonregular or reparse ZIP entry: {name}")
            if info.flag_bits & 1 or info.compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
                raise SDKError("Encrypted or unsupported ZIP compression")
            if info.file_size > limits.file_bytes or info.file_size / max(1, info.compress_size) > limits.compression_ratio:
                raise SDKError(f"ZIP entry exceeds extraction limits: {name}")
            if info.is_dir() and info.file_size:
                raise SDKError("Directory entry contains payload")
            if file_type == stat.S_IFDIR and not info.is_dir():
                raise SDKError("Conflicting ZIP directory attributes")
            kinds[folded] = info.is_dir()
            total += info.file_size
            if total > limits.total_bytes:
                raise SDKError("Expanded SDK exceeds total extraction limit")
            if not info.is_dir():
                rows[name] = {"size": info.file_size, "crc32": f"{info.CRC:08x}"}
        for folded in list(paths):
            parts = folded.split("/")
            for end in range(1, len(parts)):
                parent = "/".join(parts[:end])
                if parent in kinds and not kinds[parent]:
                    raise SDKError("ZIP file/directory collision")
                # Implicit parent directory aliases must not silently merge.
                original = "/".join(paths[folded].split("/")[:end])
                if parent in paths and paths[parent] != original:
                    raise SDKError("ZIP parent directory case/Unicode alias")
                paths.setdefault(parent, original)
        # Support no wrapper or exactly one explicit wrapper, as Unreal does.
        roots = [name[:-len("sdk.version.json")] for name in rows if name.endswith("sdk.version.json")
                 and name.count("/") <= 1]
        roots = [root for root in roots if all(root + required in rows for required in REQUIRED)]
        if len(roots) != 1 or any(not name.startswith(roots[0]) for name in rows):
            raise SDKError("Expected one complete SDK root with no sibling payloads")
        root = roots[0]
        if root and any(not (name + "/").startswith(root) for name in paths.values()):
            raise SDKError("SDK wrapper has unrelated sibling directories")
        files = {name[len(root):]: dict(row, archive_path=name) for name, row in rows.items()}
        directories = sorted({name[len(root):] for folded, name in paths.items()
                              if name[len(root):] and kinds.get(folded, True)})
        if any(name.casefold() == RECEIPT.casefold() for name in files):
            raise SDKError("Archive contains reserved installer receipt")
        if not any(re.fullmatch(r"GodotProject/levels/MP_[A-Za-z0-9_]+\.tscn", name) for name in files):
            raise SDKError("SDK has no stock map scenes")
        version_name = root + "sdk.version.json"
        project_name = root + "GodotProject/project.godot"
        for name in (version_name, project_name):
            if rows[name]["size"] > limits.metadata_bytes:
                raise SDKError("SDK metadata exceeds the bounded read limit")
        version_data = json.loads(archive.read(version_name).decode("utf-8-sig"), object_pairs_hook=json_object)
        version = version_data.get("version") if isinstance(version_data, dict) else None
        if not isinstance(version, str) or not re.fullmatch(r"\d{1,5}(?:\.\d{1,5}){1,3}", version):
            raise SDKError("Invalid SDK version")
        project = archive.read(project_name).decode("utf-8-sig", errors="replace")
        if not re.search(r"(?m)^\s*config_version\s*=\s*5\s*$", project):
            raise SDKError("Expected a Godot 4 SDK project")
        hint = hashlib.sha256(json.dumps({"files": files, "directories": directories}, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
        return {"format": 1, "version": version, "archive_bytes": os.fstat(stream.fileno()).st_size,
                "entries": count, "expanded_bytes": total, "archive_prefix": root,
                "files": files, "directories": directories, "central_metadata_sha256": hint,
                "integrity": "central-directory metadata only; payloads unverified"}


def inspect_archive(path, limits=Limits()):
    path = local_path(path, must_exist=True)
    if not path.is_file():
        raise SDKError("SDK archive must be a regular file")
    before = signature(path.stat())
    with path.open("rb") as stream:
        stable(path, stream)
        result = inspect_open(stream, limits)
        stable(path, stream)
        if signature(os.fstat(stream.fileno())) != before:
            raise SDKError("Archive changed during inspection")
    return result


def hash_stream(stream, progress=None):
    digest, done = hashlib.sha256(), 0
    while block := stream.read(CHUNK):
        digest.update(block)
        done += len(block)
        if progress:
            progress(done)
    return digest.hexdigest()


def payload_hashes(path, expected, limits):
    path = local_path(path, must_exist=True)
    before = signature(path.stat())
    with path.open("rb") as stream:
        stable(path, stream)
        if inspect_open(stream, limits) != expected:
            raise SDKError("Archive changed after diff inspection")
        with zipfile.ZipFile(stream) as archive:
            hashes = {}
            for name, row in expected["files"].items():
                with archive.open(row["archive_path"]) as payload:
                    hashes[name] = hash_stream(payload)
        stable(path, stream)
        if signature(os.fstat(stream.fileno())) != before:
            raise SDKError("Archive changed during content verification")
    return hashes


def diff_archives(old, new, verify_content=False, limits=Limits()):
    before, after = inspect_archive(old, limits), inspect_archive(new, limits)
    left, right = before["files"], after["files"]
    common = sorted(left.keys() & right.keys())
    if verify_content:
        left_hash, right_hash = payload_hashes(old, before, limits), payload_hashes(new, after, limits)
        changed = [name for name in common if left_hash[name] != right_hash[name]]
    else:
        changed = [name for name in common if (left[name]["size"], left[name]["crc32"]) != (right[name]["size"], right[name]["crc32"])]
    return {"format": 1, "old_version": before["version"], "new_version": after["version"],
            "comparison": "sha256-verified-content" if verify_content else "crc32-and-size-hints",
            "verified": bool(verify_content), "added": sorted(right.keys() - left.keys()),
            "removed": sorted(left.keys() - right.keys()), "changed": changed,
            "unchanged" if verify_content else "same_hint_unverified": sorted(set(common) - set(changed))}


def official_feed_contract(parent):
    """Read current parent constants; never duplicate fallback URLs or fetch them."""
    parent = local_path(parent, must_exist=True)
    source = parent / "Source/BF6UnrealSDK/Private/BF6UnrealSDK.cpp"
    text = local_path(source, must_exist=True).read_text(encoding="utf-8-sig")
    result = {"format": 1, "authority": "Source/BF6UnrealSDK/Private/BF6UnrealSDK.cpp"}
    for member, key in (("kOfficialIndex", "index_url"), ("kOfficialZip", "archive_url"), ("kBF6UA", "user_agent")):
        matches = re.findall(r'static\s+const\s+TCHAR\s*\*\s*' + member + r'\s*=\s*TEXT\("([^"\\]+)"\)\s*;', text)
        if len(matches) != 1:
            raise SDKError(f"Expected one authoritative SDK feed constant: {member}")
        result[key] = matches[0]
    if any(not result[key].startswith("https://") for key in ("index_url", "archive_url")):
        raise SDKError("Official SDK feed must use HTTPS")
    return result


def emit(callback, phase, done, total):
    if callback:
        callback({"phase": phase, "done": done, "total": total})


def publish_directory(stage, destination):
    """Atomic no-replace directory rename; fail closed on unsupported platforms."""
    local_path(stage, must_exist=True)
    local_path(destination)
    if os.path.lexists(destination):
        raise SDKError("Destination appeared before publication; existing contents retained")
    if os.name == "nt":
        # Windows rename never replaces an existing directory or file.
        os.rename(stage, destination)
    elif sys.platform.startswith("linux"):
        libc = ctypes.CDLL(None, use_errno=True)
        if not hasattr(libc, "renameat2"):
            raise SDKError("Atomic no-replace directory publication is unavailable")
        function = libc.renameat2
        function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        function.restype = ctypes.c_int
        if function(-100, os.fsencode(stage), -100, os.fsencode(destination), 1):
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), str(destination))
    else:
        raise SDKError("This platform needs a reviewed no-replace directory primitive")


def verify_stage(stage, hashes, expected_directories):
    found, found_directories = set(), set()
    for directory, dirs, files in os.walk(stage, followlinks=False):
        local_path(directory, must_exist=True)
        for name in dirs:
            path = local_path(Path(directory) / name, must_exist=True)
            found_directories.add(path.relative_to(stage).as_posix())
        for name in files:
            path = local_path(Path(directory) / name, must_exist=True)
            relative = path.relative_to(stage).as_posix()
            if relative not in hashes or not stat.S_ISREG(path.stat().st_mode):
                raise SDKError(f"Unexpected staged file: {relative}")
            with path.open("rb") as stream:
                digest = hash_stream(stream)
            if digest != hashes[relative]:
                raise SDKError(f"Staged SDK content changed: {relative}")
            found.add(relative)
    if found != set(hashes) or found_directories != set(expected_directories):
        raise SDKError("Staged SDK is incomplete")


def install_new(archive, destination, write=False, expected_sha256=None,
                protected_roots=(), progress=None, limits=Limits(), cancel_check=None):
    """Install into a nonexistent SDK root. Never merge/update an existing tree.

    protected_roots includes creator workspaces and previous SDK installs. A
    destination inside or above one is rejected. No source work is copied.
    expected_sha256 is an optional independently trusted download digest; the
    computed digest itself is integrity evidence, not publisher authentication.
    cancel_check, when supplied, returns True to cancel before final publication
    even if cancellation arrived during the last staged-content verification.
    """
    archive = local_path(archive, must_exist=True)
    destination = local_path(destination)
    if os.path.lexists(destination) or not destination.parent.is_dir():
        raise SDKError("Choose a NEW SDK directory under an existing parent")
    relative_path(destination.name)
    for protected in protected_roots:
        protected = local_path(protected, must_exist=True)
        if destination.is_relative_to(protected) or protected.is_relative_to(destination):
            raise SDKError("New SDK overlaps a protected workspace or installation")
    if expected_sha256 is not None and not re.fullmatch(r"[0-9a-fA-F]{64}", expected_sha256):
        raise SDKError("Expected SHA-256 must contain exactly 64 hexadecimal digits")
    inspection = inspect_archive(archive, limits)
    result = {"operation": "would_install_new", "destination": str(destination), "version": inspection["version"],
              "files": len(inspection["files"]), "expanded_bytes": inspection["expanded_bytes"],
              "workspace_action": "none; existing authored work is preserved in place"}
    if not write:
        return result
    if shutil.disk_usage(destination.parent).free < inspection["expanded_bytes"] + 64 * 1024**2:
        raise SDKError("Insufficient free space for the new SDK and verification receipt")
    stage = None
    try:
        with archive.open("rb") as stream:
            stable(archive, stream)
            before = signature(os.fstat(stream.fileno()))
            if inspect_open(stream, limits) != inspection:
                raise SDKError("Archive changed after install preflight")
            stream.seek(0)
            digest = hash_stream(stream, lambda done: emit(progress, "archive_hash", done, inspection["archive_bytes"]))
            if expected_sha256 and digest != expected_sha256.lower():
                raise SDKError("Archive SHA-256 does not match the expected download")
            local_path(destination.parent, must_exist=True)
            if os.path.lexists(destination):
                raise SDKError("Destination appeared during preflight")
            stage = Path(tempfile.mkdtemp(prefix=".bf6-sdk-stage-", dir=destination.parent))
            for name in inspection["directories"]:
                directory = local_path(stage / name)
                directory.mkdir(parents=True, exist_ok=True)
                local_path(directory, must_exist=True)
            hashes, done = {}, 0
            with zipfile.ZipFile(stream) as zipped:
                for name, row in inspection["files"].items():
                    target = local_path(stage / name)
                    target.parent.mkdir(parents=True, exist_ok=True)
                    local_path(target.parent, must_exist=True)
                    hasher, size = hashlib.sha256(), 0
                    with zipped.open(row["archive_path"]) as payload, target.open("xb") as output:
                        while block := payload.read(CHUNK):
                            size += len(block)
                            if size > row["size"]:
                                raise SDKError("Extracted file exceeds its declared size")
                            output.write(block)
                            hasher.update(block)
                            done += len(block)
                            emit(progress, "extract", done, inspection["expanded_bytes"])
                        if size != row["size"]:
                            raise SDKError("Truncated SDK entry")
                        output.flush()
                        os.fsync(output.fileno())
                    hashes[name] = hasher.hexdigest()
            stable(archive, stream)
            if signature(os.fstat(stream.fileno())) != before:
                raise SDKError("Archive changed during extraction")
        receipt = {"format": "bf6-sdk-install", "formatVersion": 1, "sdkVersion": inspection["version"],
                   "archive_sha256": digest, "central_metadata_sha256": inspection["central_metadata_sha256"],
                   "archive_digest_matched_expected": expected_sha256 is not None,
                   "directories": inspection["directories"],
                   "files": {name: {"size": inspection["files"][name]["size"], "sha256": value}
                             for name, value in sorted(hashes.items())}, "creator_workspaces_modified": False}
        encoded = (json.dumps(receipt, indent=2) + "\n").encode()
        with local_path(stage / RECEIPT).open("xb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        hashes[RECEIPT] = hashlib.sha256(encoded).hexdigest()
        emit(progress, "verify", 0, len(hashes))
        verify_stage(stage, hashes, inspection["directories"])
        # Revalidate after callbacks: callers may cancel, and concurrent writes
        # must not change which tree the final atomic operation publishes.
        local_path(stage, must_exist=True)
        local_path(destination.parent, must_exist=True)
        if cancel_check and cancel_check():
            raise InterruptedError("Cancelled before SDK publication")
        publish_directory(stage, destination)
        stage = None
        result.update(operation="installed_new", archive_sha256=digest, receipt=str(destination / RECEIPT))
        return result
    except BaseException as error:
        if stage is not None:
            error.add_note(f"Incomplete SDK retained for diagnosis at {stage}; destination was not published.")
        raise


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", nargs="?", type=Path)
    parser.add_argument("--compare", type=Path, help="Old SDK ZIP to compare with archive")
    parser.add_argument("--verify-content", action="store_true", help="Read all diff payloads and compare SHA-256")
    parser.add_argument("--destination", type=Path, help="New SDK folder, never an existing installation")
    parser.add_argument("--protect", action="append", type=Path, default=[], help="Existing creator workspace/SDK to preserve")
    parser.add_argument("--expected-sha256")
    parser.add_argument("--write", action="store_true")
    parser.add_argument("--official-feed", type=Path, metavar="PARENT", help="Read feed contract from Unreal parent source")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        if args.archive or args.write or args.destination or args.compare or args.official_feed:
            parser.error("--self-test cannot be combined with other operations")
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(SDKScenarios))
        return 0 if result.wasSuccessful() else 1
    if args.write and not args.destination or args.destination and args.compare or args.verify_content and not args.compare:
        parser.error("Use --write only with --destination; content verification only with --compare; no mixed install/diff")
    if args.official_feed and (args.archive or args.destination or args.compare or args.write):
        parser.error("--official-feed is a separate read-only operation")
    if (args.expected_sha256 or args.protect) and not args.destination:
        parser.error("Expected digest and protected roots apply only to installation")
    try:
        if args.official_feed:
            result = official_feed_contract(args.official_feed)
        elif not args.archive:
            parser.error("An SDK archive or --official-feed parent path is required")
        elif args.destination:
            result = install_new(args.archive, args.destination, args.write, args.expected_sha256, args.protect)
        elif args.compare:
            result = diff_archives(args.compare, args.archive, args.verify_content)
        else:
            result = inspect_archive(args.archive)
            result.pop("files")  # CLI is concise; API retains the full inventory.
            result["directories"] = len(result["directories"])
        print(json.dumps(result, indent=2))
        return 0
    except (OSError, ValueError, zipfile.BadZipFile) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        for note in getattr(error, "__notes__", []):
            print(note, file=sys.stderr)
        return 2


class SDKScenarios(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="bf6-sdk-tests-")
        self.root = Path(self.temporary.name)
        self.addCleanup(self.temporary.cleanup)

    def archive(self, name="sdk.zip", extra=None, prefix="", version="1.4.2.0"):
        values = {"sdk.version.json": json.dumps({"version": version}),
                  "GodotProject/project.godot": "config_version=5\n",
                  "FbExportData/asset_types.json": '{"AssetTypes": []}',
                  "code/types/mod/index.d.ts": "export function Example(): void;",
                  "GodotProject/levels/MP_Test.tscn": "[gd_scene format=3]\n"}
        values.update(extra or {})
        target = self.root / name
        with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zipped:
            for path, value in values.items():
                zipped.writestr(prefix + path, value)
        return target

    def test_inspection_default_install_does_not_write(self):
        archive = self.archive()
        before = archive.read_bytes()
        self.assertEqual(inspect_archive(archive)["version"], "1.4.2.0")
        self.assertEqual(install_new(archive, self.root / "new")["operation"], "would_install_new")
        self.assertFalse((self.root / "new").exists())
        self.assertEqual(before, archive.read_bytes())

    def test_hint_and_verified_diff_added_removed_changed(self):
        old = self.archive(extra={"docs/removed.txt": "old", "docs/changed.txt": "one", "docs/same.txt": "same"})
        new = self.archive("new.zip", {"docs/added.txt": "new", "docs/changed.txt": "two", "docs/same.txt": "same"}, version="1.4.3.0")
        hint = diff_archives(old, new)
        self.assertFalse(hint["verified"])
        self.assertNotIn("unchanged", hint)
        self.assertIn("docs/same.txt", hint["same_hint_unverified"])
        self.assertEqual(hint["added"], ["docs/added.txt"])
        self.assertEqual(hint["removed"], ["docs/removed.txt"])
        self.assertIn("docs/changed.txt", hint["changed"])
        strong = diff_archives(old, new, True)
        self.assertTrue(strong["verified"])
        self.assertIn("docs/same.txt", strong["unchanged"])

    def test_new_install_preserves_work_and_verifies_exact_payloads(self):
        archive = self.archive(prefix="PortalSDK/")
        with zipfile.ZipFile(archive, "a") as zipped:
            zipped.writestr("PortalSDK/GodotProject/empty-folder/", b"")
        workspace = self.root / "creator"
        workspace.mkdir()
        (workspace / "map.tscn").write_bytes(b"authored bytes")
        target = self.root / "new"
        result = install_new(archive, target, True, protected_roots=[workspace])
        self.assertEqual(result["operation"], "installed_new")
        self.assertEqual((workspace / "map.tscn").read_bytes(), b"authored bytes")
        self.assertFalse((target / "PortalSDK").exists())
        self.assertTrue((target / "GodotProject/empty-folder").is_dir())
        receipt = json.loads((target / RECEIPT).read_bytes())
        self.assertEqual(receipt["archive_sha256"], hashlib.sha256(archive.read_bytes()).hexdigest())
        for name, row in receipt["files"].items():
            self.assertEqual(row["sha256"], hashlib.sha256((target / name).read_bytes()).hexdigest())
        with self.assertRaises(SDKError):
            install_new(archive, target, True)
        with self.assertRaises(SDKError):
            install_new(archive, workspace / "sdk", True, protected_roots=[workspace])

    def test_unsafe_archive_names_and_aliases_are_refused_before_writes(self):
        for index, path in enumerate(("../escape", "/root", "C:/absolute", "x\\y", "x/../y", "CON.txt", "x:stream", "trailing.", "a//b", "SDK.VERSION.JSON", "GodotProject", RECEIPT)):
            with self.subTest(path=path):
                archive = self.archive(extra={path: "bad"})
                if path == "x\\y":
                    # ZipInfo normalizes Windows separators when WRITING, so
                    # forge the actual hostile local/central names afterwards.
                    archive.write_bytes(archive.read_bytes().replace(b"x/y", b"x\\y"))
                destination = self.root / f"new-{index}"
                with self.assertRaises(SDKError):
                    install_new(archive, destination, True)
                self.assertFalse(destination.exists())

    def test_symlink_and_archive_limits(self):
        archive = self.archive()
        info = zipfile.ZipInfo("link")
        info.create_system = 3
        info.external_attr = (stat.S_IFLNK | 0o777) << 16
        with zipfile.ZipFile(archive, "a") as zipped:
            zipped.writestr(info, "../elsewhere")
        with self.assertRaises(SDKError):
            inspect_archive(archive)
        archive = self.archive()
        for limits in (Limits(entries=1), Limits(central_bytes=1), Limits(total_bytes=1), Limits(file_bytes=1), Limits(metadata_bytes=1)):
            with self.subTest(limits=limits), self.assertRaises(SDKError):
                inspect_archive(archive, limits)

    def test_interrupted_stage_and_retry_no_final_partial(self):
        archive = self.archive()
        destination = self.root / "new"
        def cancel(event):
            if event["phase"] == "extract":
                raise InterruptedError("User cancelled")
        with self.assertRaises(InterruptedError):
            install_new(archive, destination, True, progress=cancel)
        self.assertFalse(destination.exists())
        stages = list(self.root.glob(".bf6-sdk-stage-*"))
        self.assertEqual(len(stages), 1)
        install_new(archive, destination, True)
        self.assertTrue((destination / RECEIPT).exists())
        self.assertTrue(stages[0].exists())

    def test_disk_failure_and_changed_stage_are_not_published(self):
        archive = self.archive()
        target = self.root / "new"
        with patch(__name__ + ".os.fsync", side_effect=OSError("disk full")):
            with self.assertRaises(OSError):
                install_new(archive, target, True)
        self.assertFalse(target.exists())
        def corrupt(event):
            if event["phase"] == "verify" and event["done"] == 0:
                latest = max(self.root.glob(".bf6-sdk-stage-*"), key=lambda p: p.stat().st_mtime_ns)
                (latest / "sdk.version.json").write_bytes(b"tampered")
        with self.assertRaises(SDKError):
            install_new(archive, target, True, progress=corrupt)
        self.assertFalse(target.exists())

    def test_raced_destination_and_wrong_archive_digest_preserved(self):
        archive = self.archive()
        target = self.root / "new"
        with self.assertRaises(SDKError):
            install_new(archive, target, True, expected_sha256="0" * 64)
        self.assertFalse(list(self.root.glob(".bf6-sdk-stage-*")))
        def race(event):
            if event["phase"] == "verify":
                target.mkdir()
                (target / "user.txt").write_bytes(b"preserve")
        with self.assertRaises(SDKError):
            install_new(archive, target, True, progress=race)
        self.assertEqual((target / "user.txt").read_bytes(), b"preserve")

    def test_feed_uses_parent_constants_changes_and_rejects_ambiguity(self):
        source = self.root / "Source/BF6UnrealSDK/Private/BF6UnrealSDK.cpp"
        source.parent.mkdir(parents=True)
        text = '\n'.join(f'static const TCHAR* {key} = TEXT("{value}");' for key, value in
                         (("kOfficialIndex", "https://example.test/new-index"), ("kOfficialZip", "https://example.test/new-sdk"), ("kBF6UA", "parent-agent")))
        source.write_text(text)
        self.assertEqual(official_feed_contract(self.root)["archive_url"], "https://example.test/new-sdk")
        source.write_text(text + '\nstatic const TCHAR* kOfficialZip = TEXT("https://other.test");')
        with self.assertRaises(SDKError):
            official_feed_contract(self.root)

    def test_actual_equal_crc_and_size_are_not_content_identity(self):
        # Construct two DIFFERENT equal-length payloads with the same CRC32.
        # This control exercises real ZIPs, not mocked metadata comparisons.
        first = b"old-content-123456789"
        prefix = b"new-content-12345"
        self.assertEqual(len(prefix) + 4, len(first))
        base = zlib.crc32(prefix + bytes(4))
        basis = {}
        for bit in range(32):
            vector = zlib.crc32(prefix + (1 << bit).to_bytes(4, "little")) ^ base
            mask = 1 << bit
            while vector:
                pivot = vector.bit_length() - 1
                if pivot not in basis:
                    basis[pivot] = (vector, mask)
                    break
                vector ^= basis[pivot][0]
                mask ^= basis[pivot][1]
        vector, solution = zlib.crc32(first) ^ base, 0
        while vector:
            pivot = vector.bit_length() - 1
            vector ^= basis[pivot][0]
            solution ^= basis[pivot][1]
        second = prefix + solution.to_bytes(4, "little")
        self.assertNotEqual(first, second)
        self.assertEqual(zlib.crc32(first), zlib.crc32(second))
        old = self.archive(extra={"docs/collision.bin": first})
        new = self.archive("new.zip", {"docs/collision.bin": second})
        self.assertIn("docs/collision.bin", diff_archives(old, new)["same_hint_unverified"])
        self.assertIn("docs/collision.bin", diff_archives(old, new, True)["changed"])

    def test_source_change_and_corrupt_payload_refuse_publication(self):
        archive = self.archive()
        changed = False
        def mutate(event):
            nonlocal changed
            if event["phase"] == "extract" and not changed:
                with archive.open("ab") as output:
                    output.write(b"source changed")
                changed = True
        with self.assertRaises(SDKError):
            install_new(archive, self.root / "new", True, progress=mutate)
        self.assertFalse((self.root / "new").exists())
        archive = self.archive()
        with zipfile.ZipFile(archive, "a") as zipped:
            zipped.writestr("docs/payload.bin", b"unique-original-payload", compress_type=zipfile.ZIP_STORED)
        archive.write_bytes(archive.read_bytes().replace(b"unique-original-payload", b"unique-corrupt!-payload"))
        # Central-only inspection makes no payload-integrity claim.
        inspect_archive(archive)
        with self.assertRaises(zipfile.BadZipFile):
            install_new(archive, self.root / "new", True)
        self.assertFalse((self.root / "new").exists())

    def test_process_interruption_does_not_publish_and_can_retry(self):
        archive = self.archive()
        destination = self.root / "new"
        code = '''import os,sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from godot_patch_sdk import install_new
def stop(event):
    if event['phase'] == 'extract':
        os._exit(73)
install_new(Path(sys.argv[2]), Path(sys.argv[3]), True, progress=stop)
'''
        process = subprocess.run([sys.executable, "-c", code, str(Path(__file__).parent), str(archive), str(destination)], capture_output=True, timeout=30)
        self.assertEqual(process.returncode, 73, process.stderr)
        self.assertFalse(destination.exists())
        self.assertTrue(list(self.root.glob(".bf6-sdk-stage-*")))
        install_new(archive, destination, True)
        self.assertTrue((destination / RECEIPT).exists())

    def test_actual_filesystem_link_is_rejected(self):
        archive = self.archive()
        real = self.root / "real"
        real.mkdir()
        link = self.root / "linked"
        if os.name == "nt":
            command = subprocess.run(["cmd.exe", "/c", "mklink", "/J", str(link), str(real)], capture_output=True, timeout=10)
            self.assertEqual(command.returncode, 0, command.stderr)
        else:
            link.symlink_to(real, target_is_directory=True)
        with self.assertRaises(SDKError):
            install_new(archive, link / "new", True)
        self.assertFalse((real / "new").exists())

    def test_cancellation_arriving_during_final_verification_does_not_publish(self):
        archive = self.archive()
        target = self.root / "new"
        cancelled = False
        original = verify_stage
        def verify_then_cancel(*arguments):
            nonlocal cancelled
            original(*arguments)
            cancelled = True
        with patch(__name__ + ".verify_stage", side_effect=verify_then_cancel):
            with self.assertRaises(InterruptedError):
                install_new(archive, target, True, cancel_check=lambda: cancelled)
        self.assertFalse(target.exists())
        self.assertTrue(list(self.root.glob(".bf6-sdk-stage-*")))


if __name__ == "__main__":
    sys.exit(main())
