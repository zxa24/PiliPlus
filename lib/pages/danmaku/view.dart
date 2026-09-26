import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/pages/danmaku/controller.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_model.dart';
import 'package:PiliPlus/pages/danmaku/danmaku_seed.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/play_status.dart';
import 'package:PiliPlus/plugin/pl_player/utils/danmaku_options.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/scheduler.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// 传入播放器控制器，监听播放进度，加载对应弹幕
class PlDanmaku extends StatefulWidget {
  final int cid;
  final PlPlayerController playerController;
  final bool isPipMode;
  final bool isFullScreen;
  final bool isFileSource;
  final Size size;

  const PlDanmaku({
    super.key,
    required this.cid,
    required this.playerController,
    this.isPipMode = false,
    required this.isFullScreen,
    required this.isFileSource,
    required this.size,
  });

  /// LibrePili (self test): the danmaku stop while the player buffers.
  /// Off only for the reverse check of `--danmaku-probe`.
  static bool debugFollowBuffering = true;

  /// LibrePili (self test): the screen is refilled after a seek. Off only
  /// for the reverse check of `--danmaku-probe`.
  static bool debugRefill = true;

  /// LibrePili (self test): the last refill — how many danmaku were still
  /// on screen at its place, how many the renderer has taken so far, and
  /// the longest the handing over held up one position report (µs).
  static ({int alive, int placed, int micros})? debugLastRefill;

  @override
  State<PlDanmaku> createState() => _PlDanmakuState();

  bool get notFullscreen => !isFullScreen || isPipMode;
}

class _PlDanmakuState extends State<PlDanmaku> {
  PlPlayerController get playerController => widget.playerController;

  late final PlDanmakuController _plDanmakuController;
  DanmakuController<DanmakuExtra>? _controller;
  int latestAddedPosition = -1;

  StreamSubscription<bool>? _bufferingSub;

  @override
  void initState() {
    super.initState();
    _plDanmakuController = PlDanmakuController(
      widget.cid,
      playerController,
      widget.isFileSource,
    );
    if (playerController.enableShowDanmaku.value) {
      if (widget.isFileSource) {
        _plDanmakuController.initFileDmIfNeeded();
      } else {
        _plDanmakuController.queryDanmaku(
          DmUtils.calcSegment(playerController.positionInMilliseconds),
        );
      }
    }
    _seenResets = playerController.danmakuResets;
    _stale = playerController.isBuffering.value;
    _bufferingSub = playerController.isBuffering.listen(_onBuffering);
    playerController
      ..addStatusLister(playerListener)
      ..addPositionListener(videoPositionListen);
  }

  @override
  void didUpdateWidget(PlDanmaku oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.notFullscreen != widget.notFullscreen &&
        !DanmakuOptions.sameFontScale) {
      _controller?.updateOption(
        DanmakuOptions.get(
          notFullscreen: widget.notFullscreen,
          speed: playerController.playbackSpeed,
        ),
      );
    }
  }

  // ------------------------------------------------ LibrePili: following
  //
  // The renderer animates by the wall clock; the picture moves only while
  // mpv is actually playing. mpv reports "playing" while it waits for data
  // (`paused-for-cache`, or one track starved) and before the first frame,
  // so following the play state alone kept the danmaku going over a frozen
  // picture, and the gap grew with every stall. They follow `isBuffering`
  // as well: media_kit sets it when a file starts and clears it only once
  // mpv is playing for real (`core-idle`), and sets it again for a stall.

  /// Whether the danmaku should be moving now.
  bool get _shouldRun =>
      playerController.playerStatus.isPlaying &&
      !(PlDanmaku.debugFollowBuffering && playerController.isBuffering.value);

  /// A stall (or the wait for the first frame) has been seen since the
  /// danmaku were last in step: what is on screen is where it was when the
  /// picture stopped, not where the picture is.
  bool _stale = false;

  void _syncRunning() {
    final controller = _controller;
    if (controller == null) return;
    if (!_shouldRun) {
      controller.pause();
      return;
    }
    if (_stale) {
      // back in step from where the picture is (the next position), rather
      // than going on from where the danmaku stopped; a plain pause of the
      // player needs none of this, as both stopped together
      _stale = false;
      _refillPending = true;
      _emptyScreen();
    }
    controller.resume();
  }

  void _onBuffering(bool buffering) {
    if (!PlDanmaku.debugFollowBuffering) return;
    if (buffering) _stale = true;
    _syncRunning();
  }

  // 播放器状态监听
  void playerListener(PlayerStatus status) {
    _syncRunning();
  }

  // ------------------------------------------------ LibrePili: refilling
  //
  // The screen is emptied on a seek and on a new source (see
  // PlPlayerController._resetDanmaku), and the danmaku are handed over one
  // 100 ms bucket at a time as playback reaches it: so after a seek the
  // screen stayed empty until new ones came along, and everything that
  // should still have been crossing it at the new place was lost. Now the
  // screen is refilled with what is still on screen there (see
  // aliveDanmakuAt), each put where it would be by now.

  /// The screen is to be refilled from the next position that can be.
  bool _refillPending = true;

  /// [PlPlayerController.danmakuResets] as last seen.
  late int _seenResets;

  /// Where the last reset sent playback, while mpv still reports the place
  /// it left (see [PlPlayerController.danmakuResetTo]), and until when that
  /// is waited for.
  int? _awaitedPosition;
  DateTime? _awaitedUntil;

  /// The last position reported, for telling a jump from playback.
  int? _lastPosition;

  /// A refill waiting for the danmaku of its place to arrive gives up once
  /// playback is past everything it could have added.
  int? _refillGivesUpAt;

  /// Notes a reset, or a jump that did not come through one (mpv looping,
  /// or seeking by itself): either way the screen is refilled.
  void _noteMove(int position) {
    final resets = playerController.danmakuResets;
    if (resets != _seenResets) {
      _seenResets = resets;
      // emptied already: nothing of the old place is to come either
      _queue.clear();
      _placements.clear();
      _refillPending = true;
      _refillGivesUpAt = null;
      _awaitedPosition = playerController.danmakuResetTo?.inMilliseconds;
      _awaitedUntil = DateTime.now().add(const Duration(seconds: 5));
    }
    final last = _lastPosition;
    final jumped =
        last != null && (position < last - 1000 || position > last + 3000);
    if (jumped) {
      _refillPending = true;
      _refillGivesUpAt = null;
    }
    if (_awaitedPosition case final awaited?) {
      if (jumped ||
          (position - awaited).abs() <= 2000 ||
          DateTime.now().isAfter(_awaitedUntil!)) {
        _awaitedPosition = null;
      }
    }
    _lastPosition = position;
  }

  /// Empties the screen and puts back what is still on it at [position].
  /// False while the danmaku there have not arrived.
  bool _refill(int position) {
    final controller = _controller!;
    final option = controller.option;
    final speed = playerController.playbackSpeed;
    // the user's durations, as the renderer has them (ms of the wall clock:
    // divided by the speed), in ms of video
    final scrollLifetime = option.durationInMilliseconds * speed;
    final staticLifetime = option.staticDurationInMilliseconds * speed;
    final longest = scrollLifetime > staticLifetime
        ? scrollLifetime
        : staticLifetime;
    if (!_plDanmakuController.isLoaded(position - longest.ceil(), position)) {
      _refillGivesUpAt ??= position + longest.ceil();
      if (position < _refillGivesUpAt!) return false;
    }
    _refillPending = false;
    _refillGivesUpAt = null;
    _emptyScreen();
    latestAddedPosition = position - position % danmakuBucketMs;
    if (!PlDanmaku.debugRefill) {
      // as it was: only the bucket playback is in
      final current = _plDanmakuController.bucketAt(
        position ~/ danmakuBucketMs,
      );
      if (current != null) _addAll(current);
      return true;
    }
    final alive = aliveDanmakuAt(
      position,
      bucketAt: _plDanmakuController.bucketAt,
      scrollLifetime: scrollLifetime.round(),
      staticLifetime: staticLifetime.round(),
      minWeight: DanmakuOptions.danmakuWeight,
    );
    for (final (:elem, :elapsed) in alive) {
      _queue.add((elem: elem, shownAt: position - elapsed));
    }
    PlDanmaku.debugLastRefill = (alive: alive.length, placed: 0, micros: 0);
    _drain(position);
    return true;
  }

  /// Everything on screen goes, and so does what was still to come of a
  /// refill.
  void _emptyScreen() {
    _controller?.clear();
    _queue.clear();
    _placements.clear();
  }

  /// Danmaku to be handed to the renderer, oldest first, with when (ms of
  /// video) each appeared: what a refill found, and what playback reaches
  /// while that is still being handed over (so the order holds).
  ///
  /// Handed over a few milliseconds' worth per position report, not all at
  /// once: the renderer lays each one out as it is added, and a busy video
  /// has hundreds on screen (measured, debug build, massive mode: ~500 in
  /// 190-420 ms in one go, a visible freeze on every seek).
  final _queue = ListQueue<({DanmakuElem elem, int shownAt})>();

  void _drain(int position) {
    final controller = _controller!;
    final option = controller.option;
    final speed = playerController.playbackSpeed;
    final scrollLifetime = option.durationInMilliseconds * speed;
    final staticLifetime = option.staticDurationInMilliseconds * speed;
    final clock = Stopwatch()..start();
    var placed = 0;
    while (_queue.isNotEmpty && clock.elapsedMicroseconds < 6000) {
      final (:elem, :shownAt) = _queue.removeFirst();
      final elapsed = position - shownAt;
      final lifetime = switch (DmUtils.getPosition(elem.mode)) {
        DanmakuItemType.scroll => scrollLifetime,
        DanmakuItemType.top || DanmakuItemType.bottom => staticLifetime,
        DanmakuItemType.special => double.infinity,
      };
      // gone meanwhile
      if (elapsed >= lifetime) continue;
      if (_addAlive(
        controller,
        elem,
        elapsed < 0 ? 0 : elapsed,
        scrollLifetime,
        speed,
      )) {
        placed++;
      }
    }
    if (PlDanmaku.debugLastRefill case final last?) {
      PlDanmaku.debugLastRefill = (
        alive: last.alive,
        placed: last.placed + placed,
        micros: clock.elapsedMicroseconds > last.micros
            ? clock.elapsedMicroseconds
            : last.micros,
      );
    }
    if (_placements.isNotEmpty) _schedulePlacement();
  }

  /// Adds [elem], [elapsed] ms of video after it appeared.
  ///
  /// canvas_danmaku cannot start a danmaku part way: the first time it
  /// paints one it puts it at the right edge (scrolling) and starts its
  /// clock (all kinds). So it is added as usual, and once it has been
  /// painted (off screen, at the right edge) it is moved to where it would
  /// be by now, or its clock is put back ([_placeAll]). Until then it is
  /// already where it will be, so the tracks the next ones are fitted into
  /// see it there.
  bool _addAlive(
    DanmakuController<DanmakuExtra> controller,
    DanmakuElem elem,
    int elapsed,
    double scrollLifetime,
    double speed,
  ) {
    final content = _contentOf(elem);
    if (content == null || !controller.addDanmaku(content)) return false;
    final viewWidth = widget.size.width;
    final tracks = controller.scrollDanmaku;
    for (final track in tracks) {
      final item = track.lastOrNull;
      if (item == null || !identical(item.content, content)) continue;
      final offset = scrollOffsetAfter(
        elapsed,
        duration: scrollLifetime,
        viewWidth: viewWidth,
        itemWidth: item.width,
        fixedVelocity: controller.option.scrollFixedVelocity,
      );
      final x = viewWidth - offset;
      track.removeLast();
      // gone already (a static one turned scrolling lives by the scrolling
      // time)
      if (x + item.width <= 0) {
        item.dispose();
        return false;
      }
      // The renderer chose the track as for one entering at the right edge;
      // this one is further in, so it goes in the first track where it
      // clears the last one (they are added oldest first, so that one is to
      // its left), and is dropped where none has room, as the renderer
      // drops what does not fit. Massive mode piles them up regardless.
      final fixedVelocity = controller.option.scrollFixedVelocity;
      bool clears(List<DanmakuItem<DanmakuExtra>> t) {
        if (t.isEmpty) return true;
        final ahead = t.last;
        final right = ahead.xPosition + ahead.width;
        // a wider one moves faster (the view plus its width in the same
        // time): it must not catch the one ahead before that has left, the
        // renderer's own rule for one entering, from where this one is
        if (fixedVelocity || item.width <= ahead.width) return x >= right;
        return x * (viewWidth + ahead.width) >=
            right * (viewWidth + item.width);
      }

      final List<DanmakuItem<DanmakuExtra>>? into =
          controller.option.massiveMode || clears(track)
          ? track
          : tracks.firstWhereOrNull(clears);
      if (into == null) {
        item.dispose();
        return false;
      }
      into.add(item);
      item.xPosition = x;
      _placements.add((item: item, scroll: true, by: offset));
      return true;
    }
    for (final item in controller.staticDanmaku) {
      if (item != null && identical(item.content, content)) {
        // its clock runs by the wall
        _placements.add((item: item, scroll: false, by: elapsed / speed));
        return true;
      }
    }
    // an advanced one: starts from its beginning
    return true;
  }

  /// Danmaku refilled, to be moved once first painted (see [_addAlive]):
  /// a scrolling one [by] px left of the right edge, the clock of a static
  /// one [by] ms back.
  final _placements =
      <({DanmakuItem<DanmakuExtra> item, bool scroll, num by})>[];
  bool _placementScheduled = false;

  void _schedulePlacement() {
    if (_placementScheduled) return;
    _placementScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback(_placeAll);
  }

  void _placeAll(Duration _) {
    _placementScheduled = false;
    if (!mounted) {
      _placements.clear();
      return;
    }
    final viewWidth = widget.size.width;
    _placements.removeWhere((p) {
      final item = p.item;
      // not painted yet (paused, or hidden): its turn comes
      if (item.drawTick == null) return false;
      if (p.scroll) {
        item.xPosition = viewWidth - p.by;
      } else {
        item.drawTick = item.drawTick! - p.by.round();
      }
      return true;
    });
    if (_placements.isNotEmpty) _schedulePlacement();
  }

  @pragma('vm:notify-debugger-on-exception')
  void videoPositionListen(Duration position) {
    int currentPosition = position.inMilliseconds;
    _noteMove(currentPosition);

    if (_controller == null || !playerController.enableShowDanmaku.value) {
      return;
    }

    if (!playerController.showDanmaku && !widget.isPipMode) {
      return;
    }

    if (!_shouldRun) {
      return;
    }

    // still the place a seek left: nothing of it is to be shown
    if (_awaitedPosition != null) {
      return;
    }

    if (_refillPending && _refill(currentPosition)) {
      return;
    }

    currentPosition -= currentPosition % 100; //取整百的毫秒数
    if (currentPosition != latestAddedPosition) {
      latestAddedPosition = currentPosition;
      List<DanmakuElem>? currentDanmakuList = _plDanmakuController
          .getCurrentDanmaku(currentPosition);
      if (currentDanmakuList != null) {
        if (_queue.isEmpty) {
          _addAll(currentDanmakuList);
        } else {
          // behind what a refill has still to hand over
          final danmakuWeight = DanmakuOptions.danmakuWeight;
          for (final e in currentDanmakuList) {
            if (e.weight < danmakuWeight) continue;
            _queue.add((elem: e, shownAt: currentPosition));
          }
        }
      }
    }
    if (_queue.isNotEmpty) _drain(position.inMilliseconds);
  }

  void _addAll(List<DanmakuElem> list) {
    final danmakuWeight = DanmakuOptions.danmakuWeight;
    for (DanmakuElem e in list) {
      if (e.weight < danmakuWeight) continue;
      if (_contentOf(e) case final content?) {
        _controller!.addDanmaku(content);
      }
    }
  }

  /// What the renderer is given for [e]; null for an advanced danmaku whose
  /// content does not parse.
  DanmakuContentItem<DanmakuExtra>? _contentOf(DanmakuElem e) {
    if (e.mode == 7) {
      try {
        return SpecialDanmakuContentItem.fromList(
          DmUtils.decimalToColor(e.color),
          e.fontsize.toDouble(),
          jsonDecode(e.content.replaceAll('\n', '\\n')),
          extra: VideoDanmaku(
            id: e.id.toInt(),
            mid: e.midHash,
            like: e.likeCount.toInt(),
          ),
        );
      } catch (_) {
        return null;
      }
    }
    return DanmakuContentItem(
      e.content,
      color: DanmakuOptions.blockColorful
          ? Colors.white
          : DmUtils.decimalToColor(e.color),
      type: DmUtils.getPosition(e.mode),
      isColorful:
          playerController.showVipDanmaku &&
          e.colorful == DmColorfulType.VipGradualColor,
      count: e.count > 1 ? e.count : null,
      selfSend: e.isSelf,
      extra: VideoDanmaku(
        id: e.id.toInt(),
        mid: e.midHash,
        like: e.likeCount.toInt(),
      ),
    );
  }

  @override
  void dispose() {
    _bufferingSub?.cancel();
    playerController
      ..removePositionListener(videoPositionListen)
      ..removeStatusLister(playerListener);
    _plDanmakuController.dispose();
    _placements.clear();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final option = DanmakuOptions.get(
      notFullscreen: widget.notFullscreen,
      speed: playerController.playbackSpeed,
    );
    return Obx(
      () => AnimatedOpacity(
        opacity: playerController.enableShowDanmaku.value
            ? playerController.danmakuOpacity.value
            : 0,
        duration: const Duration(milliseconds: 100),
        child: DanmakuScreen<DanmakuExtra>(
          createdController: (e) {
            playerController.danmakuController = _controller = e;
            // a renderer starts out running: not before the picture does
            if (!_shouldRun) e.pause();
          },
          option: option,
          size: widget.size,
        ),
      ),
    );
  }
}
