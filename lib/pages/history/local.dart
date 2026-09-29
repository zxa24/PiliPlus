import 'dart:async';

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/dialog/dialog.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/progress_bar/video_progress_indicator.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/services/local_history.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/grid.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

/// 「本机」: the watch history kept on this device ([LocalHistory]), bilibili
/// and YouTube in one list, with search, delete and 暂停记录.
///
/// Built like the local favourite folders (the store is read whole and
/// re-read when it changes) rather than on a paged list controller: there is
/// nothing to page, it is all on the device.
class LocalHistoryPage extends StatefulWidget {
  const LocalHistoryPage({super.key, this.switcher});

  /// The 本机 / B 站账号 tabs, when both are shown.
  final PreferredSizeWidget? switcher;

  @override
  State<LocalHistoryPage> createState() => _LocalHistoryPageState();
}

class _LocalHistoryPageState extends State<LocalHistoryPage> {
  List<LocalWatchEntry> _entries = LocalHistory.entries();
  bool _paused = LocalHistory.paused;
  String _query = '';
  final _gridDelegate = Grid.videoCardHDelegate();
  StreamSubscription? _sub;

  @override
  void initState() {
    super.initState();
    _sub = LocalHistory.watch().listen((_) {
      if (mounted) setState(() => _entries = LocalHistory.entries());
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  List<LocalWatchEntry> get _visible {
    final q = _query.toLowerCase();
    if (q.isEmpty) return _entries;
    return _entries
        .where(
          (e) =>
              e.title.toLowerCase().contains(q) ||
              (e.author?.toLowerCase().contains(q) ?? false) ||
              (e.lastPart?.title?.toLowerCase().contains(q) ?? false),
        )
        .toList();
  }

  Future<void> _togglePause() async {
    final pause = !_paused;
    await LocalHistory.setPaused(pause);
    setState(() => _paused = pause);
    SmartDialog.showToast(pause ? '已暂停本机记录' : '已恢复本机记录');
  }

  Future<void> _clear() async {
    final ok = await showConfirmDialog(
      context: context,
      title: const Text('清空本机观看记录？'),
      content: const Text('只清除本机保存的记录，不影响 B 站账号的历史'),
    );
    if (ok) {
      await LocalHistory.clear();
      SmartDialog.showToast('已清空本机观看记录');
    }
  }

  Future<void> _chooseMax() async {
    final current = LocalHistory.maxEntries;
    final value = await showDialog<int>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('保留条数'),
        children: [
          for (final n in LocalHistory.maxChoices)
            ListTile(
              title: Text('最近 $n 条'),
              trailing: n == current ? const Icon(Icons.check) : null,
              onTap: () => Navigator.of(context).pop(n),
            ),
        ],
      ),
    );
    if (value == null || value == current) return;
    if (value < LocalHistory.length) {
      if (!mounted) return;
      final ok = await showConfirmDialog(
        context: context,
        title: const Text('保留条数'),
        content: Text('现有 ${LocalHistory.length} 条，较早的将被删除'),
      );
      if (!ok) return;
    }
    await LocalHistory.setMaxEntries(value);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final list = _visible;
    return Scaffold(
      appBar: AppBar(
        title: const Text('观看记录'),
        bottom: widget.switcher,
        actions: [
          PopupMenuButton<int>(
            onSelected: (v) => switch (v) {
              0 => _togglePause(),
              1 => _chooseMax(),
              _ => _clear(),
            },
            itemBuilder: (_) => [
              PopupMenuItem(
                value: 0,
                child: Text(_paused ? '恢复本机记录' : '暂停本机记录'),
              ),
              PopupMenuItem(
                value: 1,
                child: Text('保留条数（${LocalHistory.maxEntries}）'),
              ),
              const PopupMenuItem(value: 2, child: Text('清空本机记录')),
            ],
          ),
          const SizedBox(width: 6),
        ],
      ),
      body: Column(
        children: [
          if (_paused) _pauseTip(theme.colorScheme),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
            child: TextField(
              onChanged: (v) => setState(() => _query = v.trim()),
              decoration: InputDecoration(
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 20),
                hintText: '搜索标题或 UP 主（${_entries.length}）',
                border: const OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(
            child: list.isEmpty
                ? Center(
                    child: Text(
                      _entries.isEmpty ? '还没有本机观看记录' : '没有匹配的记录',
                      style: TextStyle(color: theme.colorScheme.outline),
                    ),
                  )
                : GridView.builder(
                    padding: EdgeInsets.only(
                      bottom: MediaQuery.viewPaddingOf(context).bottom + 80,
                    ),
                    gridDelegate: _gridDelegate,
                    itemCount: list.length,
                    itemBuilder: (context, index) =>
                        LocalHistoryItem(entry: list[index]),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _pauseTip(ColorScheme theme) => Container(
    height: 38,
    color: theme.secondaryContainer.withValues(alpha: 0.8),
    padding: const EdgeInsets.only(left: 16, right: 6),
    child: Row(
      children: [
        Icon(Icons.info_outline, size: 18, color: theme.onSecondaryContainer),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            '本机记录已暂停',
            style: TextStyle(color: theme.onSecondaryContainer),
          ),
        ),
        TextButton(onPressed: _togglePause, child: const Text('点击恢复')),
      ],
    ),
  );
}

/// One line of the local history: cover with the progress of the part
/// watched last, title, that part, uploader, when, and the platform.
class LocalHistoryItem extends StatelessWidget {
  const LocalHistoryItem({super.key, required this.entry});

  final LocalWatchEntry entry;

  /// Opens the part watched last where it was left (from the start when it
  /// was watched to the end): the saved point is passed explicitly, so it is
  /// this device's and not the account's that decides.
  static void open(LocalWatchEntry entry) {
    final part = entry.lastPart;
    final progress = LocalHistory.resumePoint(entry.key, entry.last) ?? 0;
    if (entry.platform == LocalHistoryPlatform.yt) {
      if (entry.ytId case final id?) {
        Get.toNamed('/ytVideo', parameters: {'id': id});
      }
      return;
    }
    switch (entry.type) {
      case 'pgc':
        PageUtils.viewPgc(
          epId: part?.epId,
          seasonId: part?.epId == null ? entry.seasonId : null,
          progress: progress,
        );
      case 'pugv':
        PageUtils.viewPugv(
          epId: part?.epId,
          seasonId: part?.epId == null ? entry.seasonId : null,
          aid: entry.aid,
          progress: progress,
        );
      default:
        final cid = part?.cid;
        if (cid == null || (entry.aid == null && entry.bvid == null)) {
          SmartDialog.showToast('记录不完整，无法打开');
          return;
        }
        PageUtils.toVideoPage(
          aid: entry.aid,
          bvid: entry.bvid,
          cid: cid,
          cover: entry.cover,
          title: entry.title,
          progress: progress,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final part = entry.lastPart;
    final duration = part?.duration ?? 0;
    final progress = part?.progress ?? 0;
    final finished = part?.finished ?? false;
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        onTap: () => open(entry),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: Style.safeSpace,
                vertical: 5,
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  AspectRatio(
                    aspectRatio: Style.aspectRatio,
                    child: LayoutBuilder(
                      builder: (context, constraints) => Stack(
                        clipBehavior: Clip.none,
                        children: [
                          NetworkImgLayer(
                            src: entry.cover ?? '',
                            width: constraints.maxWidth,
                            height: constraints.maxHeight,
                          ),
                          PBadge(
                            text: finished
                                ? '已看完'
                                : duration > 0
                                ? '${DurationUtils.formatDuration(progress ~/ 1000)}/${DurationUtils.formatDuration(duration ~/ 1000)}'
                                : DurationUtils.formatDuration(
                                    progress ~/ 1000,
                                  ),
                            right: 6.0,
                            bottom: 8.0,
                            type: PBadgeType.gray,
                          ),
                          PBadge(
                            text: entry.platform.label,
                            top: 6.0,
                            right: 6.0,
                            type: entry.platform == LocalHistoryPlatform.yt
                                ? PBadgeType.error
                                : PBadgeType.primary,
                          ),
                          if (duration > 0 && progress > 0)
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 0,
                              child: VideoProgressIndicator(
                                color: theme.colorScheme.primary,
                                backgroundColor:
                                    theme.colorScheme.secondaryContainer,
                                progress: finished
                                    ? 1
                                    : (progress / duration).clamp(0.0, 1.0),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  _content(theme, part),
                ],
              ),
            ),
            Positioned(
              right: 12,
              bottom: 0,
              width: 29,
              height: 29,
              child: PopupMenuButton(
                padding: EdgeInsets.zero,
                tooltip: '功能菜单',
                icon: Icon(
                  Icons.more_vert_outlined,
                  color: theme.colorScheme.outline,
                  size: 18,
                ),
                position: PopupMenuPosition.under,
                itemBuilder: (_) => [
                  if (_uploaderRoute() case final open?)
                    PopupMenuItem(
                      onTap: open,
                      height: 38,
                      child: Row(
                        children: [
                          const Icon(MdiIcons.accountCircleOutline, size: 16),
                          const SizedBox(width: 6),
                          Text(
                            '访问：${entry.author}',
                            style: const TextStyle(fontSize: 13),
                          ),
                        ],
                      ),
                    ),
                  PopupMenuItem(
                    onTap: () => LocalHistory.remove(entry.key),
                    height: 38,
                    child: const Row(
                      children: [
                        Icon(Icons.close_outlined, size: 16),
                        SizedBox(width: 6),
                        Text('删除记录', style: TextStyle(fontSize: 13)),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  VoidCallback? _uploaderRoute() {
    if (entry.author?.isNotEmpty != true) return null;
    if (entry.platform == LocalHistoryPlatform.yt) {
      final channel = entry.channelId;
      if (channel == null || channel.isEmpty) return null;
      return () => Get.toNamed('/ytChannel', parameters: {'id': channel});
    }
    final mid = entry.mid;
    if (mid == null || mid == 0) return null;
    return () => Get.toNamed('/member?mid=$mid');
  }

  Widget _content(ThemeData theme, LocalWatchPart? part) {
    final subStyle = TextStyle(
      fontSize: theme.textTheme.labelMedium!.fontSize,
      color: theme.colorScheme.outline,
    );
    final partLabel = [
      if (part?.page case final page? when entry.parts.length > 1 || page > 1)
        'P$page',
      if (part?.title case final title? when title.isNotEmpty) title,
    ].join(' ');
    return Expanded(
      child: Column(
        spacing: 2,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.title.isEmpty ? (entry.bvid ?? entry.key) : entry.title,
            style: TextStyle(
              fontSize: theme.textTheme.bodyMedium!.fontSize,
              height: 1.42,
              letterSpacing: 0.3,
            ),
            maxLines: partLabel.isEmpty ? 2 : 1,
            overflow: TextOverflow.ellipsis,
          ),
          if (partLabel.isNotEmpty)
            Text(
              partLabel,
              style: TextStyle(fontSize: 13, color: theme.colorScheme.outline),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          const Spacer(),
          if (entry.author?.isNotEmpty == true)
            Text(
              entry.author!,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: subStyle,
            ),
          Text(
            DateFormatUtils.chatFormat(entry.time ~/ 1000, isHistory: true),
            style: subStyle,
          ),
        ],
      ),
    );
  }
}
