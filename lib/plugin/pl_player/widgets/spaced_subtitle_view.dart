/// LibrePili: media_kit's [SubtitleView], with a little space between
/// Chinese and Latin letters or digits ([CjkAutospace]) when [autospace],
/// and CJK characters set [tracking] apart.
/// Every subtitle — bilibili's, the on-device transcript, a local file —
/// reaches the screen through here. Only how a line is drawn differs; the
/// state (the line shown, the padding, dragging) is media_kit's own.
library;

import 'dart:math' as math;
import 'dart:ui' show ImageFilter, clampDouble;

import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:flutter/material.dart';
import 'package:media_kit_video/media_kit_video.dart';

class SpacedSubtitleView extends SubtitleView {
  const SpacedSubtitleView({
    super.key,
    required super.controller,
    required super.configuration,
    super.enableDragSubtitle,
    super.onUpdatePadding,
    this.autospace = true,
  });

  final bool autospace;

  /// Between two CJK characters, in em (user 2026-10-17: 「cjk之间的调宽」,
  /// 0.08 picked from screenshots of 0.05 and 0.08). Self tests try others.
  static double tracking = 0.08;

  /// Latin letters and digits on a line with CJK, times the size (user
  /// 2026-10-17 picked 1.05 of 1, 1.05 and 1.1: capitals 0.80 of the CJK
  /// face). Self tests try others.
  static double latinScale = 1.05;

  /// How far below the baseline they sit, in em (user 2026-10-17:
  /// 「英文字母和数字底边应该在两个的之间」: halfway from where they were down to
  /// the bottom of the CJK face, measured at 20–50 px), to the nearest pixel
  /// of [supersample]: CJK and Latin glyphs are each put on whole pixels, so
  /// a drop in between would come out a pixel more or less from line to
  /// line (user: 「统一不漂移」).
  static double latinDrop = 0.065;

  /// Drawn at this many times the resolution, then scaled down (1: as is).
  /// At the size of a subtitle Impeller hints glyphs and puts them on whole
  /// pixels up and down; drawn larger, neither is felt (user 2026-10-17
  /// picked 2 of 1, 2, 4 and 8, phones too). Self tests try others.
  static double supersample = 2;

  /// The size subtitles are drawn at in an area [height] tall (logical px):
  /// 40 at 1080, as the square root of the height, within 14–64, times
  /// [scale] (the 字体大小 setting). Fixed, a subtitle filled a tenth of a
  /// small window and 1.6 % of a 4K screen; in proportion, it was unreadable
  /// small and huge full screen (user 2026-10-17, ③ of the size bench).
  static double sizeFor(double height, double scale) =>
      clampDouble(40 * math.sqrt(math.max(0, height) / 1080), 14, 64) * scale;

  /// How far up the area the box's lower edge sits, of its height: where
  /// the game the look was taken from has it (11.12 %, measured on its 4K
  /// frame).
  static const lift = 0.1112;

  /// The 底部边距 setting's default: at it, the box sits at [lift].
  static const paddingBase = 24.0;

  /// The subtitle's box, after a game's (user 2026-10-17, measured on its
  /// 4K frame, em = the glyph pitch): 0.33 em either side of the glyph
  /// cells, 0.08 em above and below lines 1.45 em high (1.61 em in all for
  /// one), corners 0.125 em, [tint] over the picture behind blurred by
  /// 0.4 em (detail there was 0.12 against 1.4-2.0 beside it).
  static Widget box({
    required double em,
    required Color tint,
    required Widget child,
  }) => ClipRRect(
    borderRadius: BorderRadius.circular(0.125 * em),
    child: BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 0.4 * em, sigmaY: 0.4 * em),
      child: ColoredBox(
        color: tint,
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 0.33 * em,
            vertical: 0.08 * em,
          ),
          child: child,
        ),
      ),
    ),
  );
  static FilterQuality supersampleQuality = FilterQuality.medium;
  static bool supersampleCascade = true;

  @override
  SubtitleViewState createState() => _SpacedSubtitleViewState();
}

class _SpacedSubtitleViewState extends SubtitleViewState {
  /// [style] with every line a whole number of pixels tall (held by a
  /// strut, whatever the fonts): SkParagraph rounds a line's height, and
  /// a lowered word — a WidgetSpan shorter than the line — is placed off by
  /// what was rounded away, up to half a pixel.
  static TextStyle _whole(TextStyle style) {
    final size = style.fontSize;
    final height = style.height;
    if (size == null || height == null) return style;
    return style.copyWith(height: (size * height).roundToDouble() / size);
  }

  /// [style] with its background left to the box (see [build]).
  static TextStyle _unbacked(TextStyle style) => style.copyWith(
    backgroundColor: style.background == null ? const Color(0x00000000) : null,
    background: style.background == null
        ? null
        : (Paint()..color = const Color(0x00000000)),
  );

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) => _build(
      context,
      constraints.maxHeight.isFinite
          ? constraints.maxHeight
          : MediaQuery.sizeOf(context).height,
    ),
  );

  // as SubtitleViewState.build, the text spaced, sized for an area [height]
  // tall and set on the box of [SpacedSubtitleView.box]
  Widget _build(BuildContext context, double height) {
    final config = widget.configuration;
    final line = subtitle.toString();
    final autospace = (widget as SpacedSubtitleView).autospace;
    // the 字体大小 setting is a factor of 16 (see subTitleStyle)
    final em = SpacedSubtitleView.sizeFor(
      height,
      (config.style.fontSize ?? 16) / 16,
    );
    // a pixel of the layer drawn at supersample times the resolution
    final pixel =
        1 /
        (MediaQuery.devicePixelRatioOf(context) *
            SpacedSubtitleView.supersample);
    Widget text(TextStyle given) {
      final style = _whole(_unbacked(given).copyWith(fontSize: em));
      final drop =
          (SpacedSubtitleView.latinDrop * em / pixel).roundToDouble() *
          pixel /
          em;
      return Text.rich(
        CjkAutospace.span(
          line,
          style,
          autospace: autospace,
          tracking: SpacedSubtitleView.tracking,
          latinScale: SpacedSubtitleView.latinScale,
          latinDrop: drop,
        ),
        style: style,
        strutStyle: style.height == null
            ? null
            : StrutStyle.fromTextStyle(style, forceStrutHeight: true),
        textAlign: config.textAlign,
        textScaler: TextScaler.noScaling,
        // the box as wide as the longest line, not the whole width
        textWidthBasis: TextWidthBasis.longestLine,
      );
    }

    // at k times the resolution into a layer, which is scaled back down:
    // glyphs are not then hinted and placed on whole pixels of the screen
    Widget fine(Widget child) {
      final k = SpacedSubtitleView.supersample;
      if (k == 1) return child;
      Widget down(double by, Widget child) => ImageFiltered(
        imageFilter: ImageFilter.matrix(
          Matrix4.diagonal3Values(1 / by, 1 / by, 1).storage,
          filterQuality: SpacedSubtitleView.supersampleQuality,
        ),
        child: child,
      );
      var out = Transform.scale(
        scale: k,
        alignment: Alignment.topLeft,
        child: child,
      ) as Widget;
      // halved a step at a time: linear sampling at half the size is the
      // mean of 2×2, while at a quarter it would take the middle 2×2 of
      // 4×4 only (a layer has no mipmaps)
      if (SpacedSubtitleView.supersampleCascade) {
        for (var s = k; s > 1; s /= 2) {
          out = down(2, out);
        }
        return out;
      }
      return down(k, out);
    }

    Widget subtitleView() {
      if (config.strokeStyle case final stroke?) {
        return fine(
          Stack(
            clipBehavior: Clip.none,
            children: [text(stroke), text(config.style)],
          ),
        );
      }
      final tint =
          config.style.backgroundColor ?? config.style.background?.color;
      if (tint == null || line.isEmpty) return fine(text(config.style));
      // the box outside the layer the text is drawn in: what it blurs is
      // the picture behind, which a layer of its own would not have
      return SpacedSubtitleView.box(
        em: em,
        tint: tint,
        child: fine(text(config.style)),
      );
    }

    // the box's lower edge [SpacedSubtitleView.lift] of the height up; the
    // 底部边距 setting moves it from there (its 24 is where it sits)
    final bottom = math.max(
      0.0,
      SpacedSubtitleView.lift * height +
          padding.bottom -
          SpacedSubtitleView.paddingBase,
    );
    return AnimatedContainer(
      margin: padding.copyWith(bottom: bottom),
      duration: duration,
      alignment: Alignment.bottomCenter,
      child: widget.enableDragSubtitle
          ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragUpdate: (details) {
                final bottom = clampDouble(
                  padding.bottom - details.delta.dy,
                  0,
                  200,
                );
                padding = padding.copyWith(bottom: bottom);
                setState(() {});
              },
              onVerticalDragEnd: (details) {
                widget.onUpdatePadding?.call(padding);
              },
              child: subtitleView(),
            )
          : subtitleView(),
    );
  }
}
