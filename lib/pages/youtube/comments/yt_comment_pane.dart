/// LibrePili: a YouTube comment section — the list, the reply previews,
/// 评论详情 and the long-press menu — on the shared [CommentChrome].
///
/// It was the video page's comment tab. A channel post's detail page shows
/// the same section, so it is a widget over [YtCommentsMixin] now and both
/// pages place it; the chrome around the text is still [CommentChrome],
/// shared with bilibili's list.
library;

import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/badge.dart';
import 'package:PiliPlus/common/widgets/comments/comment_chrome.dart';
import 'package:PiliPlus/common/widgets/flutter/refresh_indicator.dart';
import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/models/common/badge_type.dart';
import 'package:PiliPlus/models/common/image_type.dart';
import 'package:PiliPlus/pages/video/widgets/translate_entry.dart';
import 'package:PiliPlus/pages/youtube/comments/yt_comments_controller.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:PiliPlus/utils/page_utils.dart';
import 'package:PiliPlus/utils/platform_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class YtCommentPane extends StatefulWidget {
  const YtCommentPane({super.key, required this.controller});

  final YtCommentsMixin controller;

  @override
  State<YtCommentPane> createState() => _YtCommentPaneState();
}

class _YtCommentPaneState extends State<YtCommentPane> {
  YtCommentsMixin get controller => widget.controller;

  /// The comments pane. It is a [MiniScaffold] because 评论详情 opens as a
  /// sheet *inside* it, the way the bilibili page does it
  /// (reply/view.dart:245): the detail takes over the comment area and
  /// leaves the video where it is, rather than covering the window.
  @override
  Widget build(BuildContext context) =>
      MiniScaffold(body: _commentList(Theme.of(context)));

  Widget _commentList(ThemeData theme) => Obx(() {
    final items = controller.comments;
    final error = controller.commentsError.value;

    if (items.isEmpty) {
      if (error != null) {
        // a failed request used to empty into 「暂无评论」, which is what a
        // video with comments turned off says: the two were the same screen
        // a box here, not the sliver HttpError is by default: as a sliver
        // it threw the moment a comment request failed
        return HttpError(
          isSliver: false,
          errMsg: error,
          onReload: controller.retryComments,
        );
      }
      if (controller.commentsPending) {
        return ListView(
          padding: EdgeInsets.zero,
          children: CommentChrome.skeletons(CommentChrome.listSkeletons),
        );
      }
      return Center(
        child: Text(
          '暂无评论',
          style: TextStyle(color: theme.colorScheme.outline),
        ),
      );
    }

    final list = refreshIndicator(
      onRefresh: controller.refreshComments,
      child: ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: items.length + 1,
        separatorBuilder: (_, _) => CommentChrome.itemDivider(theme),
        itemBuilder: (context, index) {
          if (index == items.length) return _commentsFooter(theme);
          return _thread(context, theme, items[index]);
        },
      ),
    );
    if (!TranslationService.supported) return list;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 6, 2),
            child: _translateCommentsButton(theme),
          ),
        ),
        Expanded(child: list),
      ],
    );
  });

  /// Translate the comments not in a language the viewer reads, on the
  /// device; again, back to the originals (the bilibili page has the same).
  Widget _translateCommentsButton(ThemeData theme) {
    final translator = controller.commentTranslator;
    return Obx(() {
      final on = translator.enabled.value;
      final done = translator.done.value;
      final total = translator.total.value;
      final label = !on
          ? '翻译'
          : done < total
          ? '翻译中 $done/$total'
          : '原文';
      final color = theme.colorScheme.secondary;
      return TextButton.icon(
        onPressed: () async {
          if (!on && !await TranslateEntry.ensureModel(context)) return;
          translator.toggleTexts(controller.loadedCommentTexts);
        },
        icon: Icon(Icons.translate, size: 16, color: color),
        label: Text(label, style: TextStyle(fontSize: 13, color: color)),
      );
    });
  }

  /// What the bilibili list puts at the bottom: loading, the end, or the
  /// reason the next page did not arrive.
  Widget _commentsFooter(ThemeData theme) => Obx(() {
    final error = controller.commentsError.value;
    if (error == null && controller.hasMoreComments) {
      // reaching this row means the list has been scrolled to its end
      WidgetsBinding.instance.addPostFrameCallback(
        (_) => controller.loadMoreComments(),
      );
    }
    return CommentChrome.pagingFooter(
      theme,
      isEnd: !controller.hasMoreComments,
      error: error,
      onRetry: controller.retryComments,
    );
  });

  /// A top-level comment with a preview of its replies under it, the way
  /// the bilibili page shows them: a rounded block, the first few replies as
  /// `name: text`, then 「共 N 条回复」. Tapping anywhere opens the thread.
  /// [host] is the row's own context, which is below the comment pane's
  /// MiniScaffold — the State's own context is above it, and using that
  /// would quietly send the detail back to being a window-wide route.
  Widget _thread(BuildContext host, ThemeData theme, YtComment comment) {
    // asking here means asking when the row is built, which is when it is
    // about to be seen — YouTube sends no replies with the comments, so a
    // preview costs one request per thread and twenty at once is not a page
    // opening, it is a page hanging
    controller.ensureRepliesPreview(comment);
    void more() => _commentMenu(comment);
    return Material(
      type: MaterialType.transparency,
      child: InkWell(
        // the whole row opens the thread and long-press opens the menu,
        // exactly as on the bilibili item — a comment used to be inert
        // unless it happened to have replies
        onTap: () => _openThread(host, comment),
        onLongPress: more,
        onSecondaryTap: PlatformUtils.isMobile ? null : more,
        child: Padding(
          padding: CommentChrome.itemPadding,
          child: Obx(() {
            // the preview's replies change as their translations arrive
            CommentTranslator.revision.value;
            final loaded = controller.replies[comment.commentId];
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _comment(theme, comment),
                if (comment.hasReplies)
                  Padding(
                    padding: const EdgeInsets.only(top: 5, bottom: 12),
                    child: _replyPreview(host, theme, comment, loaded),
                  ),
              ],
            );
          }),
        ),
      ),
    );
  }

  /// 复制全部 / 自由复制 — what the bilibili long-press menu offers that a
  /// logged-out YouTube can also do. 删除 / 举报 / 置顶 need an account.
  void _commentMenu(YtComment comment) {
    showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      constraints: BoxConstraints(
        maxWidth: math.min(640, MediaQuery.sizeOf(context).shortestSide),
      ),
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            ListTile(
              minLeadingWidth: 0,
              leading: const Icon(Icons.copy_all_outlined, size: 19),
              title: const Text('复制全部', style: TextStyle(fontSize: 14)),
              onTap: () {
                Get.back();
                Utils.copyText(comment.content);
              },
            ),
            ListTile(
              minLeadingWidth: 0,
              leading: const Icon(Icons.copy_outlined, size: 19),
              title: const Text('自由复制', style: TextStyle(fontSize: 14)),
              onTap: () {
                Get.back();
                _freeCopy(comment.content);
              },
            ),
            if (comment.authorChannelId?.isNotEmpty == true)
              ListTile(
                minLeadingWidth: 0,
                leading: const Icon(Icons.person_outline, size: 19),
                title: const Text('查看频道', style: TextStyle(fontSize: 14)),
                onTap: () {
                  Get
                    ..back()
                    ..toNamed(
                      '/ytChannel',
                      parameters: {'id': comment.authorChannelId!},
                    );
                },
              ),
          ],
        ),
      ),
    );
  }

  void _freeCopy(String message) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      constraints: const BoxConstraints.tightFor(width: 380),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
        child: SelectionArea(
          child: SingleChildScrollView(child: Text(message)),
        ),
      ),
    ),
  );

  /// bilibili's preview block: same indent, same rounded surface, same
  /// one-line-per-reply shape, and each row its own tap target.
  Widget _replyPreview(
    BuildContext host,
    ThemeData theme,
    YtComment comment,
    List<YtComment>? loaded,
  ) {
    const previewCount = 3;
    final shown = loaded == null
        ? const <YtComment>[]
        : loaded.take(previewCount).toList();
    // YouTube's own label is in the response's language ('962 replies'),
    // which is not this interface's. The number is the part worth keeping —
    // including when it is abbreviated ('1.2K'), which is exactly the case
    // the numeric replyCount reports as 0 rather than inventing a figure.
    final counted = comment.replyCountText == null
        ? null
        : RegExp(
            r'[\d][\d.,]*\s*[KMB]?',
            caseSensitive: false,
          ).firstMatch(comment.replyCountText!)?.group(0);
    final label = counted != null
        ? '共 $counted 条回复'
        : comment.replyCount > 0
        ? '共 ${comment.replyCount} 条回复'
        : '查看回复';
    // the count row is bilibili's "there are more than these" row: it is not
    // shown when the preview already is the whole thread
    final loading =
        loaded == null && controller.repliesLoading.contains(comment.commentId);
    final extraRow =
        loaded == null ||
        loading ||
        loaded.length > shown.length ||
        controller.hasMoreReplies(comment.commentId);
    final length = shown.length + (extraRow ? 1 : 0);
    return Padding(
      padding: const EdgeInsets.only(
        left: CommentChrome.previewIndent,
        right: 4,
      ),
      child: Material(
        animationDuration: Duration.zero,
        color: theme.colorScheme.onInverseSurface,
        borderRadius: const BorderRadius.all(
          Radius.circular(CommentChrome.previewRadiusValue),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final (index, reply) in shown.indexed)
              InkWell(
                borderRadius: CommentChrome.previewRadius(index, length),
                onTap: () => _openThread(host, comment),
                child: Padding(
                  padding: CommentChrome.previewPadding(index, length),
                  child: Text.rich(
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    TextSpan(
                      style: TextStyle(
                        height: 1.6,
                        fontSize: 14,
                        color: theme.colorScheme.onSurface.withValues(
                          alpha: 0.85,
                        ),
                      ),
                      children: [
                        TextSpan(
                          text: reply.author,
                          style: TextStyle(color: theme.colorScheme.primary),
                        ),
                        if (reply.authorIsUploader) ...[
                          const TextSpan(text: ' '),
                          const WidgetSpan(
                            alignment: PlaceholderAlignment.middle,
                            child: PBadge(
                              text: 'UP',
                              size: PBadgeSize.small,
                              isStack: false,
                              fontSize: 9,
                              textScaleFactor: 1,
                            ),
                          ),
                        ],
                        const TextSpan(text: ': '),
                        TextSpan(
                          text:
                              controller.commentTranslator.textFor(
                                reply.commentId,
                              ) ??
                              reply.content,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            if (extraRow)
              InkWell(
                borderRadius: CommentChrome.previewRadius(length - 1, length),
                onTap: () => _openThread(host, comment),
                child: Padding(
                  padding: CommentChrome.previewPadding(length - 1, length),
                  child: Row(
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.primary,
                        ),
                      ),
                      if (loading) ...[
                        const SizedBox(width: 8),
                        const SizedBox(
                          width: 10,
                          height: 10,
                          child: CircularProgressIndicator(strokeWidth: 1.5),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  /// 评论详情. It opens as a sheet inside the comment area's own
  /// [MiniScaffold] — which is what the bilibili page does
  /// (reply/view.dart:245) — so the video stays where it is and, in the
  /// wide layout, the detail stays inside the side panel. It was a route
  /// over the whole window, which is a different thing wearing the same
  /// title.
  ///
  /// [host] must be a context below that MiniScaffold, so it has to come
  /// from the row that was tapped rather than from the page.
  void _openThread(BuildContext host, YtComment comment) {
    final id = comment.commentId;
    controller.ensureRepliesPreview(comment);
    final scaffold = MiniScaffold.maybeOf(host);
    if (scaffold == null) {
      // the intro tab's related shelf has no scaffold of its own; falling
      // back keeps the thread reachable instead of silently doing nothing
      PageUtils.showVideoBottomSheet(
        host,
        maxWidth: 640,
        child: Builder(
          builder: (context) => _threadPanel(context, comment, id),
        ),
      );
      return;
    }
    scaffold.showBottomSheet(
      constraints: const BoxConstraints(),
      (context) => _threadPanel(context, comment, id),
    );
  }

  Widget _threadPanel(BuildContext context, YtComment comment, String id) {
    final theme = Theme.of(context);
    return Material(
      color: theme.canvasColor,
      child: Column(
        children: [
          CommentChrome.panelHeader(theme, title: '评论详情'),
          Expanded(child: _threadBody(theme, comment, id)),
        ],
      ),
    );
  }

  Widget _threadBody(ThemeData theme, YtComment comment, String id) =>
      refreshIndicator(
        onRefresh: () => controller.refreshReplies(comment),
        child: Obx(() {
          final loaded = controller.replies[id];
          final loading = controller.repliesLoading.contains(id);
          final error = controller.repliesError[id];
          final replies = loaded ?? const <YtComment>[];

          // the head comment, then a thick rule, then the count line — the
          // order bilibili's panel puts them in
          final head = <Widget>[
            Padding(
              padding: CommentChrome.itemPadding,
              child: _comment(theme, comment),
            ),
            CommentChrome.thickDivider(theme),
            CommentChrome.countLine(_replyCountLine(comment, replies.length)),
          ];

          if (error != null && replies.isEmpty) {
            return ListView(
              children: [
                ...head,
                SizedBox(
                  height: 300,
                  child: HttpError(
                    isSliver: false,
                    errMsg: error,
                    onReload: () => controller.refreshReplies(comment),
                  ),
                ),
              ],
            );
          }

          if (replies.isEmpty && loading) {
            return ListView(
              children: [
                ...head,
                ...CommentChrome.skeletons(CommentChrome.panelSkeletons),
              ],
            );
          }

          return ListView.separated(
            padding: EdgeInsets.zero,
            itemCount: head.length + replies.length + 1,
            separatorBuilder: (context, index) => index < head.length - 1
                ? const SizedBox.shrink()
                : CommentChrome.itemDivider(theme),
            itemBuilder: (context, index) {
              if (index < head.length) return head[index];
              final replyIndex = index - head.length;
              if (replyIndex < replies.length) {
                // full-size items, as in bilibili's panel: a reply here is
                // not a footnote to the comment above it
                return Padding(
                  padding: CommentChrome.itemPadding,
                  child: _comment(theme, replies[replyIndex]),
                );
              }
              if (controller.hasMoreReplies(id) && !loading) {
                // reaching this row means the end of the loaded replies is
                // on screen, which is how the comment list pages too
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => controller.loadMoreReplies(id),
                );
              }
              return CommentChrome.pagingFooter(
                theme,
                isEnd: !loading && !controller.hasMoreReplies(id),
                error: error,
                onRetry: () => controller.refreshReplies(comment),
                emptyText: replies.isEmpty ? '没有取到回复' : '没有更多了',
              );
            },
          );
        }),
      );

  /// 「相关回复共N条」, preferring YouTube's own total over how many have
  /// been loaded so far — the loaded count would climb as you scroll and
  /// read as the thread growing.
  static String _replyCountLine(YtComment comment, int loaded) {
    final counted = comment.replyCountText == null
        ? null
        : RegExp(
            r'[\d][\d.,]*\s*[KMB]?',
            caseSensitive: false,
          ).firstMatch(comment.replyCountText!)?.group(0);
    if (counted != null) return '相关回复共 $counted 条';
    if (comment.replyCount > 0) return '相关回复共 ${comment.replyCount} 条';
    return loaded > 0 ? '相关回复共 $loaded 条' : '相关回复';
  }

  Widget _comment(
    ThemeData theme,
    YtComment comment, {
    double avatar = 34,
  }) {
    void openChannel() {
      final channelId = comment.authorChannelId;
      if (channelId == null || channelId.isEmpty) return;
      feedBack();
      Get.toNamed('/ytChannel', parameters: {'id': channelId});
    }

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: openChannel,
          child: NetworkImgLayer(
            type: ImageType.avatar,
            width: avatar,
            height: avatar,
            src: comment.authorAvatar?.url,
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // name on one line, time on the next — the shape the bilibili
              // item uses. Side by side, a 13pt name and an 11pt time sit on
              // different baselines and read as misaligned, which is what
              // they were.
              GestureDetector(
                onTap: openChannel,
                behavior: HitTestBehavior.opaque,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            comment.author,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              color: comment.authorIsUploader
                                  ? theme.colorScheme.primary
                                  : theme.colorScheme.outline,
                            ),
                          ),
                        ),
                        if (comment.authorIsUploader) ...[
                          const SizedBox(width: 6),
                          const PBadge(
                            text: 'UP',
                            size: PBadgeSize.small,
                            isStack: false,
                            fontSize: 9,
                            textScaleFactor: 1,
                          ),
                        ],
                        if (comment.isPinned) ...[
                          const SizedBox(width: 6),
                          Icon(
                            Icons.push_pin_outlined,
                            size: 12,
                            color: theme.colorScheme.outline,
                          ),
                        ],
                      ],
                    ),
                    if (comment.publishedText case final posted?)
                      Text(
                        posted,
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 4),
              // not selectable: the row's own tap opens the thread and its
              // long-press opens 复制全部 / 自由复制, which is how the
              // bilibili item does copying. A SelectableText here would eat
              // both gestures.
              Obx(() {
                CommentTranslator.revision.value;
                final translator = controller.commentTranslator;
                final failed = translator.textFailed(comment.commentId);
                return Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text:
                            translator.textFor(comment.commentId) ??
                            comment.content,
                      ),
                      if (failed)
                        TextSpan(
                          text: '  未能翻译',
                          style: TextStyle(
                            fontSize: 12,
                            color: theme.colorScheme.outline,
                          ),
                        ),
                    ],
                  ),
                  style: const TextStyle(fontSize: 14, height: 1.75),
                );
              }),
              if (comment.likeCountText case final likes?)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(
                    children: [
                      Icon(
                        Icons.thumb_up_outlined,
                        size: 14,
                        color: theme.colorScheme.outline,
                      ),
                      const SizedBox(width: 5),
                      Text(
                        likes,
                        style: TextStyle(
                          fontSize: 12,
                          color: theme.colorScheme.outline,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
