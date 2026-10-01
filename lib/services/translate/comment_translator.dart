/// LibrePili: translating every comment on screen that is not in a language
/// the viewer reads (research/comment-translation-design-2026-09-25.md, E3).
///
/// On-device, with the subtitles' model ([TranslationService.translateText]).
/// Two switches decide what a comment shows (user 2026-10-01):
///
/// - the list's switch (the 翻译 button over the list) translates every
///   comment that needs it, including those loaded later (user 2026-09-25,
///   1A), and turned off shows every original again;
/// - each comment's own 翻译 / 原文 button turns that one comment the
///   other way, and never moves the list's switch: with the list on, one
///   comment can show its original; with it off, one can be translated.
///
/// What one comment was turned to is forgotten when the list's switch is
/// pressed: that switch says "all of them", and a comment that stayed the
/// other way after it would read as the switch not having worked.
///
/// How a translation is shown — with its original under it, or alone — is
/// [display] (评论翻译显示), the same for every list.
///
/// A comment keeps what makes it a bilibili comment: emotes, @names, topics,
/// links and timestamps are set aside before translating and put back
/// after, so the result is rendered — and clickable — exactly like the
/// original. A translation that lost one of them is not shown.
library;

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Content, ReplyInfo;
import 'package:PiliPlus/models/common/comment_translation_display.dart';
import 'package:PiliPlus/services/translate/text_language.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:get/get.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

/// Asks the model for [text] in [into]; null when it could not, or when the
/// texts [tag] asked for were dropped.
typedef CommentTranslate = Future<String?> Function(
  String text, {
  required String into,
  Object? tag,
});

class CommentTranslator {
  CommentTranslator._(this.key);

  /// One per comment list (a video's comments, a dynamic's…), so a reply
  /// panel opened from it shows the same translations.
  static CommentTranslator of(Object key) =>
      _all.putIfAbsent('$key', () => CommentTranslator._('$key'));

  static final _all = <String, CommentTranslator>{};

  /// Those made so far, without making one (the command-line reader).
  static Iterable<CommentTranslator> get live => _all.values;

  /// [key]'s translator if one was made; unlike [of], never makes one.
  static CommentTranslator? find(Object key) => _all['$key'];

  /// The translator of the list [reply] belongs to, if one was made.
  static CommentTranslator? forReply(ReplyInfo reply) =>
      _all[keyOf(reply.type.toInt(), reply.oid.toInt())];

  /// A comment list's key: the kind of thing commented on, and which.
  static String keyOf(int type, int oid) => '$type:$oid';

  /// A bilibili comment's id as the per-comment state keeps it (a YouTube
  /// comment's own id is a string already).
  static String idOf(ReplyInfo reply) => '${reply.id}';

  /// Forgets [key]'s translations, and drops what it had not done yet.
  static void release(Object key) => _all.remove('$key')?._stop();

  /// Any change to what a comment shows: rebuilds read it.
  static final revision = 0.obs;

  /// How a translated comment is shown, in every list.
  static CommentTranslationDisplay get display =>
      debugDisplay ?? Pref.commentTranslateDisplay;

  /// For tests and the self-test: [display] without the stored setting.
  static CommentTranslationDisplay? debugDisplay;

  /// What asks the model; a test puts its own here.
  @visibleForTesting
  static CommentTranslate? debugTranslate;

  /// What drops the texts a list asked for; a test puts its own here.
  @visibleForTesting
  static void Function(Object tag)? debugDrop;

  final String key;

  /// The list's switch: whether comments are translated unless turned
  /// otherwise one by one, and new comments translated as they load.
  final enabled = false.obs;

  /// Translated so far / to translate, for the button's progress.
  final done = 0.obs;
  final total = 0.obs;

  /// Comments turned the other way from [enabled] by their own button:
  /// true shows the translation with the list off, false the original with
  /// it on. Emptied whenever the list's switch is pressed.
  final _overrides = <String, bool>{};

  /// bilibili comments' translations, and YouTube's (plain text), by id.
  final _translated = <String, Content>{};
  final _texts = <String, String>{};

  /// Asked for and not back yet / came back unusable, by id.
  final _asked = <String>{};
  final _failed = <String>{};

  /// Whether a comment needs translating at all, worked out once.
  final _needs = <String, bool>{};

  /// Bumped when what was asked is dropped: an answer to an older round
  /// is kept if usable, but neither counted nor taken for a failure.
  int _round = 0;

  // ---- what one comment shows ----

  /// Whether the comment [id] is to show its translation: its own button's
  /// choice if it made one, otherwise the list's switch.
  bool shows(String id) => _overrides[id] ?? enabled.value;

  /// Whether [id] is turned the other way from the list's switch.
  bool overridden(String id) => _overrides.containsKey(id);

  /// How many comments are turned the other way (the command-line reader).
  int get overrides => _overrides.length;

  /// [id] is to show its translation and has one to show.
  bool showsTranslation(String id) =>
      shows(id) && (_translated.containsKey(id) || _texts.containsKey(id));

  /// [id] is to show its translation and it is on its way.
  bool pending(String id) => shows(id) && _asked.contains(id);

  /// [id] is to show its translation and it could not be made.
  bool failed(String id) => shows(id) && _failed.contains(id);

  /// What the bilibili comment [reply] shows instead of its own text, if
  /// anything.
  Content? contentFor(ReplyInfo reply) {
    final id = idOf(reply);
    return shows(id) ? _translated[id] : null;
  }

  /// Whether [reply] was to be translated and could not be.
  bool failedFor(ReplyInfo reply) => failed(idOf(reply));

  /// What the plain comment [id] shows instead of its own text, if anything.
  String? textFor(String id) => shows(id) ? _texts[id] : null;

  bool textFailed(String id) => failed(id);

  /// Whether [reply] is in a language the viewer does not read — the only
  /// comments that get a 翻译 button.
  bool needsReply(ReplyInfo reply) => _needs.putIfAbsent(
    idOf(reply),
    () => TextLanguage.needsTranslation(protect(reply.content).plain),
  );

  /// [needsReply] for a plain comment.
  bool needsText(String id, String text) => _needs.putIfAbsent(
    id,
    () => TextLanguage.needsTranslation(protectPlain(text).plain),
  );

  // ---- one comment's button ----

  /// [reply]'s own button: shows it the other way, asking for its
  /// translation if that is the way. The list's switch is not touched.
  void toggleReply(ReplyInfo reply) =>
      _toggleItem(idOf(reply), () => _translate(reply));

  /// [toggleReply] for a plain comment.
  void toggleText(String id, String text) =>
      _toggleItem(id, () => _translateText(id, text));

  void _toggleItem(String id, void Function() ask) {
    final show = !shows(id);
    // back in step with the list: no longer an exception to it
    if (show == enabled.value) {
      _overrides.remove(id);
    } else {
      _overrides[id] = show;
    }
    if (show) ask();
    revision.value++;
  }

  // ---- the list's switch ----

  /// On: [loaded] (and the replies shown under them) are translated. Off:
  /// every comment shows its own text again, and what was not translated
  /// yet is dropped. What was translated is kept for turning it on again.
  /// Either way, what single comments were turned to is forgotten.
  void toggle(Iterable<ReplyInfo> loaded) {
    _overrides.clear();
    if (enabled.value) {
      enabled.value = false;
      _stop();
    } else {
      enabled.value = true;
      add(loaded);
    }
    revision.value++;
  }

  /// [toggle] for plain comments: ([id], text) pairs.
  void toggleTexts(Iterable<(String, String)> loaded) {
    _overrides.clear();
    if (enabled.value) {
      enabled.value = false;
      _stop();
    } else {
      enabled.value = true;
      addTexts(loaded);
    }
    revision.value++;
  }

  /// Comments loaded while on (a new page, a reply panel).
  void add(Iterable<ReplyInfo> replies) {
    if (!enabled.value) return;
    for (final reply in replies) {
      if (shows(idOf(reply))) _translate(reply);
      for (final child in reply.replies) {
        if (shows(idOf(child))) _translate(child);
      }
    }
  }

  /// [add] for plain comments.
  void addTexts(Iterable<(String, String)> comments) {
    if (!enabled.value) return;
    for (final (id, text) in comments) {
      if (shows(id)) _translateText(id, text);
    }
  }

  bool get busy => enabled.value && done.value < total.value;

  // ---- asking ----

  void _translate(ReplyInfo reply) {
    final id = idOf(reply);
    if (_translated.containsKey(id) || _asked.contains(id)) return;
    final content = reply.content;
    final protected = protect(content);
    if (!_needs.putIfAbsent(
      id,
      () => TextLanguage.needsTranslation(protected.plain),
    )) {
      return;
    }
    _ask(id, protected, (restored) {
      _translated[id] = content.deepCopy()..message = restored;
    });
  }

  void _translateText(String id, String text) {
    if (_texts.containsKey(id) || _asked.contains(id)) return;
    final protected = protectPlain(text);
    if (!_needs.putIfAbsent(
      id,
      () => TextLanguage.needsTranslation(protected.plain),
    )) {
      return;
    }
    _ask(id, protected, (restored) => _texts[id] = restored);
  }

  /// One text to the model, and what came back, restored, to [keep].
  void _ask(String id, ProtectedText protected, void Function(String) keep) {
    _asked.add(id);
    _failed.remove(id);
    total.value++;
    final round = _round;
    final translate = debugTranslate ?? TranslationService.to.translateText;
    translate(protected.text, into: TextLanguage.native.first, tag: this).then(
      (result) {
        if (!_all.containsValue(this)) return;
        final restored = result == null ? null : protected.restore(result);
        if (restored != null) keep(restored);
        // dropped (the list turned off): not a failure, and not this
        // round's to count — the counts started again from 0
        if (round == _round) {
          _asked.remove(id);
          if (restored == null) _failed.add(id);
          done.value++;
        }
        revision.value++;
      },
    );
  }

  void _stop() {
    _round++;
    final drop = debugDrop ?? TranslationService.to.dropTexts;
    drop(this);
    _asked.clear();
    done.value = 0;
    total.value = 0;
  }

  /// [protect] for a plain comment: timestamps and links are all it has.
  static ProtectedText protectPlain(String text) => _protect(text, const []);

  /// [content]'s text with what must survive translation replaced by
  /// numbered marks, and the way back.
  static ProtectedText protect(Content content) => _protect(content.message, [
    ...content.emotes.keys,
    ...content.topics.keys.map((e) => '#$e#'),
    ...content.atNameToMid.keys.map((e) => '@$e'),
    // links only: bilibili also marks search keywords in a comment (辐射 4
    // shown as a link to its search), and those are words of the sentence —
    // set aside, the model dropped the noun they stood for. Translated, the
    // word loses its search link
    ...content.urls.keys.where((k) => k.contains('://')),
  ]);

  static ProtectedText _protect(String message, List<String> special) {
    final tokens = [
      ...special,
    ]..sort((a, b) => b.length.compareTo(a.length));
    // the same things, found the same way, as the comment renders them
    // (ReplyItemGrpc._buildMessage)
    final pattern = RegExp(
      [
        ...tokens.map(RegExp.escape),
        r'(?:\d+[:：])?\d+[:：]\d+',
        r'\{vote:\d+?\}',
        Constants.urlRegex.pattern,
      ].join('|'),
    );
    final kept = <String>[];
    var text = message.replaceAllMapped(pattern, (m) {
      kept.add(m[0]!);
      return '⟦${kept.length}⟧';
    });
    // Marks at the very start or end are not sent at all: the model dropped
    // them (a leading @name, a trailing emote — 3 of 10 comments), while
    // every one inside a sentence came back. They are put back as they were.
    String unmark(String part) => part.replaceAllMapped(
      ProtectedText._mark,
      (m) => kept[int.parse(m[1]!) - 1],
    );
    final head = RegExp(r'^(?:\s*⟦\d+⟧)+\s*').firstMatch(text)?[0] ?? '';
    text = text.substring(head.length);
    final tail = RegExp(r'\s*(?:⟦\d+⟧\s*)+$').firstMatch(text)?[0] ?? '';
    text = text.substring(0, text.length - tail.length);
    return ProtectedText(
      text: text,
      kept: kept,
      prefix: unmark(head),
      suffix: unmark(tail),
      plain: message.replaceAll(pattern, ' '),
    );
  }
}

class ProtectedText {
  const ProtectedText({
    required this.text,
    required this.kept,
    required this.plain,
    this.prefix = '',
    this.suffix = '',
  });

  /// What stood before and after [text], put back around its translation.
  final String prefix;
  final String suffix;

  /// What is translated: the marks stand for [kept].
  final String text;
  final List<String> kept;

  /// The words alone, for telling the language.
  final String plain;

  static final _mark = RegExp('⟦(\\d+)⟧');
  static final _looseMark = RegExp(r'[\[【⟦]\s*(\d+)\s*[\]】⟧]');

  /// [translated] with the marks put back; null unless every mark came back
  /// exactly once — a model that dropped or doubled one would show a
  /// comment missing an emote or a name, or with one twice.
  String? restore(String translated) {
    // the model sometimes writes a mark its own way ([1], 【1】, ⟦ 1 ⟧);
    // taken as the mark unless the text itself had that form
    translated = translated.replaceAllMapped(_looseMark, (m) {
      final n = int.parse(m[1]!);
      return n >= 1 && n <= kept.length && !text.contains(m[0]!)
          ? '⟦$n⟧'
          : m[0]!;
    });
    List<int> marks(String text) =>
        [for (final m in _mark.allMatches(text)) int.parse(m[1]!)]..sort();
    final sent = marks(text);
    final seen = marks(translated);
    if (seen.length != sent.length) return null;
    for (var i = 0; i < seen.length; i++) {
      if (seen[i] != sent[i]) return null;
    }
    final middle = translated.trim().replaceAllMapped(
      _mark,
      (m) => kept[int.parse(m[1]!) - 1],
    );
    return '$prefix$middle$suffix';
  }
}
