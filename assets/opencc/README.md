# OpenCC dictionaries (s2twp)

From Open Chinese Convert (OpenCC) ver.1.4.2, https://github.com/BYVoid/OpenCC,
Apache License 2.0 (see LICENSE in this directory). Unmodified text
dictionaries from `data/dictionary/`, except
`STPhrases_GeneratedFromRegionalPhrases.txt`, which OpenCC generates at build
time from the keys of `HKPhrases.txt` and `TWPhrases.txt` converted with
`t2s.json` (`data/scripts/generate_st_phrases_from_regional_phrases.py`); it
was generated the same way with the `opencc` 1.4.2 Python package.

Used by `lib/services/translate/chinese_convert.dart` for the `s2twp`
conversion (Simplified to Traditional, Taiwan standard, with Taiwan phrases).
