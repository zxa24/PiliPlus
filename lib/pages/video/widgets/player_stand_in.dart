import 'dart:ui' as ui;

import 'package:PiliPlus/common/assets.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/utils/extension/num_ext.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: what stands where the picture will be while there is none —
/// the player not up yet, an episode or another video opening, 听视频 — in
/// place of a black area with nothing on it (user 2026-10-17: 「只要之前有
/// 画面就要显示不出现任何黑屏」; audit 2026-10-21). [picture], the frame last
/// seen when there is one, else the [cover].
class PlayerCover extends StatelessWidget {
  const PlayerCover({
    super.key,
    required this.cover,
    required this.width,
    required this.height,
    this.picture,
  });

  final String? cover;
  final double width;
  final double height;
  final ui.Image? picture;

  @override
  Widget build(BuildContext context) {
    if (picture case final picture?) {
      return RawImage(
        image: picture,
        width: width,
        height: height,
        fit: BoxFit.fill,
        filterQuality: FilterQuality.low,
      );
    }
    return NetworkImgLayer(
      type: .emote,
      quality: 60,
      src: cover,
      width: width,
      height: height,
      cacheWidth: true,
      getPlaceHolder: () => const SizedBox.shrink(),
    );
  }
}

/// The player's loading mark, as it shows over the video.
class PlayerLoadingMark extends StatelessWidget {
  const PlayerLoadingMark({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        gradient: RadialGradient(
          colors: [Colors.black26, Colors.transparent],
        ),
      ),
      child: Image.asset(
        Assets.buffering,
        height: 25,
        cacheHeight: 25.cacheSize(context),
        semanticLabel: '加载中',
        color: Colors.white,
      ),
    );
  }
}

/// An open that failed, with 重试 (the player's `dataStatus` error: it
/// used to be shown nowhere, and the area stayed black).
class PlayerLoadFailed extends StatelessWidget {
  const PlayerLoadFailed({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: const BoxDecoration(
        color: Color(0x88000000),
        borderRadius: BorderRadius.all(Radius.circular(8)),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              '视频加载失败',
              style: TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 6),
            TextButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh, size: 18, color: Colors.white),
              label: const Text(
                '重试',
                style: TextStyle(color: Colors.white),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
