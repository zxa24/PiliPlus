import 'package:PiliPlus/pages/common/watch_page/watch_page_source.dart';

/// The shell's part of R9 (design feature-logs/watch-page-shell/design.md
/// §3.1): the page's route callbacks handed on, in R9's order, to the
/// page's own handlers. The route subscription stays in the page's State
/// (RouteAwareMixin subscribes Get.routing.route in its initState); this is
/// no mixin. Each callback has this one path to onCovered / onUncovered: the
/// page's override only calls it.
abstract final class WatchPageRoute {
  /// a page was pushed over this one
  static void didPushNext(WatchPageSource page) => page.onCovered();

  /// the page over this one was popped
  static void didPopNext(WatchPageSource page) => page.onUncovered();

  /// this page left the route stack
  static void didPop(WatchPageSource page) => page.onPopped();
}
