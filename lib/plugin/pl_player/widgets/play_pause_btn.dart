import 'dart:async';

import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';
import 'package:media_kit/media_kit.dart';

class PlayOrPauseButton extends StatefulWidget {
  final PlPlayerController plPlayerController;

  const PlayOrPauseButton({
    super.key,
    required this.plPlayerController,
  });

  @override
  PlayOrPauseButtonState createState() => PlayOrPauseButtonState();
}

class PlayOrPauseButtonState extends State<PlayOrPauseButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController controller;
  late StreamSubscription<bool> subscription;
  late Player player;

  /// A handover replaces the player instance: the icon follows the new one,
  /// or it froze on what the old one last said.
  late final Worker _epochWorker;

  @override
  void initState() {
    super.initState();
    player = widget.plPlayerController.videoPlayerController!;
    controller = AnimationController(
      vsync: this,
      value: player.state.playing ? 1 : 0,
      duration: const Duration(milliseconds: 200),
    );
    subscription = _listen();
    _epochWorker = ever(widget.plPlayerController.videoControllerEpoch, (_) {
      final next = widget.plPlayerController.videoPlayerController;
      if (!mounted || next == null || identical(next, player)) return;
      subscription.cancel();
      setState(() => player = next);
      controller.value = next.state.playing ? 1 : 0;
      subscription = _listen();
    });
  }

  StreamSubscription<bool> _listen() => player.stream.playing.listen((
    playing,
  ) {
    if (playing) {
      controller.forward();
    } else {
      controller.reverse();
    }
  });

  @override
  void dispose() {
    _epochWorker.dispose();
    subscription.cancel();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 42,
      height: 34,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.plPlayerController.onDoubleTapCenter,
        child: Center(
          child: AnimatedIcon(
            semanticLabel: player.state.playing ? '暂停' : '播放',
            progress: controller,
            icon: AnimatedIcons.play_pause,
            color: Colors.white,
            size: 20,
          ),
        ),
      ),
    );
  }
}
