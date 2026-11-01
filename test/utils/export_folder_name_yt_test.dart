// LibrePili: an export named like a YouTube page folder (`yt_` + an
// 11-character video id) gets a suffix, as one named like a bilibili page
// folder does (stage-2 plan §3.2 `_internalPageName`; design §2.2): on the
// desktop exports share the download root with `yt_<id>`, and deleting the
// download would take an export of that name with it.
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('yt_ + 11 id characters: suffixed, in any case', () {
    for (final name in [
      'yt_dQw4w9WgXcQ',
      'YT_dQw4w9WgXcQ',
      'yt_jNQXAC9IVRw',
      'yt_a-b_c-d_e-f',
    ]) {
      final out = DownloadService.exportFolderName(name);
      expect(out, '$name (视频)', reason: name);
    }
  });

  test('other yt_ names are kept', () {
    for (final name in [
      'yt_dQw4w9WgXc',
      'yt_dQw4w9WgXcQx',
      'yt_dQw4w9WgXc!',
      'yt dQw4w9WgXcQ',
      'xyt_dQw4w9WgXcQ',
      'yt_dQw4w9WgXcQ (视频)',
    ]) {
      expect(DownloadService.exportFolderName(name), name, reason: name);
    }
  });

  test("bilibili's names as before", () {
    expect(DownloadService.exportFolderName('114514'), '114514 (视频)');
    expect(DownloadService.exportFolderName('s_1234'), 's_1234 (视频)');
    expect(
      DownloadService.exportFolderName('114514 [1080P 高清]'),
      '114514 [1080P 高清]',
    );
  });
}
