#!/usr/bin/env python3
"""Command-line access to a running LibrePili.

Asks the instance the user is actually using what it is doing: the video
on screen, where its transcription and translation stand, what the subtitle
menu says, recent event-log lines, a whitelisted set of settings, and how
often and how slowly it draws (frames).

Needs 设置 → 其它设置 → 允许命令行读取状态 switched on in that instance.
The app then serves on 127.0.0.1 (port chosen by the system) and writes the
port and a token to ctl.json in its data folder; this script reads that file.

    python librepili_ctl.py status            # short summary
    python librepili_ctl.py status --raw      # the JSON
    python librepili_ctl.py log --since 2026-09-26T10:00:00 --last 50
    python librepili_ctl.py settings
    python librepili_ctl.py frames --seconds 5
    python librepili_ctl.py health
    python librepili_ctl.py --profile ctl status     # a self-test profile
    python librepili_ctl.py --android status         # a phone, through adb

With 允许命令行控制 on as well, it can also drive the app (for diagnosing
performance): scroll, size the window, trace who asks for frames.

    python librepili_ctl.py scroll --dy 120 --times 20 --interval 50
    python librepili_ctl.py window maximize | unmaximize | minimize | restore
    python librepili_ctl.py window size --width 1280 --height 720
    python librepili_ctl.py window                    # info
    python librepili_ctl.py trace-frames --seconds 10 # then: frames

Standard library only. See librepili_ctl.SKILL.md.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

APP_ID = "com.zxa24.librepili"
ANDROID_PACKAGES = [APP_ID + ".debug", APP_ID + ".dev", APP_ID]
SETTING_HINT = "设置 → 其它设置 → 允许命令行读取状态"
CONTROL_HINT = "设置 → 其它设置 → 允许命令行控制"
EXIT_NOT_RUNNING = 2
EXIT_HTTP = 3


class CtlError(Exception):
    def __init__(self, message: str, code: int = EXIT_NOT_RUNNING):
        super().__init__(message)
        self.code = code


# ---------------------------------------------------------------- discovery


def profile_dir_name(profile: str) -> str:
    """As the app names it (SelfTest.profileDir): selftest-NAME."""
    name = re.sub(r"[^A-Za-z0-9_-]", "", profile)
    return "selftest-" + name if name else "selftest"


def support_dirs() -> list[Path]:
    """Where the app's support folder is on this OS (path_provider)."""
    home = Path.home()
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA") or str(home / "AppData" / "Roaming")
        # CompanyName\ProductName from windows/runner/Runner.rc
        return [Path(appdata) / "com.zxa24" / "LibrePili"]
    if sys.platform == "darwin":
        return [
            home / "Library" / "Application Support" / APP_ID,
            home / "Library" / "Containers" / APP_ID / "Data" / "Library"
            / "Application Support" / APP_ID,
        ]
    data = os.environ.get("XDG_DATA_HOME") or str(home / ".local" / "share")
    return [Path(data) / APP_ID, Path(data) / "librepili"]


def pid_alive(pid: int) -> bool | None:
    """True / False, or None when it cannot be told."""
    if not isinstance(pid, int) or pid <= 0:
        return None
    if sys.platform == "win32":
        import ctypes

        kernel32 = ctypes.windll.kernel32
        handle = kernel32.OpenProcess(0x1000, False, pid)  # QUERY_LIMITED
        if not handle:
            # 5 = access denied: it exists, someone else's
            return ctypes.GetLastError() == 5
        try:
            code = ctypes.c_ulong()
            if not kernel32.GetExitCodeProcess(handle, ctypes.byref(code)):
                return None
            return code.value == 259  # STILL_ACTIVE
        finally:
            kernel32.CloseHandle(handle)
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    except OSError:
        return None


def read_local(args) -> dict:
    if args.dir:
        dirs = [Path(args.dir)]
    else:
        dirs = support_dirs()
        if args.profile is not None:
            dirs = [d / profile_dir_name(args.profile) for d in dirs]
    for d in dirs:
        f = d / "ctl.json"
        if f.is_file():
            try:
                info = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, ValueError) as e:
                raise CtlError(f"cannot read {f}: {e}")
            info["_file"] = str(f)
            alive = pid_alive(info.get("pid"))
            if alive is False:
                raise CtlError(
                    f"stale {f}: pid {info.get('pid')} is not running (the app "
                    "ended without removing it). Start LibrePili; with the "
                    "setting on it writes a fresh one."
                )
            return info
    where = ", ".join(str(d) for d in dirs)
    raise CtlError(
        f"no ctl.json in {where}.\nLibrePili is not running there, or "
        f"「{SETTING_HINT}」 is off (it is off by default)."
    )


def adb_run(adb: str, *cmd: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(
            [adb, *cmd], capture_output=True, text=True, timeout=20,
            encoding="utf-8", errors="replace",
        )
    except FileNotFoundError:
        raise CtlError(
            f"adb not found ({adb}). Pass --adb PATH, e.g. "
            r"--adb D:\Downloads\platform-tools-latest-windows"
            r"\platform-tools\adb.exe, or set ADB."
        )


def read_android(args) -> dict:
    adb = args.adb
    base = [] if not args.serial else ["-s", args.serial]
    sub = "" if args.profile is None else profile_dir_name(args.profile) + "/"
    packages = [args.package] if args.package else ANDROID_PACKAGES
    tried = []
    for pkg in packages:
        # the app's support folder is its files dir; run-as reads it on a
        # debuggable build
        for how, cmd in (
            ("run-as", ["shell", "run-as", pkg, "cat", f"files/{sub}ctl.json"]),
            # the copy in the app-specific external folder (Android 11+),
            # for a build run-as refuses
            ("external", ["shell", "cat",
                          f"/sdcard/Android/data/{pkg}/files/{sub}ctl.json"]),
        ):
            r = adb_run(adb, *base, *cmd)
            text = (r.stdout or "").strip()
            if r.returncode == 0 and text.startswith("{"):
                try:
                    info = json.loads(text)
                except ValueError:
                    continue
                info["_file"] = f"{pkg} ({how})"
                return forward(adb, base, info)
            tried.append(f"{pkg}/{how}: {(r.stderr or text).strip()[:80]}")
    raise CtlError(
        "no ctl.json on the device (is it connected and authorised? "
        f"is the app running with 「{SETTING_HINT}」 on?)\n  "
        + "\n  ".join(tried)
    )


def forward(adb: str, base: list, info: dict) -> dict:
    """adb forward to the phone's port; the local end is whatever is free."""
    r = adb_run(adb, *base, "forward", "tcp:0", f"tcp:{info['port']}")
    if r.returncode != 0:
        raise CtlError(f"adb forward failed: {r.stderr.strip()}")
    info["_devicePort"] = info["port"]
    info["port"] = int(r.stdout.strip())
    return info


# ------------------------------------------------------------------- request


def request(info: dict, path: str, token: bool = True, body: dict | None = None):
    """GET, or POST [body] as JSON when it is given."""
    url = f"http://127.0.0.1:{info['port']}{path}"
    data = None if body is None else json.dumps(body).encode("utf-8")
    req = urllib.request.Request(url, data=data,
                                 method="GET" if body is None else "POST")
    if data is not None:
        req.add_header("Content-Type", "application/json")
    if token:
        req.add_header("Authorization", "Bearer " + info["token"])
    # the app's own address; never a proxy
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(req, timeout=10) as resp:
            return json.loads(resp.read().decode("utf-8"))
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", "replace")
        if e.code == 401:
            raise CtlError(
                f"401 from {url}: the token was refused ({info.get('_file')} "
                "may be from an earlier run; the app writes a new one each "
                "time it starts serving).", EXIT_HTTP)
        if e.code == 403 and path.startswith("/control/"):
            raise CtlError(
                f"403 from {url}: control is off. Turn on 「{CONTROL_HINT}」 "
                "in that instance (off by default; it needs "
                f"「{SETTING_HINT}」 too).", EXIT_HTTP)
        if e.code == 405 and path.startswith("/control/"):
            raise CtlError(
                f"405 from {url}: this build takes no control (older than "
                "the control switch).", EXIT_HTTP)
        if e.code == 404 and path == "/frames":
            raise CtlError(
                f"404 from {url}: this build has no /frames (older than the "
                "control switch).", EXIT_HTTP)
        raise CtlError(f"HTTP {e.code} from {url}: {body[:300]}", EXIT_HTTP)
    except (urllib.error.URLError, ConnectionError, TimeoutError) as e:
        reason = getattr(e, "reason", e)
        raise CtlError(
            f"nothing answers on {url} ({reason}).\n{info.get('_file')} is "
            "there but the app is gone or stopped serving (the setting was "
            "just turned off?)."
        )


# ------------------------------------------------------------------ summary


def _t(seconds) -> str:
    if seconds is None:
        return "?"
    s = int(seconds)
    return f"{s // 60}:{s % 60:02d}"


def _sec(value, none: str = "?") -> str:
    return none if value is None else f"{value}s"


def _spans(spans) -> str:
    if not spans:
        return "none"
    return ", ".join(f"{_t(a)}-{_t(b)}" for a, b in spans)


def summarize_status(st: dict) -> str:
    out = []
    app = st.get("app", {})
    out.append(
        f"LibrePili {app.get('version')}+{app.get('build')} "
        f"({app.get('platform')}, pid {app.get('pid')}"
        + (f", profile {app['profile']}" if app.get("profile") else "")
        + f", commit {app.get('commit')})"
    )
    out.append("routes (top first): " + " < ".join(st.get("routes") or []))
    p = st.get("player")
    if p:
        out.append(
            f"player: {p['status']}{' (buffering)' if p['buffering'] else ''} "
            f"{_t(p['position'])} / {_t(p['duration'])}, buffered to "
            f"{_t(p['buffered'])}"
        )
    pages = st.get("pages") or []
    if not pages:
        out.append("no video page open")
    for page in pages:
        tag = "[top]" if page.get("onTop") else "[covered]"
        ids = (
            f"videoId={page.get('videoId')}" if page["platform"] == "youtube"
            else f"bvid={page.get('bvid')} aid={page.get('aid')} "
                 f"cid={page.get('cid')}"
        )
        out.append(f"{tag} {page['platform']} 「{page.get('title')}」 {ids}")
        out.append(
            f"  quality={page.get('quality')} codec={page.get('codec')} "
            f"video host={page.get('videoHost')} audio host="
            f"{page.get('audioHost')}"
        )
        subs = page.get("subtitles") or {}
        tracks = ", ".join(
            f"{t['index']}:{t['label']}({t['source']})"
            for t in subs.get("tracks", [])
        ) or "none"
        out.append(f"  subtitles: selected={subs.get('selected')} [{tracks}]")
        dev = page.get("onDevice") or {}
        menu = " | ".join(
            row["text"] + (" (picked)" if row.get("picked") else "")
            for row in dev.get("menu", [])
        )
        out.append(f"  menu: {menu or '(no on-device rows)'}")
        out.append(
            f"  on-device: shown={dev.get('shown')} picked={dev.get('picked')} "
            f"busy={dev.get('busy')} asrPending={page.get('asrPending')}"
        )
        a = page.get("transcription")
        if a:
            lead = a.get("leadWindow") or {}
            out.append(
                f"  transcription: {a['stage']} ({a.get('label')}) "
                f"lang={a.get('language')} covered {_spans(a.get('covered'))} "
                f"({_sec(a.get('coveredSeconds'))} of {_sec(a.get('duration'))}, "
                f"{a.get('cues')} cues) runs={a.get('runCount')} "
                f"ended={a.get('hasEnded')} suspended={a.get('suspended')} "
                f"fullCoverage={a.get('fullCoverageRequested')} "
                f"lead={_sec(lead.get('low'))}-{_sec(lead.get('high'), 'unbounded')}"
                + (f" message={a['message']!r}" if a.get("message") else "")
            )
        else:
            out.append("  transcription: none")
        tr = page.get("translation") or {}
        if tr.get("active") or tr.get("stage"):
            out.append(
                f"  translation: into={tr.get('into')} stage={tr.get('stage')}"
                f"{' (starting)' if tr.get('starting') else ''} units "
                f"{tr.get('unitsDone')}/{tr.get('unitsTotal')}"
                + (f" message={tr['message']!r}" if tr.get("message") else "")
            )
        else:
            out.append("  translation: none")
        if page.get("fillExport"):
            fe = page["fillExport"]
            out.append(
                f"  fill export: {fe['phase']} {fe['progress']:.0%} "
                f"over={fe['over']}"
            )
        if page.get("comments"):
            c = page["comments"]
            out.append(
                f"  comment translation: enabled={c['enabled']} "
                f"{c['done']}/{c['total']}"
            )
    models = st.get("models") or {}
    asr = models.get("asr") or {}
    tr = models.get("translation") or {}
    out.append(
        f"models: asr ready={asr.get('ready')} {asr.get('models')}; "
        f"translation {tr.get('model')} ready={tr.get('ready')}"
    )
    return "\n".join(out)


def summarize_log(log: dict) -> str:
    return "\n".join(item["line"] for item in log.get("lines", [])) or (
        "(no log lines)"
    )


def _spread(d: dict) -> str:
    if not d or not d.get("count"):
        return "none"
    return (f"p50 {d['p50']} / p90 {d['p90']} / max {d['max']} ms "
            f"({d['over100ms']} of {d['count']} over 100 ms)")


def summarize_frames(f: dict) -> str:
    out = []
    view = f.get("view") or {}
    out.append(
        f"last {f['seconds']} s: {f['frames']} frames ({f['fps']} fps), "
        f"last one {f.get('lastFrameAgoMs')} ms ago; asked for: "
        f"{f['requested']} scheduleFrame, {f['forced']} forced, "
        f"{f['metricsChanged']} metrics changes"
    )
    out.append(
        f"now: {f['transientCallbacks']} animation callbacks waiting, frame "
        f"scheduled={f['frameScheduled']}, lifecycle={f.get('lifecycle')}"
    )
    if view:
        out.append(
            f"view: {view['physicalWidth']:.0f}×{view['physicalHeight']:.0f} "
            f"px at {view['devicePixelRatio']} "
            f"({view['logicalWidth']:.0f}×{view['logicalHeight']:.0f} logical)"
        )
    t = f.get("timingsMs") or {}
    for key in ("total", "build", "raster", "startLag", "queue"):
        out.append(f"  {key:8} {_spread(t.get(key))}")
    tr = f.get("trace") or {}
    if tr.get("samples") or tr.get("running"):
        out.append(
            f"trace: {'running, ' + str(tr.get('endsInMs')) + ' ms left' if tr.get('running') else 'done'}; "
            f"{tr['samples']} asks, {tr['kinds']} different stacks"
            + (f" (+{tr['kindsNotKept']} not kept)" if tr.get("kindsNotKept") else "")
        )
        for item in tr.get("top", []):
            out.append(f"  ×{item['count']}")
            for line in item["stack"][:10]:
                out.append(f"      {line}")
    return "\n".join(out)


def summarize_settings(s: dict) -> str:
    width = max((len(k) for k in s), default=0)
    return "\n".join(
        f"{k.ljust(width)}  {'(default)' if v is None else json.dumps(v, ensure_ascii=False)}"
        for k, v in s.items()
    )


# ---------------------------------------------------------------------- main


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(
        description="Access to a running LibrePili (needs 「"
        f"{SETTING_HINT}」 on; scroll / window / trace-frames also 「"
        f"{CONTROL_HINT}」).")
    ap.add_argument("command", choices=[
        "status", "log", "settings", "frames", "health",
        "scroll", "window", "trace-frames"])
    ap.add_argument("action", nargs="?", default="info",
                    help="window: info (default), maximize, unmaximize, "
                    "minimize, restore, size")
    ap.add_argument("--profile", help="a self-test profile (--profile NAME "
                    "of the app: its folder selftest-NAME)")
    ap.add_argument("--dir", help="the app's support folder, explicitly")
    ap.add_argument("--android", action="store_true",
                    help="read ctl.json from a phone through adb, and forward")
    ap.add_argument("--adb", default=os.environ.get("ADB", "adb"),
                    help="adb executable (default: ADB env var, else adb)")
    ap.add_argument("--serial", help="adb device serial")
    ap.add_argument("--package", help="Android package (default: tries "
                    + ", ".join(ANDROID_PACKAGES) + ")")
    ap.add_argument("--raw", action="store_true", help="print the JSON")
    ap.add_argument("--since", help="log: only lines after this ISO time "
                    "(the app's local time, e.g. 2026-09-26T10:00:00)")
    ap.add_argument("--last", type=int, help="log: only the last N lines")
    ap.add_argument("--seconds", type=int,
                    help="frames: the last N seconds (1-60, default 5); "
                    "trace-frames: how long to trace (1-120, default 10)")
    ap.add_argument("--dy", type=float, help="scroll: logical px per step "
                    "(default 120; negative scrolls up)")
    ap.add_argument("--times", type=int, help="scroll: steps (default 10)")
    ap.add_argument("--interval", type=int,
                    help="scroll: ms between steps (default 50)")
    ap.add_argument("--x", type=float, help="scroll: logical x (default: "
                    "the window's middle)")
    ap.add_argument("--y", type=float, help="scroll: logical y")
    ap.add_argument("--width", type=float, help="window size: logical px")
    ap.add_argument("--height", type=float, help="window size: logical px")
    args = ap.parse_args(argv)

    # the labels are Chinese; a Windows console's code page is not UTF-8
    for stream in (sys.stdout, sys.stderr):
        if hasattr(stream, "reconfigure"):
            stream.reconfigure(encoding="utf-8", errors="replace")
    try:
        info = read_android(args) if args.android else read_local(args)
        if args.command == "health":
            data = request(info, "/health", token=False)
        elif args.command == "log":
            q = []
            if args.since:
                q.append("since=" + urllib.parse.quote(args.since))
            if args.last is not None:
                q.append(f"limit={args.last}")
            data = request(info, "/log" + ("?" + "&".join(q) if q else ""))
        elif args.command == "frames":
            data = request(info, "/frames" + (
                f"?seconds={args.seconds}" if args.seconds else ""))
        elif args.command == "scroll":
            body = {k: v for k, v in (
                ("dy", args.dy), ("times", args.times),
                ("intervalMs", args.interval), ("x", args.x), ("y", args.y),
            ) if v is not None}
            data = request(info, "/control/scroll", body=body)
        elif args.command == "window":
            body = {"action": args.action}
            if args.action == "size":
                body.update(width=args.width, height=args.height)
            data = request(info, "/control/window", body=body)
        elif args.command == "trace-frames":
            data = request(info, "/control/trace-frames",
                           body={"seconds": args.seconds or 10})
        else:
            data = request(info, "/" + args.command)
    except CtlError as e:
        print(f"librepili_ctl: {e}", file=sys.stderr)
        return e.code

    if args.raw:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    elif args.command == "status":
        print(summarize_status(data))
    elif args.command == "log":
        print(summarize_log(data))
    elif args.command == "settings":
        print(summarize_settings(data))
    elif args.command == "frames":
        print(summarize_frames(data))
    else:
        print(json.dumps(data, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
