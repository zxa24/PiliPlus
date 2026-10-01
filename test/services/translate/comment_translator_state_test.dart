import 'dart:async';

import 'package:PiliPlus/common/widgets/comments/comment_translation.dart';
import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Content, ReplyInfo;
import 'package:PiliPlus/models/common/comment_translation_display.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/services/translate/text_language.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// The list's switch and each comment's own button (user 2026-10-01): what
/// a comment shows, and that a comment's button never moves the switch.
void main() {
  // every request waits here until the test answers it
  late Map<String, Completer<String?>> asked;
  late List<Object> dropped;
  var n = 0;

  setUp(() {
    asked = {};
    dropped = [];
    TextLanguage.debugNative = ['zh'];
    CommentTranslator.debugTranslate = (text, {required into, tag}) =>
        (asked[text] = Completer<String?>()).future;
    CommentTranslator.debugDrop = (tag) {
      dropped.add(tag);
      for (final c in asked.values) {
        if (!c.isCompleted) c.complete(null);
      }
    };
  });

  tearDown(() {
    TextLanguage.debugNative = null;
    CommentTranslator.debugTranslate = null;
    CommentTranslator.debugDrop = null;
  });

  CommentTranslator fresh() => CommentTranslator.of('test:${n++}');

  ReplyInfo reply(int id, String message) => ReplyInfo(
    id: Int64(id),
    content: Content(message: message),
  );

  Future<void> answer(String text, String translation) async {
    asked[text]!.complete(translation);
    await pumpEventQueue();
  }

  const en1 = 'This is the best video I have seen this year';
  const en2 = 'I have watched this three times and it is still great';
  const zh = '这个视频真的很好看，我看了好几遍';

  test('master on translates every comment that needs it', () async {
    final t = fresh();
    final a = reply(1, en1), b = reply(2, en2), c = reply(3, zh);
    t.toggle([a, b, c]);
    expect(t.enabled.value, isTrue);
    expect(asked.keys, unorderedEquals([en1, en2]));
    expect(t.pending('1'), isTrue);
    await answer(en1, '今年看过最好的视频');
    await answer(en2, '看了三遍还是很棒');
    expect(t.contentFor(a)?.message, '今年看过最好的视频');
    expect(t.showsTranslation('2'), isTrue);
    // already in the viewer's language: nothing to show, no button
    expect(t.showsTranslation('3'), isFalse);
    expect(t.needsReply(c), isFalse);
    expect(t.needsReply(a), isTrue);
    expect(t.done.value, 2);
    expect(t.total.value, 2);
  });

  test('master off shows every original and keeps the translations', () async {
    final t = fresh();
    final a = reply(1, en1);
    t.toggle([a]);
    await answer(en1, '今年看过最好的视频');
    t.toggle([a]);
    expect(t.enabled.value, isFalse);
    expect(t.contentFor(a), isNull);
    // on again: the translation kept, not asked again
    asked.clear();
    t.toggle([a]);
    expect(asked, isEmpty);
    expect(t.contentFor(a)?.message, '今年看过最好的视频');
  });

  test('with master on, one comment turned off shows its original and the '
      'master stays on', () async {
    final t = fresh();
    final a = reply(1, en1), b = reply(2, en2);
    t.toggle([a, b]);
    await answer(en1, '甲');
    await answer(en2, '乙');
    t.toggleReply(a);
    expect(t.enabled.value, isTrue);
    expect(t.contentFor(a), isNull);
    expect(t.shows('1'), isFalse);
    expect(t.overridden('1'), isTrue);
    expect(t.contentFor(b)?.message, '乙');
    // and back: in step with the list again, no longer an exception
    t.toggleReply(a);
    expect(t.contentFor(a)?.message, '甲');
    expect(t.overridden('1'), isFalse);
    expect(t.enabled.value, isTrue);
  });

  test('with master off, one comment turned on is translated alone and the '
      'master stays off', () async {
    final t = fresh();
    final a = reply(1, en1), b = reply(2, en2);
    t.toggleReply(a);
    expect(t.enabled.value, isFalse);
    expect(asked.keys, [en1]);
    expect(t.pending('1'), isTrue);
    expect(t.pending('2'), isFalse);
    await answer(en1, '甲');
    expect(t.contentFor(a)?.message, '甲');
    expect(t.contentFor(b), isNull);
    expect(t.enabled.value, isFalse);
    // comments loaded now are not translated: the list is off
    t.add([reply(4, 'Another comment in English for the list here')]);
    expect(asked.keys, [en1]);
  });

  test(
    'pressing the master clears what single comments were turned to',
    () async {
      final t = fresh();
      final a = reply(1, en1), b = reply(2, en2);
      // off, one on — then the master on: all translated
      t.toggleReply(a);
      await answer(en1, '甲');
      t.toggle([a, b]);
      expect(t.overrides, 0);
      await answer(en2, '乙');
      expect(t.contentFor(a)?.message, '甲');
      expect(t.contentFor(b)?.message, '乙');
      // on, one off — then the master off: all originals
      t.toggleReply(b);
      expect(t.overrides, 1);
      t.toggle([a, b]);
      expect(t.overrides, 0);
      expect(t.contentFor(a), isNull);
      expect(t.contentFor(b), isNull);
      // and on again: the one turned off earlier is translated like the rest
      t.toggle([a, b]);
      expect(t.contentFor(b)?.message, '乙');
    },
  );

  test('comments loaded later are translated while the master is on', () async {
    final t = fresh();
    t.toggle([reply(1, en1)]);
    final later = reply(5, en2);
    final child = reply(6, 'And a reply to it, also written in English');
    later.replies.add(child);
    t.add([later]);
    expect(asked.keys, containsAll([en1, en2, child.content.message]));
    await answer(en2, '乙');
    await answer(child.content.message, '丙');
    expect(t.contentFor(later)?.message, '乙');
    expect(t.contentFor(child)?.message, '丙');
  });

  test('plain comments (YouTube) follow the same rules', () async {
    final t = fresh();
    t.toggleTexts([('a', en1), ('b', en2)]);
    await answer(en1, '甲');
    await answer(en2, '乙');
    t.toggleText('a', en1);
    expect(t.textFor('a'), isNull);
    expect(t.textFor('b'), '乙');
    expect(t.enabled.value, isTrue);
    t.toggleTexts(const []);
    expect(t.enabled.value, isFalse);
    expect(t.textFor('b'), isNull);
    t.toggleText('b', en2);
    expect(t.textFor('b'), '乙');
    expect(t.textFor('a'), isNull);
    expect(t.enabled.value, isFalse);
    // loaded later while on
    t.toggleTexts(const []);
    t.addTexts([('c', 'One more comment that arrives on the next page')]);
    expect(
      asked.keys,
      contains('One more comment that arrives on the next page'),
    );
  });

  test('turning the master off drops what was waiting, and it is neither a '
      'failure nor counted', () async {
    final t = fresh();
    final a = reply(1, en1);
    t.toggle([a]);
    t.toggle([a]);
    await pumpEventQueue();
    expect(dropped, [t]);
    expect(t.done.value, 0);
    expect(t.total.value, 0);
    // asked again when turned on, not taken for failed
    t.toggle([a]);
    expect(t.failed('1'), isFalse);
    expect(t.pending('1'), isTrue);
    expect(t.total.value, 1);
    expect(t.done.value, 0);
  });

  test('a translation that loses a mark is a failure, shown only while the '
      'comment is to be translated', () async {
    final t = fresh();
    final a = reply(1, 'Look at 12:30 this is the best part of the video');
    t.toggleReply(a);
    final sent = asked.keys.single;
    await answer(sent, '看这里，最好的部分');
    expect(t.failed('1'), isTrue);
    expect(t.showsTranslation('1'), isFalse);
    t.toggleReply(a);
    expect(t.failed('1'), isFalse);
  });

  group('the shared text block', () {
    Widget host(CommentTranslator t, String id, String text) => MaterialApp(
      home: Scaffold(
        body: CommentTranslatedText(
          translator: t,
          id: id,
          builder:
              (
                context, {
                required translated,
                required first,
                required style,
              }) => Text(
                (translated ? t.textFor(id) : null) ?? text,
                style: style,
              ),
        ),
      ),
    );

    tearDown(() => CommentTranslator.debugDisplay = null);

    testWidgets('bilingual: the translation first, the original under it, '
        'smaller', (tester) async {
      CommentTranslator.debugDisplay = CommentTranslationDisplay.bilingual;
      final t = fresh();
      await tester.pumpWidget(host(t, 'a', en1));
      expect(find.text(en1), findsOneWidget);
      t.toggleText('a', en1);
      await tester.runAsync(() => answer(en1, '甲'));
      await tester.pump();
      final top = tester.getTopLeft(find.text('甲')).dy;
      final under = tester.getTopLeft(find.text(en1)).dy;
      expect(top, lessThan(under));
      final size = (Text w) => w.style!.fontSize!;
      expect(
        size(tester.widget<Text>(find.text(en1))),
        lessThan(size(tester.widget<Text>(find.text('甲')))),
      );
    });

    testWidgets('translation only: the original is not shown', (tester) async {
      CommentTranslator.debugDisplay =
          CommentTranslationDisplay.translationOnly;
      final t = fresh();
      await tester.pumpWidget(host(t, 'a', en1));
      t.toggleText('a', en1);
      await tester.runAsync(() => answer(en1, '甲'));
      await tester.pump();
      expect(find.text('甲'), findsOneWidget);
      expect(find.text(en1), findsNothing);
    });
  });
}
