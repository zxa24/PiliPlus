import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_layouts.dart';
import 'package:PiliPlus/pages/common/watch_page/watch_page_source.dart';
import 'package:PiliPlus/pages/video/widgets/player_focus.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart';
import 'package:PiliPlus/utils/self_test_probe.dart';
import 'package:material_ui/material_ui.dart';

/// The watch page's shell (design feature-logs/watch-page-shell/design.md
/// §3.1): picks the layout branch (R1), then the self-test probe scope,
/// PlayerFocus (R13) and the dark video page's Theme (R11). Moved from
/// lib/pages/video/view.dart's build (05b103a52 B:1433-1476).
///
/// Never const and never kept in a field (§3.1): the branch is picked again
/// each time the page's State builds (after its didChangeDependencies), and
/// a kept or const instance would let Flutter skip that build. Lookups go
/// through the page's context ([WatchPageSource.pageContext]), never this
/// one, so this element depends on nothing of its own.
class WatchPageShell extends StatelessWidget {
  // ignore: prefer_const_constructors_in_immutables
  WatchPageShell({super.key, required this.source});

  final WatchPageSource source;

  @override
  Widget build(BuildContext context) {
    final layouts = WatchPageLayouts(source);
    final player = source.sharedPlayer;
    final maxWidth = source.maxWidth;
    final maxHeight = source.maxHeight;
    final tag = source.pageTag;
    Widget child;
    if (player.isPipMode) {
      SelfTestProbe.firstLevel(tag, SelfTestProbe.pip);
      child = layouts.pip();
    } else if (!player.horizontalScreen) {
      SelfTestProbe.firstLevel(tag, SelfTestProbe.portrait);
      child = layouts.childWhenDisabled;
    } else if (maxWidth / maxHeight >= kScreenRatio) {
      SelfTestProbe.firstLevel(tag, SelfTestProbe.landscape);
      child = layouts.childWhenDisabledLandscape;
    } else if (maxWidth / Style.aspectRatio16x9 < 0.4 * maxHeight) {
      SelfTestProbe.firstLevel(tag, SelfTestProbe.portrait);
      child = layouts.childWhenDisabled;
    } else {
      SelfTestProbe.firstLevel(tag, SelfTestProbe.almostSquare);
      child = layouts.childWhenDisabledAlmostSquare;
    }
    // self-test (F0): the probe scope, the first thing under the choice
    if (SelfTestProbe.fsScope) {
      child = SelfTestFsScope(
        tag: tag,
        player: player,
        child: child,
      );
    }
    if (player.keyboardControl) {
      child = PlayerFocus(
        plPlayerController: player,
        introController: source.introController,
        onSendDanmaku: source.onSendDanmaku,
        canPlay: source.canPlay,
        onSkipSegment: source.onSkipSegment,
        onRefresh: source.onRefresh,
        child: child,
      );
    }
    return player.darkVideoPage
        ? Theme(data: source.theme, child: child)
        : child;
  }
}
