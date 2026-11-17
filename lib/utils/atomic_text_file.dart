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
///
/// [replace] false: the name is reserved first, by creating [file] only if
/// none is there (`create(exclusive: true)`, review 4 P1); a [file] already
/// there, whoever made it and whenever, is left as it is (the `.part`
/// removed) and false is returned. Then the `.part` is renamed over the
/// empty reservation, which is ours. Cut off between the two, an empty
/// [file] is left: a caller that writes only where a file is absent takes
/// an empty one as absent and writes it with [replace] true.
Future<bool> writeTextAtomic(
  File file,
  String text, {
  bool replace = true,
}) async {
  final part = File('${file.path}.part');
  var reserved = false;
  try {
    await part.writeAsString(text, flush: true);
    for (var wait = 50; ; wait *= 2) {
      try {
        if (!replace && !reserved) {
          try {
            await file.create(exclusive: true);
            reserved = true;
          } on FileSystemException {
            // there already: kept
            await part.delete();
            return false;
          }
        }
        await part.rename(file.path);
        return true;
      } on FileSystemException {
        if (wait > 800) rethrow;
        await Future<void>.delayed(Duration(milliseconds: wait));
      }
    }
  } catch (_) {
    try {
      if (part.existsSync()) await part.delete();
    } catch (_) {}
    // our reservation, still empty: not left behind
    try {
      if (reserved && file.lengthSync() == 0) await file.delete();
    } catch (_) {}
    rethrow;
  }
}
