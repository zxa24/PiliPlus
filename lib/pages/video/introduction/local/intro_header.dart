import 'dart:typed_data';

import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/common/style.dart';
import 'package:PiliPlus/common/widgets/expandable.dart';
import 'package:PiliPlus/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/selection_text.dart';
import 'package:PiliPlus/common/widgets/stat/stat.dart';
import 'package:PiliPlus/common/widgets/video_intro/intro_metrics.dart';
import 'package:PiliPlus/models_new/video/video_detail/desc_v2.dart';
import 'package:PiliPlus/models_new/video/video_tag/data.dart';
import 'package:PiliPlus/pages/search/widgets/search_text.dart';
import 'package:PiliPlus/pages/video/controller.dart';
import 'package:PiliPlus/pages/video/introduction/local/local_intro.dart';
import 'package:PiliPlus/pages/video/introduction/ugc/widgets/action_item.dart';
import 'package:PiliPlus/plugin/pl_player/models/fullscreen_mode.dart'
    show kScreenRatio;
import 'package:PiliPlus/utils/app_scheme.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/duration_utils.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: the top of the offline intro page, laid out as the online one
/// (UgcIntroPanel: uploader, title, numbers, then on a tap the id,
/// description and tags) from what was saved with the download
/// ([LocalIntro]). Read-only: no follow, like or favourite, the numbers are
/// those of the day it was downloaded, and the avatars are the saved ones.
class LocalIntroHeader extends StatefulWidget {
  const LocalIntroHeader({
    super.key,
    required this.intro,
    required this.heroTag,
  });

  final LocalIntro intro;
  final String heroTag;

  @override
  State<LocalIntroHeader> createState() => _LocalIntroHeaderState();
}

class _LocalIntroHeaderState extends State<LocalIntroHeader> {
  bool _expand = false;

  late final _videoDetailCtr = Get.find<VideoDetailController>(
    tag: widget.heroTag,
  );

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.of(context);
    final intro = widget.intro;
    final view = intro.view;
    final stat = view.stat;
    // as the online page: a wide desktop window shows it all at once
    final open =
        _expand ||
        (PlatformUtils.isDesktop &&
            MediaQuery.sizeOf(context).aspectRatio >= kScreenRatio);
    return SliverPadding(
      padding: const .only(
        left: Style.safeSpace,
        right: Style.safeSpace,
        top: 10,
      ),
      sliver: SliverToBoxAdapter(
        child: GestureDetector(
          behavior: .opaque,
          onTap: () {
            feedBack();
            setState(() => _expand = !_expand);
          },
          child: Column(
            crossAxisAlignment: .start,
            children: [
              _owner(colorScheme),
              const SizedBox(height: 8),
              GestureDetector(
                onLongPress: () => Utils.copyText(view.title ?? ''),
                child: ExpandablePanel(
                  collapsed: _title(view.title, false),
                  expanded: _title(view.title, true),
                  expand: open,
                ),
              ),
              const SizedBox(height: 8),
              Row(
                spacing: 10,
                children: [
                  StatWidget(
                    type: .play,
                    value: stat?.view,
                    color: colorScheme.outline,
                  ),
                  StatWidget(
                    type: .danmaku,
                    value: stat?.danmaku,
                    color: colorScheme.outline,
                  ),
                  Text(
                    DateFormatUtils.format(view.pubdate),
                    style: TextStyle(
                      fontSize: IntroMetrics.stat,
                      color: colorScheme.outline,
                    ),
                  ),
                ],
              ),
              if (open) ..._infos(colorScheme),
              if (stat != null) ...[
                const SizedBox(height: 8),
                // the numbers only: nothing here reaches bilibili
                SizedBox(
                  height: 48,
                  child: Row(
                    crossAxisAlignment: .start,
                    children: [
                      ActionItem(
                        icon: const Icon(FontAwesomeIcons.thumbsUp),
                        semanticsLabel: '点赞数',
                        text: NumUtils.numFormat(stat.like),
                      ),
                      ActionItem(
                        icon: const Icon(FontAwesomeIcons.b),
                        semanticsLabel: '投币数',
                        text: NumUtils.numFormat(stat.coin),
                      ),
                      ActionItem(
                        icon: const Icon(FontAwesomeIcons.star),
                        semanticsLabel: '收藏数',
                        text: NumUtils.numFormat(stat.favorite),
                      ),
                      ActionItem(
                        icon: const Icon(FontAwesomeIcons.shareFromSquare),
                        semanticsLabel: '分享数',
                        text: NumUtils.numFormat(stat.share),
                      ),
                    ],
                  ),
                ),
              ],
              if (intro.fetchedAt case final at?)
                Text(
                  '以上为下载时（${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}）保存的信息',
                  style: TextStyle(fontSize: 12, color: colorScheme.outline),
                ),
              const SizedBox(height: 10),
            ],
          ),
        ),
      ),
    );
  }

  Widget _title(String? title, bool expand) => Text(
    title ?? '',
    maxLines: expand ? null : 2,
    overflow: expand ? null : .ellipsis,
    style: const TextStyle(fontSize: IntroMetrics.title),
  );

  Widget _avatar(ColorScheme colorScheme, Uint8List? bytes) => ClipOval(
    child: SizedBox.square(
      dimension: IntroMetrics.avatarSize,
      child: bytes == null
          ? ColoredBox(
              color: colorScheme.onInverseSurface,
              child: Icon(Icons.person, size: 20, color: colorScheme.outline),
            )
          : Image.memory(
              bytes,
              fit: .cover,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => const SizedBox.shrink(),
            ),
    ),
  );

  Widget _owner(ColorScheme colorScheme) {
    final intro = widget.intro;
    final view = intro.view;
    if (view.staff case final staff? when staff.isNotEmpty) {
      return SingleChildScrollView(
        scrollDirection: .horizontal,
        child: Row(
          spacing: 25,
          children: [
            for (final s in staff)
              Row(
                spacing: 8,
                children: [
                  _avatar(colorScheme, intro.face(s.face)),
                  Column(
                    mainAxisSize: .min,
                    crossAxisAlignment: .start,
                    children: [
                      Text(
                        s.name ?? '',
                        maxLines: 1,
                        overflow: .ellipsis,
                        style: const TextStyle(fontSize: 13),
                      ),
                      Text(
                        s.title ?? '',
                        style: TextStyle(
                          fontSize: 12,
                          color: colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
          ],
        ),
      );
    }
    final card = intro.card;
    final name = card?.card?.name ?? view.owner?.name ?? '';
    return Row(
      spacing: IntroMetrics.avatarGap,
      children: [
        _avatar(colorScheme, intro.face(card?.card?.face)),
        Expanded(
          child: Column(
            crossAxisAlignment: .start,
            children: [
              Text(
                name,
                maxLines: 1,
                overflow: .ellipsis,
                style: const TextStyle(fontSize: IntroMetrics.ownerName),
              ),
              if (card != null)
                Text(
                  '${NumUtils.numFormat(card.follower)}粉丝    ${NumUtils.numFormat(card.archiveCount)}视频',
                  style: TextStyle(
                    fontSize: IntroMetrics.ownerSecondary,
                    color: colorScheme.outline,
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  List<Widget> _infos(ColorScheme colorScheme) {
    final view = widget.intro.view;
    final tags = widget.intro.tags;
    return [
      const SizedBox(height: 8, width: .infinity),
      GestureDetector(
        onTap: () => Utils.copyText('${view.bvid}'),
        child: Text(
          view.bvid ?? '',
          style: TextStyle(fontSize: 14, color: colorScheme.secondary),
        ),
      ),
      if (view.descV2 case final descV2? when descV2.isNotEmpty) ...[
        const SizedBox(height: 8),
        SelectionText.rich(
          _desc(colorScheme, descV2),
          style: const TextStyle(
            fontSize: IntroMetrics.description,
            height: IntroMetrics.descriptionHeight,
          ),
        ),
      ],
      if (tags.isNotEmpty) _tags(tags),
    ];
  }

  // as the online page's (UgcIntroPanel.urlRegExp)
  static final _linkRegExp = RegExp(
    Constants.urlRegex.pattern + r'|av\d+|bv[a-z\d]{10}|(?:\d+[:：])?\d+[:：]\d+',
    caseSensitive: false,
  );

  TextSpan _link(String text, VoidCallback onTap, ColorScheme colorScheme) =>
      TextSpan(
        text: text,
        style: TextStyle(color: colorScheme.primary),
        recognizer: NoDeadlineTapGestureRecognizer()..onTap = onTap,
      );

  TextSpan _desc(ColorScheme colorScheme, List<DescV2> descV2) {
    final children = <InlineSpan>[];
    for (final d in descV2) {
      switch (d.type) {
        case 1:
          d.rawText?.splitMapJoin(
            _linkRegExp,
            onMatch: (match) {
              final text = match[0]!;
              final lower = text.toLowerCase();
              if (lower.startsWith('http')) {
                children.add(
                  _link(text, () => PageUtils.handleWebview(text), colorScheme),
                );
              } else if (lower.startsWith('av')) {
                final aid = int.tryParse(text.substring(2));
                children.add(
                  aid == null
                      ? TextSpan(text: text)
                      : _link(
                          text,
                          () => PiliScheme.videoPush(aid, null),
                          colorScheme,
                        ),
                );
              } else if (lower.startsWith('bv')) {
                children.add(
                  _link(
                    text,
                    () => PiliScheme.videoPush(null, text),
                    colorScheme,
                  ),
                );
              } else {
                children.add(
                  _link(
                    text,
                    () => _videoDetailCtr.plPlayerController.seekTo(
                      Duration(seconds: DurationUtils.parseDuration(text)),
                      isSeek: false,
                    ),
                    colorScheme,
                  ),
                );
              }
              return '';
            },
            onNonMatch: (text) {
              children.add(TextSpan(text: text));
              return '';
            },
          );
        case 2:
          children.add(
            _link(
              '@${d.rawText}',
              () => Get.toNamed('/member?mid=${d.bizId}'),
              colorScheme,
            ),
          );
      }
    }
    return TextSpan(children: children);
  }

  Widget _tags(List<VideoTagItem> tags) => Padding(
    padding: const .only(top: 8),
    child: Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        for (final item in tags)
          if (item.tagName case final tagName?)
            SearchText(
              fontSize: 13,
              text: switch (item.tagType) {
                'bgm' => tagName.replaceFirst('发现', '♫ BGM：'),
                'topic' => '#$tagName',
                _ => tagName,
              },
              // as the online page's
              onTap: switch (item.tagType) {
                'bgm' when item.musicId != null => (_) => Get.toNamed(
                  '/musicDetail',
                  parameters: {'musicId': item.musicId!},
                ),
                'topic' when item.tagId != null => (_) => Get.toNamed(
                  '/dynTopic',
                  parameters: {'id': item.tagId!.toString()},
                ),
                _ => (_) => Get.toNamed(
                  '/searchResult',
                  parameters: {'keyword': tagName},
                ),
              },
              onLongPress: Utils.copyText,
            ),
      ],
    ),
  );
}
