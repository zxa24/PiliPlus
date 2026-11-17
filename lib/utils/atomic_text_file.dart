import 'dart:io';

/// LibrePili: [text] written to [file] whole or not at all (review 1 of the
/// YouTube extras, c3/l4): to `<file>.part`, flushed, then renamed over
/// [file]; the `.part` is removed when any of it fails, and the error goes
/// on. A reader never finds a half-written file under its real name: a
/// subtitle offered as a track, a JSON a page reads.
///
/// The rename is tried again a few times (about 1.5 s in all) while Windows
/// refuses it, as it does while another program has [file] open (the same
/// as the download record's save, download_platform_bili.dart).
Future<void> writeTextAtomic(File file, String text) async {
  final part = File('${file.path}.part');
  try {
    await part.writeAsString(text, flush: true);
    for (var wait = 50; ; wait *= 2) {
      try {
        await part.rename(file.path);
        return;
      } on FileSystemException {
        if (wait > 800) rethrow;
        await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
  } catch (_) {
    try {
      if (part.existsSync()) await part.delete();
    } catch (_) {}
    rethrow;
  }
}
