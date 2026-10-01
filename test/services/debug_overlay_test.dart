import 'package:PiliPlus/services/debug_overlay.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 30, 12, 0, 5);
  DateTime at(int seconds) => t0.add(Duration(seconds: seconds));

  group('DebugOverlayModel', () {
    test('a line reads as a terminal line: time, area, message', () {
      final model = DebugOverlayModel()..add(t0, 'asr', 'run 1 paused');
      expect(model.lines.single.text, '12:00:05 [asr] run 1 paused');
      expect(model.lines.single.key, isNull);
    });

    test('new lines go to the bottom', () {
      final model = DebugOverlayModel()
        ..add(at(0), 'asr', 'first')
        ..add(at(1), 'player', 'second');
      expect(
        model.lines.map((l) => l.text),
        ['12:00:05 [asr] first', '12:00:06 [player] second'],
      );
    });

    test('progress with the same key changes its line in place', () {
      final model = DebugOverlayModel()
        ..add(at(0), 'asr', 'before')
        ..progress(at(1), 'download x', 'download', '10%')
        ..add(at(2), 'asr', 'after');
      final id = model.lines[1].id;
      model.progress(at(3), 'download x', 'download', '55%');
      expect(model.lines, hasLength(3));
      expect(model.lines[1].id, id);
      expect(model.lines[1].text, '12:00:08 [download] 55%');
      expect(model.lines[1].at, at(3));
      expect(model.lines.last.text, '12:00:07 [asr] after');
    });

    test('another key is another line', () {
      final model = DebugOverlayModel()
        ..progress(at(0), 'asr', 'asr', 'covered to 10 s')
        ..progress(at(0), 'translate', 'translate', 'translated to 5 s');
      expect(model.lines.map((l) => l.key), ['asr', 'translate']);
    });

    test('a line goes 15 s after it last changed', () {
      final model = DebugOverlayModel()
        ..add(at(0), 'asr', 'old')
        ..progress(at(0), 'p', 'player', '1%')
        ..progress(at(10), 'p', 'player', '50%');
      expect(model.prune(at(14)), isFalse);
      expect(model.lines, hasLength(2));
      expect(model.prune(at(15)), isTrue);
      // the progress line was renewed at 10 s: it stays to 25 s
      expect(model.lines.single.key, 'p');
      expect(model.nextExpiry(), at(25));
      model.prune(at(25));
      expect(model.lines, isEmpty);
      expect(model.nextExpiry(), isNull);
    });

    test('the same progress again is no change: it still goes', () {
      final model = DebugOverlayModel()
        ..progress(at(0), 'p', 'player', 'stuck at 0%');
      expect(model.progress(at(10), 'p', 'player', 'stuck at 0%'), isFalse);
      expect(model.lines.single.at, at(0));
      model.prune(at(15));
      expect(model.lines, isEmpty);
    });

    test('at most maxLines, the top ones scrolling away', () {
      final model = DebugOverlayModel(maxLines: 8);
      for (var i = 0; i < 12; i++) {
        model.add(at(i), 'asr', 'line $i');
      }
      expect(model.lines, hasLength(8));
      expect(model.lines.first.text, endsWith('line 4'));
      expect(model.lines.last.text, endsWith('line 11'));
    });

    test('a progress line scrolled away comes back at the bottom', () {
      final model = DebugOverlayModel(maxLines: 2)
        ..progress(at(0), 'p', 'player', '1%')
        ..add(at(1), 'asr', 'a')
        ..add(at(2), 'asr', 'b')
        ..progress(at(3), 'p', 'player', '2%');
      expect(model.lines.map((l) => l.key), [null, 'p']);
    });

    test('mpv only by its errors', () {
      final model = DebugOverlayModel();
      expect(model.add(t0, 'mpv', 'warn ffmpeg: something'), isFalse);
      expect(model.add(t0, 'mpv', 'info cplayer: playing'), isFalse);
      expect(model.add(t0, 'mpv', 'error stream: -138'), isTrue);
      expect(model.add(t0, 'mpv', 'fatal cplayer: gone'), isTrue);
      expect(model.add(t0, 'player', 'warn is a word here'), isTrue);
      expect(model.lines, hasLength(3));
    });

    test('drop takes a progress line away', () {
      final model = DebugOverlayModel()
        ..progress(t0, 'buffering', 'player', '40%')
        ..add(t0, 'player', 'buffering over');
      expect(model.drop('buffering'), isTrue);
      expect(model.drop('buffering'), isFalse);
      expect(model.lines.single.key, isNull);
    });
  });

  group('DebugOverlay', () {
    tearDown(() => DebugOverlay.setEnabled(false));

    test('off, the event log is not listened to and progress is not '
        'built', () async {
      var built = false;
      DebugOverlay.progress('k', 'asr', () {
        built = true;
        return 'x';
      });
      EventLog.add('asr', 'not shown');
      await Future<void>.delayed(Duration.zero);
      expect(built, isFalse);
      expect(DebugOverlay.model.lines, isEmpty);
    });

    test('on, the event log feeds it; progress stays out of the log', () async {
      DebugOverlay.setEnabled(true);
      EventLog.add('gate', 'loading gate up');
      EventLog.add('mpv', 'warn ffmpeg: noise');
      await Future<void>.delayed(Duration.zero);
      expect(
        DebugOverlay.model.lines.single.text,
        endsWith(
          '[gate] loading gate up',
        ),
      );
      final logged = EventLog.recent.length;
      DebugOverlay.progress('asr', 'asr', () => 'covered to 10 s');
      expect(DebugOverlay.model.lines, hasLength(2));
      expect(EventLog.recent.length, logged);
    });

    test('progress is shown at most once per interval, the last one '
        'kept', () async {
      DebugOverlay.setEnabled(true);
      const every = Duration(milliseconds: 100);
      DebugOverlay.progress('p', 'player', () => '1%', every: every);
      DebugOverlay.progress('p', 'player', () => '2%', every: every);
      DebugOverlay.progress('p', 'player', () => '3%', every: every);
      expect(DebugOverlay.model.lines.single.text, endsWith('1%'));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(DebugOverlay.model.lines.single.text, endsWith('3%'));
    });

    test('turned off, it empties and stops listening', () async {
      DebugOverlay.setEnabled(true);
      EventLog.add('asr', 'shown');
      await Future<void>.delayed(Duration.zero);
      expect(DebugOverlay.model.lines, hasLength(1));
      DebugOverlay.setEnabled(false);
      expect(DebugOverlay.model.lines, isEmpty);
      EventLog.add('asr', 'not shown');
      await Future<void>.delayed(Duration.zero);
      expect(DebugOverlay.model.lines, isEmpty);
    });
  });
}
