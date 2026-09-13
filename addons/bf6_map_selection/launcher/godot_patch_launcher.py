#!/usr/bin/env python3
"""Development setup launcher for clean, side-by-side Godot Portal SDK installs.

Run with Python 3.12+ (including Tk). No network request happens until Check
latest is clicked. SDK download and optional plugin installation are pending;
this launcher inspects an existing official ZIP and installs to a NEW folder.
Its file diff is not the SDK capability/semantic miner.
"""
from __future__ import annotations

import argparse
import hashlib
import io
import json
import os
from pathlib import Path
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
import urllib.parse
import urllib.request

import godot_patch_sdk as sdk


def read_object(path, maximum=1024 * 1024):
    path = sdk.local_path(path, must_exist=True)
    if not path.is_file() or path.stat().st_size > maximum:
        raise sdk.SDKError(f"Invalid or oversized JSON file: {path.name}")
    with path.open("rb") as source:
        data = source.read(maximum + 1)
    if len(data) > maximum:
        raise sdk.SDKError("JSON changed beyond its size limit")
    value = json.loads(data.decode("utf-8-sig"), object_pairs_hook=sdk.json_object)
    if not isinstance(value, dict):
        raise sdk.SDKError("Expected a JSON object")
    return value


def secure_url(url, host=None):
    if not isinstance(url, str) or any(ord(c) < 33 for c in url):
        raise sdk.SDKError("Invalid SDK feed URL")
    parsed = urllib.parse.urlsplit(url)
    if (parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password
            or parsed.port not in (None, 443) or parsed.fragment or parsed.query):
        raise sdk.SDKError("SDK feed requires a plain HTTPS URL")
    if host is not None and parsed.hostname.lower() != host.lower():
        raise sdk.SDKError("SDK feed redirected outside its configured official host")
    return parsed.hostname.lower()


def validate_feed(value):
    if value.get("format") != 1:
        raise sdk.SDKError("Unsupported SDK feed contract")
    host = secure_url(value.get("index_url"))
    secure_url(value.get("archive_url"), host)
    user_agent = value.get("user_agent")
    if not isinstance(user_agent, str) or not 1 <= len(user_agent) <= 512 or any(ord(c) < 32 or ord(c) > 126 for c in user_agent):
        raise sdk.SDKError("Invalid parent SDK user agent")
    return value


def palette_from_catalog(value):
    if value.get("format") != 1 or value.get("theme_color_space") != "srgb":
        raise sdk.SDKError("Unsupported parent map theme")
    theme = value.get("theme", {})
    keys = ("ink", "panel", "panel_light", "accent", "text", "text_dim", "line")
    if not isinstance(theme, dict):
        raise sdk.SDKError("Invalid parent theme object")
    for key in keys:
        rgba = theme.get(key)
        if (not isinstance(rgba, list) or len(rgba) != 4
                or any(type(number) not in (int, float) or not 0 <= number <= 1 for number in rgba)):
            raise sdk.SDKError(f"Invalid parent theme color: {key}")
    result = {}
    for key in keys:
        rgba = theme[key]
        # Tk has no alpha channel. Composite the authored line opacity over
        # the authored panel rather than treating the translucent line opaque.
        rgb = rgba[:3]
        if rgba[3] < 1:
            panel = theme.get("panel", [0, 0, 0, 1])
            rgb = [part * rgba[3] + panel[index] * (1 - rgba[3]) for index, part in enumerate(rgb)]
        result[key] = "#" + "".join(f"{round(part * 255):02x}" for part in rgb)
    return result


def load_assets(data_root=None):
    """Installed distributions use data/*.json; source runs reuse parent data."""
    base = Path(__file__).resolve().parent
    directory = Path(data_root) if data_root else base / "data"
    catalog_path = directory / "map_catalog.json"
    feed_path = directory / "sdk-feed.json"
    if data_root or catalog_path.exists():
        palette = palette_from_catalog(read_object(catalog_path))
    else:
        registry = read_object(base.parent / "Shared/Godot/plugins.json")
        entries = [row for row in registry.get("plugins", []) if row.get("id") == "map_selection"]
        if len(entries) != 1:
            raise sdk.SDKError("Expected one parent Home/Map Selection package")
        source = sdk.relative_path(entries[0].get("source"))
        palette = palette_from_catalog(read_object(base.parent / source / "addons/bf6_map_selection/data/map_catalog.json"))
    if data_root or feed_path.exists():
        feed = validate_feed(read_object(feed_path))
    else:
        feed = validate_feed(sdk.official_feed_contract(base.parent))
    return palette, feed


class OfficialRedirect(urllib.request.HTTPRedirectHandler):
    def __init__(self, host):
        self.host = host

    def redirect_request(self, request, response, code, message, headers, newurl):
        secure_url(newurl, self.host)
        return super().redirect_request(request, response, code, message, headers, newurl)


def latest_metadata(body):
    if len(body) > 1024 * 1024:
        raise sdk.SDKError("Official SDK index exceeds the metadata size limit")
    data = json.loads(body.decode("utf-8-sig"), object_pairs_hook=sdk.json_object)
    rows = data.get("versions") if isinstance(data, dict) else None
    if not isinstance(rows, list) or not 1 <= len(rows) <= 10000:
        raise sdk.SDKError("Unsupported official SDK versions schema")
    versions, seen = [], set()
    for row in rows:
        version = row.get("version") if isinstance(row, dict) else None
        if not isinstance(version, str) or not re.fullmatch(r"\d{1,5}(?:\.\d{1,5}){1,3}", version):
            raise sdk.SDKError("Invalid SDK version in official feed")
        parts = tuple(int(part) for part in version.split("."))
        normalized = parts + (0,) * (4 - len(parts))
        if normalized in seen:
            raise sdk.SDKError("Ambiguous duplicate SDK versions in official feed")
        seen.add(normalized)
        size = row.get("fileSize")
        if size is not None:
            if isinstance(size, str) and re.fullmatch(r"[0-9]{1,12}", size):
                size = int(size)
            if type(size) is not int or not 0 < size <= sdk.Limits().archive_bytes:
                raise sdk.SDKError("Invalid advisory SDK archive size")
        versions.append((normalized, version, size))
    _, version, size = max(versions)
    return {"version": version, "advisory_archive_bytes": size,
            "note": "Version metadata only. Archive size is advisory; no SDK was downloaded."}


def check_latest(feed, cancel=None, opener=None):
    feed = validate_feed(feed)
    host = secure_url(feed["index_url"])
    if cancel and cancel.is_set():
        raise InterruptedError("Cancelled")
    opener = opener or urllib.request.build_opener(OfficialRedirect(host))
    request = urllib.request.Request(feed["index_url"], headers={"User-Agent": feed["user_agent"], "Accept-Encoding": "identity"})
    with opener.open(request, timeout=20) as response:
        secure_url(response.geturl(), host)
        if response.status != 200 or response.headers.get("Content-Encoding", "identity").lower() != "identity":
            raise sdk.SDKError("Official SDK metadata request failed or used unsupported encoding")
        length = response.headers.get("Content-Length")
        if length and (not length.isdigit() or int(length) > 1024 * 1024):
            raise sdk.SDKError("Official index content length exceeds its limit")
        chunks, size = [], 0
        while block := response.read(min(64 * 1024, 1024 * 1024 + 1 - size)):
            if cancel and cancel.is_set():
                raise InterruptedError("Cancelled")
            chunks.append(block)
            size += len(block)
            if size > 1024 * 1024:
                raise sdk.SDKError("Official SDK metadata response is too large")
        return latest_metadata(b"".join(chunks))


def validate_installed(root, require_engine=False):
    """Only accept a completed installation receipt; validate launch inputs."""
    root = sdk.local_path(root, must_exist=True)
    receipt = read_object(root / sdk.RECEIPT, 64 * 1024 * 1024)
    files = receipt.get("files")
    if receipt.get("format") != "bf6-sdk-install" or receipt.get("formatVersion") != 1 or not isinstance(files, dict):
        raise sdk.SDKError("A completed SDK installation receipt is required")
    if not isinstance(receipt.get("sdkVersion"), str) or not re.fullmatch(r"\d{1,5}(?:\.\d{1,5}){1,3}", receipt["sdkVersion"]):
        raise sdk.SDKError("Invalid installed SDK version")
    for name, row in files.items():
        sdk.relative_path(name)
        if not isinstance(row, dict) or not re.fullmatch(r"[0-9a-f]{64}", str(row.get("sha256", ""))):
            raise sdk.SDKError("Invalid installed file digest")
    engines = sorted(name for name in files if re.fullmatch(r"Godot[^/]*win64[^/]*\.exe", name, re.I) and "console" not in name.lower())
    if require_engine and len(engines) != 1:
        raise sdk.SDKError("This launcher requires exactly one bundled Windows Godot executable")
    checked = list(sdk.REQUIRED) + (engines if require_engine else [])
    for name in checked:
        path = sdk.local_path(root / name, must_exist=True)
        if name not in files or not path.is_file():
            raise sdk.SDKError(f"Installed SDK is incomplete: {name}")
        with path.open("rb") as source:
            if sdk.hash_stream(source) != files[name]["sha256"]:
                raise sdk.SDKError(f"Installed launch input differs from its verified baseline: {name}")
    return {"root": str(root), "project": str(root / "GodotProject"),
            "engine": str(root / engines[0]) if require_engine else None,
            "version": receipt["sdkVersion"]}


class Worker:
    """UI-agnostic worker. Results/progress are only consumed on Tk's thread."""
    def __init__(self):
        self.events = queue.Queue()
        self.cancel = threading.Event()
        self.thread = None
        self.last_progress = 0.0
        self.last_phase = None

    def progress(self, event):
        if self.cancel.is_set():
            raise InterruptedError("Cancelled; any incomplete SDK remains unpublished")
        now = time.monotonic()
        if now - self.last_progress >= 0.1 or event["phase"] != self.last_phase:
            self.events.put(("progress", event))
            self.last_progress, self.last_phase = now, event["phase"]

    def start(self, name, operation):
        if self.thread and self.thread.is_alive():
            raise sdk.SDKError("Another setup operation is already running")
        self.cancel.clear()
        def execute():
            try:
                value = operation()
                self.events.put(("complete", {"operation": name, "result": value}))
            except Exception as error:
                message = str(error) + "\n" + "\n".join(getattr(error, "__notes__", []))
                self.events.put(("error", message.strip()))
        self.thread = threading.Thread(target=execute, name="bf6-sdk-setup", daemon=False)
        self.thread.start()


class Launcher:
    def __init__(self, window, palette, feed):
        import tkinter as tk
        from tkinter import ttk
        self.window, self.feed, self.worker = window, feed, Worker()
        self.busy, self.closing, self.installed = False, False, None
        self.buttons = []
        self.zip_path, self.previous_path, self.destination = tk.StringVar(), tk.StringVar(), tk.StringVar()
        self.status = tk.StringVar(value="Choose the official PortalSDK.zip to inspect or install.")
        window.title("BF6 Godot Patch | Development setup")
        window.geometry("900x690")
        window.minsize(720, 560)
        window.configure(bg=palette["ink"])
        style = ttk.Style(window)
        style.theme_use("clam")
        style.configure("TFrame", background=palette["ink"])
        style.configure("TLabel", background=palette["ink"], foreground=palette["text"])
        style.configure("TButton", background=palette["panel_light"], foreground=palette["text"], padding=9)
        style.map("TButton", background=[("active", palette["panel"])], foreground=[("disabled", palette["text_dim"])])
        style.configure("TEntry", fieldbackground=palette["panel"], foreground=palette["text"])
        style.configure("Horizontal.TProgressbar", background=palette["accent"], troughcolor=palette["panel"])
        frame = ttk.Frame(window, padding=20)
        frame.pack(fill="both", expand=True)
        ttk.Label(frame, text="BF6 GODOT PATCH", font=("Segoe UI", 23, "bold")).pack(anchor="w")
        ttk.Label(frame, text="Development setup | New SDK installs preserve existing creator work").pack(anchor="w", pady=(3, 16))
        self.path_row(frame, "Official SDK ZIP", self.zip_path, lambda: self.choose_zip(self.zip_path))
        self.path_row(frame, "Previous ZIP (optional file comparison)", self.previous_path, lambda: self.choose_zip(self.previous_path))
        self.path_row(frame, "New SDK destination (must not exist)", self.destination, self.choose_destination)
        actions = ttk.Frame(frame)
        actions.pack(fill="x", pady=12)
        for label, operation in (("Inspect ZIP", self.inspect), ("Compare ZIPs", self.compare), ("Check latest SDK", self.latest), ("Install new SDK", self.install)):
            button = ttk.Button(actions, text=label, command=operation)
            button.pack(side="left", padx=(0, 7))
            self.buttons.append(button)
        self.progress_bar = ttk.Progressbar(frame, mode="determinate")
        self.progress_bar.pack(fill="x", pady=5)
        ttk.Label(frame, textvariable=self.status, wraplength=820).pack(anchor="w", pady=5)
        self.output = tk.Text(frame, height=12, bg=palette["panel"], fg=palette["text"], insertbackground=palette["text"], relief="flat", wrap="word")
        self.output.pack(fill="both", expand=True, pady=8)
        self.output.configure(state="disabled")
        bottom = ttk.Frame(frame)
        bottom.pack(fill="x")
        self.open_button = ttk.Button(bottom, text="Open installed folder", command=lambda: self.open_installed(False), state="disabled")
        self.open_button.pack(side="left")
        self.launch_button = ttk.Button(bottom, text="Launch installed Godot", command=lambda: self.open_installed(True), state="disabled")
        self.launch_button.pack(side="left", padx=8)
        self.cancel_button = ttk.Button(bottom, text="Cancel operation", command=self.worker.cancel.set, state="disabled")
        self.cancel_button.pack(side="right")
        ttk.Label(frame, text="Planned: direct SDK download, optional plugin install/update, and semantic SDK change reports.", wraplength=820).pack(anchor="w", pady=(12, 0))
        window.protocol("WM_DELETE_WINDOW", self.close)
        window.after(50, self.poll)

    def path_row(self, parent, label, variable, choose):
        from tkinter import ttk
        ttk.Label(parent, text=label).pack(anchor="w", pady=(5, 2))
        row = ttk.Frame(parent)
        row.pack(fill="x")
        entry = ttk.Entry(row, textvariable=variable)
        entry.pack(side="left", fill="x", expand=True)
        button = ttk.Button(row, text="Browse", command=choose)
        button.pack(side="right", padx=(6, 0))
        self.buttons.extend((entry, button))

    def choose_zip(self, variable):
        from tkinter import filedialog
        path = filedialog.askopenfilename(parent=self.window, title="Choose an official SDK archive", filetypes=[("ZIP archives", "*.zip")])
        if path:
            variable.set(path)

    def choose_destination(self):
        from tkinter import filedialog
        path = filedialog.askdirectory(parent=self.window, title="Choose the parent folder for a NEW SDK installation", mustexist=True)
        if path:
            self.destination.set(str(Path(path) / "PortalSDK-new"))

    def begin(self, name, operation):
        if self.busy:
            return
        self.busy = True
        for button in self.buttons:
            button.configure(state="disabled")
        self.open_button.configure(state="disabled")
        self.launch_button.configure(state="disabled")
        self.cancel_button.configure(state="normal")
        self.status.set(name + "...")
        self.progress_bar.configure(mode="indeterminate")
        self.progress_bar.start(20)
        self.worker.start(name, operation)

    def inspect(self):
        path = self.zip_path.get()
        def operation():
            value = sdk.inspect_archive(path)
            value["files"] = len(value["files"])
            value["directories"] = len(value["directories"])
            return value
        self.begin("Inspect SDK ZIP", operation)

    def compare(self):
        old, new = self.previous_path.get(), self.zip_path.get()
        self.begin("Compare ZIP file hints", lambda: sdk.diff_archives(old, new))

    def latest(self):
        self.begin("Check official SDK metadata", lambda: check_latest(self.feed, self.worker.cancel))

    def install(self):
        archive, destination = self.zip_path.get(), self.destination.get()
        self.begin("Install new SDK", lambda: sdk.install_new(archive, destination, write=True, progress=self.worker.progress, cancel_check=self.worker.cancel.is_set))

    def open_installed(self, launch):
        root = self.installed
        if root:
            self.begin("Launch installed Godot" if launch else "Open installed folder", lambda: validate_installed(root, launch))

    def render(self, value):
        self.output.configure(state="normal")
        self.output.delete("1.0", "end")
        text = json.dumps(value, indent=2) if not isinstance(value, str) else value
        # The API retains complete diffs; a giant Tk insert must not stall UI.
        if len(text) > 100000:
            text = text[:100000] + "\nDisplay truncated. Use the SDK module CLI for the full file inventory."
        self.output.insert("end", text)
        self.output.configure(state="disabled")

    def poll(self):
        try:
            while True:
                kind, value = self.worker.events.get_nowait()
                if kind == "progress":
                    self.progress_bar.stop()
                    if value["phase"] == "verify":
                        self.progress_bar.configure(mode="indeterminate")
                        self.progress_bar.start(20)
                        self.status.set("Verifying staged SDK before publication...")
                    else:
                        self.progress_bar.configure(mode="determinate", maximum=max(value["total"], 1), value=value["done"])
                        self.status.set(f"{value['phase'].replace('_', ' ').capitalize()}: {value['done']:,} / {value['total']:,} bytes")
                    continue
                self.busy = False
                self.progress_bar.stop()
                self.progress_bar.configure(mode="determinate", maximum=1, value=1 if kind == "complete" else 0)
                for button in self.buttons:
                    button.configure(state="normal")
                self.cancel_button.configure(state="disabled")
                if kind == "error":
                    self.status.set("Operation stopped. Existing SDKs and creator files were preserved.")
                    self.render(value)
                else:
                    result, operation = value["result"], value["operation"]
                    self.status.set(operation + " complete.")
                    self.render(result)
                    if operation == "Install new SDK":
                        self.installed = result["destination"]
                    try:
                        if not self.closing and operation == "Launch installed Godot":
                            subprocess.Popen([result["engine"], "--editor", "--path", result["project"]], cwd=result["root"])
                        elif not self.closing and operation == "Open installed folder":
                            if os.name != "nt":
                                raise sdk.SDKError("Open this folder manually on this platform: " + result["root"])
                            os.startfile(result["root"])
                    except (OSError, ValueError) as error:
                        self.render(str(error))
                if self.installed:
                    self.open_button.configure(state="normal")
                    self.launch_button.configure(state="normal")
        except queue.Empty:
            pass
        if self.closing and not self.busy:
            self.window.destroy()
            return
        self.window.after(50, self.poll)

    def close(self):
        if self.busy:
            self.closing = True
            self.worker.cancel.set()
            self.status.set("Cancelling safely before closing...")
        else:
            self.window.destroy()


def export_feed(parent, target):
    value = validate_feed(sdk.official_feed_contract(parent))
    target = sdk.local_path(target)
    if os.path.lexists(target):
        raise sdk.SDKError("Feed output already exists; refusing replacement")
    encoded = (json.dumps(value, indent=2) + "\n").encode()
    descriptor, temporary = tempfile.mkstemp(prefix=".bf6-feed-", suffix=".tmp", dir=target.parent)
    staged = Path(temporary)
    try:
        with os.fdopen(descriptor, "wb") as output:
            output.write(encoded)
            output.flush()
            os.fsync(output.fileno())
        if sdk.local_path(staged, must_exist=True).read_bytes() != encoded:
            raise sdk.SDKError("Staged feed changed before publication")
        sdk.local_path(target.parent, must_exist=True)
        os.link(staged, target)  # atomic no replacement, including raced targets
    finally:
        sdk.local_path(staged).unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", type=Path)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--export-feed", type=Path, help="Write NEW sdk-feed.json from authoritative parent constants")
    parser.add_argument("--parent", type=Path, help="Unreal parent plugin source for --export-feed")
    args = parser.parse_args(argv)
    if args.self_test:
        result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(LauncherScenarios))
        return 0 if result.wasSuccessful() else 1
    try:
        if args.export_feed:
            if not args.parent:
                parser.error("--export-feed requires --parent")
            export_feed(args.parent, args.export_feed)
            return 0
        palette, feed = load_assets(args.data_root)
        import tkinter as tk
        window = tk.Tk()
        Launcher(window, palette, feed)
        window.mainloop()
        return 0
    except (OSError, ValueError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


class LauncherScenarios(unittest.TestCase):
    def test_real_parent_assets_and_alpha_conversion(self):
        palette, feed = load_assets()
        self.assertEqual(palette["accent"], "#ff3c00")
        self.assertNotEqual(palette["line"], "#aec0cc")
        self.assertEqual(feed["archive_url"], sdk.official_feed_contract(Path(__file__).resolve().parent.parent)["archive_url"])

    def test_version_order_and_advisory_string_size(self):
        value = latest_metadata(b'{"versions":[{"version":"1.9.0.0","fileSize":"100"},{"version":"1.10.0.0","fileSize":200}]}')
        self.assertEqual(value["version"], "1.10.0.0")
        self.assertEqual(value["advisory_archive_bytes"], 200)
        for invalid in (b'{}', b'{"versions":[]}', b'{"versions":[{"version":"latest"}]}', b'{"versions":[{"version":"1.2","fileSize":true}]}', b'{"versions":[{"version":"1.2"},{"version":"1.2.0"}]}'):
            with self.subTest(body=invalid), self.assertRaises(sdk.SDKError):
                latest_metadata(invalid)

    def test_redirect_controls(self):
        for url in ("http://official.test/index", "https://other.test/index", "https://name@official.test/index", "https://official.test:444/index"):
            with self.subTest(url=url), self.assertRaises(sdk.SDKError):
                secure_url(url, "official.test")
        handler = OfficialRedirect("official.test")
        with self.assertRaises(sdk.SDKError):
            handler.redirect_request(None, None, 302, "redirect", {}, "https://elsewhere.test/data")

    def test_worker_does_not_block_and_errors_return_to_ui_queue(self):
        worker = Worker()
        entered, release = threading.Event(), threading.Event()
        def operation():
            entered.set()
            if not release.wait(5):
                raise RuntimeError("test worker timeout")
            return {"done": True}
        worker.start("test", operation)
        self.assertTrue(entered.wait(2))
        self.assertTrue(worker.thread.is_alive())
        with self.assertRaises(sdk.SDKError):
            worker.start("another", lambda: None)
        release.set()
        worker.thread.join(5)
        self.assertEqual(worker.events.get_nowait(), ("complete", {"operation": "test", "result": {"done": True}}))
        worker.start("failure", lambda: (_ for _ in ()).throw(sdk.SDKError("failure control")))
        worker.thread.join(5)
        self.assertEqual(worker.events.get_nowait(), ("error", "failure control"))

    def test_cancel_and_progress_throttling(self):
        worker = Worker()
        for i in range(1000):
            worker.progress({"phase": "extract", "done": i, "total": 1000})
        self.assertLess(worker.events.qsize(), 10)
        worker.cancel.set()
        with self.assertRaises(InterruptedError):
            worker.progress({"phase": "extract", "done": 1000, "total": 1000})

    def test_installed_launch_validation_detects_binary_and_config_changes(self):
        fixture = sdk.SDKScenarios()
        fixture.setUp()
        try:
            archive = fixture.archive(extra={"Godot_v4.6.3-stable_win64.exe": b"not-executed-test-payload"})
            target = fixture.root / "new"
            sdk.install_new(archive, target, True)
            result = validate_installed(target, True)
            self.assertEqual(result["project"], str(target / "GodotProject"))
            (target / "Godot_v4.6.3-stable_win64.exe").write_bytes(b"changed")
            with self.assertRaises(sdk.SDKError):
                validate_installed(target, True)
        finally:
            fixture.doCleanups()

    def test_bounded_official_metadata_network_transport_controls(self):
        feed = {"format": 1, "index_url": "https://official.test/versions.json", "archive_url": "https://official.test/PortalSDK.zip", "user_agent": "parent-agent"}
        class Response(io.BytesIO):
            status = 200
            headers = {}
            def geturl(self):
                return "https://official.test/versions.json"
        class Opener:
            def __init__(self, response):
                self.response = response
            def open(self, request, timeout):
                self.request, self.timeout = request, timeout
                return self.response
        opener = Opener(Response(b'{"versions":[{"version":"1.4.2.0","fileSize":"123"}]}'))
        self.assertEqual(check_latest(feed, opener=opener)["version"], "1.4.2.0")
        self.assertEqual(opener.request.get_header("User-agent"), "parent-agent")
        self.assertEqual(opener.timeout, 20)
        with self.assertRaises(sdk.SDKError):
            check_latest(feed, opener=Opener(Response(b" " * (1024 * 1024 + 1))))
        response = Response(b"should not read body")
        response.geturl = lambda: "https://elsewhere.test/versions.json"
        with self.assertRaises(sdk.SDKError):
            check_latest(feed, opener=Opener(response))

    def test_feed_publication_failure_preserves_final_and_retry(self):
        with tempfile.TemporaryDirectory(prefix="bf6-feed-test-") as directory:
            target = Path(directory) / "sdk-feed.json"
            parent = Path(__file__).resolve().parent.parent
            with patch(__name__ + ".os.fsync", side_effect=OSError("disk full")):
                with self.assertRaises(OSError):
                    export_feed(parent, target)
            self.assertFalse(target.exists())
            export_feed(parent, target)
            original = target.read_bytes()
            with self.assertRaises(sdk.SDKError):
                export_feed(parent, target)
            self.assertEqual(target.read_bytes(), original)

    def test_actual_tk_controls_inspect_and_install_fixture_without_blocking(self):
        import tkinter as tk
        window = tk.Tk()
        window.withdraw()
        fixture = sdk.SDKScenarios()
        fixture.setUp()
        try:
            palette, feed = load_assets()
            app = Launcher(window, palette, feed)
            archive = fixture.archive()
            app.zip_path.set(str(archive))
            app.destination.set(str(fixture.root / "new"))
            def finish():
                deadline = time.monotonic() + 10
                updates = 0
                while app.busy and time.monotonic() < deadline:
                    window.update()
                    updates += 1
                    time.sleep(0.005)
                self.assertFalse(app.busy, "GUI worker failed to deliver its completion")
                self.assertGreater(updates, 0)
            app.inspect()
            self.assertTrue(app.busy)
            finish()
            self.assertIn('"version": "1.4.2.0"', app.output.get("1.0", "end"))
            self.assertFalse((fixture.root / "new").exists())
            app.install()
            finish()
            self.assertTrue((fixture.root / "new" / sdk.RECEIPT).exists())
            self.assertEqual(str(app.open_button.cget("state")), "normal")
            receipt = (fixture.root / "new" / sdk.RECEIPT).read_bytes()
            app.install()
            finish()
            self.assertIn("Choose a NEW SDK directory", app.output.get("1.0", "end"))
            self.assertEqual((fixture.root / "new" / sdk.RECEIPT).read_bytes(), receipt)
        finally:
            window.destroy()
            fixture.doCleanups()


if __name__ == "__main__":
    sys.exit(main())
