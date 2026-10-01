/// LibrePili: the row over a creator's video list — 共N视频, 播放全部, and
/// the sort button at the right — floating, so it comes back as soon as the
/// list is scrolled up a little.
///
/// It was bilibili's `MemberVideo._buildHeader`; the YouTube 视频 / 直播
/// tabs and the playlist page show the same row from here, so its spacing
/// and type are one definition. What the sort *means* stays each
/// platform's: bilibili flips its order, YouTube steps through the chips
/// the channel offers (最新 / 最热门 / 最早).
library;

import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/sliver/sliver_floating_header.dart';
import 'package:material_ui/material_ui.dart';

class SpaceListHeader extends StatelessWidget {
  const SpaceListHeader({
    super.key,
    this.count,
    this.playAllLabel,
    this.onPlayAll,
    this.sortLabel,
    this.onSort,
  });

  /// '共935视频'. Absent when the platform does not say.
  final String? count;

  /// Shown when [onPlayAll] is set; '播放全部' by default.
  final String? playAllLabel;
  final VoidCallback? onPlayAll;

  /// Shown when [onSort] is set.
  final String? sortLabel;
  final VoidCallback? onSort;

  /// Whether there is anything to show at all.
  bool get isEmpty => count == null && onPlayAll == null && onSort == null;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = this.count;
    return SliverFloatingHeaderWidget(
      backgroundColor: theme.colorScheme.surface,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 2.5, 8, 2.5),
        child: Row(
          children: [
            if (count != null)
              Text(count, style: const TextStyle(fontSize: 13)),
            if (onPlayAll != null)
              Padding(
                padding: EdgeInsets.only(left: count != null ? 6 : 0),
                child: _button(
                  theme,
                  Icons.play_circle_outline_rounded,
                  playAllLabel ?? '播放全部',
                  onPlayAll,
                ),
              ),
            const Spacer(),
            if (onSort != null)
              _button(theme, Icons.sort, sortLabel ?? '', onSort),
          ],
        ),
      ),
    );
  }

  static Widget _button(
    ThemeData theme,
    IconData icon,
    String label,
    VoidCallback? onPressed,
  ) => TextButton.icon(
    style: Style.buttonStyle,
    onPressed: onPressed,
    icon: Icon(icon, size: 16, color: theme.colorScheme.secondary),
    label: Text(
      label,
      style: TextStyle(fontSize: 13, color: theme.colorScheme.secondary),
    ),
  );
}
