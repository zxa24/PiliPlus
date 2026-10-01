import 'dart:async';

import 'package:PiliPlus/services/debug_overlay.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: the lines of [DebugOverlay] over the player's bottom-left
/// corner, newest at the bottom. Nothing at all while 调试模式 is off.
class DebugOverlayView extends StatelessWidget {
  const DebugOverlayView({
    super.key,
    required this.controlsShown,
    required this.isFullScreen,
  });

  /// The player's bars: shown, the lines move up above the progress bar
  /// and the buttons instead of being drawn under them.
  final RxBool controlsShown;
  final bool isFullScreen;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: DebugOverlay.enabled,
    builder: (context, on, _) => on
        ? IgnorePointer(
            // never in the way of a tap, a drag or a double tap on the video
            child: Obx(
              () => AnimatedPadding(
                duration: const Duration(milliseconds: 200),
                curve: Curves.easeOut,
                padding: EdgeInsets.only(
                  left: 8,
                  right: 8,
                  top: 8,
                  // the bottom bar (progress bar and buttons) is about 80
                  // high, a little more fullscreen
                  bottom: controlsShown.value ? (isFullScreen ? 100 : 84) : 8,
                ),
                child: LayoutBuilder(
                  // at most half the player's width: the rest of the
                  // picture (and most of a centred subtitle) stays clear
                  builder: (context, box) => Align(
                    alignment: Alignment.bottomLeft,
                    child: ConstrainedBox(
                      constraints: BoxConstraints(maxWidth: box.maxWidth * 0.5),
                      child: const _Lines(),
                    ),
                  ),
                ),
              ),
            ),
          )
        : const SizedBox.shrink(),
  );
}

class _Lines extends StatefulWidget {
  const _Lines();

  @override
  State<_Lines> createState() => _LinesState();
}

class _LinesState extends State<_Lines> {
  /// A line starts fading this long before it goes.
  static const _fade = Duration(seconds: 1);

  static const _style = TextStyle(
    color: Colors.white,
    fontSize: 11,
    height: 1.3,
    fontFamily: 'monospace',
    // 'monospace' is a name Android knows; the desktops need one of theirs
    fontFamilyFallback: [
      'Consolas',
      'Menlo',
      'DejaVu Sans Mono',
      'Courier New',
    ],
  );

  /// Wakes the view when the next line starts fading or goes; set only
  /// while there are lines.
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    DebugOverlay.revision.addListener(_rebuild);
  }

  @override
  void dispose() {
    DebugOverlay.revision.removeListener(_rebuild);
    _timer?.cancel();
    super.dispose();
  }

  void _rebuild() {
    if (mounted) setState(() {});
  }

  void _wakeAt(DateTime now, List<DebugLine> lines) {
    _timer?.cancel();
    _timer = null;
    final model = DebugOverlay.model;
    DateTime? next;
    for (final line in lines) {
      final end = line.at.add(model.lifetime);
      final fade = end.subtract(_fade);
      final at = fade.isAfter(now) ? fade : end;
      if (next == null || at.isBefore(next)) next = at;
    }
    if (next == null) return;
    var wait = next.difference(now);
    if (wait < const Duration(milliseconds: 16)) {
      wait = const Duration(milliseconds: 16);
    }
    _timer = Timer(wait, _rebuild);
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final model = DebugOverlay.model..prune(now);
    final lines = model.lines;
    _wakeAt(now, lines);
    if (lines.isEmpty) return const SizedBox.shrink();
    final fadeAfter = model.lifetime - _fade;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final line in lines)
          AnimatedOpacity(
            key: ValueKey(line.id),
            opacity: now.difference(line.at) >= fadeAfter ? 0 : 1,
            duration: _fade,
            child: DecoratedBox(
              decoration: const BoxDecoration(color: Color(0x99000000)),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 4,
                  vertical: 1,
                ),
                child: Text(
                  line.text,
                  style: _style,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 调试模式 in the player's ⋮ menu: the same setting as in 设置 → 其它设置,
/// taking effect at once.
class DebugModeTile extends StatelessWidget {
  const DebugModeTile({super.key, required this.titleStyle});

  final TextStyle titleStyle;

  static void _set(bool value) {
    GStorage.setting.put(SettingBoxKey.debugMode, value);
    DebugOverlay.setEnabled(value);
  }

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: DebugOverlay.enabled,
    builder: (context, on, _) => ListTile(
      dense: true,
      onTap: () => _set(!on),
      leading: const Icon(Icons.bug_report_outlined, size: 20),
      title: Text('调试模式', style: titleStyle),
      trailing: Transform.scale(
        alignment: Alignment.centerRight,
        scale: 0.8,
        child: Switch(value: on, onChanged: _set),
      ),
    ),
  );
}
