import 'dart:io';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/dialog/simple_dialog_option.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/progress_bar/video_progress_indicator.dart';
import 'package:PiliPlus/common/widgets/select_mask.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/models_new/download/download_entry.dart';
import 'package:PiliPlus/pages/common/multi_select/base.dart';
import 'package:PiliPlus/pages/download/delete_dialog.dart';
import 'package:PiliPlus/pages/download/downloading/view.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/download/download_transcripts.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class DetailItem extends StatelessWidget {
  const DetailItem({
    super.key,
    required this.entry,
    this.progress,
    required this.downloadService,
    this.onDelete,
    required this.showTitle,
    this.isCurr = false,
    //
    required this.controller,
    this.checked,
    this.onSelect,
  });

  final DownloadEntry entry;
  final ChangeNotifier? progress;
  final DownloadService downloadService;

  /// Gets whether the exported video folder is deleted too.
  final void Function(bool deleteExported)? onDelete;
  final bool showTitle;
  final bool isCurr;
  //
  final MultiSelectBase controller;
  final bool? checked;
  final ValueChanged<DownloadEntry>? onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final outline = theme.colorScheme.outline;
    // what the entry's platform does its own way (design §3.1)
    final platform = downloadService.platformOf(entry);
    final canDel = onDelete != null;
    final titles = platform.titleLines(entry, showTitle);
    final enableMultiSelect = controller.enableMultiSelect.value;
    // the video is complete, comments etc. are still being saved
    final savingExtras = downloadService.isSavingExtras(entry);
    void onLongPress() => canDel && !enableMultiSelect
        ? showDialog(
            context: context,
            builder: (context) => SimpleDialog(
              clipBehavior: Clip.hardEdge,
              contentPadding: const EdgeInsets.symmetric(vertical: 12),
              children: [
                DialogOption(
                  onPressed: () async {
                    Get.back();
                    final deleteExported = await showDeleteDownloadDialog(
                      context,
                      exportOption: entry.mergedPath != null,
                    );
                    if (deleteExported != null) onDelete!(deleteExported);
                  },
                  child: const Text('删除', style: TextStyle(fontSize: 14)),
                ),
                for (final item in platform.menu(entry))
                  DialogOption(
                    onPressed: () {
                      Get.back();
                      item.onTap();
                    },
                    child: Text(
                      item.label,
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
              ],
            ),
          )
        : null;

    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () async {
          if (!canDel) {
            Get.to(const DownloadingPage());
            return;
          }
          if (enableMultiSelect) {
            (onSelect ?? controller.onSelect).call(entry);
            return;
          }
          if (entry.isCompleted) {
            if (entry.mergedPath case final merged?
                when !File(merged).existsSync()) {
              SmartDialog.showToast('视频文件已被移动或删除，可删除此条后重新下载');
              return;
            }
            if (entry.mergedParts case final parts?) {
              // the segments could not be joined: playback covers part 1
              SmartDialog.showToast(
                '该视频分为${parts.length + 1}个文件保存，此处仅播放第1个',
              );
            }
            await platform.openOffline(entry);
            if (context.mounted) {
              Future.delayed(const Duration(milliseconds: 400), () {
                if (context.mounted) {
                  // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
                  progress?.notifyListeners();
                }
              });
            }
          } else {
            final curDownload = downloadService.curDownload.value;
            if (curDownload != null &&
                curDownload.key == entry.key &&
                curDownload.status.isDownloading) {
              downloadService.cancelDownload(
                isDelete: false,
                downloadNext: false,
              );
            } else {
              downloadService.startDownload(entry);
            }
          }
        },
        onLongPress: onLongPress,
        onSecondaryTap: PlatformUtils.isMobile ? null : onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: Style.safeSpace,
            vertical: 5,
          ),
          child: Row(
            spacing: 10,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  AspectRatio(
                    aspectRatio: Style.aspectRatio,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final (file: cover, :network) = platform.localCover(
                          entry,
                        );
                        final byWidth = platform.coverCacheWidth(entry);
                        final maxWidth = constraints.maxWidth;
                        final maxHeight = constraints.maxHeight;
                        int? cacheWidth, cacheHeight;
                        if (byWidth ?? false) {
                          cacheWidth = maxWidth.cacheSize(context);
                        } else {
                          cacheHeight = maxHeight.cacheSize(context);
                        }
                        return cover != null
                            ? ClipRRect(
                                borderRadius: Style.mdRadius,
                                child: Image.file(
                                  cover,
                                  width: maxWidth,
                                  height: maxHeight,
                                  fit: BoxFit.cover,
                                  cacheWidth: cacheWidth,
                                  cacheHeight: cacheHeight,
                                  colorBlendMode: NetworkImgLayer.reduce
                                      ? BlendMode.modulate
                                      : null,
                                  color: NetworkImgLayer.reduce
                                      ? NetworkImgLayer.reduceLuxColor
                                      : null,
                                ),
                              )
                            : NetworkImgLayer(
                                // none: a placeholder
                                src: network ?? '',
                                width: maxWidth,
                                height: maxHeight,
                                cacheWidth: byWidth,
                              );
                      },
                    ),
                  ),
                  if (entry.qualityLabel case final quality?)
                    PBadge(
                      text: quality,
                      right: 6.0,
                      top: 6.0,
                      type: PBadgeType.gray,
                    ),
                  if (progress != null)
                    ListenableBuilder(
                      listenable: progress!,
                      builder: (_, _) {
                        final watched = platform.progressOf(entry);
                        if (watched != null) {
                          final progress = watched.positionMs;
                          return Positioned(
                            left: 0,
                            right: 0,
                            bottom: 0,
                            child: Column(
                              crossAxisAlignment: .end,
                              children: [
                                Padding(
                                  padding: const .only(right: 6, bottom: 3),
                                  child: PBadge(
                                    isStack: false,
                                    text: watched.finished
                                        ? '已看完'
                                        : '${DurationUtils.formatDuration(
                                                progress ~/ 1000,
                                              )}/'
                                              '${DurationUtils.formatDuration(
                                                entry.totalTimeMilli ~/ 1000,
                                              )}',
                                    type: .gray,
                                  ),
                                ),
                                VideoProgressIndicator(
                                  color: theme.colorScheme.primary,
                                  backgroundColor:
                                      theme.colorScheme.secondaryContainer,
                                  progress: progress / entry.totalTimeMilli,
                                ),
                              ],
                            ),
                          );
                        }
                        return PBadge(
                          text: DurationUtils.formatDuration(
                            entry.totalTimeMilli ~/ 1000,
                          ),
                          right: 6.0,
                          bottom: 7.0,
                          type: PBadgeType.gray,
                        );
                      },
                    )
                  else if (entry.totalTimeMilli != 0)
                    PBadge(
                      text: DurationUtils.formatDuration(
                        entry.totalTimeMilli ~/ 1000,
                      ),
                      right: 6,
                      bottom: 7,
                      type: PBadgeType.gray,
                    ),
                  Positioned.fill(
                    child: selectMask(
                      theme.colorScheme,
                      checked ?? entry.checked,
                    ),
                  ),
                ],
              ),
              Expanded(
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Column(
                      spacing: 5,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          titles.first.text,
                          textAlign: TextAlign.start,
                          style: TextStyle(
                            fontSize: theme.textTheme.bodyMedium!.fontSize,
                            height: 1.42,
                            letterSpacing: 0.3,
                          ),
                          maxLines: titles.first.maxLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                        for (final line in titles.more)
                          Text(
                            line.text,
                            maxLines: line.maxLines,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.onSurfaceVariant,
                            ),
                          ),
                      ],
                    ),
                    if (entry.isCompleted && !savingExtras) ...[
                      Positioned(
                        left: 0,
                        bottom: 0,
                        child: Obx(
                          () => Text(
                            // segments kept apart: only the first part plays
                            '${entry.mergedParts != null ? '分${entry.mergedParts!.length + 1}段  ' : ''}'
                            '${CacheManager.formatSize(entry.totalBytes)}${entry.ownerName != null ? '  ${entry.ownerName}' : ''}'
                            '${transcriptLabel(downloadService.transcripts.stateOf(entry.key), pending: entry.transcriptPending, appOpenOnly: PlatformUtils.isMobile)}',
                            style: TextStyle(
                              fontSize: 12,
                              height: 1.6,
                              color: outline,
                            ),
                          ),
                        ),
                      ),
                      Positioned(
                        right: 0,
                        bottom: 0,
                        child: platform.actions(entry, theme.colorScheme),
                      ),
                    ] else
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: savingExtras
                            ? RepaintBoundary(
                                child: ListenableBuilder(
                                  listenable: entry.progress,
                                  builder: (_, _) => entryProgress(
                                    theme,
                                    entry,
                                    active:
                                        entry.status ==
                                        DownloadStatus.savingExtras,
                                  ),
                                ),
                              )
                            : isCurr
                            ? RepaintBoundary(
                                child: Obx(
                                  () {
                                    final curDownload =
                                        downloadService.curDownload.value;
                                    if (curDownload != null) {
                                      return entryProgress(
                                        theme,
                                        curDownload,
                                        active:
                                            curDownload.status !=
                                            DownloadStatus.pause,
                                      );
                                    }
                                    return entryProgress(theme, entry);
                                  },
                                ),
                              )
                            : entryProgress(theme, entry),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// One bar over every part of the download (danmaku, video, audio, the
  /// merge, comments / subtitles ...), see [DownloadProgress]; the label says
  /// which part is running, the bytes while the streams download.
  Widget entryProgress(
    ThemeData theme,
    DownloadEntry entry, {
    bool active = false,
  }) {
    final progress = entry.progress;
    final status = entry.status;
    final statusMsg = switch (status) {
      DownloadStatus.getDanmaku when progress.danmakuTotal > 1 =>
        '${status.message} ${progress.danmakuDone}/${progress.danmakuTotal}',
      DownloadStatus.savingExtras => progress.extrasLabel ?? status.message,
      _ => status.message,
    };
    final showBytes =
        progress.mediaReceived > 0 &&
        switch (status) {
          DownloadStatus.downloading ||
          DownloadStatus.audioDownloading ||
          DownloadStatus.pause ||
          DownloadStatus.wait ||
          DownloadStatus.failDownload ||
          DownloadStatus.failDownloadAudio => true,
          _ => false,
        };
    final percent = '${(progress.value * 100).floor()}%';
    return progressWidget(
      statusMsg: statusMsg,
      progressStr: showBytes
          ? '${CacheManager.formatSize(progress.mediaReceived)}/'
                '${CacheManager.formatSize(progress.mediaTotal)}  $percent'
          : progress.value > 0
          ? percent
          : '',
      progress: progress.value,
      color: active ? theme.colorScheme.primary : theme.colorScheme.outline,
      highlightColor: theme.highlightColor,
    );
  }

  Widget progressWidget({
    required String statusMsg,
    required String progressStr,
    required double progress,
    required Color color,
    required Color highlightColor,
  }) {
    return Column(
      spacing: 6,
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              statusMsg,
              style: TextStyle(
                fontSize: 12,
                height: 1,
                color: color,
              ),
            ),
            Text(
              progressStr,
              style: TextStyle(
                fontSize: 12,
                height: 1,
                color: color,
              ),
            ),
          ],
        ),
        LinearProgressIndicator(
          // ignore: deprecated_member_use
          year2023: true,
          minHeight: 2.5,
          borderRadius: Style.mdRadius,
          color: color,
          backgroundColor: highlightColor,
          value: progress,
        ),
      ],
    );
  }
}
