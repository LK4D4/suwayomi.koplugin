"""Opt-in upgrade acceptance. Private evidence belongs to the disposable root."""
import json
from pathlib import Path
import time


class AcceptanceFailure(RuntimeError):
    pass


class Blocked(RuntimeError):
    pass


class Evidence:
    """One bounded run; failed assertions remain failed even if caught or retried."""
    def __init__(self, directory, requirements):
        if not requirements or any(not checks for checks in requirements.values()):
            raise AcceptanceFailure("Empty scenario or assertion discovery")
        self.directory = Path(directory)
        self.directory.mkdir(parents=True, exist_ok=True)
        self.requirements = requirements
        self.results = {name: {"status": "unverified", "attempts": []} for name in requirements}
        self.active = None
        self.metadata = {}
        self.save()

    def save(self):
        (self.directory / "results.json").write_text(json.dumps({
            "metadata": self.metadata, "scenarios": self.results,
            "desktop_demonstrated": self.demonstrated(),
            "hardware": "unverified; separate Palma evidence required",
        }, indent=2) + "\n", encoding="utf-8")

    def check(self, name, condition):
        if self.active is None or name not in self.requirements[self.active[0]]:
            raise AcceptanceFailure("Unknown or out-of-scenario assertion")
        attempt = self.active[1]
        attempt["assertions"][name] = bool(condition) and attempt["assertions"].get(name, True)
        self.save()
        if not condition:
            raise AcceptanceFailure("Failed assertion: " + name)

    def scenario(self, name, action, diagnose=None):
        if name not in self.requirements:
            raise AcceptanceFailure("Unknown scenario")
        result = self.results[name]
        attempt = {"status": "unverified", "assertions": {}, "started": time.time()}
        result["attempts"].append(attempt)
        self.active = name, attempt
        try:
            action()
            missing = self.requirements[name] - set(attempt["assertions"])
            if missing or not all(attempt["assertions"].values()):
                raise AcceptanceFailure("Missing or failed required assertions")
            attempt["status"] = "demonstrated"
        except Blocked as error:
            attempt["reason"] = str(error)
        except Exception as error:
            attempt["status"] = "failed"
            # Exceptions may contain private paths/state; this report stays private.
            attempt["reason"] = type(error).__name__ + ": " + str(error)
            if diagnose:
                try:
                    diagnose(name)
                except Exception as diagnostic_error:
                    attempt["diagnostic_error"] = type(diagnostic_error).__name__
        finally:
            self.active = None
            statuses = [item["status"] for item in result["attempts"]]
            result["status"] = ("failed" if "failed" in statuses else
                                "unverified" if "unverified" in statuses else "demonstrated")
            self.save()
        return result["status"] == "demonstrated"

    def demonstrated(self):
        return (bool(self.results) and all(item["status"] == "demonstrated" for item in self.results.values())
                and not self.metadata.get("dirty")
                and not any(key in self.metadata for key in ("blocked", "failure", "reader_cleanup_error", "server_cleanup_error")))

# Fixed assertions prevent an accidentally empty or shortened scenario from passing.
REQUIRED = {
    "native-reader-return": {"native_entry", "server_membership", "pages", "progress", "archives"},
    "mixed-authority": {"legacy_open_only", "safe_action", "preserved", "foreign_refused"},
    "pending-unread": {"cache_read", "row_unread", "context_unread", "admitted", "preserved"},
    "verification-faults": {"rejected_twice", "released", "uncertain", "fenced", "recovered", "preserved"},
    "stale-controls": {"feedback", "policy", "ledger", "fresh_off"},
    "publication-stages": {"cache-reject", "cache-uncertain", "merge-reject", "merge-uncertain",
                           "visible-reject", "visible-uncertain", "empty", "stale", "preserved", "preload"},
    "deleted-category": {"selected", "deleted", "all_manga"},
    "browse-layouts": {"discovered", "list", "cover_text", "cover_only", "last_page"},
}


def lua(value):
    if value is None:
        return "nil"
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if isinstance(value, list):
        return "{" + ",".join(lua(item) for item in value) + "}"
    return "{" + ",".join("[" + lua(key) + "]=" + lua(item) for key, item in value.items()) + "}"


def prepare(root):
    """Install labeled synthetic preconditions only in a stopped disposable sandbox."""
    import shutil
    import sandbox
    sandbox.configuration(root)
    if sandbox.live_process(root, "reader") or sandbox.live_process(root, "server"):
        raise Blocked("Stop this sandbox before preparing upgrade fixtures")
    if (root / "upgrade-prepared.json").exists():
        raise Blocked("Upgrade fixtures already prepared; preserve evidence and use a fresh root")
    source = root / "server-data/local/Sandbox Alpha"
    archives = sorted(source.glob("*.cbz"))
    if len(archives) != 3 or not (source / "cover.png").is_file():
        raise AcceptanceFailure("Expected exactly three synthetic baseline chapters and cover")
    for index in range(1, 36):
        folder = root / "server-data/local" / f"Upgrade Manga {index:02}"
        folder.mkdir()
        shutil.copyfile(archives[0], folder / "Chapter 001.cbz")
        shutil.copyfile(source / "cover.png", folder / "cover.png")
        (folder / "details.json").write_text(json.dumps({"title": folder.name, "author": "Fixture"}))
    shutil.copyfile(Path(__file__).with_name("sandbox-upgrade.lua"), root / "profile/patches/2-upgrade-acceptance.lua")
    sandbox.write_json(root / "upgrade-prepared.json", {"fixture_manga": 36, "fixture_chapters": 3,
        "faults": "opt-in rename/sync_dir rejection; not physical storage exhaustion"})
    return {"prepared": True, "synthetic_manga": 36}


class DesktopUpgrade:
    def __init__(self, root, source, evidence):
        import sandbox
        from sandbox_ui import Inspector
        self.root, self.source, self.evidence = root, source, evidence
        self.ui = Inspector(root)
        self.server = sandbox.ServerClient(root)
        self.children = []
        self.baseline = None
        self.baseline_files = {}
        self.reset_number = 0
        self.archive = None

    def check(self, name, condition):
        self.evidence.check(name, condition)

    def settings(self):
        import subprocess
        code = "local j=require('dkjson'); print(j.encode(assert(loadfile(" + lua(str(self.root / 'profile/settings/suwayomi.lua')) + "))()))"
        result = subprocess.run(["luajit", "-e", code], capture_output=True, text=True, check=True)
        return json.loads(result.stdout)

    def write_settings(self, values):
        import sandbox
        if sandbox.live_process(self.root, "reader"):
            raise AcceptanceFailure("Fixture edit requires stopped reader")
        (self.root / "profile/settings/suwayomi.lua").write_text("return " + lua(values) + "\n", encoding="utf-8")

    def events(self):
        path = self.root / "profile/acceptance-events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def count(self, event):
        return sum(item["event"] == event for item in self.events())

    def fault(self, mode):
        (self.root / "profile/acceptance-fault").write_text(mode + "\n")

    def files(self):
        import sandbox
        return {str(path.relative_to(self.root)): sandbox.digest(path)
                for path in (self.root / "downloads").rglob("*") if path.is_file()}

    def start(self, service):
        import subprocess
        import sandbox
        if sandbox.live_process(self.root, service):
            raise Blocked("Service already running; ownership unresolved")
        log = (self.evidence.directory / (service + "-launcher.log")).open("ab")
        child = subprocess.Popen(["python3", str(Path(__file__).with_name("sandbox.py")), "--root", str(self.root), "run", service], stdout=log, stderr=log)
        log.close()
        self.children.append(child)
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise Blocked(service + " failed startup; inspect private launcher log")
            try:
                if service == "reader":
                    self.ui._transition_until = 0
                    self.ui._observe(deadline=deadline)
                    # Let initial UI transitions settle before the first observed action.
                    time.sleep(2)
                    self.ui._observe(deadline=deadline)
                else:
                    self.server.request("/api/v1/source/list")
                    if not (self.root / "server.pid.json").exists():
                        raise ConnectionError()
                    # Launcher performs fixture seeding before its readiness line.
                    if "server ready" not in (self.evidence.directory / "server-launcher.log").read_text():
                        raise ConnectionError()
                return
            except Exception:
                time.sleep(.2)
        raise Blocked(service + " startup deadline expired")

    def stop(self, service):
        import sandbox
        sandbox.stop(self.root, service)

    def native_key(self, value):
        import os
        import subprocess
        windows = set()
        expected = ("KO_HOME=" + str(self.root / "profile")).encode()
        for proc in Path("/proc").iterdir():
            if not proc.name.isdigit():
                continue
            try:
                if expected not in (proc / "environ").read_bytes().split(b"\0"):
                    continue
                result = subprocess.run(["xdotool", "search", "--onlyvisible", "--pid", proc.name], capture_output=True, text=True)
                windows.update(result.stdout.split())
            except OSError:
                continue
        if len(windows) != 1:
            raise Blocked("Expected one visible window owned by this sandbox")
        window = windows.pop()
        subprocess.run(["xdotool", "windowactivate", "--sync", window], check=True)
        subprocess.run(["xdotool", "windowfocus", "--sync", window], check=True)
        time.sleep(.4)
        subprocess.run(["xdotool", "key", "--clearmodifiers", "--delay", "100",
                        "F1" if value == "menu" else value], check=True)

    def native_entry(self):
        self.native_key("menu")
        self.ui._wait(lambda s: any(c.get("label") == "appbar.search" for c in s["controls"]), "native Search tab")
        if not any(c.get("label") == "appbar.search" and c.get("selected") for c in self.ui._observe()["controls"]):
            self.ui.tap("appbar.search")
        if not any(c.get("label") == "Suwayomi" for c in self.ui._observe()["controls"]):
            self.native_key("Next")
            self.ui._wait(lambda s: any(c.get("label") == "Suwayomi" for c in s["controls"]), "native Suwayomi item")
        self.ui.tap("Suwayomi")
        self.ui.wait("Suwayomi Library")

    def chapters(self, wait_online=True):
        import sandbox
        before = self.count("chapter-response")
        self.ui._wait(lambda s: any(c.get("label") == "Sandbox Alpha" for c in s["controls"]), "fixture Library membership")
        self.ui.tap("Sandbox Alpha")
        self.ui.tap("Open chapters")
        self.rows()
        if wait_online and sandbox.live_process(self.root, "server"):
            self.ui._wait(lambda state: self.count("chapter-response") > before, "complete background chapter response")
        return self.rows()

    def rows(self):
        return self.ui._wait(lambda s: all(any(c.get("label") == f"Chapter {index:03}" for c in s["controls"])
                                          for index in range(1, 4)), "three fixture rows")

    def row(self):
        return next(c for c in self.rows()["controls"] if c.get("label") == "Chapter 001")

    def message(self, text):
        return self.ui._wait(lambda s: text in s.get("message", ""), "required feedback", 25)

    def refresh(self):
        before = self.count("context-publication")
        self.ui.tap("appbar.menu")
        self.ui.tap("Refresh chapters")
        self.ui._wait(lambda s: self.count("context-publication") > before, "refreshed context")
        return self.rows()

    def reset(self, settings=None, online=True):
        import copy
        import sandbox
        self.stop("reader")
        self.fault("none")
        if settings is not None:
            import shutil
            self.reset_number += 1
            retained = self.evidence.directory / ("before-reset-" + str(self.reset_number))
            retained.mkdir()
            for path in (self.root / "downloads").rglob("*"):
                if path.is_file():
                    relative = path.relative_to(self.root / "downloads")
                    target = retained / relative
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
                    if relative.as_posix() not in self.baseline_files:
                        path.unlink()  # Preserved above; only this run's synthetic root.
            for relative, data in self.baseline_files.items():
                path = self.root / "downloads" / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(data)
            self.write_settings(copy.deepcopy(settings))
        running = sandbox.live_process(self.root, "server")
        if online and not running:
            self.start("server")
        elif not online and running:
            self.stop("server")
        if online and settings is not None:
            cached = settings["chapter_cache"]["mangas"][self.manga_id]["chapters"]
            for chapter in cached:
                self.graphql('mutation($input:UpdateChapterInput!){updateChapter(input:$input){chapter{id isRead}}}',
                             {"input": {"id": int(chapter["id"]), "patch": {"isRead": chapter.get("is_read") is True}}})
        self.start("reader")
        self.native_entry()
        self.chapters()

    def diagnose(self, name):
        # Preserve state before any restart. Raw evidence remains private.
        directory = self.evidence.directory
        (directory / (name + "-events.json")).write_text(json.dumps(self.events(), indent=2))
        (directory / (name + "-settings.json")).write_text(json.dumps(self.settings(), indent=2))
        (directory / (name + "-ui.json")).write_text(json.dumps(self.ui._observe(), indent=2))
        self.ui.screenshot(directory / (name + ".png"))

    def native_reader_return(self):
        import sandbox
        from sandbox_ui import _pages
        self.native_entry()
        self.check("native_entry", self.ui._observe().get("title") == "Suwayomi Library")
        self.chapters()
        source = [s for s in self.server.request("/api/v1/source/list") if s["name"] == "Local source"]
        if len(source) != 1:
            raise AcceptanceFailure("Local source discovery failed")
        self.source_id = source[0]["id"]
        manga = self.server.request(f"/api/v1/source/{self.source_id}/popular/1")["mangaList"]
        matches = [m for m in manga if m["title"] == "Sandbox Alpha"]
        self.check("server_membership", len(matches) == 1)
        self.manga_id = str(matches[0]["id"])
        self.ui.tap("Chapter 001")
        if any(c.get("label") == "Download" for c in self.ui._observe()["controls"]):
            self.ui.tap("Download")
            self.ui._wait(lambda s: any(c.get("label") == "Chapter 001" and "Downloaded" in (c.get("status") or "") for c in s["controls"]), "download", 90)
        else:
            self.native_key("Escape")
            self.rows()
        saved = self.settings()
        cached = saved["chapter_cache"]["mangas"][self.manga_id]["chapters"]
        first_id = str(next(c["id"] for c in cached if c["name"] == "Chapter 001"))
        self.archive = Path(saved["chapter_ledger"][self.manga_id + ":" + first_id]["path"])
        if not self.archive.is_file() or not self.archive.is_relative_to(self.root / "downloads"):
            raise AcceptanceFailure("Expected downloaded synthetic archive inside owned root")
        before = sandbox.digest(self.archive)
        self.check("pages", _pages(self.archive) == _pages(self.root / "server-data/local/Sandbox Alpha/Chapter 001.cbz"))
        self.ui.tap("Chapter 001")
        self.ui.tap("Open")
        opened = self.ui._wait(lambda s: s.get("document_file") is not None and s.get("screen") == "reader", "native reader")
        self.check("pages", Path(opened["document_file"]) == self.archive and opened["document_pages"] == 3)
        self.ui._request("/koreader/ui/menu/onShowMenu/")
        self.ui._wait(lambda state: state.get("screen") == "reader-menu", "reader menu")
        if not any(c.get("label") == "appbar.navigation" and c.get("selected") for c in self.ui._observe()["controls"]):
            self.ui.tap("appbar.navigation")
        for _ in range(3):
            if any(c.get("label") == "Go to page" for c in self.ui._observe()["controls"]):
                break
            self.native_key("Next")
            time.sleep(.2)
        self.ui.tap("Go to page")
        self.ui.fill("1", "2")
        self.ui.tap("Go to page")
        self.ui._wait(lambda state: state.get("document_page") == 2, "page two")
        self.ui.close_reader()
        self.rows()
        self.ui.tap("Chapter 001")
        self.ui.tap("Open")
        reopened = self.ui._wait(lambda s: s.get("document_file") is not None, "reopen")
        self.check("progress", reopened.get("document_page") == 2)
        self.ui.close_reader()
        self.rows()
        self.check("archives", sandbox.digest(self.archive) == before)
        self.baseline = self.settings()
        self.baseline_files = {path.relative_to(self.root / "downloads").as_posix(): path.read_bytes()
                               for path in (self.root / "downloads").rglob("*") if path.is_file()}
        cached = self.baseline["chapter_cache"]["mangas"][self.manga_id]["chapters"]
        self.chapter_id = str(next(c["id"] for c in cached if c["name"] == "Chapter 001"))
        self.ledger_key = self.manga_id + ":" + self.chapter_id
        self.ui.screenshot(self.evidence.directory / "native-return.png")

    def verification_faults(self):
        self.reset(self.baseline)
        before = self.files()
        prior = self.count("verification-save")
        self.fault("reject")
        for _ in range(2):
            self.ui.tap("Chapter 001")
            self.ui.tap("Open")
            state = self.message("Verification finished, but its result could not be saved.")
            self.check("preserved", not state.get("document_file") and self.files() == before)
            self.ui.tap("Dismiss message")
            self.rows()
            self.check("released", "Verifying" not in (self.row().get("status") or ""))
        self.check("rejected_twice", self.count("verification-save") == prior + 2)
        self.fault("uncertain")
        self.ui.tap("Chapter 001")
        self.ui.tap("Verify download")
        self.message("Verification finished, but saving its result is blocked")
        self.check("uncertain", self.files() == before)
        self.ui.tap("Dismiss message")
        count = self.count("verification-save")
        self.ui.tap("Chapter 001")
        self.ui.tap("Verify download")
        self.message("Verification is blocked by uncertain storage.")
        self.check("fenced", self.count("verification-save") == count and self.files() == before)
        self.fault("none")
        self.ui.tap("Dismiss message")
        time.sleep(3)
        released = self.count("verification-released")
        self.ui.tap("Chapter 001")
        self.ui.tap("Verify download")
        self.ui._wait(lambda s: self.count("verification-released") > released, "explicit recovery")
        self.check("recovered", self.files() == before)

    def pending_unread(self):
        import copy
        import sandbox
        self.reset(self.baseline)
        self.ui.tap("Chapter 001")
        self.ui.tap("Mark as read")
        def remote_read():
            chapters = self.server.request(f"/api/v1/manga/{self.manga_id}/chapters")
            return next(c for c in chapters if str(c["id"]) == self.chapter_id).get("read") is True
        deadline = time.monotonic() + 20
        while not remote_read() and time.monotonic() < deadline:
            time.sleep(.2)
        self.check("cache_read", remote_read())
        self.refresh()
        self.stop("server")
        self.ui.tap("Chapter 001")
        self.ui.tap("Mark as unread")
        values = self.settings()
        entry = values["chapter_ledger"][self.ledger_key]
        self.check("preserved", entry.get("pending_read_sync") and entry.get("pending_read_state") is False)
        self.stop("reader")
        held = self.root / "upgrade-held.cbz"
        self.archive.rename(held)
        original_hash = sandbox.digest(held)
        values["download_directory"] = str(self.root / "downloads/changed")
        (self.root / "downloads/changed").mkdir(exist_ok=True)
        self.write_settings(values)
        try:
            self.start("reader")
            self.native_entry()
            self.chapters()
            cached = self.settings()["chapter_cache"]["mangas"][self.manga_id]["chapters"]
            self.check("cache_read", next(c for c in cached if str(c["id"]) == self.chapter_id)["is_read"] is True)
            self.check("row_unread", "Read" not in (self.row().get("status") or ""))
            context = next(e for e in reversed(self.events()) if e["event"] == "context-publication")
            self.check("context_unread", next(c for c in context["reads"] if c["id"] == self.chapter_id)["read"] is False)
            self.ui.tap("appbar.menu")
            self.ui.tap("Bulk downloads >")
            self.ui.tap("Download first unread")
            jobs = self.settings().get("download_queue", {})
            if isinstance(jobs, dict):
                jobs = list(jobs.values())
            self.check("admitted", any(str(j.get("chapter", {}).get("id")) == self.chapter_id for j in jobs))
            self.check("preserved", sandbox.digest(held) == original_hash)
        except Exception:
            self.diagnose("pending-unread-before-stop")
            raise
        finally:
            self.stop("reader")
            if self.archive.exists():
                raise AcceptanceFailure("Unexpected replacement archive; held original retained")
            held.rename(self.archive)

    def mixed_authority(self):
        import copy
        self.reset(self.baseline)
        self.stop("reader")
        values = copy.deepcopy(self.baseline)
        entry = values["chapter_ledger"][self.ledger_key]
        entry.pop("endpoint_scope", None)
        contexts = values.get("reader_return_contexts", {})
        for context in contexts.values() if isinstance(contexts, dict) else contexts:
            if context.get("path") == str(self.archive):
                context.pop("endpoint_scope", None)
        before_files = self.files()
        self.write_settings(values)
        self.start("reader")
        self.native_entry()
        self.chapters()
        self.ui.tap("Chapter 001")
        controls = {c.get("label") for c in self.ui._observe()["controls"]}
        self.check("legacy_open_only", "Open" in controls and "Mark as read" not in controls and "Delete" not in controls)
        self.native_key("Escape")
        self.rows()
        self.ui.tap("appbar.menu")
        self.ui.tap("Bulk downloads >")
        self.check("safe_action", any(c.get("label") == "Download first unread" and c.get("enabled") for c in self.ui._observe()["controls"]))
        self.native_key("Escape")
        after = self.settings()
        self.check("preserved", after["chapter_ledger"][self.ledger_key] == entry and self.files() == before_files)
        self.stop("reader")
        entry["endpoint_scope"] = "https://foreign.invalid"
        self.write_settings(values)
        self.start("reader")
        self.native_entry()
        self.chapters()
        self.ui.tap("Chapter 001")
        controls = {c.get("label") for c in self.ui._observe()["controls"]}
        self.check("foreign_refused", "Open" not in controls and "Delete" not in controls and self.files() == before_files)
        self.native_key("Escape")

    def stale_controls(self):
        import os
        import signal
        import sandbox
        import copy
        configured = copy.deepcopy(self.baseline)
        configured["manga_keep_next_unread_downloads"] = {self.manga_id: 5}
        self.reset(configured)
        self.ui.tap("appbar.menu")
        self.ui.tap("Library")
        self.ui._wait(lambda s: any(c.get("label") == "Sandbox Alpha" for c in s["controls"]), "Library")
        server = sandbox.live_process(self.root, "server")
        if not server:
            raise Blocked("Owned server unavailable")
        os.kill(server["pid"], signal.SIGSTOP)
        try:
            self.chapters(wait_online=False)
            prior = self.count("context-publication")
            self.ui.tap("appbar.menu")
            label = next(c["label"] for c in self.ui._observe()["controls"] if c.get("label", "").startswith("Auto-download:"))
            self.ui.tap(label)
        finally:
            os.kill(server["pid"], signal.SIGCONT)
        self.ui._wait(lambda s: self.count("context-publication") > prior, "background publication")
        before = self.settings()
        self.check("policy", (before.get("manga_keep_next_unread_downloads") or {}).get(self.manga_id) == 5)
        self.ui.tap("Turn off auto-download")
        self.message("Chapter controls expired.")
        self.check("feedback", self.count("stale-guard") > 0)
        after = self.settings()
        self.check("policy", after.get("manga_keep_next_unread_downloads") == before.get("manga_keep_next_unread_downloads"))
        self.check("ledger", after.get("chapter_ledger") == before.get("chapter_ledger"))
        time.sleep(3.2)
        # Expired bulk controls reopen the current action menu.
        if any(c.get("label", "").startswith("Auto-download:") for c in self.ui._observe()["controls"]):
            label = next(c["label"] for c in self.ui._observe()["controls"] if c.get("label", "").startswith("Auto-download:"))
            self.ui.tap(label)
        self.ui.tap("Turn off auto-download")
        after = self.settings()
        requests = (after.get("download_refill") or {}).get("requests") or {}
        self.check("fresh_off", not (after.get("manga_keep_next_unread_downloads") or {}).get(self.manga_id)
                   and not requests.get(self.manga_id))

    def publication_stages(self):
        import copy
        import sandbox
        cached = self.baseline["chapter_cache"]["mangas"][self.manga_id]["chapters"]
        second = next(c for c in cached if c["name"] == "Chapter 002")
        second_key = self.manga_id + ":" + str(second["id"])
        for stage in ("cache", "merge", "visible"):
            for outcome in ("reject", "uncertain"):
                self.reset(self.baseline)
                self.stop("reader")
                values = copy.deepcopy(self.baseline)
                values["chapter_ledger"][second_key] = {
                    "manga_id": self.manga_id, "chapter_id": str(second["id"]),
                    "endpoint_scope": values["credentials"]["server_url"], "read": False,
                    "pending_read_sync": True, "pending_read_state": False,
                    "path": str(self.root / "downloads/missing-002.cbz"),
                }
                self.write_settings(values)
                remote = self.graphql('mutation($input:UpdateChapterInput!){updateChapter(input:$input){chapter{id isRead}}}',
                    {"input": {"id": int(self.chapter_id), "patch": {"isRead": True}}})
                if remote["updateChapter"]["chapter"]["isRead"] is not True:
                    raise AcceptanceFailure("Server read precondition failed")
                server_chapters = self.server.request(f"/api/v1/manga/{self.manga_id}/chapters")
                if len(server_chapters) != 3:
                    raise AcceptanceFailure("Server fixture discovery changed")
                before = sandbox.digest(self.archive)
                self.fault(stage + "-" + outcome)
                count = self.count("stage-fault")
                self.start("reader")
                self.native_entry()
                pending = self.settings()["chapter_ledger"].get(second_key, {})
                if pending.get("pending_read_sync") is not True or pending.get("pending_read_state") is not False:
                    raise AcceptanceFailure("Publication pending-unread precondition lost before chapter request")
                self.ui.tap("Sandbox Alpha")
                self.ui.tap("Open chapters")
                state = self.ui._wait(lambda state: self.count("stage-fault") > count, "injected stage fault")
                if state.get("message"):
                    (self.evidence.directory / (stage + "-" + outcome + "-feedback.json")).write_text(json.dumps(state))
                    if any(c.get("label") == "Dismiss message" for c in state["controls"]):
                        self.ui.tap("Dismiss message")
                state = self.ui._wait(lambda state: any(c.get("label") == "Chapter 001" for c in state["controls"]),
                                      "chapter membership after stage feedback")
                labels = {c.get("label") for c in state["controls"]}
                disk = self.settings()
                persisted = disk["chapter_cache"]["mangas"][self.manga_id]["chapters"]
                # Labeled response fixture drops Chapter 003 after the real server returns all three.
                expected_cache = 3 if stage == "cache" and outcome == "reject" else 2
                ack = (disk.get("chapter_ledger") or {}).get(second_key, {})
                expected_pending = stage == "cache" or (stage == "merge" and outcome == "reject")
                self.check(stage + "-" + outcome, "Chapter 001" in labels and "Chapter 002" in labels and "Chapter 003" not in labels
                           and len(persisted) == expected_cache
                           and (ack.get("pending_read_sync") is True) == expected_pending
                           and ack.get("read") is False and ack.get("chapter_id") == str(second["id"])
                           and ack.get("endpoint_scope") == values["credentials"]["server_url"]
                           and ack.get("path") == str(self.root / "downloads/missing-002.cbz")
                           and (ack.get("pending_read_state") is False if expected_pending else ack.get("pending_read_state") is None))
                self.check("preserved", sandbox.digest(self.archive) == before)
                self.diagnose(stage + "-" + outcome)
                self.fault("none")
        self.reset(self.baseline)
        self.fault("empty")
        self.refresh_empty()
        self.check("empty", self.settings()["chapter_cache"]["mangas"][self.manga_id]["chapters"] in ([], {}))
        self.fault("none")
        self.reset(self.baseline)
        self.fault("stale-response")
        before = self.settings()
        count = self.count("stale-response-injected")
        self.ui.tap("appbar.menu")
        self.ui.tap("Refresh chapters")
        self.ui._wait(lambda state: self.count("stale-response-injected") > count, "stale response injection")
        self.check("stale", self.settings()["chapter_cache"] == before["chapter_cache"])
        self.fault("none")
        self.reset(self.baseline)
        self.stop("reader")
        values = copy.deepcopy(self.baseline)
        values["chapter_cache"]["mangas"].pop(self.manga_id)
        self.write_settings(values)  # Labeled missing-cache precondition forces action preload.
        self.start("reader")
        self.native_entry()
        self.ui._wait(lambda state: any(c.get("label") == "Sandbox Alpha" for c in state["controls"]), "preload manga")
        self.ui.tap("Sandbox Alpha")
        before = self.count("menu-preparation")
        preloads = self.count("action-preload")
        self.ui.tap("Open next unread")
        self.ui._wait(lambda state: self.count("action-preload") > preloads, "action preload")
        opened = self.ui._wait(lambda state: state.get("screen") == "reader" and state.get("document_file"),
                               "preload action opens archive", 90)
        from sandbox_ui import _pages
        saved = self.settings()
        entry = saved["chapter_ledger"][self.ledger_key]
        context = next(e for e in reversed(self.events()) if e["event"] == "context-publication")
        self.check("preload", self.count("menu-preparation") == before
                   and len(context["reads"]) == 3
                   and len(saved["chapter_cache"]["mangas"][self.manga_id]["chapters"]) == 3
                   and entry.get("endpoint_scope") == self.baseline["credentials"]["server_url"]
                   and Path(opened["document_file"]) == self.archive and opened["document_pages"] == 3
                   and _pages(self.archive) == _pages(self.root / "server-data/local/Sandbox Alpha/Chapter 001.cbz"))
        self.ui.close_reader()

    def refresh_empty(self):
        count = self.count("context-publication")
        self.ui.tap("appbar.menu")
        self.ui.tap("Refresh chapters")
        self.ui._wait(lambda s: self.count("context-publication") > count and not any(c.get("label", "").startswith("Chapter 00") for c in s["controls"]), "authoritative empty result")

    def graphql(self, query, variables=None):
        import base64
        import urllib.request
        import sandbox
        config = sandbox.configuration(self.root)
        if config["auth_mode"] != "basic_auth":
            raise Blocked("Upgrade mutation controls currently require disposable Basic Auth sandbox")
        credentials = sandbox.read_json(self.root / "secrets.json")
        auth = base64.b64encode((credentials["username"] + ":" + credentials["password"]).encode()).decode()
        request = urllib.request.Request(config["server_url"] + "/api/graphql", data=json.dumps({"query": query, "variables": variables or {}}).encode(), headers={"Authorization": "Basic " + auth, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=15) as response:
            value = json.load(response)
        if value.get("errors") or "data" not in value:
            raise AcceptanceFailure("Synthetic server GraphQL operation failed")
        return value["data"]

    def deleted_category(self):
        import copy
        self.reset(self.baseline)
        result = self.graphql('mutation { createCategory(input:{name:"Upgrade category"}) { category { id } } }')
        category_id = result["createCategory"]["category"]["id"]
        self.stop("reader")
        values = copy.deepcopy(self.baseline)
        values["library_category_picker_behavior"] = "always"
        self.write_settings(values)
        self.start("reader")
        self.native_entry()
        self.ui._wait(lambda state: any(c.get("label") == "Upgrade category" for c in state["controls"]), "synthetic category")
        self.ui.tap("Upgrade category")
        self.check("selected", any(c.get("label") == "No manga in this library category." for c in self.ui._observe()["controls"]))
        self.graphql('mutation($id:Int!){deleteCategory(input:{categoryId:$id}){clientMutationId}}', {"id": category_id})
        categories = self.graphql('{categories{nodes{id}}}')["categories"]["nodes"]
        self.check("deleted", all(c["id"] != category_id for c in categories))
        self.ui.tap("appbar.menu")
        self.ui.tap("Refresh")
        state = self.ui._wait(lambda state: any(c.get("label") == "Sandbox Alpha" for c in state["controls"]), "All manga after deleted-category Refresh")
        self.check("all_manga", any(c.get("label") == "Sandbox Alpha" for c in state["controls"]))

    def browse_layouts(self):
        self.reset(self.baseline)
        self.ui.tap("appbar.menu")
        self.ui.tap("Suwayomi home")
        self.ui.tap("Browse")
        self.ui._wait(lambda s: any("Local source" in c.get("label", "") for c in s["controls"]), "Local source")
        label = next(c["label"] for c in self.ui._observe()["controls"] if "Local source" in c.get("label", ""))
        self.ui.tap(label)
        self.ui.tap("Popular")
        self.ui.wait("Popular")
        self.check("discovered", any(c.get("label", "").startswith("Upgrade Manga") for c in self.ui._observe()["controls"]))
        for name, label in (("list", "List"), ("cover_text", "Cover with text"), ("cover_only", "Cover only")):
            state = self.ui._observe()
            self.check(name, state.get("pages", 0) > 1)
            if state.get("page") == 1:
                self.native_key("Next")
                state = self.ui._wait(lambda current: current.get("page", 0) > 1, "later Browse page")
            first = next(c["label"] for c in state["controls"] if c.get("label", "").startswith("Upgrade Manga"))
            buttons = [c for c in state["controls"] if c.get("label") == "appbar.menu"]
            if not buttons:
                raise AcceptanceFailure("Missing Browse view widget")
            self.ui._request(buttons[-1]["activate"])
            self.ui.wait("View")
            self.ui.tap(label)
            self.ui.wait("Popular")
            observed = self.ui._observe()
            self.check(name, observed.get("view_mode") == name
                       and self.settings().get("browse_view_mode", "list") == name
                       and any(c.get("label") == first for c in observed["controls"]))
            self.ui.screenshot(self.evidence.directory / ("browse-" + name + ".png"))
        seen = set()
        for _ in range(30):
            state = self.ui._observe()
            seen.update(c["label"] for c in state["controls"] if c.get("label", "").startswith("Upgrade Manga"))
            if state.get("page") == state.get("pages"):
                break
            old = state["page"]
            self.native_key("Next")
            self.ui._wait(lambda s: s.get("page", 0) > old, "Browse next page")
        self.check("last_page", "Upgrade Manga 35" in seen)


def candidate(source):
    import os
    import subprocess
    # Windows-managed worktree pointers need translation under WSL.
    env = dict(os.environ)
    pointer = source / ".git"
    if pointer.is_file():
        gitdir = pointer.read_text().strip().removeprefix("gitdir: ")
        if len(gitdir) > 2 and gitdir[1] == ":":
            gitdir = subprocess.check_output(["wslpath", "-u", gitdir], text=True).strip()
        env.update(GIT_DIR=gitdir, GIT_WORK_TREE=str(source))
    command = ["git", "-c", "core.autocrlf=true", "-C", str(source)]
    revision = subprocess.check_output(command + ["rev-parse", "HEAD"], env=env, text=True).strip()
    dirty = subprocess.check_output(command + ["status", "--porcelain", "--untracked-files=all"], env=env, text=True)
    files = subprocess.check_output(command + ["ls-files", "-z", "main.lua", "_meta.lua", "suwayomi"], env=env).split(b"\0")
    if b"main.lua" not in files or not any(f.startswith(b"suwayomi/") for f in files):
        raise AcceptanceFailure("Runtime Git discovery empty or incomplete")
    repairs = {"63": "f9f6474", "64": "2409294", "65": "7e85063"}
    present = {issue: subprocess.run(command + ["merge-base", "--is-ancestor", commit, "HEAD"], env=env,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
               for issue, commit in repairs.items()}
    return {"commit": revision, "dirty": dirty.splitlines(), "required_repairs": present}


def run(root, source, only=None):
    import sandbox
    import shutil
    import tempfile
    import subprocess
    import uuid
    directory = root / "evidence" / ("upgrade-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
    evidence = Evidence(directory, REQUIRED)
    if only and only not in REQUIRED:
        raise AcceptanceFailure("Unknown diagnostic scenario")
    driver = None
    try:
        if not (root / "upgrade-prepared.json").is_file():
            raise Blocked("Run upgrade-acceptance --prepare in a fresh stopped sandbox first")
        if sandbox.live_process(root, "reader") or sandbox.live_process(root, "server"):
            raise Blocked("Existing sandbox service ownership; stop before this command")
        if not shutil.which("xdotool") or not shutil.which("luajit"):
            raise Blocked("Desktop controls require xdotool and LuaJIT")
        metadata = candidate(source)
        evidence.metadata = {**metadata, "versions": sandbox.configuration(root)["versions"],
            "layer": "desktop KOReader + real server", "route": "loopback",
            "faults": "labeled profile patch; not physical storage exhaustion", "selection": only}
        if not all(metadata["required_repairs"].values()) and not only:
            raise Blocked("Required #63-65 repair ancestry missing; diagnostic selections cannot establish readiness")
        expected_patch = Path(__file__).with_name("sandbox-upgrade.lua")
        if sandbox.digest(expected_patch) != sandbox.digest(root / "profile/patches/2-upgrade-acceptance.lua"):
            raise Blocked("Upgrade instrumentation changed; stop and refresh disposable profile patch")
        sandbox.verify_deployment(root)
        manifest = sandbox.read_json(root / "deployment.json")
        with tempfile.TemporaryDirectory(prefix="suwayomi-upgrade-payload-") as temp:
            payload = Path(temp) / "payload"
            subprocess.run(["bash", str(source / ".github/scripts/stage-release-payload.sh"), str(payload)], cwd=source, check=True, stdout=subprocess.DEVNULL)
            expected = {p.relative_to(payload).as_posix(): sandbox.digest(p) for p in payload.rglob("*") if p.is_file()}
        if not expected or expected != manifest["files"]:
            raise AcceptanceFailure("Canonical source payload differs from deployed manifest")
        evidence.metadata["deployed_hashes"] = expected
        evidence.metadata["instrumentation_sha256"] = sandbox.digest(root / "profile/patches/2-upgrade-acceptance.lua")
        evidence.save()
        driver = DesktopUpgrade(root, source, evidence)
        driver.fault("none")
        driver.start("server")
        driver.start("reader")
        for name in REQUIRED:
            # Native baseline always runs; selected runs cannot claim full acceptance.
            if only and name not in ("native-reader-return", only):
                continue
            method = getattr(driver, name.replace("-", "_"), None)
            if method is None:
                raise AcceptanceFailure("Required scenario missing")
            if not evidence.scenario(name, method, driver.diagnose):
                break
        sandbox.verify_deployment(root)
        evidence.metadata["hashes_after"] = True
    except Exception as error:
        evidence.metadata["blocked" if isinstance(error, Blocked) else "failure"] = type(error).__name__ + ": " + str(error)
    finally:
        if driver:
            for service in ("reader", "server"):
                try:
                    driver.stop(service)
                    evidence.metadata[service + "_stopped"] = True
                except Exception as error:
                    evidence.metadata[service + "_cleanup_error"] = type(error).__name__
        evidence.save()
    ready = evidence.demonstrated() and not evidence.metadata.get("dirty") and not any(k in evidence.metadata for k in ("blocked", "failure", "reader_cleanup_error", "server_cleanup_error"))
    print(json.dumps({"desktop_demonstrated": ready, "dirty": bool(evidence.metadata.get("dirty")),
                      "scenarios": {name: row["status"] for name, row in evidence.results.items()},
                      "hardware": "unverified", "private_report": str(directory / "results.json")}, indent=2))
    return 0 if ready else 1
