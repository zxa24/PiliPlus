// LibrePili: the key a bilibili download is known by (design feature-logs/
// download-platforms/design.md, §4 平台键), checked against the fields of its
// entry.json rather than through keyOf, which reads the same getter: a part
// by its page_data cid; a bangumi episode, and the official client's record,
// by its source cid. A key built from the wrong field (M14b: page_data only)
// gives a bangumi episode without page_data `bili:0`, and two of them share
// it.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

import 'download_test_support.dart';

/// [entry]'s cid in its entry.json under [field] (`page_data` or `source`).
int? cidIn(String root, String entry, String field) =>
    (readEntryJson(root, entry)[field] as Map?)?['cid'] as int?;

String keyOfFixture(String root, String entry) => fixtureEntry(root, entry).key;

void main() {
  test('the key: a part by its page_data cid, a bangumi episode by its '
      'source cid', () {
    expect(cidIn(recordFixtures, recordUgc, 'source'), isNull);
    expect(
      keyOfFixture(recordFixtures, recordUgc),
      'bili:${cidIn(recordFixtures, recordUgc, 'page_data')}',
    );

    expect(cidIn(recordFixtures, recordPgc, 'page_data'), isNull);
    expect(
      keyOfFixture(recordFixtures, recordPgc),
      'bili:${cidIn(recordFixtures, recordPgc, 'source')}',
    );

    // both: the source's cid, the episode's (page_data's is the page's)
    expect(cidIn(recordFixtures, recordOfficial, 'page_data'), isNotNull);
    expect(
      keyOfFixture(recordFixtures, recordOfficial),
      'bili:${cidIn(recordFixtures, recordOfficial, 'source')}',
    );
  });

  test('two entries never share a key', () {
    final entries = [
      for (final f in Directory(listFixtures).listSync(recursive: true))
        if (path.basename(f.path) == 'entry.json')
          path.relative(path.dirname(f.path), from: listFixtures),
    ];
    // P1 and P2 (one video), two episodes of a season, the official one
    expect(entries, hasLength(5));
    final keys = {for (final e in entries) e: keyOfFixture(listFixtures, e)};
    expect(keys.values.toSet(), hasLength(entries.length), reason: '$keys');
  });
}
