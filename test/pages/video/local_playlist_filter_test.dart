// LibrePili: the offline playlist of the `/videoV` page (bilibili's offline
// player) takes bilibili's complete downloads only, in each group's order,
// out of every group of the download page (design feature-logs/
// download-platforms/design.md, AC1 「/videoV 离线播放列表只收 B 站条目」).
// The groups of exactly one such download are the ones the page lists by
// their video (aidSet). Another platform's downloads open a page of their
// own and must not join it.
import 'package:PiliPlus/models_new/download/bili_download_entry_info.dart';
import 'package:PiliPlus/models_new/download/download_info.dart';
import 'package:PiliPlus/pages/video/introduction/local/controller.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../services/download/download_test_support.dart';

/// A complete download of a platform that is not bilibili.
class _Elsewhere extends DownloadEntry {
  _Elsewhere(this.sortKey);

  @override
  final int sortKey;

  @override
  bool isCompleted = true;

  @override
  String get platform => 'fake';

  @override
  DownloadKey get key => 'fake:$sortKey';

  @override
  String get groupId => 'fake_group';

  // the rest is not read by the playlist
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

DownloadPageInfo group(String id, List<DownloadEntry> entries) =>
    DownloadPageInfo(
      pageId: id,
      dirPath: id,
      title: id,
      cover: '',
      sortKey: 0,
      entries: entries,
    );

void main() {
  test('complete bilibili downloads only, by each group order; the groups '
      'of one of them', () {
    final p1 = fixtureEntry(listFixtures, fixtureP1);
    final p2 = fixtureEntry(listFixtures, fixtureP2);
    // the season: episode 1 complete, episode 2 still downloading
    final s1 = fixtureEntry(listFixtures, fixtureS);
    final s2 = fixtureEntry(listFixtures, 's_41001/733002')
      ..isCompleted = false;
    final official = fixtureEntry(listFixtures, fixtureOfficial);
    final elsewhere = [_Elsewhere(2), _Elsewhere(1)];
    final elsewhereAlone = _Elsewhere(3);

    final (:list, :aidSet) = LocalIntroController.offlinePlaylist([
      group(p1.pageId, [p2, p1]),
      group(elsewhere.first.groupId, elsewhere),
      group(s1.pageId, [s2, s1]),
      group('fake_alone', [elsewhereAlone]),
      group(official.pageId, [official]),
    ]);

    expect(list, hasLength(4));
    for (final (i, e) in [p1, p2, s1, official].indexed) {
      expect(identical(list[i], e), isTrue, reason: 'entry $i');
    }
    expect(aidSet, {s1.pageId, official.pageId});
    expect(aidSet.contains(elsewhere.first.groupId), isFalse);
    expect(aidSet.contains('fake_alone'), isFalse);
  });

  test('no groups: an empty list', () {
    final (:list, :aidSet) = LocalIntroController.offlinePlaylist(const []);
    expect(list, isEmpty);
    expect(aidSet, isEmpty);
  });
}
