# watch_page reports: the shape `run.ps1 -Plan watch_page` reads

What the self-test checks of S0b (`lib/utils/self_test.dart`, a later part
of S0b) must write so the runner can judge them. Design:
`feature-logs/watch-page-shell/design.md` §5 S0b (runner items, 「多份报告的判法」,
「uiErrors」, 「AC-S1 的比较」), §6.2 (the fields). The runner side is
`test/mutants/run.ps1` (header comment) and its offline self-test
`test/mutants/wp_compare_selftest.ps1`.

## 1. One run = one report file

The runner starts the app as

    LibrePili.exe --selftest --profile <new name> --out <pass folder>\<report>
                  [--pref k:type=v ...] <the field table's run.args>

`run.args` may use `${SHOTS}` (a folder `<pass folder>\<table id>_shots`
for screenshots), `${FIXTURES}` (the tree's `test\fixtures`) and `${OUT}`
(the pass folder). `--pref` comes from `wp-mutants.json` `prefs` (unless
the table says `"planPrefs": false`) and the table's `run.prefs`, merged by
key, the table's last.

The report is the JSON the self test already writes:

```json
{
  "checks": [ { "name": "<check>", "pass": true, "measured": true, "...": "..." } ],
  "display": { "name": "\\\\.\\DISPLAY1", "resolution": "3840x2160", "dpi": 120 },
  "eventLog": ["..."]
}
```

- `checks[]` holds the check objects; the field table names one by `check`
  (its `name`) and the file by `report`. One command line may produce
  several checks (several tables then share one `report`).
- `display` (report root; a table may point elsewhere with `"display":
  "<path>"`): the display the test window was on and its DPI (runner
  补充⑦). Reports taken on different displays are not compared (无结果).
  Missing = not checked.

## 2. The check object

| key | meaning |
|---|---|
| `name` | the check's name (the framework sets it) |
| `pass` | judging check: decided by behaviour. recording check: = `measured`. `uiErrors` must **not** make it false for watch_page checks (design §5 「uiErrors」; today `self_test.dart:837-843` does, for every check) |
| `measured` | the JSON boolean `true` only when the check got to the step that measures. Anything else (missing, false, `"true"`, `1`, `[true]`) = the run did not measure: 无结果 in `-Compare`, error for a mutant (runner 补充①) |
| the fields | any structure; the field table's `path` points into it (`a.b[2].c`, `@a.b` from the report root) |
| `uiErrors` | see §4; **always written**, `[]` when there were none. A report without the key is 无结果 (a broken writer must not read as "no errors"); only a legacy table (today's reports) or `uiErrors.optional: true` allows its absence |

Suggested layout of the fields (design §6.2; paths are free, the table
says where): `window` (`logical` size as the app laid out at, from
`MediaQuery.sizeOf`), `end` (endpoint readings at the check's end),
`moments` (`enterBefore`, `enterDone`, `exitBefore`, `exitDone`, and
`before:<action>` for every action in fullscreen), `events` (event-defined
readings, e.g. "the first frame with value ≥ 0.5"), `frames` (the per-frame
record: never in a field table's must-same fields).

Values are compared as canonical JSON text: key order does not matter,
numbers compare by value (`1`, `1.0` and `1e0` are one value: Dart writes a
`double` 1 as `1.0`), and a date is the string written (two offsets for the
same instant are two values). Round rectangles to 0.5 logical px in the app, report
tab **roles** not texts (`'评论 ${count}'` changes), and keep times, counts
and paths out of must-same fields (they go in as `unstable`, found by the
calibration mode). A screenshot field holds a PNG path or a list of them
(table field `"type": "shot"`, `"tolerance": <pixels>`); write the PNGs
under `${SHOTS}` — the runner finds them beside the report by file name
when the folder has moved. An image that is not there, or does not
decode, is no reading (无结果 / error), not a value that differs.

### Unreadable readings

When an accessor cannot read a value it writes the marker instead of the
value — never `null`, never a missing key:

```json
{ "$unread": "pageRoute" }
```

The reason is free text (`pageRoute` = the named page's route did not
validate, design §5 「每个访问器读一个指名的页面」). The marker anywhere
inside a field's value makes that field 无结果 in `-Compare` and, for a
mutant's expected field, error. A missing key is treated the same way
(①): two missing keys are not "the same".

## 3. Preconditions

A table may require a value in every pass (`preconditions: [{ path,
equals, extraRuns }]`, e.g. `--open-bili`'s `played: true`). A pass that
fails it is spoiled: rerun on the same commit (at most `extraRuns` per
side), more = 无结果.

## 4. uiErrors

From S0b on, one object per framework error, raw (the runner makes the
keys; the report keeps everything):

```json
{
  "text": "<the error's text, may be cut>",
  "kind": "A RenderFlex overflowed by 13 pixels on the right",
  "widget": "Row",
  "origin": "lib/common/widgets/video_card/video_card_h.dart:132:11",
  "context": "during layout",
  "frames": ["#3 _Foo.build (package:PiliPlus/pages/video/view.dart:1012:7)"]
}
```

| key | from | note |
|---|---|---|
| `kind` | the assertion's first sentence | numbers are removed by the runner |
| `widget` | the type in "The relevant error-causing widget was: Row …" | |
| `origin` | the creation location in that same diagnostic | **not truncated**; a `file:///<root>/…` URI, an absolute path or repo-relative — the runner strips the worktree root named in the folder's `manifest.json`. `null` when the error has no error-causing widget |
| `context` | `details.context` description | |
| `frames` | the first app frames (`_appFrames`) | `package:PiliPlus/…` is read as `lib/…`; absolute paths are stripped of the root |

Key = kind + widget + origin; with no origin, kind + context + first app
frame (weak); with neither, kind + context (weak). Between two commits the
location goes through `git diff -U0` and `wp_origin_map.json` (run.ps1
header); between a mutant and its baseline through the mutant's patch.
Today's string entries (320-character text) are read too, for AC-S0a; they
cannot carry an untruncated origin (a line number the cut runs into is not
read), which is why S0b adds the object form. An entry that is a
`{"$unread": …}` marker, or neither text nor an object, cannot be placed.

## 5. Report folders (written by the runner, not the app)

`run.ps1 -Alternate` writes, per commit:

```
<Out>\parent-<sha9>\  (or new-<sha9>\, or <sha9>\ for one commit)
  manifest.json
  runs.jsonl          one line per check run, in run order
  pass1\pass.json     { "pass": 1, "checks": [ids], "started": … }
  pass1\<report> <report> ...   pass2\ ...
```

`pass.json` is written before the pass runs and names the checks it was
meant to hold: a pass of some checks (`-Checks`, a batch) is not read as
the other checks' missing reports. Without it every check is expected in
the pass. Tables that share a report file are run once (one command line).

`manifest.json`:

```json
{
  "plan": "watch_page",
  "commit": "<full sha>",
  "lib": "<tree>", "fixtures": "<tree>", "windowsRunner": "<tree>",
  "media": { "<path>|<file>": "<sha256>" },
  "root": "C:\\...\\_tmp\\mutants\\wpA",
  "runner": "<run.ps1 blob>",
  "slot": 1
}
```

`-Compare` refuses a folder without it, checks that the trees match the
commit, strips `root` from uiErrors paths, and needs the two commits to be
the same (calibration) or parent and child (comparison). Two manifests
whose `media` differ are not compared (every row 无结果); roots of
different length make today's string uiErrors 无法比较. Hand-made folders
(the S0a 核对 runs, design §5 S0a 「由谁判」) use the same layout; `root` is
the worktree the build was made in, `plan` must be `watch_page`.

## 6. Profile snapshots (offline checks)

A table's `run.profile` is `fresh` or `snapshot:<dir>` (relative = from
the repository root). Before each run the runner copies `<dir>\appdata\`
to `%APPDATA%\com.zxa24\LibrePili\selftest-<profile>\` and `<dir>\temp\`
to `%TEMP%\LibrePili\selftest-<profile>\` (a snapshot with neither is all
appdata), and in every copied `.json` replaces `${PROFILE_APPDATA}` /
`${PROFILE_TEMP}` with those folders — so download records can hold the
new absolute `merged_path` (design v7 wp6#13). The snapshot folder is
hashed into the manifest's `media`.
