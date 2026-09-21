import 'package:PiliPlus/common/widgets/button/icon_button.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/menu_row.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/theme_utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

mixin HeaderMixin<T extends StatefulWidget> on State<T> {
  PlPlayerController get plPlayerController;

  bool get isFullScreen => plPlayerController.isFullScreen.value;

  ThemeData? get theme {
    if (plPlayerController.darkVideoPage) {
      return ThemeUtils.darkTheme;
    }
    return null;
  }

  Future<void>? showBottomSheet(
    StatefulWidgetBuilder builder, {
    ValueGetter<EdgeInsets>? padding,
  }) {
    final theme = this.theme;
    return PageUtils.showVideoBottomSheet(
      context,
      maxWidth: 512,
      padding: padding,
      child: theme != null
          ? Theme(
              data: theme,
              child: StatefulBuilder(builder: builder),
            )
          : StatefulBuilder(builder: builder),
    );
  }

  Widget resetBtn(ThemeData theme, Object def, VoidCallback onPressed) {
    return iconButton(
      tooltip: '默认值: $def',
      icon: const Icon(Icons.refresh),
      onPressed: onPressed,
      iconColor: theme.colorScheme.outline,
      size: 24,
      iconSize: 24,
    );
  }

  double get subtitleFontScale => plPlayerController.subtitleFontScale;
  double get subtitleFontScaleFS => plPlayerController.subtitleFontScaleFS;
  int get subtitlePaddingH => plPlayerController.subtitlePaddingH;
  int get subtitlePaddingB => plPlayerController.subtitlePaddingB;
  double get subtitleBgOpacity => plPlayerController.subtitleBgOpacity;
  double get subtitleStrokeWidth => plPlayerController.subtitleStrokeWidth;
  int get subtitleFontWeight => plPlayerController.subtitleFontWeight;

  /// 字幕设置。LibrePili: it lives here rather than in the bilibili header so
  /// the YouTube player can open the very same panel — it only ever touches
  /// the player, never the bilibili page's data.
  void showSetSubtitle() {
    showBottomSheet(
      padding: () => isFullScreen ? const .only(bottom: 70) : .zero,
      (context, setState) {
        final theme = Theme.of(context);

        const EdgeInsets sliderPadding = .symmetric(vertical: 16);

        final sliderTheme = SliderThemeData(
          trackHeight: 10,
          padding: const .symmetric(horizontal: 6),
          trackShape: const MSliderTrackShape(),
          thumbColor: theme.colorScheme.primary,
          activeTrackColor: theme.colorScheme.primary,
          inactiveTrackColor: theme.colorScheme.onInverseSurface,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
        );

        void updateStrokeWidth(double val) {
          plPlayerController
            ..subtitleStrokeWidth = val
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateOpacity(double val) {
          plPlayerController
            ..subtitleBgOpacity = val.toPrecision(2)
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateBottomPadding(double val) {
          plPlayerController
            ..subtitlePaddingB = val.round()
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateHorizontalPadding(double val) {
          plPlayerController
            ..subtitlePaddingH = val.round()
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateFontScaleFS(double val) {
          plPlayerController
            ..subtitleFontScaleFS = val.toPrecision(2)
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateFontScale(double val) {
          plPlayerController
            ..subtitleFontScale = val.toPrecision(2)
            ..updateSubtitleStyle();
          setState(() {});
        }

        void updateFontWeight(double val) {
          plPlayerController
            ..subtitleFontWeight = val.toInt()
            ..updateSubtitleStyle();
          setState(() {});
        }

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SliderTheme(
                data: sliderTheme,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(
                      height: 45,
                      child: Center(child: Text('字幕设置', style: TextStyle(fontSize: 14))),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体大小 ${(subtitleFontScale * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '100.0%', () => updateFontScale(1.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: subtitleFontScale,
                        divisions: 200,
                        label:
                            '${(subtitleFontScale * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontScale,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '全屏字体大小 ${(subtitleFontScaleFS * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '150.0%', () => updateFontScaleFS(1.5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: subtitleFontScaleFS,
                        divisions: 200,
                        label:
                            '${(subtitleFontScaleFS * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontScaleFS,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('字体粗细 ${subtitleFontWeight + 1}（可能无法精确调节）'),
                        resetBtn(theme, 6, () => updateFontWeight(5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 8,
                        value: subtitleFontWeight.toDouble(),
                        divisions: 8,
                        label: '${subtitleFontWeight + 1}',
                        onChanged: updateFontWeight,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('描边粗细 $subtitleStrokeWidth'),
                        resetBtn(theme, 2.0, () => updateStrokeWidth(2.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 5,
                        value: subtitleStrokeWidth,
                        divisions: 10,
                        label: '$subtitleStrokeWidth',
                        onChanged: updateStrokeWidth,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('左右边距 $subtitlePaddingH'),
                        resetBtn(theme, 24, () => updateHorizontalPadding(24)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 100,
                        value: subtitlePaddingH.toDouble(),
                        divisions: 100,
                        label: '$subtitlePaddingH',
                        onChanged: updateHorizontalPadding,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('底部边距 $subtitlePaddingB'),
                        resetBtn(theme, 24, () => updateBottomPadding(24)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 200,
                        value: subtitlePaddingB.toDouble(),
                        divisions: 200,
                        label: '$subtitlePaddingB',
                        onChanged: updateBottomPadding,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '背景不透明度 ${(subtitleBgOpacity * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '67%', () => updateOpacity(0.67)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 1,
                        divisions: 100,
                        value: subtitleBgOpacity,
                        onChanged: updateOpacity,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    )?.whenComplete(plPlayerController.putSubtitleSettings);
  }
  /// 弹幕功能
  void showSetDanmaku({bool isLive = false}) {
    // 屏蔽类型
    const blockTypesList = [
      (value: 2, label: '滚动'),
      (value: 5, label: '顶部'),
      (value: 4, label: '底部'),
      (value: 6, label: '彩色'),
      (value: 7, label: '高级'),
    ];

    final danmakuController = plPlayerController.danmakuController;

    final isFullScreen = this.isFullScreen;

    // the panel's [DanmakuOptions.save] writes every option back on close,
    // so start from what the box holds now — a settings import / reset
    // since app start would otherwise be overwritten with the old values
    // (the opacity comes from the player controller, same story)
    DanmakuOptions.applyPrefs();
    plPlayerController.danmakuOpacity.value = Pref.danmakuOpacity;

    showBottomSheet(
      (context, setState) {
        final theme = Theme.of(context);

        void setOptions() => danmakuController?.updateOption(
          DanmakuOptions.get(
            notFullscreen: !isFullScreen,
            speed: plPlayerController.playbackSpeed,
          ),
        );

        const EdgeInsets sliderPadding = .symmetric(vertical: 16);

        final sliderTheme = SliderThemeData(
          trackHeight: 10,
          padding: const .symmetric(horizontal: 6),
          trackShape: const MSliderTrackShape(),
          thumbColor: theme.colorScheme.primary,
          activeTrackColor: theme.colorScheme.primary,
          inactiveTrackColor: theme.colorScheme.onInverseSurface,
          thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6.0),
        );

        void updateLineHeight(double val) {
          DanmakuOptions.danmakuLineHeight = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateDuration(double val) {
          DanmakuOptions.danmakuDuration = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateStaticDuration(double val) {
          DanmakuOptions.danmakuStaticDuration = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateFontSizeFS(double val) {
          DanmakuOptions.danmakuFontScaleFS = val.toPrecision(2);
          setState(() {});
          if (isFullScreen) {
            setOptions();
          }
        }

        void updateFontSize(double val) {
          DanmakuOptions.danmakuFontScale = val.toPrecision(2);
          setState(() {});
          if (!isFullScreen) {
            setOptions();
          }
        }

        void updateStrokeWidth(double val) {
          DanmakuOptions.danmakuStrokeWidth = val;
          setState(() {});
          setOptions();
        }

        void updateFontWeight(double val) {
          DanmakuOptions.danmakuFontWeight = val.toInt();
          setState(() {});
          setOptions();
        }

        void updateOpacity(double val) {
          plPlayerController.danmakuOpacity.value = val.toPrecision(2);
          setState(() {});
        }

        void updateShowArea(double val) {
          DanmakuOptions.danmakuShowArea = val.toPrecision(1);
          setState(() {});
          setOptions();
        }

        void updateDanmakuWeight(double val) {
          DanmakuOptions.danmakuWeight = val.toInt();
          setState(() {});
        }

        void onUpdateBlockType(int blockType, bool blocked) {
          if (blocked) {
            DanmakuOptions.blockTypes.remove(blockType);
          } else {
            DanmakuOptions.blockTypes.add(blockType);
          }
          DanmakuOptions.blockColorful = DanmakuOptions.blockTypes.contains(6);
          setState(() {});
          setOptions();
        }

        return Padding(
          padding: const EdgeInsets.all(12),
          child: Material(
            clipBehavior: Clip.hardEdge,
            color: theme.colorScheme.surface,
            borderRadius: const BorderRadius.all(Radius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: SliderTheme(
                data: sliderTheme,
                child: ListView(
                  padding: EdgeInsets.zero,
                  children: [
                    const SizedBox(
                      height: 45,
                      child: Center(
                        child: Text('弹幕设置', style: TextStyle(fontSize: 14)),
                      ),
                    ),
                    const SizedBox(height: 10),
                    if (!isLive) ...[
                      Row(
                        mainAxisAlignment: .spaceBetween,
                        children: [
                          Text('智能云屏蔽 ${DanmakuOptions.danmakuWeight} 级'),
                          TextButton(
                            style: TextButton.styleFrom(
                              padding: EdgeInsets.zero,
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                            onPressed: () => Get
                              ..back()
                              ..toNamed(
                                '/danmakuBlock',
                                arguments: plPlayerController,
                              ),
                            child: Text(
                              "屏蔽管理(${plPlayerController.filters.count})",
                            ),
                          ),
                        ],
                      ),
                      Padding(
                        padding: sliderPadding,
                        child: Slider(
                          min: 0,
                          max: 11,
                          value: DanmakuOptions.danmakuWeight.toDouble(),
                          divisions: 11,
                          label: DanmakuOptions.danmakuWeight.toString(),
                          onChanged: updateDanmakuWeight,
                        ),
                      ),
                    ],
                    const Text('按类型屏蔽'),
                    SingleChildScrollView(
                      scrollDirection: .horizontal,
                      padding: const .symmetric(vertical: 10),
                      child: Row(
                        spacing: 10,
                        children: blockTypesList.map(
                          (e) {
                            final blocked = DanmakuOptions.blockTypes.contains(
                              e.value,
                            );
                            return ActionRowLineItem(
                              onTap: () => onUpdateBlockType(e.value, blocked),
                              text: e.label,
                              selectStatus: blocked,
                            );
                          },
                        ).toList(),
                      ),
                    ),
                    const Text('其他'),
                    SingleChildScrollView(
                      scrollDirection: .horizontal,
                      padding: const .symmetric(vertical: 10),
                      child: Row(
                        spacing: 10,
                        children: [
                          ActionRowLineItem(
                            selectStatus: DanmakuOptions.danmakuMassiveMode,
                            onTap: () {
                              DanmakuOptions.danmakuMassiveMode =
                                  !DanmakuOptions.danmakuMassiveMode;
                              setState(() {});
                              setOptions();
                            },
                            text: '海量弹幕',
                          ),
                          ActionRowLineItem(
                            selectStatus: DanmakuOptions.danmakuStatic2Scroll,
                            onTap: () {
                              DanmakuOptions.danmakuStatic2Scroll =
                                  !DanmakuOptions.danmakuStatic2Scroll;
                              setState(() {});
                              setOptions();
                            },
                            text: '固定转滚动',
                          ),
                          ActionRowLineItem(
                            selectStatus: DanmakuOptions.danmakuFixedV,
                            onTap: () {
                              DanmakuOptions.danmakuFixedV =
                                  !DanmakuOptions.danmakuFixedV;
                              setState(() {});
                              setOptions();
                            },
                            text: '滚动弹幕固定速度',
                          ),
                        ],
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '显示区域 ${(DanmakuOptions.danmakuShowArea * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '50.0%', () => updateShowArea(0.5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.1,
                        max: 1,
                        value: DanmakuOptions.danmakuShowArea,
                        divisions: 9,
                        label: '${DanmakuOptions.danmakuShowArea * 100}%',
                        onChanged: updateShowArea,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '不透明度 ${(plPlayerController.danmakuOpacity * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '100.0%', () => updateOpacity(1.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 1,
                        value: plPlayerController.danmakuOpacity.value,
                        divisions: 100,
                        label:
                            '${(plPlayerController.danmakuOpacity * 100).toStringAsFixed(1)}%',
                        onChanged: updateOpacity,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体粗细 ${DanmakuOptions.danmakuFontWeight + 1}（可能无法精确调节）',
                        ),
                        resetBtn(theme, 6, () => updateFontWeight(5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 8,
                        value: DanmakuOptions.danmakuFontWeight.toDouble(),
                        divisions: 8,
                        label: '${DanmakuOptions.danmakuFontWeight + 1}',
                        onChanged: updateFontWeight,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('描边粗细 ${DanmakuOptions.danmakuStrokeWidth}'),
                        resetBtn(theme, 1.5, () => updateStrokeWidth(1.5)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0,
                        max: 5,
                        value: DanmakuOptions.danmakuStrokeWidth,
                        divisions: 10,
                        label: DanmakuOptions.danmakuStrokeWidth.toString(),
                        onChanged: updateStrokeWidth,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '字体大小 ${(DanmakuOptions.danmakuFontScale * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '100.0%', () => updateFontSize(1.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: DanmakuOptions.danmakuFontScale,
                        divisions: 200,
                        label:
                            '${(DanmakuOptions.danmakuFontScale * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontSize,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '全屏字体大小 ${(DanmakuOptions.danmakuFontScaleFS * 100).toStringAsFixed(1)}%',
                        ),
                        resetBtn(theme, '120.0%', () => updateFontSizeFS(1.2)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 0.5,
                        max: 2.5,
                        value: DanmakuOptions.danmakuFontScaleFS,
                        divisions: 200,
                        label:
                            '${(DanmakuOptions.danmakuFontScaleFS * 100).toStringAsFixed(1)}%',
                        onChanged: updateFontSizeFS,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('滚动弹幕时长 ${DanmakuOptions.danmakuDuration} 秒'),
                        resetBtn(theme, 7.0, () => updateDuration(7.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 1,
                        max: 50,
                        value: DanmakuOptions.danmakuDuration,
                        divisions: 49,
                        label: DanmakuOptions.danmakuDuration.toString(),
                        onChanged: updateDuration,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text(
                          '静态弹幕时长 ${DanmakuOptions.danmakuStaticDuration} 秒',
                        ),
                        resetBtn(theme, 4.0, () => updateStaticDuration(4.0)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 1,
                        max: 50,
                        value: DanmakuOptions.danmakuStaticDuration,
                        divisions: 49,
                        label: DanmakuOptions.danmakuStaticDuration.toString(),
                        onChanged: updateStaticDuration,
                      ),
                    ),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        Text('弹幕行高 ${DanmakuOptions.danmakuLineHeight}'),
                        resetBtn(theme, 1.6, () => updateLineHeight(1.6)),
                      ],
                    ),
                    Padding(
                      padding: sliderPadding,
                      child: Slider(
                        min: 1.0,
                        max: 3.0,
                        value: DanmakuOptions.danmakuLineHeight,
                        onChanged: updateLineHeight,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    )?.whenComplete(
      () => DanmakuOptions.save(plPlayerController.danmakuOpacity.value),
    );
  }
}

class MSliderTrackShape extends RoundedRectSliderTrackShape {
  const MSliderTrackShape();

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    SliderThemeData? sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    const double trackHeight = 3;
    final double trackLeft = offset.dx;
    final double trackTop =
        offset.dy + (parentBox.size.height - trackHeight) / 2;
    final double trackWidth = parentBox.size.width;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }
}
