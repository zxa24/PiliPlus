/// LibrePili: translating every comment on screen that is not in a language
/// the viewer reads (research/comment-translation-design-2026-09-25.md, E3).
///
/// On-device, with the subtitles' model ([TranslationService.translateText]);
/// the translation replaces the comment's text and the whole list goes back
/// to the originals at a touch. Once on, comments loaded later are
/// translated too (user 2026-09-25, 1A).
///
/// A comment keeps what makes it a bilibili comment: emotes, @names, topics,
/// links and timestamps are set aside before translating and put back
/// after, so the result is rendered — and clickable — exactly like the
/// original. A translation that lost one of them is not shown.
library;

import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Content, ReplyInfo;
import 'package:PiliPlus/services/translate/text_language.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:get/get.dart';
import 'package:protobuf/protobuf.dart' show GeneratedMessageGenericExtensions;

class CommentTranslator {
  CommentTranslator._(this.key);

  /// One per comment list (a video's comments, a dynamic's…), so a reply
  /// panel opened from it shows the same translations.
  static CommentTranslator of(Object key) =>
      _all.putIfAbsent('$key', () => CommentTranslator._('$key'));

  static final _all = <String, CommentTranslator>{};

  /// The translator of the list [reply] belongs to, if one was made.
  static CommentTranslator? forReply(ReplyInfo reply) =>
      _all[keyOf(reply.type.toInt(), reply.oid.toInt())];

  /// A comment list's key: the kind of thing commented on, and which.
  static String keyOf(int type, int oid) => '$type:$oid';

  /// Forgets [key]'s translations, and drops what it had not done yet.
  static void release(Object key) => _all.remove('$key')?._stop();

  /// Any change to what a comment shows: rebuilds read it.
  static final revision = 0.obs;

  final String key;

  /// Whether translations are shown and new comments translated.
  final enabled = false.obs;

  /// Translated so far / to translate, for the button's progress.
  final done = 0.obs;
  final total = 0.obs;

  final _translated = <int, Content>{};
  final _failed = <int>{};
  final _asked = <int>{};

  bool get busy => enabled.value && done.value < total.value;

  /// What [reply] shows instead of its own text, if anything.
  Content? contentFor(ReplyInfo reply) =>
      enabled.value ? _translated[reply.id.toInt()] : null;

  /// Whether [reply] was to be translated and could not be.
  bool failedFor(ReplyInfo reply) =>
      enabled.value && _failed.contains(reply.id.toInt());

  /// On: [loaded] (and the replies shown under them) are translated. Off:
  /// every comment shows its own text again, and what was not translated
  /// yet is dropped. What was translated is kept for turning it on again.
  void toggle(Iterable<ReplyInfo> loaded) {
    if (enabled.value) {
      enabled.value = false;
      _stop();
    } else {
      enabled.value = true;
      add(loaded);
    }
    revision.value++;
  }

  /// Comments loaded while on (a new page, a reply panel).
  void add(Iterable<ReplyInfo> replies) {
    if (!enabled.value) return;
    for (final reply in replies) {
      _translate(reply);
      for (final child in reply.replies) {
        _translate(child);
      }
    }
  }

  void _translate(ReplyInfo reply) {
    final id = reply.id.toInt();
    if (_translated.containsKey(id) || _asked.contains(id)) return;
    final content = reply.content;
    final protected = protect(content);
    if (!TextLanguage.needsTranslation(protected.plain)) return;
    _asked.add(id);
    _failed.remove(id);
    total.value++;
    TranslationService.to
        .translateText(
          protected.text,
          into: TextLanguage.native.first,
          tag: this,
        )
        .then((result) {
          _asked.remove(id);
          if (!_all.containsValue(this)) return;
          final restored = result == null ? null : protected.restore(result);
          if (restored == null) {
            _failed.add(id);
          } else {
            _translated[id] = content.deepCopy()..message = restored;
          }
          done.value++;
          revision.value++;
        });
  }

  void _stop() {
    TranslationService.to.dropTexts(this);
    _asked.clear();
    done.value = 0;
    total.value = 0;
  }

  /// [content]'s text with what must survive translation replaced by
  /// numbered marks, and the way back.
  static ProtectedText protect(Content content) {
    final tokens = [
      ...content.emotes.keys,
      ...content.topics.keys.map((e) => '#$e#'),
      ...content.atNameToMid.keys.map((e) => '@$e'),
      ...content.urls.keys,
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
    var text = content.message.replaceAllMapped(pattern, (m) {
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
      plain: content.message.replaceAll(pattern, ' '),
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

  /// [translated] with the marks put back; null unless every mark came back
  /// exactly once — a model that dropped or doubled one would show a
  /// comment missing an emote or a name, or with one twice.
  String? restore(String translated) {
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
