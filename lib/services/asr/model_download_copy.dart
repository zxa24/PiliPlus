/// LibrePili: what the model-download prompts say about the download
/// itself (research/subtitle-switch-design-2026-09-26.md, 9③).
///
/// The models are 0.2–2.8 GB. On Wi-Fi that is a wait; on a phone's mobile
/// data it can be a month's allowance, and the prompt says so before
/// anything is fetched.
library;

import 'package:PiliPlus/utils/cache_manager.dart';

/// The first line of a model-download prompt: [what] (the model's name, or
/// null) and [bytes], and — on [mobileData] — what that costs.
String modelDownloadNote({
  String? what,
  required int bytes,
  required bool mobileData,
}) {
  final size = CacheManager.formatSize(bytes);
  final named = what == null ? '共 $size' : '$what，共 $size';
  if (mobileData) {
    return '正在使用移动网络：$named，下载会消耗约 $size 流量，建议连上 Wi-Fi 再下载。'
        '只需下载一次，存在应用数据目录，可随时删除。';
  }
  return '$named，只需下载一次，存在应用数据目录，可随时删除。';
}
