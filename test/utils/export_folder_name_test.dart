import 'package:PiliPlus/services/download/download_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// Internal page folders in the download root (see _getDownloadEntryDir).
final _internal = RegExp(r'^(s_)?\d+$', caseSensitive: false);

void main() {
  group('DownloadService.exportFolderName', () {
    test('names shaped like internal page folders get a suffix', () {
      for (final name in ['114514', 's_1234', 'S_1234', '0']) {
        final out = DownloadService.exportFolderName(name);
        expect(out, isNot(name), reason: name);
        expect(_internal.hasMatch(out), isFalse, reason: name);
      }
    });

    test('ordinary titles are kept as they are', () {
      for (final name in [
        '114514 [1080P 高清]',
        'Title - P2 part',
        's_1234x',
        'av114514',
        '114514 (2)',
      ]) {
        expect(DownloadService.exportFolderName(name), name);
      }
    });

    test('the suffixed name and its numbered variants never look internal', () {
      final base = DownloadService.exportFolderName('114514');
      for (final n in [base, '$base (2)', '$base (13)']) {
        expect(_internal.hasMatch(n), isFalse, reason: n);
      }
    });
  });
}
