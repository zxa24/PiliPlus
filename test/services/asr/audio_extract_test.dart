import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards the shape of the extraction isolate's entry point.
///
/// `Isolate.run` ships the whole context object of its enclosing scope, not
/// just the variables the closure reads. Called directly from `extract`, it
/// dragged that method's progress `Timer` along, and a Timer cannot cross an
/// isolate: every transcription in the app died with
/// "object is unsendable - Class: _Timer" before decoding began.
///
/// This is checked on the source rather than by running it, deliberately:
/// **the failure does not reproduce under `flutter test`.** Whether a closure
/// context includes a neighbouring variable is a compiler decision, and the
/// JIT the tests run under groups them differently from the AOT build on a
/// phone — a behavioural test here passes with the bug still in place, which
/// is worse than no test. What can be guaranteed is that the spawn stays in a
/// helper whose scope holds nothing but its arguments.
void main() {
  test('the isolate is spawned from a scope holding only its arguments', () {
    final source = File('lib/services/asr/audio_extract.dart')
        .readAsStringSync();

    final calls = 'Isolate.run('.allMatches(source).length;
    expect(
      calls,
      1,
      reason: 'Isolate.run belongs in _spawn and nowhere else',
    );

    final spawn = RegExp(
      r'static Future<_ExtractOutcome> _spawn\(_ExtractArgs args\) =>\s*'
      r'Isolate\.run\(\(\) => _extract\(args\)\);',
    );
    expect(
      spawn.hasMatch(source),
      isTrue,
      reason: 'the spawn helper must capture args and nothing else',
    );
  });
}
