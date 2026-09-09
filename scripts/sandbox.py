#!/usr/bin/env python3
"""Run an isolated, opt-in Suwayomi/KOReader sandbox on Linux x86_64."""
import argparse
import base64
import ctypes.util
import hashlib
import http.cookiejar
import json
import os
from pathlib import Path
import platform
import secrets
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib

# Digests published by the upstream GitHub release API. Updates are deliberate.
RELEASES = {
    "server": {
        "version": "v2.3.2243",
        "url": "https://github.com/Suwayomi/Suwayomi-Server/releases/download/v2.3.2243/Suwayomi-Server-v2.3.2243-linux-x64.tar.gz",
        "sha256": "7ed20b7890a6720c4d5dd51fe9c3247f537ffcab01a1cba5c2a75626743236c3",
    },
    "koreader": {
        "version": "v2026.07.1",
        "url": "https://github.com/koreader/koreader/releases/download/v2026.07.1/koreader-linux-x86_64-v2026.07.1.tar.xz",
        "sha256": "299aadb28147a25e9432ced1214ea444a4184393b5ae97cf42402c8a61b1a1b0",
    },
}
HERE = Path(__file__).resolve().parent


def write_json(path, value):
    path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
    path.chmod(0o600)


def read_json(path):
    return json.loads(path.read_text(encoding="utf-8"))


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def configuration(root):
    value = read_json(root / "sandbox.json")
    if value.get("format") != 1:
        raise RuntimeError("Not a supported sandbox root")
    value.setdefault("auth_mode", "basic_auth")
    if value["auth_mode"] not in ("basic_auth", "simple_login"):
        raise RuntimeError("Unsupported sandbox authentication mode")
    return value


def inside(path, root):
    return path.resolve().is_relative_to(root.resolve())


def unpack(archive, destination):
    destination.mkdir()
    with tarfile.open(archive) as package:
        for member in package:
            target = destination / member.name
            if not inside(target, destination) or member.isdev() or member.isfifo():
                raise RuntimeError("Unsafe release archive entry")
            if member.issym() or member.islnk():
                link = (target.parent if member.issym() else destination) / member.linkname
                if not inside(link, destination):
                    raise RuntimeError("Unsafe release archive link")
            package.extract(member, destination)


def fetch_release(root, name):
    release = RELEASES[name]
    archive = root / "packages" / release["url"].rsplit("/", 1)[1]
    request = urllib.request.Request(release["url"], headers={"User-Agent": "suwayomi-plugin-sandbox"})
    with urllib.request.urlopen(request, timeout=60) as response, archive.open("wb") as output:
        shutil.copyfileobj(response, output)
    if digest(archive) != release["sha256"]:
        raise RuntimeError("Release checksum mismatch: " + name)
    unpack(archive, root / "runtime" / name)
    print(name + " release verified", flush=True)


def fixture_png(chapter, page):
    # Small visible numeric labels, generated without an imaging dependency.
    digits = ["111101101101111", "010110010010111", "111001111100111",
              "111001111001111", "101101111001001", "111100111001111",
              "111100111101111", "111001001001001", "111101111101111",
              "111101111001111"]
    width, height, scale = 240, 320, 10
    pixels = bytearray([255]) * (width * height)
    for index, digit in enumerate(f"{chapter:03}{page:02}"):
        for y in range(5):
            for x in range(3):
                if digits[int(digit)][y * 3 + x] == "1":
                    for dy in range(scale):
                        start = (100 + y * scale + dy) * width + 20 + index * 40 + x * scale
                        pixels[start:start + scale] = bytes(scale)
    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))
    scanlines = b"".join(b"\0" + pixels[y * width:(y + 1) * width] for y in range(height))
    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 0, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(scanlines)) + chunk(b"IEND", b""))


def setup(root, args):
    if root.exists() and any(root.iterdir()):
        raise RuntimeError("Setup requires an empty directory; existing data is never reset")
    if args.server_port == args.inspector_port:
        raise RuntimeError("Server and inspector require different ports")
    root.mkdir(parents=True, exist_ok=True, mode=0o700)
    root.chmod(0o700)
    for name in ("packages", "runtime", "server-data/local/Sandbox Alpha", "profile/settings",
                 "profile/plugins", "profile/patches", "downloads", "evidence", "logs"):
        (root / name).mkdir(parents=True, exist_ok=True)
    for name in RELEASES:
        fetch_release(root, name)
    values = {"format": 1, "server_port": args.server_port, "inspector_port": args.inspector_port,
              "auth_mode": args.auth_mode,
              "versions": {"suwayomi": RELEASES["server"]["version"], "koreader": RELEASES["koreader"]["version"]}}
    credentials = {"username": "sandbox", "password": secrets.token_hex(24)}
    write_json(root / "secrets.json", credentials)
    (root / "profile/inspector.token").write_text(secrets.token_hex(32) + "\n", encoding="utf-8")
    (root / "profile/inspector.token").chmod(0o600)
    (root / "profile/inspector.port").write_text(str(args.inspector_port) + "\n", encoding="utf-8")
    shutil.copyfile(HERE / "sandbox-inspector.lua", root / "profile/patches/2-sandbox-inspector.lua")
    server = {
        "ip": "127.0.0.1", "port": args.server_port, "authMode": args.auth_mode,
        "authUsername": credentials["username"], "authPassword": credentials["password"],
        "systemTrayEnabled": False, "initialOpenInBrowserEnabled": False,
        "webUIEnabled": True, "webUIChannel": "BUNDLED", "webUIUpdateCheckInterval": 0,
        "kcefEnabled": False, "extensionStores": [], "globalUpdateInterval": 0,
        "autoDownloadNewChapters": False, "backupInterval": 0,
    }
    (root / "server-data/server.conf").write_text(
        "".join(f"server.{key} = {json.dumps(value)}\n" for key, value in server.items()), encoding="utf-8")
    (root / "server-data/server.conf").chmod(0o600)
    profile = (
        "return {\n"
        f"  credentials = {{ server_url = {json.dumps('http://127.0.0.1:' + str(args.server_port))}, "
        f"username = {json.dumps(credentials['username'])}, password = {json.dumps(credentials['password'])}, "
        f"auth_method = {json.dumps(args.auth_mode)} }},\n"
        f"  download_directory = {json.dumps(str(root / 'downloads'), ensure_ascii=False)},\n"
        "  source_languages = { 'en' }, library_category_picker_behavior = 'automatic',\n"
        "  max_parallel_chapter_downloads = 1, manga_keep_next_unread_downloads = {},\n"
        "  delete_chapters_settings = { delete_after_mark_read = false, delete_finished_while_reading = 0 },\n"
        "}\n"
    )
    (root / "profile/settings/suwayomi.lua").write_text(profile, encoding="utf-8")
    (root / "profile/settings/suwayomi.lua").chmod(0o600)
    (root / "profile/settings.reader.lua").write_text(
        'return { language = "en", color_rendering = true, quickstart_shown_version = 202607010000, }\n', encoding="utf-8")
    fixture = root / "server-data/local/Sandbox Alpha"
    write_json(fixture / "details.json", {"title": "Sandbox Alpha", "author": "Sandbox", "description": "Generated test fixture"})
    fixture_hashes = {}
    for chapter in range(1, 4):
        filename = fixture / f"Chapter {chapter:03}.cbz"
        with zipfile.ZipFile(filename, "w", compression=zipfile.ZIP_DEFLATED) as cbz:
            for page in range(1, 4):
                entry = zipfile.ZipInfo(f"{page:03}.png", date_time=(2020, 1, 1, 0, 0, 0))
                cbz.writestr(entry, fixture_png(chapter, page))
        fixture_hashes[filename.name] = digest(filename)
    (fixture / "cover.png").write_bytes(fixture_png(1, 1))
    write_json(root / "fixtures.json", {"version": 1, "archives": fixture_hashes})
    write_json(root / "sandbox.json", values)
    return {"setup": "complete", "versions": values["versions"], "fixture_chapters": 3, "auth_mode": args.auth_mode}


def process_identity(pid):
    try:
        # comm can contain spaces/parentheses; fields after its final ')' are stable.
        fields = Path(f"/proc/{pid}/stat").read_text().rsplit(")", 1)[1].split()
        if fields[0] == "Z":
            return None
        return fields[19]
    except (FileNotFoundError, ProcessLookupError):
        return None


def live_process(root, service):
    path = root / (service + ".pid.json")
    if not path.exists():
        return None
    state = read_json(path)
    if state["start_time"] is not None and process_identity(state["pid"]) == state["start_time"]:
        return state
    return None


def verify_deployment(root):
    if not (root / "deployment.json").is_file():
        raise RuntimeError("No recorded deployment; run deploy before starting the reader")
    record = read_json(root / "deployment.json")
    destination = root / "profile/plugins/suwayomi.koplugin"
    paths = [path for path in destination.rglob("*") if path.is_file()]
    actual = {path.relative_to(destination).as_posix() for path in paths}
    if (actual != set(record["files"]) or any(path.is_symlink() for path in paths)
            or any(digest(destination / name) != expected for name, expected in record["files"].items())):
        raise RuntimeError("Installed plugin differs from its deployment record; preserve and inspect the changed files")


def deploy(root, source, revision):
    configuration(root)
    if live_process(root, "reader"):
        raise RuntimeError("Stop the sandbox reader before deploying")
    source = source.resolve()
    files = [source / name for name in ("_meta.lua", "main.lua", "README.md")]
    files += [path for path in (source / "suwayomi").rglob("*") if path.is_file()]
    files += list((source / "l10n").glob("*/suwayomi.mo"))
    if not (source / "suwayomi").is_dir() or not all(path.is_file() for path in files):
        raise RuntimeError("Source is not a plugin checkout with the required runtime payload")
    if any(not inside(path, source) or path.is_symlink() for path in files):
        raise RuntimeError("Runtime payload must contain ordinary files inside the checkout")
    destination = root / "profile/plugins/suwayomi.koplugin"
    if destination.exists() and not (root / "deployment.json").is_file():
        raise RuntimeError("Refusing to replace an unrecorded plugin installation")
    if destination.exists():
        verify_deployment(root)
    staging = root / "profile/plugins/suwayomi-payload-staging"
    staging.mkdir()
    hashes = {}
    for path in files:
        relative = path.relative_to(source)
        target = staging / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        hashes[relative.as_posix()] = digest(path)
        if digest(target) != hashes[relative.as_posix()]:
            raise RuntimeError("Deployed payload differs from source")
    if destination.exists():
        shutil.rmtree(destination)
    staging.rename(destination)
    # Keep the private adapter aligned with the CLI without changing credentials.
    patch = root / "profile/patches/2-sandbox-inspector.lua"
    shutil.copyfile(HERE / "sandbox-inspector.lua", patch)
    record = {"revision": revision, "revision_kind": "caller-supplied label", "files": hashes,
              "inspector_patch_sha256": digest(patch)}
    write_json(root / "deployment.json", record)
    return {"deployed_files": len(hashes), "revision": revision, "exact_bytes_verified": True}


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, file, code, message, headers, new_url):
        return None


class ServerClient:
    """One launcher-owned in-memory session; never share it with KOReader."""

    def __init__(self, root):
        config = configuration(root)
        self.url = f"http://127.0.0.1:{config['server_port']}"
        self.mode = config["auth_mode"]
        self.credentials = read_json(root / "secrets.json")
        self.cookies = http.cookiejar.CookieJar()
        self.http = urllib.request.build_opener(
            urllib.request.ProxyHandler({}), _NoRedirect(),
            urllib.request.HTTPCookieProcessor(self.cookies))
        self.plain_http = urllib.request.build_opener(urllib.request.ProxyHandler({}), _NoRedirect())
        self.logged_in = False

    def login(self):
        self.cookies.clear()
        body = urllib.parse.urlencode({
            "user": self.credentials["username"], "pass": self.credentials["password"],
        }).encode("utf-8")
        request = urllib.request.Request(self.url + "/login.html", data=body, headers={
            "Content-Type": "application/x-www-form-urlencoded",
        })
        # The pinned release returns 303 to /. Do not follow even that redirect:
        # the next authenticated API call proves the session, not a WebUI page.
        try:
            with self.http.open(request, timeout=5):
                raise RuntimeError("Simple Login did not establish a session")
        except urllib.error.HTTPError as error:
            try:
                if error.code != 303 or error.headers.get("Location") != "/" or not self.cookies:
                    raise RuntimeError("Simple Login did not establish a session") from None
            finally:
                error.close()
        self.logged_in = True

    def request(self, path, authorized=True):
        if not path.startswith("/api/") or "\\" in path or "#" in path:
            raise RuntimeError("Invalid sandbox API path")
        headers = {}
        if authorized:
            if self.mode == "simple_login":
                if not self.logged_in:
                    self.login()
            else:
                headers["Authorization"] = "Basic " + base64.b64encode(
                    (self.credentials["username"] + ":" + self.credentials["password"]).encode()).decode()
        request = urllib.request.Request(self.url + path, headers=headers)
        client = self.http if authorized and self.mode == "simple_login" else self.plain_http
        with client.open(request, timeout=5) as response:
            body = response.read()
            return json.loads(body) if body else None


def seed_library(client):
    sources = client.request("/api/v1/source/list")
    local = [source for source in sources if source["name"] == "Local source"]
    if len(local) != 1:
        raise RuntimeError("Expected one Local source")
    page = client.request(f"/api/v1/source/{local[0]['id']}/popular/1")
    manga = [manga for manga in page["mangaList"] if manga["title"] == "Sandbox Alpha"]
    if len(manga) != 1:
        raise RuntimeError("Generated fixture was not discovered")
    manga_id = manga[0]["id"]
    client.request(f"/api/v1/manga/{manga_id}?onlineFetch=true")
    client.request(f"/api/v1/manga/{manga_id}/library")
    chapters = client.request(f"/api/v1/manga/{manga_id}/chapters?onlineFetch=true")
    if len(chapters) != 3:
        raise RuntimeError("Fixture chapter discovery did not return three chapters")
    try:
        client.request("/api/v1/source/list", authorized=False)
    except urllib.error.HTTPError as error:
        if error.code != 401:
            raise
    else:
        raise RuntimeError("Server accepted an unauthenticated request")


def available_port(port):
    with socket.socket() as probe:
        try:
            probe.bind(("127.0.0.1", port))
        except OSError as error:
            raise RuntimeError("Requested sandbox port is already in use; choose another port at setup") from error


def unique_path(root, pattern):
    paths = list(root.glob(pattern))
    if len(paths) != 1:
        raise RuntimeError("Pinned runtime layout does not match its launcher")
    return paths[0]


def launch(root, service):
    from sandbox_ui import Inspector
    config = configuration(root)
    if live_process(root, service):
        raise RuntimeError("Sandbox service is already running")
    available_port(config["server_port" if service == "server" else "inspector_port"])
    environment = os.environ.copy()
    if service == "server":
        server_client = ServerClient(root)
        runtime = unique_path(root / "runtime/server", "*/bin/Suwayomi-Server.jar").parent.parent
        command = [str(runtime / "jre/bin/java"),
                   "-Dsuwayomi.tachidesk.config.server.rootDir=" + str(root / "server-data"),
                   "-jar", str(runtime / "bin/Suwayomi-Server.jar")]
    else:
        if not (environment.get("DISPLAY") or environment.get("WAYLAND_DISPLAY")):
            raise RuntimeError("KOReader needs a desktop display (Linux, WSLg, or a Linux VM)")
        if not ctypes.util.find_library("SDL2-2.0"):
            raise RuntimeError("Install the SDL2 runtime using your OS package manager before running KOReader")
        verify_deployment(root)
        runtime = unique_path(root / "runtime/koreader", "**/koreader.sh").parent
        environment.update(KO_HOME=str(root / "profile"), EMULATE_READER_W="600", EMULATE_READER_H="800")
        environment.setdefault("SDL_VIDEODRIVER", "x11" if environment.get("DISPLAY") else "wayland")
        command = ["sh", str(runtime / "koreader.sh"), str(root / "downloads")]
    with (root / "logs" / (service + ".log")).open("ab") as log:
        child = subprocess.Popen(command, cwd=runtime, env=environment, stdout=log, stderr=log, start_new_session=True)
    state = {"pid": child.pid, "start_time": process_identity(child.pid)}
    write_json(root / (service + ".pid.json"), state)
    try:
        deadline = time.monotonic() + 90
        while True:
            if child.poll() is not None:
                raise RuntimeError(service + " exited before readiness; inspect its private log")
            try:
                if service == "server":
                    server_client.request("/api/v1/source/list")
                else:
                    Inspector(root).observe()
                break
            except urllib.error.HTTPError as error:
                raise RuntimeError(service + " readiness returned HTTP " + str(error.code)) from error
            except (urllib.error.URLError, ConnectionError, TimeoutError):
                if time.monotonic() >= deadline:
                    raise RuntimeError(service + " did not become ready; inspect its private log")
                time.sleep(0.25)
        if service == "server":
            seed_library(server_client)
        print(service + " ready", flush=True)
        code = child.wait()
        if code not in ((0, -signal.SIGTERM, 128 + signal.SIGTERM) if service == "server" else (0,)):
            raise RuntimeError(service + " exited unsuccessfully; inspect its private log")
    except BaseException:
        if child.poll() is None:
            if service == "reader":
                try:
                    Inspector(root).quit()
                except Exception:
                    print("Reader did not accept graceful quit; retained its owned process record", file=sys.stderr)
            else:
                os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=15)
            except subprocess.TimeoutExpired:
                print("Service did not exit; retained its owned process record", file=sys.stderr)
        raise
    finally:
        if child.poll() is not None:
            (root / (service + ".pid.json")).unlink(missing_ok=True)


def stop(root, service):
    from sandbox_ui import Inspector
    configuration(root)
    state = live_process(root, service)
    if not state:
        return {service: "not running; no process signaled"}
    if service == "reader":
        Inspector(root).quit()
    else:
        if os.getpgid(state["pid"]) != state["pid"]:
            raise RuntimeError("Owned server process group changed; refusing to signal it")
        os.killpg(state["pid"], signal.SIGTERM)
    deadline = time.monotonic() + 20
    while process_identity(state["pid"]) == state["start_time"]:
        if time.monotonic() >= deadline:
            raise RuntimeError("Graceful stop timed out; process retained for inspection")
        time.sleep(0.1)
    return {service: "stopped gracefully"}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", required=True, type=Path, help="Dedicated Linux sandbox directory")
    commands = parser.add_subparsers(dest="command", required=True)
    setup_args = commands.add_parser("setup", help="Download pinned releases into an empty root")
    setup_args.add_argument("--server-port", type=int, default=4569)
    setup_args.add_argument("--inspector-port", type=int, default=8083)
    setup_args.add_argument("--auth-mode", choices=("basic_auth", "simple_login"), default="basic_auth")
    deploy_args = commands.add_parser("deploy", help="Copy and hash the runtime payload with reader stopped")
    deploy_args.add_argument("--source", required=True, type=Path)
    deploy_args.add_argument("--revision", required=True, help="Candidate revision label; exact bytes are recorded separately")
    for name in ("run", "stop"):
        commands.add_parser(name).add_argument("service", choices=("server", "reader"))
    commands.add_parser("status")
    commands.add_parser("smoke", help="Download and open one unused fixture chapter through the real UI")
    commands.add_parser("auth-smoke", help="Fill and test the real setup connection dialog, then download a fixture")
    ui = commands.add_parser("ui").add_subparsers(dest="action", required=True)
    for name in ("observe", "home", "close-reader"):
        ui.add_parser(name)
    ui.add_parser("tap").add_argument("label")
    fill = ui.add_parser("fill", help="Fill a visible field without putting secrets in arguments or output")
    fill.add_argument("field", help="Observed field hint or 1-based index")
    source = fill.add_mutually_exclusive_group(required=True)
    source.add_argument("--credential", choices=("server_url", "username", "password"))
    source.add_argument("--stdin", action="store_true", help="Read the exact field text from standard input")
    fill.add_argument("--invalid", action="store_true", help="Use a deliberately wrong sandbox password")
    wait = ui.add_parser("wait")
    wait.add_argument("title")
    wait.add_argument("--timeout", type=float, default=15)
    ui.add_parser("screenshot").add_argument("path", type=Path)
    args = parser.parse_args()
    if sys.platform != "linux" or platform.machine() not in ("x86_64", "amd64"):
        parser.error("Run inside Linux x86_64, WSLg, or a Linux VM; no native Windows/macOS runtime launcher is provided")
    os.umask(0o077)
    root = args.root.expanduser().resolve()
    if args.command == "setup":
        if not all(1024 <= port <= 65535 for port in (args.server_port, args.inspector_port)):
            parser.error("Use unprivileged ports between 1024 and 65535")
        result = setup(root, args)
    elif args.command == "deploy":
        result = deploy(root, args.source, args.revision)
    elif args.command == "run":
        launch(root, args.service)
        return
    elif args.command == "stop":
        result = stop(root, args.service)
    elif args.command == "status":
        configuration(root)
        result = {service: "running" if live_process(root, service) else "stopped" for service in ("server", "reader")}
    else:
        from sandbox_ui import Inspector
        configuration(root)
        client = Inspector(root)
        if args.command == "smoke":
            result = client.smoke()
        elif args.command == "auth-smoke":
            result = client.auth_smoke()
        elif args.action == "fill":
            if args.invalid and args.credential != "password":
                parser.error("--invalid requires --credential password")
            value = sys.stdin.read(4097) if args.stdin else client.credential(args.credential, args.invalid)
            result = client.fill(args.field, value)
        elif args.action == "tap":
            result = client.tap(args.label)
        elif args.action == "wait":
            result = client.wait(args.title, args.timeout)
        elif args.action == "screenshot":
            result = client.screenshot(args.path)
        else:
            result = getattr(client, args.action.replace("-", "_"))()
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(130)
    except (OSError, RuntimeError, ValueError, KeyError) as error:
        # Do not echo HTTP bodies, credentials, or runtime logs into the transcript.
        message = str(error) if isinstance(error, RuntimeError) else type(error).__name__ + ": operation failed; inspect sandbox prerequisites/private logs"
        print("sandbox: " + message, file=sys.stderr)
        sys.exit(1)
