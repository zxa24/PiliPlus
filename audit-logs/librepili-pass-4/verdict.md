# pass 4 verdict — second global audit (HEAD 35040e4e3)
- voices returned: 1 codex (fresh session) + 1 claude xhigh (read-only, no Bash) + 2 Agents on disjoint areas (accounts/privacy, downloads/media) + 1 Agent ANCHORED on the pass-3 fixes = 5/5
- anchored voice verified ~120 pass-3 claims: mostly CONFIRMED, 3 PARTLY (mt:* authority check, _streamKey without size, live danmaku first-connect retry) and 18 new defects introduced by pass 3
- union: 77 findings -> batch A 38 groups + batch B 20 groups + 2 route picks (D1 identity rename, D2 iOS/macOS URL+document registration), both decided by the user (A/A)
- fixers: two sessions (b5b42b1e, c9f83b90); the refinement turn was killed once by OS low memory and resumed on the user's instruction
- codex re-review: 106/120 RESOLVED, 7 PARTIAL -> all fixed in iter 2 -> TOTAL: ROUND-OK
- notable: B16 measured 49,570 ms -> 185 ms for a 10-minute FLV remux (buffered writer + ~1 s chunk grouping; stco 164,380 -> 4,804 B), which also speeds up the DASH merge path
- orchestrator re-run: dart analyze lib test exit 0; flutter test 113/113; flutter build windows --debug OK
- device work this pass: ASR benchmarks on OnePlus (SD 8 Gen 2) and Pixel 4 XL (SD855) — see research/
- NOT verified: Kotlin/Java/Swift/C++ and workflow changes (CI build pending), all UI changes; the Dart package name is still `PiliPlus` by decision (6379 imports); D2's macOS bridge is untested on a Mac
