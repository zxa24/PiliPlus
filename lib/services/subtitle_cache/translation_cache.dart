/// LibrePili: a translation of a transcript tied to the subtitle cache
/// (research/subtitle-switch-design-2026-09-26.md, 9B).
///
/// Kept outside the session on purpose: the session knows nothing of the
/// cache. It is handed what was kept before it starts — results under the
/// same keys a session uses (where a unit starts, in milliseconds), each
/// with the text it was made from, so one whose text has changed since is
/// simply not settled and is translated again — and what it adds is kept
/// as it goes, a few seconds after each change, and when it ends.
library;

import 'dart:async';

import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:get/get.dart';

class TranslationCacheLink {
  /// Puts what [entry] keeps under [key] into [session]'s results — before
  /// the session starts, so a unit translated before is settled from its
  /// first look and never loads the model — and keeps what it makes.
  TranslationCacheLink(this.session, this.entry, {required this.key}) {
    final kept = entry.translationsFor(key);
    preloaded = kept.length;
    session.results.addAll(kept);
    _worker = ever<int>(session.revision, (_) => _schedule());
  }

  final TranslationSession session;
  final SubtitleCacheEntry entry;

  /// See [subtitleTranslationKey].
  final String key;

  /// How many results the cache had, for the probes.
  late final int preloaded;

  /// Changes are kept this long after the last one: a burst of units that
  /// needed no model settles many in a row.
  static const delay = Duration(seconds: 3);

  late final Worker _worker;
  Timer? _timer;
  var _closed = false;

  void _schedule() {
    if (_closed) return;
    _timer?.cancel();
    _timer = Timer(delay, save);
  }

  /// Keeps the results as they stand.
  void save() {
    _timer?.cancel();
    _timer = null;
    final before = entry.translations[key];
    entry.captureTranslations(key, session.results, {
      for (final unit in session.units) unit.key: unit.text,
    });
    final after = entry.translations[key]!;
    // nothing new: no write
    if (before != null &&
        before.length == after.length &&
        after.entries.every((e) => before[e.key] == e.value)) {
      return;
    }
    unawaited(entry.save());
  }

  /// The session is going: what it made is kept, and nothing more is
  /// listened to.
  void close() {
    if (_closed) return;
    _closed = true;
    _worker.dispose();
    save();
  }
}
