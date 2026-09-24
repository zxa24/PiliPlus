import 'dart:io';

import 'package:PiliPlus/services/translate/chinese_convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// Against OpenCC 1.4.2 itself: test/fixtures/s2twp_reference.tsv is the
/// FLORES-200 Simplified Chinese dev and devtest sets (2 009 sentences) and a
/// few lines of their own, each with what the `opencc` 1.4.2 Python package
/// makes of it with s2twp.json.
void main() {
  late S2twpConverter converter;

  setUpAll(() {
    converter = S2twpConverter.fromTexts({
      for (final name in S2twpConverter.files)
        name: File('assets/opencc/$name.txt').readAsStringSync(),
    });
  });

  test('matches OpenCC on every line of the reference', () {
    final lines = File(
      'test/fixtures/s2twp_reference.tsv',
    ).readAsLinesSync().where((l) => l.contains('\t'));
    final wrong = <String>[];
    var count = 0;
    for (final line in lines) {
      count++;
      final [source, expected] = line.split('\t');
      final got = converter.convert(source);
      if (got != expected) wrong.add('$source\n  want $expected\n  got  $got');
    }
    expect(count, greaterThan(2000));
    expect(wrong, isEmpty, reason: wrong.take(5).join('\n'));
  });

  test('Taiwan phrases, not only characters', () {
    expect(converter.convert('软件、网络、信息、视频'), '軟體、網路、資訊、影片');
  });

  test('a character outside the BMP is one character', () {
    // 𪚥 is its own traditional form, and must come through whole
    expect(converter.convert('𪚥'), '𪚥');
  });

  test('nothing to convert comes back as it was', () {
    expect(converter.convert(''), '');
    expect(converter.convert('Hello, world 123'), 'Hello, world 123');
  });
}
