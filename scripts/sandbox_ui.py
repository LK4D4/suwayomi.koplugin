"""Authenticated, standard-library UI control for the repository sandbox.

Only the sandbox patch's compact observation and existing visible controls are
used. Download and Open always go through the production plugin's UI handlers.
"""

import errno
import hashlib
import json
import re
import struct
import time
import urllib.error
import urllib.request
import zipfile
import zlib
from pathlib import Path


class SandboxUIError(RuntimeError):
    """A public diagnostic which contains no response body or private path."""


def _require(condition, message):
    if not condition:
        raise SandboxUIError(message)


def _digest(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _png(data):
    """Check the complete non-interlaced fixture PNG, including CRCs and pixels."""
    _require(data.startswith(b"\x89PNG\r\n\x1a\n"), "Invalid PNG signature")
    offset, header, pixels, ended = 8, None, bytearray(), False
    while offset < len(data):
        _require(offset + 12 <= len(data), "Truncated PNG chunk")
        size = struct.unpack_from(">I", data, offset)[0]
        kind = data[offset + 4:offset + 8]
        end = offset + 12 + size
        _require(end <= len(data), "Truncated PNG data")
        chunk = data[offset + 8:end - 4]
        crc = struct.unpack_from(">I", data, end - 4)[0]
        _require(zlib.crc32(kind + chunk) & 0xFFFFFFFF == crc, "Invalid PNG checksum")
        if header is None:
            _require(kind == b"IHDR" and size == 13, "Missing PNG header")
            header = struct.unpack(">IIBBBBB", chunk)
        elif kind == b"IHDR":
            raise SandboxUIError("Duplicate PNG header")
        if kind == b"IDAT":
            pixels.extend(chunk)
        if kind == b"IEND":
            _require(size == 0 and end == len(data), "Invalid PNG end")
            ended = True
        offset = end
    _require(header is not None and ended, "Incomplete PNG")
    width, height, depth, color, compression, filtering, interlace = header
    _require(width > 0 and height > 0 and compression == filtering == interlace == 0,
             "Unsupported fixture PNG format")
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}.get(color)
    _require(channels and depth in (1, 2, 4, 8, 16), "Invalid PNG pixel format")
    row_size = (width * channels * depth + 7) // 8
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(pixels, (row_size + 1) * height + 1)
    except zlib.error:
        raise SandboxUIError("Invalid PNG compressed pixels") from None
    _require(decoder.eof and not decoder.unused_data and len(raw) == (row_size + 1) * height,
             "Invalid PNG pixel count")
    _require(all(raw[index] <= 4 for index in range(0, len(raw), row_size + 1)),
             "Invalid PNG row filter")
    return {"width": width, "height": height}


def _pages(path):
    try:
        with zipfile.ZipFile(path) as archive:
            entries = [entry for entry in archive.infolist() if not entry.is_dir()]
            _require(len(entries) == 3 and all(entry.filename.lower().endswith(".png") for entry in entries),
                     "Fixture archive must contain exactly three PNG pages")
            _require(len({entry.filename for entry in entries}) == 3, "Duplicate archive page")
            pages = [archive.read(entry) for entry in sorted(entries, key=lambda entry: entry.filename)]
            for page in pages:
                _png(page)
            return pages
    except (OSError, zipfile.BadZipFile, RuntimeError):
        raise SandboxUIError("Could not validate fixture archive") from None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


class Inspector:
    """Control one configured sandbox without printing private transport data."""

    def __init__(self, root: Path):
        self.root = Path(root).resolve()
        try:
            configuration = json.loads((self.root / "sandbox.json").read_text(encoding="utf-8"))
            port = configuration["inspector_port"]
            self.token = (self.root / "profile/inspector.token").read_text(encoding="ascii").strip()
            secrets = json.loads((self.root / "secrets.json").read_text(encoding="utf-8"))
            self.auth_mode = configuration.get("auth_mode", "basic_auth")
            self.credentials = {
                "server_url": f"http://127.0.0.1:{configuration['server_port']}",
                "username": secrets["username"], "password": secrets["password"],
            }
        except (OSError, ValueError, KeyError):
            raise SandboxUIError("Missing or invalid sandbox inspector configuration") from None
        _require(type(port) is int and 1024 <= port <= 65535, "Invalid inspector port")
        _require(re.fullmatch(r"[0-9a-fA-F]{64}", self.token), "Invalid inspector token")
        _require(self.auth_mode in ("basic_auth", "simple_login", "ui_login"), "Invalid sandbox authentication mode")
        self.url = f"http://127.0.0.1:{port}"
        self._private = [self.token, str(self.root)] + [
            value for value in secrets.values() if isinstance(value, str) and value
        ]
        # Never inherit proxy settings or redirect the Authorization header.
        self._http = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
        self._transition_until = time.monotonic() + 15

    def _request(self, path, data=None):
        _require(path.startswith("/koreader/") and "?" not in path and "#" not in path,
                 "Invalid inspector control")
        headers = {"Authorization": "Bearer " + self.token}
        body = None
        if data is not None:
            headers["Content-Type"] = "application/json"
            body = json.dumps(data, ensure_ascii=False).encode("utf-8")
            _require(len(body) <= 8192, "Inspector input is too large")
        request = urllib.request.Request(self.url + path, headers=headers, data=body)
        observation = path in ("/koreader/ui/httpinspector/observe/", "/koreader/device/screen/bb")
        while True:
            try:
                with self._http.open(request, timeout=10) as response:
                    _require(response.status == 200, "Unexpected inspector response")
                    return response.read()
            except urllib.error.HTTPError as error:
                raise SandboxUIError(f"Inspector HTTP {error.code}") from None
            except urllib.error.URLError as error:
                refused = isinstance(error.reason, ConnectionRefusedError) or (
                    isinstance(error.reason, OSError) and error.reason.errno == errno.ECONNREFUSED)
                reset = observation and isinstance(error.reason, ConnectionResetError)
                if (refused or reset) and time.monotonic() < self._transition_until:
                    time.sleep(max(0, min(0.2, self._transition_until - time.monotonic())))
                    continue
                raise SandboxUIError("Inspector connection refused" if refused else "Inspector transport failed") from None
            except ConnectionResetError:
                # A listener can close after connect but before accepting this
                # observation. Never replay a possibly executed control action.
                if observation and time.monotonic() < self._transition_until:
                    time.sleep(0.2)
                    continue
                raise SandboxUIError("Inspector connection reset") from None
            except (OSError, ValueError) as error:
                raise SandboxUIError("Inspector transport failed: " + type(error).__name__) from None

    def _observe(self):
        try:
            response = json.loads(self._request("/koreader/ui/httpinspector/observe/"))
            _require(isinstance(response, list) and len(response) == 1 and isinstance(response[0], dict),
                     "Invalid inspector observation")
            state = response[0]
            state["controls"] = state.get("controls") or []
            state["fields"] = state.get("fields") or []
            _require(isinstance(state["fields"], list) and all(isinstance(item, dict) for item in state["fields"]),
                     "Invalid inspector fields")
            _require(isinstance(state["controls"], list) and all(isinstance(item, dict) for item in state["controls"]),
                     "Invalid inspector controls")
            return state
        except (ValueError, TypeError):
            raise SandboxUIError("Invalid inspector observation") from None

    def _public(self, value):
        if isinstance(value, dict):
            return {key: self._public(item) for key, item in value.items()
                    if key not in ("activate", "fill", "document_file", "directory_path")}
        if isinstance(value, list):
            return [self._public(item) for item in value]
        if isinstance(value, str):
            for private in self._private:
                value = value.replace(private, "[private]")
            value = re.sub(r"https?://\S+", "[endpoint]", value)
            return re.sub(r"(?<![\w])(?:[A-Za-z]:[\\/]|/[A-Za-z_.])[^\n]*", "[path]", value)
        return value

    def observe(self):
        return self._public(self._observe())

    def _wait(self, predicate, description, timeout=15):
        _require(timeout > 0, "Wait timeout must be positive")
        deadline = time.monotonic() + timeout
        while True:
            state = self._observe()
            if predicate(state):
                return state
            if time.monotonic() >= deadline:
                last = json.dumps(self._public(state), ensure_ascii=False)[:800]
                raise SandboxUIError("Timed out waiting for " + description + "; last observation: " + last)
            time.sleep(0.2)

    def wait(self, title, timeout=15):
        return self._public(self._wait(lambda state: state.get("title") == title, "expected title", timeout))

    @staticmethod
    def _control(state, label):
        matches = [control for control in state["controls"] if control.get("label") == label]
        _require(len(matches) == 1 and matches[0].get("enabled") is True,
                 "Label must identify exactly one enabled control on the current screen")
        return matches[0]

    def _tap(self, label):
        before = self._observe()
        control = self._control(before, label)
        if not control.get("ready"):
            before = self._wait(
                lambda state: any(item.get("label") == label and item.get("enabled") and item.get("ready")
                                  for item in state["controls"]), "painted control")
            control = self._control(before, label)
        if label in ("Open", "Go to Suwayomi"):
            self._transition_until = time.monotonic() + 15
        self._request(control["activate"])
        # Widget callbacks may enqueue work for the next UI tick. A successful
        # HTTP method invocation alone does not establish a visible transition.
        time.sleep(0.1)
        return self._wait(lambda state: state != before, "visible control effect")

    def tap(self, label):
        return self._public(self._tap(label))

    def credential(self, name, invalid=False):
        _require(name in self.credentials, "Unknown sandbox credential")
        _require(not invalid or name == "password", "Only the password supports the invalid control")
        return self.credentials[name] + ("-invalid" if invalid else "")

    def fill(self, field, value):
        """Fill one observed InputText without exposing its old or new content."""
        _require(isinstance(value, str) and len(value.encode("utf-8")) <= 4096
                 and not any(char in value for char in "\0\r\n"), "Invalid field input")
        before = self._observe()
        matches = [item for item in before["fields"]
                   if item.get("hint") == str(field) or str(item.get("index")) == str(field)]
        _require(len(matches) == 1 and matches[0].get("enabled") is True,
                 "Field must identify exactly one editable input on the current screen")
        if value:
            self._private.insert(0, value)
        self._request("/koreader/ui/httpinspector/fill/", {"field": matches[0]["fill"], "value": value})
        self._wait(lambda state: state.get("input_revision", 0) > before.get("input_revision", 0),
                   "field edit")
        return {"filled_field": matches[0]["index"], "value_omitted": True}

    def auth_smoke(self):
        """Exercise setup fields, method selection and connection test before smoke."""
        self.home()
        self._tap("Settings")
        self._tap("Setup wizard")
        self.wait("Suwayomi setup: connection (not tested)")
        for field, name in (("Server URL", "server_url"), ("Username", "username"), ("Password", "password")):
            self.fill(field, self.credential(name))
        labels = {"basic_auth": "Basic Auth", "simple_login": "Simple Login", "ui_login": "UI Login"}
        desired = labels[self.auth_mode]
        # Exercise all choices, then restore the configured method for testing.
        for choice in [label for label in labels.values() if label != desired] + [desired]:
            state = self._observe()
            controls = [item for item in state["controls"]
                        if item.get("label") in ("Authentication: " + label for label in labels.values())]
            _require(len(controls) == 1, "Expected the setup authentication selector")
            self._tap(controls[0]["label"])
            self.wait("Authentication method")
            self._tap(choice)
        for invalid in (True, False):
            self.fill("Password", self.credential("password", invalid=invalid))
            self._tap("Test connection")
            result = self._wait(lambda state: bool(state.get("message"))
                                and state.get("message") != "Testing Suwayomi connection...",
                                "connection test result", 40)
            passed = result.get("message", "").startswith("Connection test passed")
            _require(passed != invalid, "Wrong password was accepted" if invalid else "Corrected credentials failed")
            dismiss = [item["label"] for item in result["controls"]
                       if item.get("label") in ("Dismiss message", "Close") and item.get("enabled")]
            _require(len(dismiss) == 1, "Expected one connection result dismiss action")
            self._tap(dismiss[0])
            state = self.wait("Suwayomi setup: connection (" + ("failed" if invalid else "tested") + ")")
            proceed = [item for item in state["controls"] if item.get("label") == "Continue"]
            _require(len(proceed) == 1 and proceed[0].get("enabled") == (not invalid),
                     "Setup Continue does not match the connection result")
        self._tap("Continue")
        directory = self._wait(lambda state: state.get("directory_path") is not None,
                               "download directory chooser")
        _require(Path(directory["directory_path"]).resolve() == self.root / "downloads",
                 "Setup directory is not the sandbox downloads directory")
        self._tap("Use this folder")
        self._tap("Choose")
        self.wait("Suwayomi")
        result = self.smoke()
        return {"auth_mode": self.auth_mode, "setup_fields_filled": True,
                "method_selected_via_ui": True, "setup_connection_test_passed": True,
                "wrong_password_rejected": True, "continue_blocked_after_rejection": True,
                "corrected_credentials_passed": True,
                "credentials_saved_via_continue": True, "chapter_smoke": result}

    def home(self):
        before = self._observe()
        if before.get("document_file"):
            self.close_reader()
        elif before.get("title") == "Suwayomi":
            self._control(before, "Library")
            return self._public(before)
        self._request("/koreader/ui/suwayomi/showHome/")
        state = self._wait(lambda state: state.get("title") == "Suwayomi"
                           and any(item.get("label") == "Library" for item in state["controls"]), "Suwayomi home")
        self._control(state, "Library")
        return self._public(state)

    def screenshot(self, path):
        data = self._request("/koreader/device/screen/bb")
        dimensions = _png(data)
        try:
            Path(path).write_bytes(data)
        except OSError:
            raise SandboxUIError("Could not save screenshot") from None
        return {"screenshot_sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data), **dimensions}

    def close_reader(self):
        state = self._observe()
        _require(state.get("document_file"), "No open reader document")
        if state.get("screen") != "reader-menu":
            self._request("/koreader/ui/menu/onShowMenu/")
            state = self._wait(lambda state: state.get("screen") == "reader-menu", "reader menu")
        if not any(item.get("label") == "Go to Suwayomi" for item in state["controls"]):
            # The file-browser icon is an action, not a tab. Use the observed
            # main-menu icon instead of walking unrelated reader controls.
            self._tap("appbar.menu")
        self._wait(lambda current: any(item.get("label") == "Go to Suwayomi"
                                      for item in current["controls"]), "reader return action")
        self._tap("Go to Suwayomi")
        returned = self._wait(lambda current: not current.get("document_file")
                              and any(re.fullmatch(r"Chapter 00[123]", item.get("label", ""))
                                      for item in current["controls"]), "Suwayomi chapter return")
        return self._public(returned)

    def quit(self):
        if self._observe().get("document_file"):
            self.close_reader()
        self._request("/koreader/ui/httpinspector/quit/")
        self._transition_until = 0
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                self._observe()
            except SandboxUIError as error:
                if str(error) == "Inspector connection refused":
                    return {"inspector_stopped": True, "exit_requested": "normal"}
                raise
            time.sleep(0.2)
        raise SandboxUIError("Inspector did not stop after normal quit")

    def _archives(self):
        try:
            files = sorted(path for path in (self.root / "downloads").rglob("*")
                           if path.is_file() and path.suffix.lower() == ".cbz")
            _require(all(path.resolve().is_relative_to(self.root / "downloads") for path in files),
                     "Download archive escapes sandbox")
            return {path: _digest(path) for path in files}
        except OSError:
            raise SandboxUIError("Could not inspect sandbox archives") from None

    def smoke(self):
        """Download one unused fixture through the UI and prove archive identity."""
        try:
            deployment = json.loads((self.root / "deployment.json").read_text(encoding="utf-8"))
            plugin = self.root / "profile/plugins/suwayomi.koplugin"
            deployed_files = {}
            for name, expected in deployment["files"].items():
                path = (plugin / name).resolve()
                _require(path.is_relative_to(plugin), "Deployment path escapes sandbox plugin")
                deployed_files[name] = _digest(path)
                _require(deployed_files[name] == expected, "Deployed payload differs from deployment manifest")
            _require(deployed_files, "Deployment manifest contains no runtime files")
            patch_digest = _digest(self.root / "profile/patches/2-sandbox-inspector.lua")
        except (OSError, ValueError, KeyError, TypeError):
            raise SandboxUIError("Could not verify sandbox deployment") from None
        before = self._archives()
        self.home()
        self._tap("Library")
        self._wait(lambda state: any(item.get("label") == "Sandbox Alpha" for item in state["controls"]), "fixture library row")
        self._tap("Sandbox Alpha")
        self._wait(lambda state: any(item.get("label") == "Open chapters" for item in state["controls"]), "manga actions")
        self._tap("Open chapters")
        labels = [f"Chapter {index:03}" for index in range(1, 4)]
        state = self._wait(lambda state: all(any(item.get("label") == label for item in state["controls"])
                                             for label in labels), "three fixture chapters")
        chapter = None
        for label in labels:
            control = self._control(state, label)
            status = control.get("status", "") or ""
            _require(not any(word in status for word in ("Queued", "Downloading", "Verifying", "Failed", "pending", "blocked")),
                     "Fixture has existing active or failed work; use a fresh sandbox")
            if not status or status == "Read":
                chapter = label
                break
        _require(chapter is not None, "All fixture chapters are already downloaded; create a new empty sandbox")
        source = self.root / "server-data/local/Sandbox Alpha" / (chapter + ".cbz")
        source_pages = _pages(source)
        self._tap(chapter)
        self._wait(lambda state: state.get("title") == chapter
                   and any(item.get("label") == "Download" for item in state["controls"]), "chapter Download action")
        self._tap("Download")
        observed_statuses = []

        def completed(current):
            rows = [item for item in current["controls"] if item.get("label") == chapter]
            if len(rows) != 1:
                return False
            status = rows[0].get("status", "") or ""
            _require("Failed" not in status and "blocked" not in status, "Fixture download failed")
            if "Downloading" in status or "Downloaded" in status:
                if status not in observed_statuses:
                    observed_statuses.append(status)
            return "Downloaded" in status

        self._wait(completed, "fixture download completion", 90)
        _require(observed_statuses, "No Downloading or Downloaded UI state was observed")
        after = self._archives()
        _require(all(after.get(path) == digest for path, digest in before.items()), "Existing archive bytes changed")
        added = set(after) - set(before)
        _require(len(added) == 1, "Download must create exactly one new CBZ")
        archive = added.pop()
        pages = _pages(archive)
        _require(pages == source_pages, "Downloaded PNG bytes differ from source fixture")
        self._tap(chapter)
        self._wait(lambda state: state.get("title") == chapter
                   and any(item.get("label") == "Open" for item in state["controls"]), "chapter Open action")
        self._tap("Open")
        reader = self._wait(lambda state: state.get("screen") == "reader"
                            and state.get("document_file") is not None, "rendered reader document")
        _require(Path(reader["document_file"]).resolve() == archive.resolve(), "Reader opened a different archive")
        _require(reader.get("document_pages") == 3, "Reader did not open all three fixture pages")
        evidence = self.root / "evidence"
        evidence.mkdir(exist_ok=True)
        screenshot_name = chapter.lower().replace(" ", "-") + "-reader.png"
        screenshot = self.screenshot(evidence / screenshot_name)
        returned = self.close_reader()
        _require(self._archives() == after, "Archive set or bytes changed after reader return")
        _require(_pages(archive) == source_pages, "Archive pages changed after reader return")
        return {
            "fixture": "Sandbox Alpha", "chapter": chapter,
            "deployment_revision": self._public(deployment.get("revision")),
            "deployed_files": deployed_files, "inspector_patch_sha256": patch_digest,
            "observed_download_states": observed_statuses,
            "new_archives": 1, "existing_archives_unchanged": len(before),
            "archive_sha256": after[archive],
            "source_pages_identical": True,
            "page_sha256": [hashlib.sha256(page).hexdigest() for page in pages],
            "opened_exact_archive": True, "reader_pages": reader["document_pages"],
            "screenshot": {"alias": screenshot_name, **screenshot},
            "returned_via": "Go to Suwayomi", "return_title": returned.get("title"),
            "archives_unchanged_after_return": True,
        }
