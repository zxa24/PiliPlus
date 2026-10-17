/// LibrePili: media_kit's [SubtitleView], with a little space between
/// Chinese and Latin letters or digits ([CjkAutospace]) when [autospace],
/// and CJK characters set [tracking] apart.
/// Every subtitle — bilibili's, the on-device transcript, a local file —
/// reaches the screen through here. Only how a line is drawn differs; the
/// state (the line shown, the padding, dragging) is media_kit's own.
library;

import 'dart:ui' show BoxHeightStyle, ImageFilter, clampDouble;

import 'package:PiliPlus/utils/cjk_autospace.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
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

  /// [style] with its background left to [LineBands].
  static TextStyle _unbacked(TextStyle style) => style.copyWith(
    backgroundColor: style.background == null ? const Color(0x00000000) : null,
    background: style.background == null
        ? null
        : (Paint()..color = const Color(0x00000000)),
  );

  // as SubtitleViewState.build, the text spaced
  @override
  Widget build(BuildContext context) {
    final config = widget.configuration;
    final line = subtitle.toString();
    final autospace = (widget as SpacedSubtitleView).autospace;
    // a pixel of the layer drawn at supersample times the resolution
    final pixel =
        1 /
        (MediaQuery.devicePixelRatioOf(context) *
            SpacedSubtitleView.supersample);
    Widget text(TextStyle given) {
      final band = given.backgroundColor ?? given.background?.color;
      final style = _whole(band == null ? given : _unbacked(given));
      final size = style.fontSize ?? 14;
      final drop =
          (SpacedSubtitleView.latinDrop * size / pixel).roundToDouble() *
          pixel /
          size;
      final paragraph = Text.rich(
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
      );
      return band == null
          ? paragraph
          : LineBands(color: band, child: paragraph);
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
      return fine(text(config.style));
    }

    return AnimatedContainer(
      margin: padding,
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

/// [color] behind each line of the text below as one band, as tall as the
/// line: a background in the text's style is a box behind each run of
/// text, and where two runs meet at a fraction of a pixel their soft edges
/// left a seam (user 2026-10-17: 「统一」).
class LineBands extends SingleChildRenderObjectWidget {
  const LineBands({super.key, required this.color, super.child});

  final Color color;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderLineBands(color);

  @override
  void updateRenderObject(BuildContext context, RenderObject renderObject) =>
      (renderObject as _RenderLineBands).color = color;
}

class _RenderLineBands extends RenderProxyBox {
  _RenderLineBands(this._color);

  Color _color;
  set color(Color value) {
    if (value == _color) return;
    _color = value;
    markNeedsPaint();
  }

  static RenderParagraph? _paragraph(RenderObject node) {
    if (node is RenderParagraph) return node;
    RenderParagraph? found;
    node.visitChildren((child) => found ??= _paragraph(child));
    return found;
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    if (child == null ? null : _paragraph(child!) case final text?) {
      final length = text.text.toPlainText().length;
      final bands = <Rect>[];
      for (final box in text.getBoxesForSelection(
        TextSelection(baseOffset: 0, extentOffset: length),
        boxHeightStyle: BoxHeightStyle.max,
      )) {
        final rect = box.toRect();
        final i = bands.indexWhere(
          (b) => rect.center.dy > b.top && rect.center.dy < b.bottom,
        );
        if (i < 0) {
          bands.add(rect);
        } else {
          bands[i] = bands[i].expandToInclude(rect);
        }
      }
      final transform = text.getTransformTo(this);
      final paint = Paint()..color = _color;
      for (final band in bands) {
        context.canvas.drawRect(
          MatrixUtils.transformRect(transform, band).shift(offset),
          paint,
        );
      }
    }
    super.paint(context, offset);
  }
}
