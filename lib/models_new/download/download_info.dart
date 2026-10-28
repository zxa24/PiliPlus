import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart'
    show MultiSelectData;

class DownloadPageInfo with MultiSelectData {
  final String pageId;
  final String dirPath;
  final String title;
  String cover;
  int sortKey;
  final int? seasonType;
  final List<DownloadEntry> entries;

  DownloadPageInfo({
    required this.pageId,
    required this.dirPath,
    required this.title,
    required this.cover,
    required this.sortKey,
    this.seasonType,
    required this.entries,
  });
}
