/// One interface, so that adding an Invidious-instance implementation later
/// touches no caller.
///
/// Stage 1 ships exactly one implementation ([YtDirectSource]). The interface
/// exists now because the *routing rule* is the deliverable, and a routing rule
/// with one source is testable while a routing rule bolted on afterwards is
/// not. `research/invidious-spike.md` describes the deferred second
/// implementation; nothing here assumes anything about it beyond this
/// interface.
library;

import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';

/// A video stream and an audio stream, ready to hand to a player.
class YtStreamPair {
  const YtStreamPair({
    required this.videoUrl,
    required this.audioUrl,
    required this.sourceId,
    required this.expiresIn,
    this.video,
    this.audio,
  });

  final String videoUrl;
  final String audioUrl;

  /// Which [YouTubeVideoSource] produced these. Kept so the UI can say so and
  /// so a stale URL is re-minted from the source that issued it.
  final String sourceId;

  /// Measured consistently ~6 h on the direct path. A direct URL is also bound
  /// to our egress IP, so it cannot be handed to another network.
  final Duration expiresIn;

  final YtFormat? video;
  final YtFormat? audio;

  /// The mpv `edl://` string the app's player controller consumes.
  ///
  /// Measured 2 329–2 403 chars on the direct path — roughly half the size of
  /// the Invidious equivalent — plain ASCII, with no bare `;` inside either
  /// URL needing escaping. The `%N%` length prefix makes that safe regardless.
  String get edl =>
      'edl://!no_chapters;%${videoUrl.length}%$videoUrl;'
      '!new_stream;!no_chapters;%${audioUrl.length}%$audioUrl';

  @override
  String toString() => 'YtStreamPair(via $sourceId, expires in $expiresIn)';
}

/// Where video data comes from. Implemented by the direct InnerTube client
/// now, and by an Invidious instance later.
abstract class YouTubeVideoSource {
  /// Stable id used as the key of the health state and in diagnostics.
  String get id;

  /// Human label for the (later) source-switch menu.
  String get label;

  /// Full metadata for one video: title, author, duration, thumbnails,
  /// formats, caption tracks.
  Future<YtResult<YtVideoDetail>> detail(String videoId);

  /// A playable pair for one video.
  Future<YtResult<YtStreamPair>> streams(
    String videoId, {
    YtFormatPreference preference,
  });

  /// The caption tracks for one video.
  ///
  /// Not cacheable as authoritative: measured, the same video returned 1 track
  /// on three consecutive calls and 21 on the fourth.
  Future<YtResult<List<YtCaptionTrack>>> captionTracks(String videoId);

  /// The content of one caption track.
  Future<YtResult<String>> captionContent(
    YtCaptionTrack track, {
    YtCaptionFormat format,
    String? translateTo,
  });

  /// A CHEAP liveness check, used when a cooled-down source is being retried.
  ///
  /// Must NOT be a full request: a probe that costs what the real request
  /// costs cannot be used to decide whether to make the real request. For the
  /// direct source it is one `visitor_id` POST (~600 B, ~200 ms).
  Future<YtVerdict> probe();
}
