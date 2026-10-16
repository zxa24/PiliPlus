import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/services/asr/asr_cue.dart';
import 'package:PiliPlus/services/asr/transcript_files.dart';
import 'package:PiliPlus/services/asr/transcript_store.dart';
import 'package:PiliPlus/services/subtitle_cache/subtitle_cache.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

/// A downloaded video's transcript beside it: `base.asr.srt` to read,
/// `base.asr.json` for the app to go on from.
void main() {
  const recogniser = 'sense-voice-2024-07-17+silero-vad';
  final key = SubtitleCacheKey.bilibili(221238811);
  late Directory root;
  late String video;

  AsrCue cue(double from, double to, String content) =>
      AsrCue(from: from, to: to, content: content);

  /// A transcript of [0, end): one segment of Chinese, one of English.
  SubtitleCacheEntry entryUpTo(double end) {
    final store = TranscriptStore();
    final run = store.startRun(0);
    store
      ..addSegment(
        run,
        1,
        3,
        [cue(1, 4, '你好，世界。')],
        language: 'zh',
        weight: 7 + 20,
      )
      ..addSegment(
        run,
        6,
        3,
        [cue(6, 9, 'Hello, world.')],
        language: 'en',
        weight: 14,
      )
      ..advance(run, end);
    return SubtitleCacheEntry(key, recogniser)..captureTranscript(store);
  }

  setUp(() {
    root = Directory.systemTemp.createTempSync('transcript_files_test');
    video = path.join(root.path, 'a [480P].mp4');
    File(video).writeAsStringSync('');
  });
  tearDown(() => root.deleteSync(recursive: true));

  test('the SRT is the transcript as the player shows it', () async {
    expect(await TranscriptFiles.write(entryUpTo(12), video), isTrue);
    final srt = File(
      path.join(root.path, 'a [480P].asr.srt'),
    ).readAsStringSync();
    // Chinese loses its commas and full stops on screen, English keeps them
    expect(srt, contains('你好 世界'));
    expect(srt, isNot(contains('你好，')));
    expect(srt, contains('Hello, world.'));
    expect(srt, contains('00:00:01,000 --> '));
  });

  test('the entry beside the video reads back as it was', () async {
    final entry = entryUpTo(12);
    await TranscriptFiles.write(entry, video);
    final read = await TranscriptFiles.read(video, key, recogniser);
    expect(read, isNotNull);
    expect(read!.coveredSeconds, entry.coveredSeconds);
    expect(jsonEncode(read.toJson()), jsonEncode(entry.toJson()));
    // another recogniser's text, or another part, is not this one
    expect(await TranscriptFiles.read(video, key, 'other+vad'), isNull);
    expect(
      await TranscriptFiles.read(
        video,
        SubtitleCacheKey.bilibili(1),
        recogniser,
      ),
      isNull,
    );
  });

  test('nothing is written for an entry with no transcript', () async {
    expect(
      await TranscriptFiles.write(SubtitleCacheEntry(key, recogniser), video),
      isFalse,
    );
    expect(File(TranscriptFiles.srtPath(video)).existsSync(), isFalse);
  });

  test('files covering more are not replaced by less', () async {
    await TranscriptFiles.write(entryUpTo(300), video);
    expect(await TranscriptFiles.write(entryUpTo(12), video), isFalse);
    final read = await TranscriptFiles.read(video, key, recogniser);
    expect(read!.coveredSeconds, 300);
    expect(await TranscriptFiles.write(entryUpTo(400), video), isTrue);
  });

  test('the cache takes the entry from beside the video when it knows '
      'less, and only then', () async {
    final cache = SubtitleCache(
      Directory(path.join(root.path, 'cache')),
      limitBytes: () => 1 << 29,
    );
    expect(await cache.adopt(entryUpTo(300)), isTrue);
    expect((await cache.open(key, recogniser)).coveredSeconds, 300);
    expect(await cache.adopt(entryUpTo(12)), isFalse);
    expect((await cache.open(key, recogniser)).coveredSeconds, 300);
    await cache.flush();
    // kept on disk, for the next start
    final later = SubtitleCache(
      Directory(path.join(root.path, 'cache')),
      limitBytes: () => 1 << 29,
    );
    expect((await later.open(key, recogniser)).coveredSeconds, 300);
  });

  test('the cache tells of what it keeps', () async {
    final cache = SubtitleCache(
      Directory(path.join(root.path, 'cache')),
      limitBytes: () => 1 << 29,
    );
    final told = <String>[];
    SubtitleCache.onSaved = (e) => told.add(e.key.id);
    addTearDown(() => SubtitleCache.onSaved = null);
    await cache.save(entryUpTo(12));
    // an empty one is not kept, so not told of
    await cache.save(SubtitleCacheEntry(SubtitleCacheKey.youtube('x'), 'r'));
    expect(told, ['bili:221238811']);
  });
}
