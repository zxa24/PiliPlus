---
name: librepili-ctl
description: Inspect what a running LibrePili (the bilibili + YouTube Flutter client) is doing, read-only — the video page on top and any covered ones, playback position/state, quality/codec/CDN host, subtitle tracks, the subtitle menu's on-device rows exactly as the user sees them (原文（端侧） · 生成中 / 准备中 …), transcription session (stage, covered spans, runs, lead window, suspended), translation (stage, units done/total), fill-export and comment-translation state, model readiness, recent event-log lines, and a whitelisted set of settings. Use when the user asks why their running instance is stuck or what it is doing (e.g. "the subtitle menu says 准备中 forever"), when checking a self-test instance started with --profile, or a phone build through adb. Cannot change anything in the app.
---

# librepili-ctl

`lib/scripts/librepili_ctl.py` (Python 3, standard library only) asks a
running LibrePili for its state over a loopback-only HTTP server built into
the app. Read-only: GET and JSON only; nothing it does changes the app.

## Prerequisite (the user must do this; it is off by default)

In that instance: **设置 → 其它设置 → 允许命令行读取状态** on. While on, the app
listens on `127.0.0.1:<port chosen by the system>` and writes
`ctl.json` (`port`, `token`, `pid`, `startedAt`, `version`, `build`,
`profile`, `app`) into its data folder. Turning it off (or quitting) closes
the server and deletes the file; a start with it off also deletes a file a
crashed run left.

Where the data folder is:

| Where | Folder |
|---|---|
| Windows | `%APPDATA%\com.zxa24\LibrePili\` |
| Windows self-test `--profile NAME` | `%APPDATA%\com.zxa24\LibrePili\selftest-NAME\` |
| Linux | `~/.local/share/com.zxa24.librepili/` |
| macOS | `~/Library/Application Support/com.zxa24.librepili/` |
| Android | the app's files dir, `/data/data/<package>/files/` (plus a copy in `/sdcard/Android/data/<package>/files/` on Android 11+) |

## Usage

```
python lib/scripts/librepili_ctl.py status            # short human summary
python lib/scripts/librepili_ctl.py status --raw      # full JSON
python lib/scripts/librepili_ctl.py log               # event log (last ~300 lines kept by the app)
python lib/scripts/librepili_ctl.py log --last 30 --since 2026-09-26T10:00:00
python lib/scripts/librepili_ctl.py settings          # whitelisted prefs; (default) = never set
python lib/scripts/librepili_ctl.py health            # liveness, no token needed
```

Options:
- `--profile NAME` — a self-test instance started with `--selftest --profile NAME`.
- `--dir PATH` — the data folder, explicitly.
- `--android` — a phone over adb: reads `ctl.json` with `adb shell run-as <pkg> cat files/ctl.json` (debuggable builds: the `.debug` package) or, failing that, from `/sdcard/Android/data/<pkg>/files/ctl.json` (Android 11+, any build), then `adb forward tcp:0 tcp:<port>`. Tries `com.zxa24.librepili.debug`, `.dev`, then `com.zxa24.librepili`; `--package` picks one, `--serial` a device, `--adb PATH` (or env `ADB`) the adb binary, e.g. `--adb D:\Downloads\platform-tools-latest-windows\platform-tools\adb.exe`. Combine with `--profile` for a phone self-test profile.
- `--raw` — print the JSON instead of the summary (use it when you need a field the summary leaves out).
- `--since ISO` — `log` only: lines after that moment, in the app's local time. `--last N` — the last N lines.

Output is always UTF-8 (the labels are Chinese), also on a Windows console
whose code page is not; read it as UTF-8.

Exit codes: 0 ok; 2 not reachable (no `ctl.json`, stale file, nothing
listening); 3 HTTP error (401 and others).

## What `status` returns

- `app`: version, build, commit, buildTime, pid, platform, osVersion, profile, now.
- `routes`: the root navigator's route names, **top first** (`/videoV` = bilibili or local video page, `/ytVideo?id=…` = YouTube page; popups and dialogs show as their route type).
- `player` (one player, shared): `status` (playing/paused/completed), `buffering`, `position`/`duration`/`buffered` in whole seconds. It belongs to the page on top.
- `pages`: the video pages in the stack, top first; `onTop` marks the one with the player.
  - `platform`: `bilibili`, `local` (a file or a download played in the page's local mode) or `youtube`.
  - ids: `bvid`, `aid`, `cid`, `epId`, `seasonId`, `heroTag` (bilibili/local); `videoId` (YouTube). `title`.
  - bilibili/local: `ready` (the page's video state), `quality`, `audioQuality`, `codec`, `videoHost`/`audioHost` (**host only**). YouTube: `stage` (loading/ready/failed), `message`, `quality`, `codec`, `audioCodec`, `maxHeight`, `source` (which extractor), hosts.
  - `subtitles`: `tracks` (index, label as the menu shows it, `lan`, `source`: author = uploaded by the publisher, platform = the site's own/automatic, device = made on this device) and `selected` (bilibili: 0 = off, n = tracks[n-1]; YouTube: -1 = off, else the index).
  - `onDevice`: `menu` — the on-device rows exactly as the subtitle menu reads them (`text`, plus `code` = `asr` or a language, `label`, `status`, `picked`); `shown` / `picked` (`asr` or a language), `busy`, `canTranscribe`, `canTranslate`, `appLanguage`.
  - `asrPending`: the page is held in loading waiting for the first subtitles.
  - `transcription` (null = no session): `stage` (idle/models/extracting/transcribing/standby/done/failed), `label`, `message`, `progress`, `language`, `covered` (list of `[from, to]` seconds), `coveredSeconds`, `duration`, `cues`, `runCount`, `hasEnded` (true = it will make no more text: failed, or ran and stopped), `suspended` (stopped by the model guard), `fullCoverageRequested` (a save waits for the whole transcript), `leadWindow` {`low`, `high` (null = unbounded), `pauses`}.
  - `translation`: `active` (asked for or running), `into`, `starting` (asked for, session not made yet), `stage` (idle/loading/translating/waiting/paused/done/failed), `message`, `unitsDone`/`unitsTotal`.
  - `fillExport` (bilibili/local): a save waiting for its subtitle to be whole — `phase`, `progress`, `over`; null = none.
  - `comments`: this page's comment translation — `enabled`, `done`, `total`.
- `commentTranslation`: every live comment translator (`key`, `enabled`, `done`, `total`).
- `models`: `asr` {`ready`, per-model installed}, `translation` {`supported`, `model` id, `ready`}.

`/log` returns `{now, count, lines: [{at, line}]}`; the lines are the app's
EventLog (`HH:MM:SS.mmm [area] message`: player recovery, CDN switches, slow
and failed requests, asr, ctl…).

## Privacy: what is never sent

No cookies, access keys, tokens, account or login data, request headers,
proxy host/port, or full stream URLs (their query strings carry keys) — only
hostnames. `/settings` is a fixed whitelist (playback, CDN/network switches,
subtitles, transcription/translation, YouTube region/language, this switch,
error log) with a second filter that drops any key whose name looks secret
(`cookie`, `token`, `access`, `auth`, `user`, `login`, `…key`, `proxyHost`…);
values are reduced to plain ones (a URL becomes its host, a long string its
length).

## Security model

- Bound to 127.0.0.1 only (Android: reach it with `adb forward`).
- Every endpoint but `/health` needs `Authorization: Bearer <token>`; the token is 32 random bytes, new each time the server starts, kept only in `ctl.json` in the app's private data folder — reading that file is the access boundary (the same OS user; `run-as` on a debuggable Android build; the external copy only exists on Android 11+, where other apps cannot read it).
- `/health` answers `{ok, app, version, build, profile}` without a token.
- Requests carrying an `Origin` header (a browser page) are refused (403); anything but GET is 405.

## Troubleshooting

| Message | Meaning / fix |
|---|---|
| `no ctl.json in …` | App not running there, or the setting is off (default). Ask the user to turn on 设置 → 其它设置 → 允许命令行读取状态. For a self-test instance pass `--profile NAME`. |
| `stale …ctl.json: pid N is not running` | The app died without removing it. Starting the app (setting on) writes a fresh one; with the setting off, it deletes it. |
| `nothing answers on http://127.0.0.1:P` | The file is there but the server is gone (just turned off, or the app is hanging/quitting). On Android: the app was killed; the file stays until the next start. |
| `401 … token was refused` | `ctl.json` from an earlier run; re-run (the script re-reads it every call). |
| `adb not found` / `no ctl.json on the device` | Pass `--adb PATH`; check `adb devices`; a release build needs Android 11+ for the external copy, otherwise use the `.debug` build (run-as). |
| Page missing from `pages` | Only `/videoV` and `/ytVideo` routes are read; a video playing in a mini player/PiP after its page closed is not listed (the `player` block still shows the player). |

## Example: why is the subtitle menu stuck at 准备中?

```
python lib/scripts/librepili_ctl.py status
```
Look at the top page's `menu` row reading `… · 准备中`, then at
`transcription` (null? `hasEnded` true? `suspended`?) and `translation`
(`starting` true with no session?), and at `log --last 50` for `[asr]`
lines around that time.
