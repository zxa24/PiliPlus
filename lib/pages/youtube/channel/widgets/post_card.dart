/// LibrePili: one YouTube post, in a channel's 帖子 tab or at the top of
/// its detail page.
///
/// The frame — the band under it, the author row, the count buttons — is
/// [DynCardFrame], the frame of bilibili's 动态 card. The content is this
/// file's: a post is runs of text (some of them links) and one attachment,
/// where a bilibili dynamic is rich nodes and forwarded dynamics; see
/// `dyn_card_frame.dart` for why they are not one widget. Where a piece
/// has a bilibili counterpart it is built the same way: text through
/// [TextMore] in the list and selectable text in the detail, at the sizes
/// bilibili's content panel uses; images through the same [ImageGridView].
library;

import 'package:PiliPlus/common/widgets/gesture/tap_gesture_recognizer.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/image_grid/image_grid_view.dart';
import 'package:PiliPlus/common/widgets/selection_text.dart';
import 'package:PiliPlus/common/widgets/space/dyn_card_frame.dart';
import 'package:PiliPlus/common/widgets/text_more/text_more.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/youtube/widgets/video_tile.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:font_awesome_flutter/font_awesome_flutter.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtPostCard extends StatelessWidget {
  const YtPostCard({
    super.key,
    required this.post,
    this.isDetail = false,
    this.band = true,
  });

  final YtPost post;

  /// At the top of its own detail page: the text is selectable and whole,
  /// and there are no count buttons — the comments are right below.
  final bool isDetail;
  final bool band;

  /// Opens the post with its comments, the way a bilibili dynamic opens.
  static void open(YtPost post) {
    final params = post.detailParams;
    if (params == null) return;
    Get.toNamed(
      '/ytPost',
      parameters: {'params': params, 'id': post.postId},
      arguments: post,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DynCardFrame(
      band: band,
      onTap: isDetail ? null : () => open(post),
      author: DynAuthorRow(
        avatar: NetworkImgLayer(
          type: ImageType.avatar,
          width: DynAuthor.avatarSize,
          height: DynAuthor.avatarSize,
          src: post.authorAvatar?.url,
        ),
        name: post.author,
        time: post.publishedText,
        onTap: post.authorChannelId == null || isDetail
            ? null
            : () {
                feedBack();
                Get.toNamed(
                  '/ytChannel',
                  parameters: {'id': post.authorChannelId!},
                );
              },
      ),
      children: [
        _content(context, theme),
        if (post.video case final video?) _video(video),
        const SizedBox(height: 2),
        if (!isDetail) _actions(theme) else const SizedBox(height: 12),
      ],
    );
  }

  Widget _content(BuildContext context, ThemeData theme) {
    final text = _textSpan(theme);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (post.runs.isNotEmpty)
            isDetail
                ? SelectionText.rich(text, style: const TextStyle(fontSize: 16))
                : TextMore.rich(
                    text,
                    style: const TextStyle(fontSize: 15),
                    maxLines: 6,
                    onShowMore: () => open(post),
                    primary: theme.colorScheme.primary,
                  ),
          if (post.images.isNotEmpty)
            ImageGridView(
              fullScreen: true,
              picArr: [
                for (final image in post.images)
                  ImageModel(
                    width: image.width,
                    height: image.height,
                    url: image.url,
                  ),
              ],
            ),
          if (post.pollChoices.isNotEmpty) _poll(theme),
        ],
      ),
    );
  }

  /// An attached video: the horizontal card every video list uses, at the
  /// height it has in those lists. It brings its own side padding, so it
  /// sits outside the text's.
  Widget _video(YtSearchItem video) => SizedBox(
    height: 110,
    child: YtVideoTile(
      item: video,
      onTap: () => Get.toNamed('/ytVideo', parameters: {'id': video.videoId}),
    ),
  );

  /// The text as one span, its links tappable.
  TextSpan _textSpan(ThemeData theme) => TextSpan(
    children: [
      for (final run in post.runs)
        if (!run.isLink)
          TextSpan(text: run.text)
        else
          TextSpan(
            text: run.text,
            style: TextStyle(color: theme.colorScheme.primary),
            recognizer: NoDeadlineTapGestureRecognizer()
              ..onTap = () => _openRun(run),
          ),
    ],
  );

  static void _openRun(YtTextRun run) {
    if (run.videoId case final id?) {
      Get.toNamed('/ytVideo', parameters: {'id': id});
    } else if (run.browseId case final id? when id.startsWith('UC')) {
      Get.toNamed('/ytChannel', parameters: {'id': id});
    } else if (run.url case final url?) {
      // a link to a YouTube video stays in the app
      if (tryParseYouTubeVideoId(url) case final id?) {
        Get.toNamed('/ytVideo', parameters: {'id': id});
      } else {
        PageUtils.launchURL(url);
      }
    }
  }

  /// A poll's choices. Read-only: voting needs an account.
  Widget _poll(ThemeData theme) => Padding(
    padding: const EdgeInsets.only(top: 6),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      spacing: 6,
      children: [
        for (final choice in post.pollChoices)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              borderRadius: const BorderRadius.all(Radius.circular(6)),
              border: Border.all(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
            ),
            child: Text(choice, style: const TextStyle(fontSize: 14)),
          ),
        if (post.pollVotesText case final votes?)
          Text(
            votes,
            style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
          ),
      ],
    ),
  );

  /// The count buttons, as bilibili's [ActionPanel] lays them out. Both open
  /// the post: liking needs an account, and the comments are on that page.
  Widget _actions(ThemeData theme) {
    final style = DynAction.buttonStyle(theme.colorScheme);
    final outline = theme.colorScheme.outline;
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceAround,
      children: [
        Expanded(
          child: TextButton.icon(
            onPressed: () => open(post),
            icon: Icon(
              FontAwesomeIcons.comment,
              size: DynAction.iconSize,
              color: outline,
              semanticLabel: '评论',
            ),
            style: style,
            label: Text(post.commentCountText ?? '评论'),
          ),
        ),
        Expanded(
          child: TextButton.icon(
            onPressed: () => open(post),
            icon: Icon(
              FontAwesomeIcons.thumbsUp,
              size: DynAction.iconSize,
              color: outline,
              semanticLabel: '点赞',
            ),
            style: style,
            label: Text(post.likeCountText ?? '点赞'),
          ),
        ),
      ],
    );
  }
}
