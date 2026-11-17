// LibrePili: a subtitle file beside a local video (the plain-file page's
// `_loadLocalSubtitles`): an empty one is not offered as a track (review 4
// of the YouTube extras, P1: a write cut off between reserving the name and
// filling it leaves one; the next export fills it).
import 'dart:convert';
import 'dart:typed_data';

import 'package:PiliPlus/pages/video/controller.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('an empty subtitle file is no track; one with text is', () {
    expect(VideoDetailController.subtitleFileText(Uint8List(0)), isNull);
    expect(
      VideoDetailController.subtitleFileText(
        Uint8List.fromList(utf8.encode('1\n00:00:01,000 --> 00:00:02,000\nhi\n')),
      ),
      contains('hi'),
    );
  });
}
