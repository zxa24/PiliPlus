/// LibrePili: a creator page's header card, and the parts it is made of.
///
/// The arrangement (banner, avatar overlapping it, the counts and the
/// follow button at the right, then the name, sign and extra lines; or, on
/// a wide window, avatar · text · actions in one row) and the type each
/// part is set in were bilibili's `UserInfoCard`. They are here so the
/// YouTube channel header is the same card rather than a lookalike: a
/// change to the banner height or the name's size now lands on both.
///
/// What each platform puts in the slots stays its own. bilibili's header
/// has a level badge, a vip label, a live medal, verification, charge and
/// guard rows, a ban notice; YouTube's has a handle, a description and a
/// link. Those are passed in, not shared — they are different facts.
library;

import 'package:PiliPlus/common/widgets/image_viewer/hero.dart';
import 'package:PiliPlus/common/widgets/selection_text.dart';
import 'package:PiliPlus/common/widgets/space/header_layout_widget.dart';
import 'package:PiliPlus/common/widgets/view_safe_area.dart';
import 'package:PiliPlus/models/common/image_preview_type.dart';
import 'package:PiliPlus/utils/extension/context_ext.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/extension/theme_ext.dart';
import 'package:PiliPlus/utils/image_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:cached_network_image_ce/cached_network_image.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:material_ui/material_ui.dart';

export 'package:PiliPlus/common/widgets/space/header_layout_widget.dart'
    show kAvatarSize, kHeaderHeight;

/// Narrower than this, the header is the portrait card; wider, one row.
const double kSpaceHeaderWideBreakpoint = 600;

/// The header card: the layout, with the platform's content in its slots.
class SpaceHeaderCard extends StatelessWidget {
  const SpaceHeaderCard({
    super.key,
    required this.banner,
    required this.avatar,
    required this.left,
    required this.actions,
    this.bottom,
  });

  /// The image across the top of the portrait card. Not shown wide.
  final Widget banner;
  final Widget avatar;

  /// The text column — name, sign, extra lines. A builder, because some of
  /// it lays out differently in the two arrangements.
  final List<Widget> Function(bool isPortrait) left;

  /// The counts and the follow button ([SpaceActions]).
  final Widget actions;

  /// A full-width strip under everything (bilibili's promotion bar).
  final Widget? bottom;

  @override
  Widget build(BuildContext context) {
    final width = context.width;
    final isPortrait = width < kSpaceHeaderWideBreakpoint;
    return ViewSafeArea(
      top: !isPortrait,
      child: isPortrait ? _portrait() : _wide(),
    );
  }

  Widget _portrait() => Column(
    mainAxisSize: .min,
    crossAxisAlignment: .start,
    children: [
      HeaderLayoutWidget(header: banner, avatar: avatar, actions: actions),
      const SizedBox(height: 5),
      ...left(true),
      ?bottom,
      const SizedBox(height: 5),
    ],
  );

  Widget _wide() => Column(
    mainAxisSize: .min,
    crossAxisAlignment: .start,
    children: [
      const SizedBox(height: kToolbarHeight),
      Row(
        children: [
          const SizedBox(width: 20),
          Padding(
            padding: .only(top: 10, bottom: bottom != null ? 0 : 10),
            child: avatar,
          ),
          const SizedBox(width: 10),
          Expanded(
            flex: 5,
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: .start,
              children: [
                const SizedBox(height: 10),
                ...left(false),
                const SizedBox(height: 5),
              ],
            ),
          ),
          Expanded(flex: 3, child: actions),
          const SizedBox(width: 20),
        ],
      ),
      ?bottom,
    ],
  );
}

/// The banner: full width, [kHeaderHeight] tall, tinted toward the surface
/// so the avatar and the text over its edge stay readable; tap to view.
class SpaceBanner extends StatelessWidget {
  const SpaceBanner({
    super.key,
    required this.url,
    this.fullCover,
    this.filter = true,
    this.alignment = .center,
  });

  /// Null or empty: an empty band of the same height, so the avatar sits
  /// where it always does.
  final String? url;

  /// The image the viewer opens, when it is not [url] itself.
  final String? fullCover;
  final bool filter;
  final Alignment alignment;

  @override
  Widget build(BuildContext context) {
    final url = this.url;
    if (url == null || url.isEmpty) {
      return const SizedBox(width: .infinity, height: kHeaderHeight);
    }
    final width = context.width;
    final isLight = ColorScheme.of(context).isLight;
    final img = fullCover ?? url;
    return GestureDetector(
      behavior: .opaque,
      onTap: () => PageUtils.imageView(imgList: [SourceModel(url: img)]),
      child: fromHero(
        tag: img,
        child: CachedNetworkImage(
          fit: .cover,
          alignment: alignment,
          height: kHeaderHeight,
          width: width,
          memCacheWidth: width.cacheSize(context),
          imageUrl: ImageUtils.thumbnailUrl(url),
          placeholder: (_, _) =>
              const SizedBox(width: .infinity, height: kHeaderHeight),
          color: filter
              ? isLight
                    ? const Color(0x5DFFFFFF)
                    : const Color(0x8D000000)
              : null,
          colorBlendMode: filter
              ? isLight
                    ? .lighten
                    : .darken
              : null,
          fadeInDuration: const Duration(milliseconds: 120),
          fadeOutDuration: const Duration(milliseconds: 120),
        ),
      ),
    );
  }
}

/// The 2px surface-coloured ring an avatar wears over the banner.
class SpaceAvatarRing extends StatelessWidget {
  const SpaceAvatarRing({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => DecoratedBox(
    decoration: BoxDecoration(
      border: .all(width: 2, color: ColorScheme.of(context).surface),
      shape: .circle,
    ),
    child: Padding(padding: const .all(2), child: child),
  );
}

/// One of the counts over the follow button: 粉丝 / 关注 / 获赞 on
/// bilibili, 订阅者 / 视频 on YouTube.
class SpaceCount {
  const SpaceCount({
    required this.value,
    required this.label,
    this.alignment = .center,
    this.onTap,
    this.detail,
  });

  /// Already formatted: bilibili formats a number, YouTube gives text.
  final String value;
  final String label;
  final Alignment alignment;
  final VoidCallback? onTap;

  /// What a long-press (secondary tap on desktop) shows, if anything.
  final String? detail;
}

/// The counts and the follow button: the right-hand column of the header.
class SpaceActions extends StatelessWidget {
  const SpaceActions({
    super.key,
    required this.counts,
    required this.follow,
    this.leading = const [],
  });

  final List<SpaceCount> counts;

  /// [SpaceFollowButton].
  final Widget follow;

  /// Buttons left of the follow button (bilibili's message button).
  final List<Widget> leading;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    return Column(
      spacing: 5,
      mainAxisSize: .min,
      children: [
        Row(
          children: counts
              .map((e) => Expanded(child: _count(scheme, e)))
              .expand((child) sync* {
                yield const SizedBox(
                  height: 15,
                  width: 1,
                  child: VerticalDivider(),
                );
                yield child;
              })
              .skip(1)
              .toList(),
        ),
        Row(
          spacing: 10,
          mainAxisSize: .min,
          children: [
            ...leading,
            Expanded(child: follow),
          ],
        ),
      ],
    );
  }

  static void _toast(String detail) =>
      SmartDialog.showToast(detail, alignment: const Alignment(0.0, -0.8));

  static Widget _count(ColorScheme scheme, SpaceCount count) {
    final detail = count.detail;
    return GestureDetector(
      behavior: .opaque,
      onTap: count.onTap,
      onLongPress: detail != null && PlatformUtils.isMobile
          ? () => _toast(detail)
          : null,
      onSecondaryTap: detail != null && PlatformUtils.isDesktop
          ? () => _toast(detail)
          : null,
      child: Align(
        alignment: count.alignment,
        widthFactor: 1.0,
        child: Column(
          mainAxisSize: .min,
          children: [
            Text(count.value, style: const TextStyle(fontSize: 14)),
            Text(
              count.label,
              style: TextStyle(
                height: 1.2,
                fontSize: 12,
                color: scheme.outline,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The follow button: tonal; greyed — `onInverseSurface` with outline text
/// — once followed.
class SpaceFollowButton extends StatelessWidget {
  const SpaceFollowButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.followed = false,
    this.icon,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool followed;

  /// A small icon before the label (blocked, grouped).
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.of(context);
    return FilledButton.tonal(
      onPressed: onPressed,
      style: ButtonStyle(
        padding: const WidgetStatePropertyAll(.zero),
        backgroundColor: followed
            ? WidgetStatePropertyAll(scheme.onInverseSurface)
            : null,
        tapTargetSize: .padded,
        visualDensity: const VisualDensity(vertical: -1.8),
      ),
      child: Text.rich(
        style: followed ? TextStyle(color: scheme.outline) : null,
        TextSpan(
          children: [
            if (icon case final icon?) ...[
              WidgetSpan(
                alignment: .middle,
                child: Icon(icon, size: 16, color: scheme.outline),
              ),
              const TextSpan(text: ' '),
            ],
            TextSpan(text: label),
          ],
        ),
      ),
    );
  }
}

/// The name line: 17pt bold, then whatever badges follow it.
class SpaceName extends StatelessWidget {
  const SpaceName({
    super.key,
    required this.name,
    this.color,
    this.onTap,
    this.trailing = const [],
  });

  final String name;
  final Color? color;
  final VoidCallback? onTap;
  final List<Widget> trailing;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const .only(left: 20, right: 20),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: .center,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Text(
            name,
            strutStyle: const StrutStyle(
              height: 1,
              leading: 0,
              fontSize: 17,
              fontWeight: .bold,
            ),
            style: TextStyle(
              height: 1,
              fontSize: 17,
              fontWeight: .bold,
              color: color,
            ),
          ),
        ),
        ...trailing,
      ],
    ),
  );
}

/// The sign / description: 14pt, selectable, blank-line runs collapsed.
class SpaceSign extends StatelessWidget {
  const SpaceSign(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const .only(left: 20, top: 6, right: 20),
    child: SelectionText(
      text.trim().replaceAll(RegExp(r'\n{2,}'), '\n'),
      style: const TextStyle(fontSize: 14),
    ),
  );
}

/// The small grey line under the sign (UID and tags; handle and link).
class SpaceExtraLine extends StatelessWidget {
  const SpaceExtraLine({super.key, required this.children});

  final List<Widget> children;

  /// The type an item of this line is set in; a link is `secondary`.
  static TextStyle style(ColorScheme scheme, {bool link = false}) => TextStyle(
    fontSize: 12,
    color: link ? scheme.secondary : scheme.outline,
  );

  @override
  Widget build(BuildContext context) => Padding(
    padding: const .only(left: 20, top: 6, right: 20),
    child: Wrap(
      spacing: 10,
      runSpacing: 8,
      crossAxisAlignment: .center,
      children: children,
    ),
  );
}
