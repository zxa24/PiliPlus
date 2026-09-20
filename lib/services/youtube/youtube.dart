/// LibrePili — YouTube support, stage 1: the data layer.
///
/// Nothing in this folder touches the UI, the player, the downloader or the
/// router, and nothing in it goes through the app's bilibili request stack —
/// see `yt_transport.dart` for why that separation is load-bearing rather than
/// stylistic.
///
/// Import this barrel rather than the individual files.
///
/// ```dart
/// final source = YtDirectSource.create();
/// final router = YtSourceRouter(source);       // fallback slot left empty
/// final routed = await router.run((s) => s.streams(parseYouTubeVideoId(url)));
/// if (routed.ok) player.open(routed.value!.edl);
/// else           showError(routed.verdict);    // carries a pasteable signal
/// ```
///
/// Provenance: request shapes and reason-string matching are ported from
/// NewPipeExtractor (GPL-3.0, the same licence as this app), measured and
/// corrected by the spike in `research/youtube-direct-spike.md`.
library;

export 'package:PiliPlus/services/youtube/direct_source.dart';
export 'package:PiliPlus/services/youtube/innertube_client.dart';
export 'package:PiliPlus/services/youtube/source_router.dart';
export 'package:PiliPlus/services/youtube/video_source.dart';
export 'package:PiliPlus/services/youtube/yt_classifier.dart';
export 'package:PiliPlus/services/youtube/yt_format_select.dart';
export 'package:PiliPlus/services/youtube/yt_identity.dart';
export 'package:PiliPlus/services/youtube/yt_json.dart';
export 'package:PiliPlus/services/youtube/yt_models.dart';
export 'package:PiliPlus/services/youtube/yt_parser.dart';
export 'package:PiliPlus/services/youtube/yt_transport.dart';
export 'package:PiliPlus/services/youtube/yt_verdict.dart';
export 'package:PiliPlus/services/youtube/yt_video_id.dart';
