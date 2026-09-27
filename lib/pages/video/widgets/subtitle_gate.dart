/// LibrePili: what the player area shows while a video waits for the
/// subtitles the switch makes on the device (research/subtitle-switch-
/// design-2026-09-26.md, 3A): the same spinner as any other loading — the
/// bilibili page used to be a silent black box here — and, once the wait
/// has gone on for a while, a way to watch without them for now. The
/// subtitles keep being made, and come in when they are ready.
library;

import 'package:material_ui/material_ui.dart';

/// How long the page waits for subtitles before offering to play without
/// them (the user's refinement of 3A).
const subtitleGateSkipAfter = Duration(seconds: 5);

class SubtitleGate extends StatelessWidget {
  const SubtitleGate({
    super.key,
    required this.skippable,
    required this.onSkip,
  });

  /// The wait has lasted [subtitleGateSkipAfter]: 先播放视频 is offered.
  final bool skippable;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: Colors.black,
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          const SizedBox(height: 12),
          const Text(
            '正在准备字幕…',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
          if (skippable) ...[
            const SizedBox(height: 12),
            FilledButton.tonal(
              onPressed: onSkip,
              child: const Text('先播放视频'),
            ),
          ],
        ],
      ),
    ),
  );
}
