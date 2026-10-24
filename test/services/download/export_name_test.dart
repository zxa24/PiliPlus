// LibrePili: the export's folder / file name (design feature-logs/
// download-platforms/design.md, AC1 长标题的导出名). Expected names are
// worked out by hand from the rules as the code has them: illegal
// characters to `_`, white space runs to one space, cut to 80 code points
// and trimmed, then ` [<quality>]`, then exportFolderName.
//
// The cut is by code point: a single code point outside the BMP (U+1F600,
// a surrogate pair in UTF-16) is kept or dropped whole. A ZWJ sequence
// (several code points) would be cut through; that is how the code is and
// stays for now, so no case here uses one.
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

import 'download_test_support.dart';

BiliDownloadEntryInfo ugcTitled(String title) => BiliDownloadEntryInfo.fromJson(
  {...readEntryJson(recordFixtures, recordUgc), 'title': title},
);

bool loneSurrogate(String s) => s.runes.any((r) => r >= 0xD800 && r <= 0xDFFF);

void main() {
  test('a long title is cut to 80 code points before the quality is '
      'added', () {
    // 95 code points; illegal characters, two spaces and a tab in it; the
    // emoji is the 80th once those are replaced and joined
    final title =
        '长标题/斜杠:冒号*星号?问号"引号<小于>大于|竖线  两个空格\t制表符'
        '${'字' * 43}😀之后还有十几个码点的尾巴文字';
    expect(title.runes.length, greaterThanOrEqualTo(90));
    final name = DownloadService.exportNameForTest(ugcTitled(title));
    expect(
      name,
      '长标题_斜杠_冒号_星号_问号_引号_小于_大于_竖线 两个空格_制表符'
      '${'字' * 43}😀 [1080P 高清]',
    );
    expect(name, endsWith(' [1080P 高清]'));
    expect(
      name.substring(0, name.length - ' [1080P 高清]'.length).runes.length,
      lessThanOrEqualTo(80),
    );
    expect(loneSurrogate(name), isFalse);
  });

  test('a short title keeps its part and the quality', () {
    expect(
      DownloadService.exportNameForTest(ugcTitled('短标题: A/B')),
      '短标题_ A_B - P1 第一部分 [1080P 高清]',
    );
    expect(
      DownloadService.exportNameForTest(
        fixtureEntry(recordFixtures, recordPgc),
      ),
      '夹具番剧 - 第1话 开端 [720P 准高清]',
    );
  });
}
