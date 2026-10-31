/// LibrePili: what the self-test reads of a watch page, and the window it
/// reads it in (feature-logs/watch-page-shell/design.md §5 「自测」,
/// 「自测窗口」, §6.1; the report shape is test/mutants/WP_REPORT_SHAPE.md).
///
/// Every reading names one page, by its tag (the bilibili page's
/// `heroTag`, the YouTube page's controller tag), and finds it through the
/// page-route table the pages fill ([SelfTestProbe.pages]), checked on
/// every read: the route is still in the root navigator's stack, its
/// subtree holds the page's element, and the bilibili page's route
/// arguments carry the tag. Never through the page's keys: picture in
/// picture builds no `childKey`, and a mutant takes a key away. A covered
/// page is still mounted, so a search of the whole tree would find the
/// page under it first.
///
/// Read only, and without a dependency: nothing here calls `X.of`,
/// `X.maybeOf` or `dependOn…` on an element of a page. A dependency made by
/// a reading would rebuild what it read whenever, say, the route's status
/// changes (u#11), and differently once S1 reorders the tree. Only
/// `visitAncestorElements`, `findAncestorStateOfType`,
/// `findAncestorWidgetOfExactType`,
/// `getElementForInheritedWidgetOfExactType`, `findRenderObject` and walks
/// down.
///
/// A value that cannot be read is `{"$unread": "<why>"}`: never null and
/// never a missing key, so a reading that silently found nothing cannot
/// read as the same on two sides. Rectangles are `[left, top, width,
/// height]` in the app's logical pixels, rounded to 0.5. S1 does not change
/// what any of this reads: the layout code moves, these readings do not.
library;

import 'dart:async' show Completer;
import 'dart:io' show Platform;

import 'package:PiliPlus/common/widgets/fractionally_sized_box.dart';
import 'package:PiliPlus/common/widgets/scaffold/bottom_sheet.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/common/publish/publish_route.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/reply/controller.dart';
import 'package:PiliPlus/pages/video/reply/local_reply_panel.dart';
import 'package:PiliPlus/pages/video/reply/view.dart' show VideoReplyPanel;
import 'package:PiliPlus/pages/video/view.dart' show VideoDetailPageV;
import 'package:PiliPlus/pages/youtube/comments/yt_comment_pane.dart'
    show YtCommentPane;
import 'package:PiliPlus/pages/youtube/video/controller.dart';
import 'package:PiliPlus/pages/youtube/video/view.dart' show YtVideoPage;
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/services/ctl/ctl_app.dart';
import 'package:PiliPlus/utils/self_test_probe.dart';
import 'package:PiliPlus/utils/self_test_window.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:extended_nested_scroll_view/extended_nested_scroll_view.dart';
import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart'
    show Tab, TabBar, TabBarView, TabController;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:window_manager/window_manager.dart';

/// A watch page as a reading found it, validated.
final class WpPage {
  WpPage._(this.tag, this.kind, this.route, this.element, this.subtree);

  final String tag;

  /// `bili` or `yt`.
  final String kind;
  final ModalRoute<dynamic> route;

  /// The page State's element, as the page recorded it.
  final Element element;

  /// The route's page content ([ModalRoute.subtreeContext]): what is under
  /// it is this page's, whatever key or branch built it.
  final Element subtree;

  /// Whether [e] is this page's: [subtree] is among its ancestors (the
  /// route's content is under its `_subtreeKey`, Flutter
  /// `widgets/routes.dart`).
  bool contains(Element e) => WpRead.within(e, subtree);
}

abstract final class WpRead {
  /// u#11's control: false = every reading answers `walksOff` without
  /// walking the tree, so a run with walks off and one with them on show
  /// whether the readings change what the pages rebuild
  /// (`--wp-walks off`).
  static bool walks = true;

  static Map<String, Object?> unread(String why) => {r'$unread': why};

  static bool isUnread(Object? value) =>
      value is Map && value.containsKey(r'$unread');

  /// Rounded to half a logical pixel (design §6.2).
  static double half(double value) => (value * 2).roundToDouble() / 2;

  static const _slotPrefix = 'watchPage.slot.';

  /// Whether [ancestor] is [e] or one of its ancestors.
  static bool within(Element e, Element ancestor) {
    if (identical(e, ancestor)) return true;
    var found = false;
    e.visitAncestorElements((a) {
      if (!identical(a, ancestor)) return true;
      found = true;
      return false;
    });
    return found;
  }

  /// Whether [e] lies under an [Offstage] that is off: laid out, not shown.
  static bool offstage(Element e) {
    var off = false;
    e.visitAncestorElements((a) {
      final widget = a.widget;
      if (widget is! Offstage || !widget.offstage) return true;
      off = true;
      return false;
    });
    return off;
  }

  /// [e]'s box in the app's logical pixels.
  static Object rect(Element? e) {
    if (e == null) return unread('noElement');
    final box = e.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) {
      return unread('noBox');
    }
    final origin = box.localToGlobal(Offset.zero);
    return [
      half(origin.dx),
      half(origin.dy),
      half(box.size.width),
      half(box.size.height),
    ];
  }

  // ------------------------------------------------------------ the page

  /// The page named [tag], or why it cannot be read. Checked on every
  /// read: a route popped or replaced, a page disposed, or two rows under
  /// one tag is no page.
  static ({WpPage? page, String? why}) find(String tag) {
    final rows = SelfTestProbe.pages[tag];
    if (rows == null || rows.isEmpty) {
      return (page: null, why: 'no row for "$tag" in the page table');
    }
    if (rows.length != 1) {
      return (page: null, why: '${rows.length} rows under "$tag"');
    }
    final row = rows.single;
    final route = row.route;
    if (route is! ModalRoute<dynamic>) {
      return (page: null, why: 'the recorded route is ${route.runtimeType}');
    }
    if (!Ctl.routes.stack.contains(route)) {
      return (page: null, why: 'its route is not in the root navigator');
    }
    final subtree = route.subtreeContext;
    if (subtree is! Element) {
      return (page: null, why: 'its route has no content');
    }
    final element = row.element;
    if (element is! Element || !element.mounted) {
      return (page: null, why: 'the page is no longer mounted');
    }
    if (!within(element, subtree)) {
      return (page: null, why: "the page is not under its route's content");
    }
    final String kind;
    switch (element.widget) {
      case VideoDetailPageV():
        kind = 'bili';
        final args = route.settings.arguments;
        if (args is! Map || args['heroTag'] != tag) {
          return (page: null, why: "the route's arguments name another page");
        }
      case YtVideoPage():
        kind = 'yt';
      case final other:
        return (page: null, why: 'a ${other.runtimeType}, not a watch page');
    }
    return (
      page: WpPage._(tag, kind, route, element, subtree),
      why: null,
    );
  }

  /// The tags of the mounted watch pages, sorted (for the report).
  static List<String> tags() => SelfTestProbe.pages.keys.toList()..sort();

  /// The tags in the order the pages were mounted (the page table keeps
  /// insertion order).
  static List<String> mountOrder() => SelfTestProbe.pages.keys.toList();

  /// Every reading of the page named [tag]. `measured` is true only when
  /// the page was found and checked. Something that is not there, or not
  /// shown, is a value (`none`, `offstage: true`); `$unread` is only for a
  /// reading that could not be taken.
  static Map<String, Object?> read(String tag) {
    final (:page, :why) = find(tag);
    const parts = [
      'window',
      'branch',
      'tabs',
      'lists',
      'slots',
      'sheet',
      'player',
    ];
    if (page == null) {
      return {
        'measured': false,
        'page': {'tag': tag, 'why': why},
        for (final p in parts) p: unread('pageRoute'),
      };
    }
    final stack = Ctl.routes.stack;
    final at = stack.indexOf(page.route);
    final info = {
      'tag': tag,
      'kind': page.kind,
      'route': page.route.settings.name ?? unread('noRouteName'),
      // covered: another route above it (a popup counts)
      'top': at == stack.length - 1,
      'above': [
        for (final r in stack.skip(at + 1))
          r.settings.name ?? '${r.runtimeType}',
      ],
    };
    if (!walks) {
      return {
        'measured': true,
        'walks': false,
        'page': info,
        for (final p in parts) p: unread('walksOff'),
      };
    }
    final scan = _Scan.of(page);
    return {
      'measured': true,
      'page': info,
      'window': _guard(() => pageWindow(page.subtree)),
      'branch': _guard(() => _branch(page, scan)),
      'tabs': _guard(() => [for (final t in scan.tabBars) _tabBar(t)]),
      'lists': _guard(() => _lists(page, scan)),
      'slots': _guard(() => _slots(page, scan)),
      'sheet': _guard(() => _sheet(page, scan)),
      'player': _guard(() => _player(page)),
    };
  }

  /// [read] for every mounted watch page, by tag.
  static Map<String, Object?> readAll() => {
    for (final tag in tags()) tag: read(tag),
  };

  static Object _guard(Object Function() read) {
    try {
      return read();
    } catch (e) {
      return unread('error: $e');
    }
  }

  // ------------------------------------------------------------ window

  /// The window as the app lays out in it: `logical` is the size of the
  /// [MediaQuery] the pages get (main.dart's builder, `uiScale` applied),
  /// read from the root navigator's element without depending on it; then
  /// the view's physical size and ratio.
  static Map<String, Object?> appWindow() {
    final view = WidgetsBinding.instance.platformDispatcher.implicitView;
    if (view == null) return unread('noView');
    final context = Get.key.currentContext;
    final media = context
        ?.getElementForInheritedWidgetOfExactType<MediaQuery>()
        ?.widget;
    return {
      'logical': media is MediaQuery
          ? [half(media.data.size.width), half(media.data.size.height)]
          : unread('noMediaQuery'),
      'physical': [view.physicalSize.width, view.physicalSize.height],
      'devicePixelRatio': view.devicePixelRatio,
      'uiScale': Pref.uiScale,
    };
  }

  /// The page's own [MediaQuery] (what `MediaQuery.sizeOf` would give the
  /// page), found without depending on it.
  static Object pageWindow(Element subtree) {
    final widget = subtree
        .getElementForInheritedWidgetOfExactType<MediaQuery>()
        ?.widget;
    if (widget is! MediaQuery) return unread('noMediaQuery');
    final size = widget.data.size;
    return {
      'logical': [half(size.width), half(size.height)],
      'padding': [
        half(widget.data.padding.left),
        half(widget.data.padding.top),
        half(widget.data.padding.right),
        half(widget.data.padding.bottom),
      ],
    };
  }

  /// Settled, by §6.2's rule: no `didChangeMetrics` for [quiet] on the wall
  /// clock, then a frame scheduled and [read] taken in its post-frame
  /// callback (a paused page with no animation may draw no frame of its
  /// own). Null when the metrics do not settle within [limit].
  static Future<T?> settled<T>(
    T Function() read, {
    Duration quiet = const Duration(seconds: 1),
    Duration limit = const Duration(seconds: 10),
  }) async {
    final watch = _MetricsWatch();
    WidgetsBinding.instance.addObserver(watch);
    final clock = Stopwatch()..start();
    try {
      while (watch.since.elapsed < quiet) {
        if (clock.elapsed > limit) return null;
        await Future.delayed(const Duration(milliseconds: 50));
      }
    } finally {
      WidgetsBinding.instance.removeObserver(watch);
    }
    final done = Completer<T>();
    WidgetsBinding.instance
      ..addPostFrameCallback((_) {
        try {
          done.complete(read());
        } catch (e, s) {
          done.completeError(e, s);
        }
      })
      ..scheduleFrame();
    return done.future;
  }

  /// The screen the window is on (runner 补充⑦): its name, resolution
  /// (physical) and DPI. Windows only.
  static Future<Object> display() async {
    if (!Platform.isWindows) return unread('notWindows');
    try {
      final view = WidgetsBinding.instance.platformDispatcher.implicitView!;
      final ratio = view.devicePixelRatio;
      final dpi = (ratio * 96).round();
      // the window's centre in physical pixels: getBounds divides by the
      // window's ratio
      final bounds = await windowManager.getBounds();
      final centre = bounds.center * ratio;
      String? name;
      Size? near;
      for (final d in await screenRetriever.getAllDisplays()) {
        final scale = (d.scaleFactor ?? 1).toDouble();
        final at = (d.visiblePosition ?? Offset.zero) * scale;
        final size = (d.visibleSize ?? d.size) * scale;
        if ((at & size).contains(centre)) {
          name = d.name;
          near = d.size * scale;
          break;
        }
      }
      // no screen under the window's centre: no guess at which it is
      if (name == null || near == null) {
        return unread('noScreenAtTheWindow');
      }
      // the exact resolution from the runner's own list: of this DPI, the
      // one closest to what screen_retriever reports (its size is rounded)
      String? resolution;
      var best = double.infinity;
      for (final m in await SelfTestWindow.monitors()) {
        if (m['dpi'] != dpi) continue;
        final w = (m['width'] as int).toDouble();
        final h = (m['height'] as int).toDouble();
        final off = (w - near.width).abs() + (h - near.height).abs();
        if (off < best) {
          best = off;
          resolution = '${w.round()}x${h.round()}';
        }
      }
      return {
        'name': name,
        'resolution': resolution ?? unread('noMonitorOfThisDpi'),
        'dpi': dpi,
      };
    } catch (e) {
      return unread('display: $e');
    }
  }

  // ------------------------------------------------------------ parts

  /// A box as a branch reads it: where it is and whether it is shown.
  static Map<String, Object?> _box(Element e, [Map<String, Object?>? more]) => {
    'rect': rect(e),
    'offstage': offstage(e),
    ...?more,
  };

  /// The player's box, found by structure on each page: the bilibili
  /// page's player-slot Stack, or in picture in picture (which builds the
  /// player alone, no slot Stack) the player itself, `plPlayer`'s pop
  /// scope; the YouTube page's player, the positioned layer over its page.
  static Object _playerBox(WpPage page, _Scan scan) => switch (page.kind) {
    'bili' when scan.slotStack != null => _box(scan.slotStack!, {
      'via': 'slotStack',
    }),
    'bili' when scan.biliPlayer != null => _box(scan.biliPlayer!, {
      'via': 'plPlayer',
    }),
    'yt' when scan.ytPlayer != null => _box(scan.ytPlayer!, {
      'via': 'ytPlayer',
    }),
    _ => unread('noPlayer'),
  };

  /// The tab area: the bilibili page's scaffold under the tabs (a shown
  /// one first), the YouTube page's column that holds its tab bar.
  static Object _tabArea(WpPage page, _Scan scan) {
    if (page.kind == 'bili') {
      final shown = scan.scaffolds.where((s) => !offstage(s)).firstOrNull;
      final any = shown ?? scan.scaffolds.firstOrNull;
      return any == null ? 'none' : _box(any);
    }
    final bar = scan.tabBars.where((b) => !scan.inSheet(b)).firstOrNull;
    if (bar == null) return 'none';
    Element? column;
    bar.visitAncestorElements((a) {
      if (a.widget is! Column) return true;
      column = a;
      return false;
    });
    return column == null ? 'none' : _box(column!);
  }

  /// The intro when it is a column of its own; in the tabs it is a tab
  /// (`inTabs`), not a column.
  static Object _intro(_Scan scan) {
    final e = scan.intro;
    if (e != null) return scan.introInTabs ? 'inTabs' : _box(e);
    // the YouTube page's narrow layout: its intro is the 简介 tab
    for (final l in scan.lists) {
      if (_tabOf(scan, l) == 'intro') return 'inTabs';
    }
    return 'none';
  }

  /// The role of the tab [l] is in, by the tab bar driven by the same
  /// controller as its tab view; `none` outside the tabs.
  static Object _tabOf(_Scan scan, _List l) {
    if (l.tabView case (final Element view, final int index)) {
      final viewCtr = (view.widget as TabBarView).controller;
      Element? bar;
      for (final b in scan.tabBars) {
        if (viewCtr != null &&
            identical((b.widget as TabBar).controller, viewCtr)) {
          bar = b;
          break;
        }
      }
      final texts = bar == null ? null : _tabTexts(bar);
      return texts != null && index < texts.length
          ? tabRole(texts[index])
          : 'index:$index';
    }
    return 'none';
  }

  static Object _branch(WpPage page, _Scan scan) {
    // the YouTube page records no decision points: none, a value
    final scalars = page.kind == 'bili'
        ? (SelfTestProbe.branches[page.tag]?.toJson() ??
              unread('noBranchRecorded'))
        : 'none';
    final player = _playerBox(page, scan);
    final tabArea = _tabArea(page, scan);
    final intro = _intro(scan);
    // the geometry the branch is read from: the shown boxes, left to
    // right, overlapping ones (more than a pixel across) in one column,
    // top to bottom inside it
    final shown = <String, List<double>>{
      for (final (key, part) in [
        ('player', player),
        ('intro', intro),
        ('tabArea', tabArea),
      ])
        if (part case {'rect': final List<double> r, 'offstage': false}) key: r,
    };
    final order = shown.keys.toList()
      ..sort((a, b) => shown[a]![0].compareTo(shown[b]![0]));
    final columns = <List<String>>[];
    double? right;
    for (final key in order) {
      final r = shown[key]!;
      if (right != null && r[0] < right - 1) {
        columns.last.add(key);
        right = right > r[0] + r[2] ? right : r[0] + r[2];
      } else {
        columns.add([key]);
        right = r[0] + r[2];
      }
    }
    for (final c in columns) {
      c.sort((a, b) => shown[a]![1].compareTo(shown[b]![1]));
    }
    final nested = scan.nested.isNotEmpty;
    final String label;
    if (isUnread(player)) {
      label = 'noPlayer';
    } else if (!shown.containsKey('player')) {
      label = 'playerHidden';
    } else if (nested) {
      label = 'portrait';
    } else if (columns.length >= 3) {
      label = 'threeColumn';
    } else if (columns.length == 2) {
      label = 'sideBySide';
    } else if (shown.length > 1) {
      label = 'stacked';
    } else {
      label = 'playerOnly';
    }
    return {
      'scalars': scalars,
      'geometry': {
        'label': label,
        'nested': nested,
        'columns': columns,
        'player': player,
        'intro': intro,
        'tabArea': tabArea,
        'tabBars': [
          for (final t in scan.tabBars)
            if (!scan.inSheet(t)) rect(t),
        ],
      },
    };
  }

  /// A tab's role, not its text (`评论 1234` changes with the count); a
  /// tab whose text cannot be read is no reading, not a role.
  static Object tabRole(String? text) => switch (text) {
    null => unread('noTabText'),
    '简介' => 'intro',
    '离线视频' => 'offlineIntro',
    '相关视频' => 'related',
    '播放列表' => 'playlist',
    final t when t.startsWith('评论') => 'reply',
    final t => 'text:$t',
  };

  static List<String?> _tabTexts(Element bar) {
    final texts = <String?>[];
    void visit(Element e) {
      if (e.widget case final Tab tab) {
        texts.add(switch (tab) {
          Tab(text: final t?) => t,
          Tab(child: Text(data: final t?)) => t,
          _ => null,
        });
        return;
      }
      e.visitChildren(visit);
    }

    bar.visitChildren(visit);
    return texts;
  }

  static Map<String, Object?> _tabBar(Element bar) {
    final texts = _tabTexts(bar);
    final controller = (bar.widget as TabBar).controller;
    return {
      // in the page, or in a sheet open over it (the episode panel's own
      // tabs): the page's come first and are what a check reads
      'in': _Scan._inSheet(bar) ? 'sheet' : 'page',
      'roles': [for (final t in texts) tabRole(t)],
      'texts': texts.map((t) => t ?? unread('noTabText')).toList(),
      'index': controller?.index ?? unread('noController'),
      'length': controller?.length ?? unread('noController'),
      'rect': rect(bar),
      'offstage': offstage(bar),
    };
  }

  static List<Object?> _lists(WpPage page, _Scan scan) {
    // the controllers known by name, by identity
    final named = <ScrollController, String>{};
    for (final e in scan.nested) {
      if (e case StatefulElement(
        state: final ExtendedNestedScrollViewState s,
      )) {
        try {
          named[s.outerController] = 'nested.outer';
          named[s.innerController] = 'nested.inner';
        } catch (_) {}
      }
    }
    if (page.kind == 'bili') {
      if (Get.isRegistered<VideoDetailController>(tag: page.tag)) {
        final ctr = Get.find<VideoDetailController>(tag: page.tag);
        if (ctr.introScrollCtr case final c?) named[c] = 'introScrollCtr';
      }
      if (Get.isRegistered<VideoReplyController>(tag: page.tag)) {
        named[Get.find<VideoReplyController>(tag: page.tag).scrollController] =
            'replyScrollCtr';
      }
    }
    return [for (final l in scan.lists) _list(page, scan, l, named)];
  }

  static Map<String, Object?> _list(
    WpPage page,
    _Scan scan,
    _List l,
    Map<ScrollController, String> named,
  ) {
    final controller = l.state.widget.controller;
    final name = controller == null
        ? 'none'
        : named[controller] ?? 'other:${controller.runtimeType}';
    final tab = _tabOf(scan, l);
    // by what it is in, by widget type: the comment panels and the intro
    // list (the same widget as a column of its own and as a tab); a list
    // inside one of them is that one's `.inner`
    final role = switch (name) {
      'nested.outer' => 'nestedOuter',
      _ when l.container != null =>
        l.depth == 0 ? l.container! : '${l.container}.inner',
      _ when l.tabBar => 'tabBar',
      _ when l.pageView => 'tabView',
      _ when tab is String && tab != 'none' => tab,
      // the YouTube page's wide layout: its intro, a list of its own under
      // the player, not in a tab
      _ when page.kind == 'yt' && l.slot == null && !l.inPlayer => 'intro',
      _ when l.slot != null => 'slot.${l.slot}',
      _ => 'other',
    };
    Object pixels = unread('noPosition'), max = unread('noPosition');
    Object physics = unread('noPosition');
    try {
      final p = l.state.position;
      pixels = p.hasPixels ? half(p.pixels) : unread('noPixels');
      max = p.hasContentDimensions
          ? half(p.maxScrollExtent)
          : unread('noContentDimensions');
      physics = [
        for (ScrollPhysics? s = p.physics; s != null; s = s.parent)
          '${s.runtimeType}',
      ];
    } catch (_) {}
    return {
      'role': role,
      'tab': tab,
      'controller': name,
      'axis': l.state.widget.axisDirection.name,
      'pixels': pixels,
      'max': max,
      'physics': physics,
      'viewport': rect(l.element),
      'offstage': offstage(l.element),
    };
  }

  /// The layers of the bilibili page's player-slot Stack, by the role keys
  /// ([SelfTestProbe.slotBlack]), a layer without one by its type; `none`
  /// where there is no slot Stack (picture in picture builds the player
  /// alone; the YouTube page has none).
  static Object _slots(WpPage page, _Scan scan) {
    final stack = scan.slotStack;
    if (page.kind != 'bili' || stack == null) return 'none';
    final roles = <String>[];
    stack.visitChildren((c) {
      final key = c.widget.key;
      roles.add(
        key is ValueKey<String> && key.value.startsWith(_slotPrefix)
            ? key.value.substring(_slotPrefix.length)
            : '?${c.widget.runtimeType}',
      );
    });
    return roles;
  }

  /// Where a bottom sheet is open: `page` (in this page, the bilibili
  /// page's own scaffold), `global` (the [PublishRoute] directly above this
  /// page's route, `PageUtils.showVideoBottomSheet`, read from that route:
  /// it is not under this one) or `none`. Read positively both ways, so
  /// that "opened globally" and "opened nowhere" do not read alike.
  static Map<String, Object?> _sheet(WpPage page, _Scan scan) {
    Map<String, Object?>? here;
    if (scan.sheet case final sheet?) {
      Element? body;
      void visit(Element e) {
        if (body != null) return;
        if (e.widget case KeyedSubtree(key: GlobalKey())) {
          e.visitChildren((c) => body ??= c);
          return;
        }
        e.visitChildren(visit);
      }

      sheet.visitChildren(visit);
      here = {
        'panel': body == null
            ? unread('noPanel')
            : '${body!.widget.runtimeType}',
        'rect': rect(body),
        'inScaffold':
            sheet.findAncestorWidgetOfExactType<MiniScaffold>() != null,
      };
    }
    Map<String, Object?>? global;
    final stack = Ctl.routes.stack;
    final at = stack.indexOf(page.route);
    if (at >= 0 && at + 1 < stack.length) {
      final above = stack[at + 1];
      if (above is PublishRoute) {
        final root = above.subtreeContext;
        Element? body;
        if (root is Element) {
          void visit(Element e) {
            if (body != null) return;
            if (e.widget is CustomFractionallySizedBox) {
              // its Padding, then the panel
              e.visitChildren((padding) {
                padding.visitChildren((c) => body ??= c);
              });
              return;
            }
            e.visitChildren(visit);
          }

          root.visitChildren(visit);
        }
        global = {
          'panel': body == null
              ? unread('noPanel')
              : '${body!.widget.runtimeType}',
          'rect': rect(body),
        };
      }
    }
    return {
      'host': here != null && global != null
          ? 'pageAndGlobal'
          : here != null
          ? 'page'
          : global != null
          ? 'global'
          : 'none',
      'page': here ?? 'none',
      'global': global ?? 'none',
    };
  }

  static Object _player(WpPage page) {
    final PlPlayerController player;
    if (page.kind == 'bili') {
      if (!Get.isRegistered<VideoDetailController>(tag: page.tag)) {
        return unread('noController');
      }
      player = Get.find<VideoDetailController>(
        tag: page.tag,
      ).plPlayerController;
    } else {
      if (!Get.isRegistered<YtVideoController>(tag: page.tag)) {
        return unread('noController');
      }
      player = Get.find<YtVideoController>(tag: page.tag).plPlayerController;
    }
    return {
      'isFullScreen': player.isFullScreen.value,
      'fsProcessing': player.fsProcessing,
      'pip': player.isPipMode,
    };
  }

  /// The bilibili page's tab controller, the one place the self-test reaches
  /// it (wp2#17): S1 moves it into the shell behind a forwarding getter,
  /// and the step that removes the getter changes this line only.
  static TabController tabsOf(VideoDetailController ctr) => ctr.tabCtr;
}

/// The wall-clock time since the last `didChangeMetrics` ([WpRead.settled]).
final class _MetricsWatch with WidgetsBindingObserver {
  final since = Stopwatch()..start();

  @override
  void didChangeMetrics() => since
    ..reset()
    ..start();
}

/// One scrollable of a page, and what it is in.
final class _List {
  _List(
    this.state,
    this.element, {
    required this.container,
    required this.depth,
    required this.tabBar,
    required this.slot,
    required this.inPlayer,
    required this.tabView,
    required this.pageView,
  });

  final ScrollableState state;
  final Element element;

  /// The nearest panel it is in, by widget type (`reply`, `intro`), and how
  /// many scrollables lie between (0: it is the panel's own list).
  final String? container;
  final int depth;

  /// A tab bar's own scroll view (a scrollable tab bar).
  final bool tabBar;

  /// The player-slot layer it is in (its role), if any.
  final String? slot;

  /// Inside the YouTube page's player.
  final bool inPlayer;

  /// The tab view and the index of the tab it is in, if any.
  final (Element, int)? tabView;

  /// A tab view's own page view.
  final bool pageView;
}

/// What a walk down the page carries to each element.
typedef _At = ({
  String? container,
  int depth,
  bool tabBar,
  String? slot,
  bool inPlayer,
  Element? view,
  (Element, int)? tab,
});

/// One walk down a page's content.
final class _Scan {
  _Scan._();

  /// The bilibili page's player-slot Stack (its layers keyed by role).
  Element? slotStack;

  /// The bilibili page's player itself (`plPlayer`'s pop scope): the one
  /// the page builds alone in picture in picture.
  Element? biliPlayer;

  /// The YouTube page's player layer (the [Positioned] over its page).
  Element? ytPlayer;

  /// The bilibili page's portrait branch builds one.
  final nested = <Element>[];
  final tabBars = <Element>[];
  final scaffolds = <Element>[];

  /// The intro: the bilibili page's list keyed
  /// `PageStorageKey(CommonIntroController)`, the YouTube page's intro
  /// list.
  Element? intro;

  /// The first bottom sheet open in the page.
  Element? sheet;
  final lists = <_List>[];

  /// The intro is in a tab (portrait, offline), not a column of its own.
  bool introInTabs = false;

  bool inSheet(Element e) => _inSheet(e);

  static bool _inSheet(Element e) {
    var found = false;
    e.visitAncestorElements((a) {
      if (a.widget is! BottomSheet_) return true;
      found = true;
      return false;
    });
    return found;
  }

  static String? _containerOf(Widget widget) {
    if (widget is VideoReplyPanel ||
        widget is LocalReplyPanel ||
        widget is YtCommentPane) {
      return 'reply';
    }
    if (widget.key case PageStorageKey(:final value)
        when value == CommonIntroController) {
      return 'intro';
    }
    return null;
  }

  static _Scan of(WpPage page) {
    final scan = _Scan._();
    final yt = page.kind == 'yt';
    void visit(Element e, _At at) {
      final widget = e.widget;
      var next = at;
      if (widget case KeyedSubtree(key: ValueKey<String>(:final value))
          when value.startsWith(WpRead._slotPrefix)) {
        next = (
          container: next.container,
          depth: next.depth,
          tabBar: next.tabBar,
          slot: value.substring(WpRead._slotPrefix.length),
          inPlayer: next.inPlayer,
          view: next.view,
          tab: next.tab,
        );
      }
      switch (widget) {
        case ExtendedNestedScrollView():
          scan.nested.add(e);
        case TabBar():
          scan.tabBars.add(e);
          next = (
            container: next.container,
            depth: next.depth,
            tabBar: true,
            slot: next.slot,
            inPlayer: next.inPlayer,
            view: next.view,
            tab: next.tab,
          );
        case MiniScaffold():
          scan.scaffolds.add(e);
        case BottomSheet_():
          scan.sheet ??= e;
        // plPlayer's pop scope: the one in the player layer, or (no slot
        // Stack: picture in picture) the page's first
        case PopScope()
            when !yt &&
                scan.biliPlayer == null &&
                (scan.slotStack == null || next.slot == 'player'):
          scan.biliPlayer = e;
        case Stack() when !yt && scan.slotStack == null && _isSlotStack(e):
          scan.slotStack = e;
        case Stack() when yt && scan.ytPlayer == null:
          // the page and, over it, the player: [Offstage(page), Positioned]
          final children = <Element>[];
          e.visitChildren(children.add);
          if (children
              case [
                Element(widget: Offstage()),
                final Element player,
              ]
              when player.widget is Positioned) {
            scan.ytPlayer = player;
            next = (
              container: next.container,
              depth: next.depth,
              tabBar: next.tabBar,
              slot: next.slot,
              inPlayer: false,
              view: next.view,
              tab: next.tab,
            );
          }
        case TabBarView():
          next = (
            container: next.container,
            depth: next.depth,
            tabBar: next.tabBar,
            slot: next.slot,
            inPlayer: next.inPlayer,
            view: e,
            tab: null,
          );
        default:
      }
      if (identical(e, scan.ytPlayer)) {
        next = (
          container: next.container,
          depth: next.depth,
          tabBar: next.tabBar,
          slot: next.slot,
          inPlayer: true,
          view: next.view,
          tab: next.tab,
        );
      }
      // a tab of the tab view above: its child widget, by identity
      if (next.view case final view? when next.tab == null) {
        final children = (view.widget as TabBarView).children;
        final i = children.indexWhere((c) => identical(c, widget));
        if (i >= 0) {
          next = (
            container: next.container,
            depth: next.depth,
            tabBar: next.tabBar,
            slot: next.slot,
            inPlayer: next.inPlayer,
            view: view,
            tab: (view, i),
          );
        }
      }
      if (_containerOf(widget) case final c?) {
        next = (
          container: c,
          depth: -1,
          tabBar: next.tabBar,
          slot: next.slot,
          inPlayer: next.inPlayer,
          view: next.view,
          tab: next.tab,
        );
        if (c == 'intro' && scan.intro == null) {
          scan
            ..intro = e
            ..introInTabs = next.view != null;
        }
      }
      if (e is StatefulElement && e.state is ScrollableState) {
        final state = e.state as ScrollableState;
        final depth = next.container == null ? 0 : next.depth + 1;
        final list = _List(
          state,
          e,
          container: next.container,
          depth: depth,
          tabBar: next.tabBar,
          slot: next.slot,
          inPlayer: next.inPlayer,
          tabView: next.tab,
          pageView:
              next.view != null &&
              next.tab == null &&
              !next.tabBar &&
              state.widget.axisDirection == AxisDirection.right,
        );
        scan.lists.add(list);
        // the YouTube page's wide intro: its list under the player, in no
        // tab and no panel
        if (yt &&
            scan.intro == null &&
            next.container == null &&
            next.view == null &&
            !next.inPlayer &&
            !next.tabBar) {
          scan.intro = e;
        }
        next = (
          container: next.container,
          depth: depth,
          tabBar: next.tabBar,
          slot: next.slot,
          inPlayer: next.inPlayer,
          view: next.view,
          tab: next.tab,
        );
      }
      e.visitChildren((c) => visit(c, next));
    }

    visit(page.subtree, (
      container: null,
      depth: 0,
      tabBar: false,
      slot: null,
      inPlayer: false,
      view: null,
      tab: null,
    ));
    return scan;
  }

  static bool _isSlotStack(Element stack) {
    var keyed = false;
    stack.visitChildren((c) {
      if (c.widget.key case ValueKey<String>(:final value)
          when value.startsWith(WpRead._slotPrefix)) {
        keyed = true;
      }
    });
    return keyed;
  }
}

/// `--window-size WxH [--monitor WxH@DPI]` for the watch-page checks: the
/// window's content (client area) set to a logical size as the app lays
/// out (`uiScale` applied), through the runner's channel, without raising
/// the window ([SelfTestWindow.setContentSize]). A size the window cannot
/// take is refused, not measured at another size.
abstract final class WpWindow {
  /// What was asked and what came out, or null with nothing asked. With
  /// `error` set the check must not measure. [arg] reads an option's value
  /// (the self-test's own `_arg`).
  static Future<Map<String, Object?>?> apply(
    String? Function(String name) arg,
  ) async {
    final sizeArg = arg('--window-size');
    final monitorArg = arg('--monitor');
    if (sizeArg == null && monitorArg == null) return null;
    final out = <String, Object?>{
      'requested': ?sizeArg,
      'monitor': ?monitorArg,
    };
    if (!Platform.isWindows) {
      return out..['error'] = '--window-size / --monitor: Windows only';
    }
    if (monitorArg != null) {
      final m = RegExp(r'^(\d+)x(\d+)@(\d+)$').firstMatch(monitorArg);
      if (m == null) {
        return out..['error'] = '--monitor takes WxH@DPI, not "$monitorArg"';
      }
      try {
        await SelfTestWindow.moveToMonitor(
          width: int.parse(m[1]!),
          height: int.parse(m[2]!),
          dpi: int.parse(m[3]!),
        );
      } catch (e) {
        return out..['error'] = '--monitor $monitorArg: $e';
      }
      // the move can change the DPI and Windows resizes the window: the
      // size is set once that has settled
      if (await WpRead.settled(() => true) == null) {
        return out
          ..['error'] = '--monitor $monitorArg: the window never settled';
      }
    }
    Size? size;
    if (sizeArg != null) {
      final m = RegExp(
        r'^(\d+(?:\.\d+)?)x(\d+(?:\.\d+)?)$',
      ).firstMatch(sizeArg);
      if (m == null) {
        return out..['error'] = '--window-size takes WxH, not "$sizeArg"';
      }
      size = Size(double.parse(m[1]!), double.parse(m[2]!));
      final ({int width, int height, int dpi}) got;
      try {
        got = await SelfTestWindow.setContentSize(size);
      } catch (e) {
        return out..['error'] = '--window-size $sizeArg: $e';
      }
      final scale = Pref.uiScale;
      int physical(double logical) => (logical * got.dpi / 96 * scale).round();
      out['content'] = {
        'width': got.width,
        'height': got.height,
        'dpi': got.dpi,
      };
      // the runner reads the client area back: what it could not reach
      // (a minimum size, a screen too small) is a refusal
      if ((got.width - physical(size.width)).abs() > 1 ||
          (got.height - physical(size.height)).abs() > 1) {
        return out
          ..['error'] =
              '--window-size $sizeArg: the content came out '
              '${got.width}x${got.height} px at ${got.dpi} dpi, not '
              '${physical(size.width)}x${physical(size.height)}';
      }
    }
    // and the app laid out at it: once the metrics have settled (§6.2),
    // the size of the MediaQuery the pages get, read after a frame
    final laid = await WpRead.settled(WpRead.appWindow);
    if (laid == null) {
      return out
        ..['error'] = 'the window never settled (metrics kept changing)';
    }
    out['laidOut'] = laid;
    if (size != null) {
      switch (laid['logical']) {
        case [final double w, final double h]:
          if ((w - size.width).abs() > 1 || (h - size.height).abs() > 1) {
            return out
              ..['error'] =
                  '--window-size $sizeArg: the app laid out at ${w}x$h';
          }
        case final other:
          return out
            ..['error'] =
                '--window-size $sizeArg: the laid-out size could not be read '
                '($other)';
      }
    }
    return out;
  }
}
