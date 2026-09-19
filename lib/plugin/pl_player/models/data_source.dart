import 'package:PiliPlus/utils/path_utils.dart';
import 'package:path/path.dart' as path;

sealed class DataSource {
  final String videoSource;
  final String? audioSource;

  DataSource({
    required this.videoSource,
    required this.audioSource,
  });
}

class NetworkSource extends DataSource {
  NetworkSource({
    required super.videoSource,
    required super.audioSource,
  });
}

class FileSource extends DataSource {
  final String dir;
  final bool isMp4;

  /// When set, a single complete (merged) video file to play instead of the
  /// separate cached streams.
  final String? mergedPath;

  FileSource({
    required this.dir,
    required this.isMp4,
    required bool hasDashAudio,
    required String typeTag,
    this.mergedPath,
    // Android local player: a `content://` document, played as is
    String? uri,
  }) : super(
         videoSource:
             uri ??
             mergedPath ??
             path.join(
               dir,
               typeTag,
               isMp4 ? PathUtils.videoNameType1 : PathUtils.videoNameType2,
             ),
         audioSource:
             uri != null || mergedPath != null || isMp4 || !hasDashAudio
             ? null
             : path.join(dir, typeTag, PathUtils.audioNameType2),
       );
}
