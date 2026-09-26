import 'package:PiliPlus/grpc/bilibili/main/community/reply/v1.pb.dart'
    show Content, Emote;
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';

/// What a comment keeps through translation
/// (research/comment-translation-design-2026-09-25.md, C2).
void main() {
  Content content(
    String message, {
    List<String> emotes = const [],
    List<String> at = const [],
  }) {
    final c = Content(message: message);
    for (final e in emotes) {
      c.emotes[e] = Emote(text: e);
    }
    for (final name in at) {
      c.atNameToMid[name] = Int64(1);
    }
    return c;
  }

  test('emotes, names, timestamps and links become marks', () {
    final p = CommentTranslator.protect(
      content(
        'look at 12:30 [doge] and https://example.com/a ok',
        emotes: ['[doge]'],
      ),
    );
    expect(p.text, 'look at ⟦1⟧ ⟦2⟧ and ⟦3⟧ ok');
    expect(
      p.restore('看 ⟦1⟧ ⟦2⟧ 和 ⟦3⟧ 好'),
      '看 12:30 [doge] 和 https://example.com/a 好',
    );
  });

  test('marks at the start and end are not sent, and are put back', () {
    final p = CommentTranslator.protect(
      content(
        '@Alice you have to watch this [doge]',
        emotes: ['[doge]'],
        at: ['Alice'],
      ),
    );
    expect(p.text, 'you have to watch this');
    // the model answered without any mark: nothing was lost
    expect(p.restore('你一定要看这个'), '@Alice 你一定要看这个 [doge]');
  });

  test('a translation that lost or doubled a mark is not shown', () {
    final p = CommentTranslator.protect(content('see 1:20 and 2:30 here'));
    expect(p.text, 'see ⟦1⟧ and ⟦2⟧ here');
    expect(p.restore('看 ⟦1⟧ 这里'), isNull);
    expect(p.restore('看 ⟦1⟧ 和 ⟦1⟧ 这里'), isNull);
  });

  test('the words alone decide the language', () {
    final p = CommentTranslator.protect(
      content('@小明 [doge] this is great', emotes: ['[doge]'], at: ['小明']),
    );
    expect(p.plain.trim(), 'this is great');
  });
}
