/// LibrePili: the YouTube page's download panel (feature-logs/
/// download-platforms stage-2 plan §4.4; design §8, §10-6 ①b, §10-7 Q6 b,
/// §10-8).
///
/// What it lists is taken once, when it opens, and kept until it closes
/// ([YtDownloadPlatform.offerFor]): the tiers the current source can give
/// as one mp4, and greyed the tiers the other source could give and this
/// one cannot. Never the page's own detail: the page sets it once, at load,
/// and changes only its streams after (another quality, another source).
library;

import 'dart:math' as math;

import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/pages/download/view.dart';
import 'package:PiliPlus/pages/setting/common_setting.dart';
import 'package:PiliPlus/services/download/download_platform_yt.dart';
import 'package:PiliPlus/services/download/download_service.dart';
import 'package:PiliPlus/services/youtube/yt_format_select.dart';
import 'package:PiliPlus/services/youtube/yt_models.dart';
import 'package:PiliPlus/services/youtube/yt_quality_tier.dart';
import 'package:PiliPlus/services/youtube/yt_verdict.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// An MP4 video stream a download can take: `avc1` / `av01`, not muxed,
/// with a plain URL — what [YtFormatPreference.mp4Download] picks from.
bool ytMp4Video(YtFormat f) =>
    f.isVideo &&
    f.isPlayable &&
    !f.isMuxed &&
    const {'avc1', 'av01'}.contains(f.codecFamily);

/// An `mp4a` audio stream with a plain URL.
bool ytMp4Audio(YtFormat f) =>
    f.isAudio && f.isPlayable && f.codecFamily == 'mp4a';

/// The video streams of [formats] a download can make one mp4 of: none
/// when the same answer has no MP4 audio.
List<YtFormat> ytMp4VideoFormats(List<YtFormat> formats) =>
    formats.any(ytMp4Audio)
    ? formats.where(ytMp4Video).toList(growable: false)
    : const [];

/// The tiers ([ytQualityTier]) of [formats] a download can take, highest
/// first, each once.
List<int> ytDownloadableTiers(List<YtFormat> formats) => {
  for (final f in ytMp4VideoFormats(formats))
    ytQualityTier(f.width ?? 0, f.height ?? 0),
}.toList()..sort((a, b) => b.compareTo(a));

/// The greyed tiers (§10-7 Q6 b): the reference — [downloadable] and the
/// other source's downloadable tiers [other] together — less
/// [downloadable]. Without the other source's answer: none.
List<int> ytGreyedTiers(List<int> downloadable, List<int>? other) {
  final reference = {...downloadable, ...?other};
  return (reference..removeAll(downloadable)).toList()
    ..sort((a, b) => b.compareTo(a));
}

/// The tier selected when the panel opens: of the formats the page's cap
/// [pageCap] would let in (short side ≤ it, as the page compares), the
/// highest tier — the best format the page would play, named as the panel
/// names it. A cap of 0 (none), or one below every format: the highest
/// tier. Not the cap compared with the tiers: a wide film's "800P" on the
/// page is the 1080 tier here.
int? ytDefaultTier(List<YtFormat> formats, int pageCap) {
  final videos = ytMp4VideoFormats(formats);
  if (videos.isEmpty) return null;
  final within = pageCap <= 0
      ? videos
      : videos.where((f) => ytShortSide(f) <= pageCap).toList();
  return (within.isEmpty ? videos : within)
      .map((f) => ytQualityTier(f.width ?? 0, f.height ?? 0))
      .reduce(math.max);
}

/// The panel. [pageCap] is the page's quality cap when it opened (short
/// side, 0: none), used only for the tier selected first; [pageDetail]
/// only for the title shown until the panel's own answer comes.
class YtDownloadSheet extends StatefulWidget {
  const YtDownloadSheet({
    super.key,
    required this.videoId,
    required this.pageCap,
    this.pageDetail,
    this.service,
  });

  final String videoId;
  final int pageCap;
  final YtVideoDetail? pageDetail;

  /// Tests: the service (else the app's).
  final DownloadService? service;

  /// In place of [SmartDialog.showToast].
  @visibleForTesting
  static void Function(String msg)? toastForTest;

  /// The self-tests' (`--yt-panel`, stage-2 plan §5): the panel's state
  /// after each change; null in every other run.
  static void Function(Map<String, Object?> state)? selfTestState;

  @override
  State<YtDownloadSheet> createState() => _YtDownloadSheetState();
}

class _YtDownloadSheetState extends State<YtDownloadSheet> {
  late final DownloadService _service =
      widget.service ?? Get.find<DownloadService>();

  YtDownloadPlatform get _platform =>
      _service.platformNamed('youtube')! as YtDownloadPlatform;

  /// Each ask's number: a retry's answers replace an earlier one's, a
  /// late one is dropped.
  var _ask = 0;
  var _loading = true;
  YtDownloadOffer? _offer;
  List<int> _tiers = const [];
  List<int> _greyed = const [];
  var _otherPending = false;
  var _otherLive = false;
  int? _selected;

  /// Queued or downloaded already: its words, and no 「下载」.
  String? _existing;

  /// The download list read (design §8: until then 「下载」 shows a spinner
  /// and cannot be tapped).
  var _listRead = false;
  var _adding = false;

  String get _key => 'yt:${widget.videoId}';

  @override
  void initState() {
    super.initState();
    _load();
    _checkExisting();
  }

  Future<void> _checkExisting() async {
    // the list read first: before it a downloaded video is in neither
    await _service.waitForInitialization;
    if (!mounted) return;
    setState(() {
      _listRead = true;
      _existing = _existingNow();
    });
  }

  String? _existingNow() {
    if (_service.downloadList.any((e) => e.key == _key)) {
      return YtCreateResult.done.message;
    }
    if (_service.waitDownloadQueue.any((e) => e.key == _key)) {
      return YtCreateResult.queued.message;
    }
    return null;
  }

  Future<void> _load() async {
    final ask = ++_ask;
    setState(() {
      _loading = true;
      _offer = null;
      _tiers = const [];
      _greyed = const [];
      _otherPending = false;
      _otherLive = false;
      _selected = null;
    });
    YtDownloadOffer offer;
    try {
      offer = await _platform.offerFor(widget.videoId);
    } catch (e) {
      offer = YtDownloadOffer(
        detail: null,
        sourceId: null,
        verdict: const YtVerdict(YtCause.transient, 'panel'),
        liveNow: false,
        other: Future.value(),
      );
    }
    if (!mounted || ask != _ask) return;
    // the offer's own formats, the ones taken when the panel opened
    final formats = offer.detail?.formats ?? const <YtFormat>[];
    setState(() {
      _loading = false;
      _offer = offer;
      _tiers = ytDownloadableTiers(formats);
      _selected = ytDefaultTier(formats, widget.pageCap);
      _otherPending = offer.detail != null && !offer.liveNow;
    });
    final other = await offer.other;
    if (!mounted || ask != _ask) return;
    setState(() {
      _otherPending = false;
      _otherLive = other?.liveNow ?? false;
      _greyed = ytGreyedTiers(
        _tiers,
        other == null ? null : ytDownloadableTiers(other.formats),
      );
    });
  }

  bool get _live => (_offer?.liveNow ?? false) || _otherLive;

  bool get _canDownload =>
      _listRead &&
      !_loading &&
      !_adding &&
      _existing == null &&
      _offer?.detail != null &&
      !_live &&
      _selected != null;

  void _toast(String msg) =>
      (YtDownloadSheet.toastForTest ?? SmartDialog.showToast)(msg);

  Future<void> _download() async {
    final detail = _offer?.detail;
    final tier = _selected;
    if (detail == null || tier == null || _adding) return;
    setState(() => _adding = true);
    try {
      String? folder;
      final r = await YtDownloadPlatform.create(
        _service,
        detail,
        tier,
        unreadable: (f) => folder = f,
      );
      _toast(
        r == YtCreateResult.unreadable
            ? '已存在无法读取的下载：$folder，删除该文件夹后可重新下载'
            : r.message,
      );
      if (mounted) setState(() => _existing = _existingNow());
    } catch (e) {
      _toast('下载失败：$e');
    } finally {
      if (mounted) setState(() => _adding = false);
    }
  }

  @override
  void setState(VoidCallback fn) {
    super.setState(fn);
    YtDownloadSheet.selfTestState?.call({
      'loading': _loading,
      'sourceId': _offer?.sourceId,
      'verdict': _offer == null
          ? null
          : '${_offer!.verdict.cause.name}<${_offer!.verdict.signal}>',
      'liveNow': _live,
      'downloadable': _tiers,
      'reference': {..._tiers, ..._greyed}.toList()
        ..sort((a, b) => b.compareTo(a)),
      'greyed': _greyed,
      'selected': _selected,
      'otherPending': _otherPending,
      'existing': _existing,
      'message': _messageNow(),
      'canDownload': _canDownload,
      'listRead': _listRead,
    });
  }

  /// What the panel says in place of the list, or null.
  String? _messageNow() {
    if (_existing != null) return _existing;
    if (_loading) return null;
    if (_live) return '直播中或尚未开播的视频不能下载';
    if (_offer?.detail == null) return '暂时取不到可下载的格式';
    if (_tiers.isEmpty) return '没有可下载的 MP4 格式';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = _offer?.detail?.title ?? widget.pageDetail?.title ?? '';
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('下载', style: theme.textTheme.titleMedium),
                if (title.isNotEmpty)
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.outline,
                    ),
                  ),
              ],
            ),
          ),
          Flexible(child: _body(theme)),
          const Divider(height: 1),
          _bottom(theme),
        ],
      ),
    );
  }

  Widget _message(String text, {Widget? action}) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(text, textAlign: TextAlign.center),
        ?action,
      ],
    ),
  );

  Widget _body(ThemeData theme) {
    if (_existing case final existing?) return _message(existing);
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    final offer = _offer!;
    if (_live) return _message('直播中或尚未开播的视频不能下载');
    if (offer.detail == null) {
      return _message(
        '暂时取不到可下载的格式',
        action: TextButton(onPressed: _load, child: const Text('重试')),
      );
    }
    if (_tiers.isEmpty) return _message('没有可下载的 MP4 格式');
    final all = {..._tiers, ..._greyed}.toList()
      ..sort((a, b) => b.compareTo(a));
    return ListView(
      shrinkWrap: true,
      children: [
        for (final tier in all)
          if (_tiers.contains(tier))
            ListTile(
              key: ValueKey('tier-$tier'),
              dense: true,
              title: Text('${tier}P'),
              selected: tier == _selected,
              trailing: tier == _selected ? const Icon(Icons.check) : null,
              onTap: () => setState(() => _selected = tier),
            )
          else
            ListTile(
              key: ValueKey('tier-$tier'),
              dense: true,
              enabled: false,
              title: Text('${tier}P'),
              subtitle: const Text('当前来源不提供'),
            ),
        if (_otherPending)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              spacing: 8,
              children: [
                const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                Text(
                  '正在查询另一个来源',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.outline,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _bottom(ThemeData theme) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    child: Row(
      children: [
        TextButton(
          onPressed: () => Navigator.of(context).push(
            GetPageRoute(page: () => const DownloadPage()),
          ),
          child: const Text('查看缓存'),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).push(
            GetPageRoute(
              page: () => const CommonSetting(
                settingType: SettingType.downloadSetting,
              ),
            ),
          ),
          child: const Text('设置'),
        ),
        const Spacer(),
        if (_existing == null)
          FilledButton(
            key: const ValueKey('download'),
            onPressed: _canDownload ? _download : null,
            child: _adding || _loading || !_listRead
                ? const SizedBox.square(
                    dimension: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('下载'),
          ),
      ],
    ),
  );
}
