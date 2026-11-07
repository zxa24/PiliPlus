// LibrePili: the two failure statuses stage 2 adds (stage-2 plan §3.5,
// §4.1): a failure, not a download in progress, with the list's text. The
// queue passes over a failed entry (`nextDownload`) and the list shows it
// as stopped (`isDownloading` false), so a status that sorted in among the
// downloading ones (before `merging`) would be shown as running.
import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('failNoFormat and failQuality: failures, not downloading', () {
    for (final s in [DownloadStatus.failNoFormat, DownloadStatus.failQuality]) {
      expect(s.isDownloading, isFalse, reason: s.name);
      expect(s.isFailed, isTrue, reason: s.name);
    }
    expect(DownloadStatus.failNoFormat.message, '没有可合成为 mp4 的格式');
    expect(DownloadStatus.failQuality.message, '所选画质当前不可用');
  });

  test('the statuses before them keep what they were', () {
    // the downloading ones are the first five, as before
    expect(
      DownloadStatus.values.where((s) => s.isDownloading).map((s) => s.name),
      [
        'downloading',
        'audioDownloading',
        'getDanmaku',
        'getPlayUrl',
        'merging',
      ],
    );
    expect(
      DownloadStatus.values.where((s) => s.isFailed).map((s) => s.name),
      [
        'failDownload',
        'failDownloadAudio',
        'failPlayUrl',
        'failMerge',
        'failNoFormat',
        'failQuality',
      ],
    );
  });
}
