import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/custom_height_widget.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/scroll_physics.dart' show tabBarView;
import 'package:PiliPlus/models/common/platform_mode.dart';
import 'package:PiliPlus/pages/youtube/subscriptions/view.dart';
import 'package:PiliPlus/services/platform_service.dart';
import 'package:PiliPlus/pages/common/common_page.dart';
import 'package:PiliPlus/pages/home/controller.dart';
import 'package:PiliPlus/pages/main/controller.dart';
import 'package:PiliPlus/pages/mine/controller.dart';
import 'package:PiliPlus/utils/extension/get_ext.dart';
import 'package:PiliPlus/utils/extension/size_ext.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:get/get.dart';
import 'package:material_design_icons_flutter/material_design_icons_flutter.dart';
import 'package:material_ui/material_ui.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends CommonPageState<HomePage>
    with AutomaticKeepAliveClientMixin {
  late ColorScheme _colorScheme;
  final _homeController = Get.putOrFind(HomeController.new);
  final _mainController = Get.find<MainController>();

  @override
  bool get needsCorrection => _homeController.hideTopBar;

  @override
  bool get wantKeepAlive => true;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _colorScheme = ColorScheme.of(context);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    Widget tabBar;
    if (_homeController.tabs.length > 1) {
      tabBar = Padding(
        padding: const EdgeInsets.only(top: 4),
        child: SizedBox(
          height: 42,
          width: double.infinity,
          child: TabBar(
            controller: _homeController.tabController,
            tabs: _homeController.tabs.map((e) => Tab(text: e.label)).toList(),
            isScrollable: true,
            dividerColor: Colors.transparent,
            dividerHeight: 0,
            splashBorderRadius: Style.mdRadius,
            tabAlignment: TabAlignment.center,
            onTap: (_) {
              feedBack();
              if (!_homeController.tabController.indexIsChanging) {
                _homeController.animateToTop();
              }
            },
          ),
        ),
      );
      if (_homeController.hideTopBar &&
          _mainController.barHideType == .instant) {
        tabBar = Material(
          color: _colorScheme.surface,
          child: tabBar,
        );
      }
    } else {
      tabBar = const SizedBox(height: 6);
    }
    return Obx(() {
      // LibrePili: the home tab shows whichever platform is selected. In
      // `all` the bilibili tabs stay and YouTube is appended as one more,
      // because two recommendation feeds are not comparable and interleaving
      // them would be shuffling rather than merging.
      final mode = PlatformService.to.mode.value;
      if (mode == PlatformMode.youtube) {
        return Column(
          children: [
            if (!_mainController.useSideBar &&
                MediaQuery.sizeOf(context).isPortrait)
              customAppBar(),
            const Expanded(child: _YouTubeHome()),
          ],
        );
      }
      return Column(
        children: [
          if (!_mainController.useSideBar &&
              MediaQuery.sizeOf(context).isPortrait)
            customAppBar(),
          tabBar,
          Expanded(
            child: onBuild(
              tabBarView(
                controller: _homeController.tabController,
                children: _homeController.tabs.map((e) => e.page).toList(),
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget customAppBar() {
    const padding = EdgeInsets.fromLTRB(14, 6, 14, 0);
    final child = Row(
      children: [
        searchBar(),
        const SizedBox(width: 4),
        msgBadge(_mainController),
        const SizedBox(width: 8),
        platformSwitcher(
          colorScheme: _colorScheme,
          mainController: _mainController,
        ),
      ],
    );
    if (_homeController.hideTopBar) {
      if (_mainController.barOffset case final barOffset?) {
        return Obx(
          () {
            final offset = barOffset.value;
            return CustomHeightWidget(
              offset: Offset(0, -offset),
              height: Style.topBarHeight - offset,
              child: Padding(
                padding: padding,
                child: child,
              ),
            );
          },
        );
      }
      if (_homeController.showTopBar case final showTopBar?) {
        return Obx(() {
          final showSearchBar = showTopBar.value;
          return AnimatedOpacity(
            opacity: showSearchBar ? 1 : 0,
            duration: const Duration(milliseconds: 300),
            child: AnimatedContainer(
              curve: Curves.easeInOutCubicEmphasized,
              duration: const Duration(milliseconds: 500),
              height: showSearchBar ? Style.topBarHeight : 0,
              padding: padding,
              child: child,
            ),
          );
        });
      }
    }
    return Container(
      height: Style.topBarHeight,
      padding: padding,
      child: child,
    );
  }

  Widget searchBar() {
    const borderRadius = BorderRadius.all(Radius.circular(25));
    return Expanded(
      child: SizedBox(
        height: 44,
        child: Material(
          borderRadius: borderRadius,
          color: _colorScheme.onSecondaryContainer.withValues(alpha: 0.05),
          child: InkWell(
            borderRadius: borderRadius,
            splashColor: _colorScheme.primaryContainer.withValues(
              alpha: 0.3,
            ),
            // LibrePili: the same box searches whichever platform is showing
            onTap: () => openPlatformSearch(
              biliParameters: _homeController.enableSearchWord
                  ? {'hintText': _homeController.defaultSearch.value}
                  : null,
            ),
            child: Row(
              children: [
                const SizedBox(width: 14),
                Icon(
                  Icons.search_outlined,
                  color: _colorScheme.onSecondaryContainer,
                  semanticLabel: '搜索',
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Obx(
                    () => Text(
                      _homeController.defaultSearch.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: _colorScheme.outline),
                    ),
                  ),
                ),
                const SizedBox(width: 5),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// LibrePili: search whichever platform is showing.
///
/// There are three of these buttons — the home bar, the wide window's side
/// rail and 我的 — and two of them reached for bilibili's search page
/// directly, so switching to YouTube left the button next to the platform
/// switcher quietly doing the wrong thing.
void openPlatformSearch({Map<String, String>? biliParameters}) {
  switch (PlatformService.to.mode.value) {
    case PlatformMode.youtube:
      Get.toNamed('/ytSearch');
    case PlatformMode.bilibili:
      Get.toNamed('/search', parameters: biliParameters);
    case PlatformMode.all:
      // 全部 has no one search: results from two platforms are not
      // comparable, so this asks instead of picking one and not saying so.
      final context = Get.context;
      if (context == null) {
        Get.toNamed('/search', parameters: biliParameters);
        return;
      }
      showDialog<void>(
        context: context,
        builder: (context) => SimpleDialog(
          title: const Text('搜索'),
          children: [
            ListTile(
              leading: const Icon(MdiIcons.television),
              title: const Text('B 站'),
              onTap: () => Get
                ..back()
                ..toNamed('/search', parameters: biliParameters),
            ),
            ListTile(
              leading: const Icon(Icons.smart_display_outlined),
              title: const Text('YouTube'),
              onTap: () => Get
                ..back()
                ..toNamed('/ytSearch'),
            ),
          ],
        ),
      );
  }
}

/// LibrePili: the top-bar button switches platform.
///
/// It used to be the avatar / "点击登录" button. The way into 我的 is the
/// bottom navigation, and the menu keeps an entry for it; what belongs here
/// is the platform, because that is what decides everything else on screen.
Widget platformSwitcher({
  required ColorScheme colorScheme,
  required MainController mainController,
}) {
  final platform = PlatformService.to;
  return Semantics(
    label: '切换平台',
    child: Obx(() {
      final mode = platform.mode.value;
      return PopupMenuButton<Object>(
        tooltip: '切换平台',
        position: PopupMenuPosition.under,
        onSelected: (value) {
          if (value is PlatformMode) {
            platform.set(value);
          } else {
            mainController.toMinePage();
          }
        },
        itemBuilder: (context) => [
          for (final value in PlatformMode.values)
            PopupMenuItem(
              value: value,
              child: Row(
                children: [
                  Icon(
                    value == mode
                        ? Icons.radio_button_checked
                        : Icons.radio_button_unchecked,
                    size: 18,
                    color: colorScheme.primary,
                  ),
                  const SizedBox(width: 10),
                  Text(value.label),
                ],
              ),
            ),
          const PopupMenuDivider(),
          const PopupMenuItem(
            value: 'mine',
            child: Row(
              children: [
                Icon(Icons.person_outline, size: 18),
                SizedBox(width: 10),
                Text('我的'),
              ],
            ),
          ),
        ],
        child: SizedBox(
          width: 38,
          height: 38,
          child: Stack(
            clipBehavior: Clip.none,
            alignment: Alignment.center,
            children: [
              DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: colorScheme.onInverseSurface,
                ),
                child: SizedBox(
                  width: 38,
                  height: 38,
                  child: Icon(
                    switch (mode) {
                      PlatformMode.bilibili => MdiIcons.television,
                      PlatformMode.youtube => Icons.smart_display_outlined,
                      PlatformMode.all => Icons.apps,
                    },
                    size: 20,
                    color: colorScheme.primary,
                  ),
                ),
              ),
              // the incognito badge moves here with the button it replaces
              Positioned(
                right: -2,
                bottom: -2,
                child: Obx(
                  () => MineController.anonymity.value
                      ? IgnorePointer(
                          child: Container(
                            padding: const EdgeInsets.all(2),
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: colorScheme.secondaryContainer,
                            ),
                            child: Icon(
                              size: 12,
                              MdiIcons.incognito,
                              color: colorScheme.onSecondaryContainer,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          ),
        ),
      );
    }),
  );
}

Widget userAvatar({
  required ColorScheme colorScheme,
  required MainController mainController,
}) {
  return Semantics(
    label: "我的",
    child: Obx(
      () {
        if (mainController.accountService.isLogin.value) {
          return Stack(
            clipBehavior: .none,
            children: [
              NetworkImgLayer(
                type: .avatar,
                width: 34,
                height: 34,
                src: mainController.accountService.face.value,
              ),
              Positioned.fill(
                child: Material(
                  type: .transparency,
                  child: InkWell(
                    onTap: mainController.toMinePage,
                    splashColor: colorScheme.primaryContainer.withValues(
                      alpha: 0.3,
                    ),
                    customBorder: const CircleBorder(),
                  ),
                ),
              ),
              Positioned(
                right: -4,
                bottom: -4,
                child: Obx(
                  () => MineController.anonymity.value
                      ? IgnorePointer(
                          child: Container(
                            padding: const .all(2),
                            decoration: BoxDecoration(
                              shape: .circle,
                              color: colorScheme.secondaryContainer,
                            ),
                            child: Icon(
                              size: 14,
                              MdiIcons.incognito,
                              color: colorScheme.onSecondaryContainer,
                            ),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ],
          );
        }
        return SizedBox(
          width: 38,
          height: 38,
          child: IconButton(
            tooltip: '点击登录',
            style: IconButton.styleFrom(
              padding: .zero,
              backgroundColor: colorScheme.onInverseSurface,
            ),
            onPressed: mainController.toMinePage,
            icon: Icon(
              Icons.person_rounded,
              size: 22,
              color: colorScheme.primary,
            ),
          ),
        );
      },
    ),
  );
}

Widget msgBadge(MainController mainController) {
  return Obx(
    () {
      if (mainController.accountService.isLogin.value) {
        final count = mainController.msgUnReadCount.value;
        final isNumBadge = mainController.msgBadgeMode == .number;
        return IconButton(
          tooltip: '消息',
          onPressed: () {
            mainController
              ..clearUnreadMsg()
              ..lastCheckUnreadAt = DateTime.now().millisecondsSinceEpoch;
            Get.toNamed('/whisper');
          },
          icon: Badge(
            isLabelVisible:
                mainController.msgBadgeMode != .hidden && count != null,
            alignment: isNumBadge
                ? const Alignment(0.0, -0.85)
                : const Alignment(1.0, -0.85),
            label: isNumBadge && count != null ? Text(count) : null,
            child: const Icon(Icons.notifications_none),
          ),
        );
      }
      return const SizedBox.shrink();
    },
  );
}


/// LibrePili: the home tab in YouTube mode. Subscriptions, because that is
/// the only feed this platform has without an account — searching is the top
/// bar's job, the same box for whichever platform is showing.
class _YouTubeHome extends StatefulWidget {
  const _YouTubeHome();

  @override
  State<_YouTubeHome> createState() => _YouTubeHomeState();
}

class _YouTubeHomeState extends State<_YouTubeHome> {
  @override
  Widget build(BuildContext context) =>
      const YtSubscriptionsPage(showAppBar: false);
}
