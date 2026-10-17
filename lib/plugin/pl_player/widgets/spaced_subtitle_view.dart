/// LibrePili: media_kit's [SubtitleView], with a little space between
/// Chinese and Latin letters or digits ([CjkAutospace]) when [autospace],
/// and CJK characters set [tracking] apart.
/// Every subtitle — bilibili's, the on-device transcript, a local file —
/// reaches the screen through here. Only how a line is drawn differs; the
/// state (the line shown, the padding, dragging) is media_kit's own.
library;

import 'dart:ui' show clampDouble;

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
  /// 「移到基线和汉字字面下的中间」; the CJK face reaches 0.14 em below the
  /// baseline at w400).
  static double latinDrop = 0.07;

  @override
  SubtitleViewState createState() => _SpacedSubtitleViewState();
}

class _SpacedSubtitleViewState extends SubtitleViewState {
  // as SubtitleViewState.build, the text spaced
  @override
  Widget build(BuildContext context) {
    final config = widget.configuration;
    final line = subtitle.toString();
    final autospace = (widget as SpacedSubtitleView).autospace;
    Widget text(TextStyle style) => Text.rich(
      CjkAutospace.span(
        line,
        style,
        autospace: autospace,
        tracking: SpacedSubtitleView.tracking,
        latinScale: SpacedSubtitleView.latinScale,
        latinDrop: SpacedSubtitleView.latinDrop,
      ),
      style: style,
      textAlign: config.textAlign,
      textScaler: TextScaler.noScaling,
    );

    Widget subtitleView() {
      if (config.strokeStyle case final stroke?) {
        return Stack(
          clipBehavior: Clip.none,
          children: [text(stroke), text(config.style)],
        );
      }
      return text(config.style);
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
