/// LibrePili: when the picture held over a reopen or a handover (see
/// PlPlayerController.heldPicture) is let go.
///
/// It went on mpv's `video-frame-info/picture-type` alone, and on the phone
/// never went: after a quality switch on a Pixel 4 XL (mediacodec, CI build
/// 011535f5e, 2026-10-21) the log had "picture held" and no "picture let
/// go", and the same still frame stayed up for the remaining 55 s while the
/// sound and the playhead went on. A frame there carries no picture type
/// (hypothesis: MediaCodec gives none, and mpv leaves the sub-property out
/// when it does not know it), so the frame is also read from another of its
/// sub-properties, and two signals that are there on every decoder back it:
///
/// - [PictureLetGo.frame]: mpv says which frame is up, steady for
///   [frameSteady] — as before, and first on Windows (0.05-0.09 s).
/// - [PictureLetGo.playhead]: the new file's video decoded (`video-params`)
///   and the playhead moved [playedEnough] of playing: with a video track
///   mpv moves the playhead with the frames it shows.
/// - [PictureLetGo.deadline]: [playingDeadline] after the playhead began to
///   move, whatever the rest says: 「画面不能在播放时一直停着」.
///
/// None of them while paused: a file opened paused shows nothing on
/// Windows until it plays — mpv says a frame is up (picture type "B") and
/// the texture stays black, with or without the hold, on this tree and on
/// the commit before it (self-test 2026-10-21: a paused quality switch
/// black for the whole 15 s watched once the picture went; HEAD with
/// `--no-hold` black for all 9 s). So a paused open keeps the picture (or
/// the cover) until play, and it goes by the frame or the playhead then.
///
/// Each later than the signal before it whenever that one works, so the
/// picture does not go earlier on Windows than it did.
///
/// The last two go by the new file only: they count once it is the one
/// loaded (`loaded`: mpv plays the playlist entry this open put there),
/// from where its playhead stood then — the previous file's frame or
/// playhead read just after the open is not taken for the new one's
/// (review 2026-10-21, codex).
///
/// Pure: no mpv, so it can be tested.
library;

/// Why a held picture was let go.
enum PictureLetGo {
  frame('a frame shown'),
  playhead('the playhead moved'),
  deadline('the deadline after playing');

  const PictureLetGo(this.label);

  /// Said in the event log.
  final String label;
}

class PictureReleaseWatch {
  /// [opened]: the player watched opened a file just now, and the frame
  /// info of the file before can still read for a moment: a gap in it is
  /// waited for first (or [gapWait] of it reading). False for a second
  /// player whose frames are its own already (a handover).
  PictureReleaseWatch({
    required bool opened,
    required this.start,
  }) : _gap = !opened;

  /// How long a frame must have been up: the texture takes the frame mpv
  /// says is up a frame or two later.
  static const frameSteady = Duration(milliseconds: 100);

  /// The longest the frame info is waited on to go blank after an open.
  static const gapWait = Duration(seconds: 2);

  /// Seconds of playing that show the new frames are up.
  static const playedEnough = 1.0;

  /// From the first move of the playhead to the picture going regardless.
  static const playingDeadline = Duration(seconds: 3);

  /// A step of the playhead larger than this between two ticks is a seek
  /// (or the open's start) rather than playing.
  static const maxStep = 0.5;

  /// When the watch began.
  final DateTime start;
  bool _gap;
  DateTime? _shownAt;
  double? _lastPosition;
  double _played = 0;
  DateTime? _playingSince;

  /// Seconds of playing seen so far.
  double get played => _played;

  /// One look, every 50 ms or so. [frame]: mpv says which frame is up;
  /// [sized]: the player has a size and the page an area for it;
  /// [decoded]: the open file's video parameters are there; [loaded]: the
  /// file opened is the one loaded (true where nothing was opened: a
  /// handover's second player, the decoder back after a sleep); [position]:
  /// the playhead in seconds; [playing]: mpv is not paused. Null while the
  /// picture stays.
  PictureLetGo? tick({
    required DateTime now,
    required bool frame,
    required bool sized,
    required bool decoded,
    required double position,
    bool loaded = true,
    bool playing = true,
  }) {
    if (loaded) {
      // the first position read once loaded is where the new file starts
      final last = _lastPosition;
      _lastPosition = position;
      if (last != null) {
        final step = position - last;
        if (step > 0 && step <= maxStep) {
          _played += step;
          _playingSince ??= now;
        }
      }
    } else {
      _lastPosition = null;
    }
    decoded = decoded && loaded;

    final shown = frame && sized;
    if (!shown) {
      _gap = true;
      _shownAt = null;
    }
    // paused: the frame mpv says is up may not be in the texture (see the
    // library comment); the picture stays until play
    if (!playing) {
      _shownAt = null;
      return null;
    }
    final waited = _gap || now.difference(start) >= gapWait;
    if (shown && waited) {
      _shownAt ??= now;
      if (now.difference(_shownAt!) >= frameSteady) return PictureLetGo.frame;
    }
    // a hair under: the steps are sums of doubles
    if (waited && decoded && _played >= playedEnough - 1e-6) {
      return PictureLetGo.playhead;
    }
    if (_playingSince case final since?
        when now.difference(since) >= playingDeadline) {
      return PictureLetGo.deadline;
    }
    return null;
  }
}
