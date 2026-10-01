/// LibrePili: a YouTube comment section's state — the comments, their
/// paging, the replies under each thread and their translation.
///
/// It was the video page's. A post on a channel's 帖子 tab has the same
/// comment section (the same payloads, the same thread tokens, measured
/// 2026-09-30), reached through `browse` instead of `next`; rather than a
/// second copy for posts, both pages mix this in and say only where their
/// comments come from.
library;

import 'dart:async';

import 'package:PiliPlus/pages/youtube/common/yt_list_controller.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/services/youtube/youtube.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding;
import 'package:get/get.dart';

mixin YtCommentsMixin on GetxController {
  YtSourceRouter get router;

  /// What the translator keys this section's texts under (`yt:$videoId`).
  String get commentsKey;

  /// A fresh first-page token, for pull-to-refresh: the one held belongs to
  /// a position in a list that is about to be thrown away.
  Future<YtRoutedResult<String?>> fetchCommentsBootstrap();

  /// One page of comments, or of a thread's replies.
  Future<YtResult<YtPage<YtComment>>> fetchCommentsPage(
    YouTubeVideoSource source,
    String token,
  );

  /// The words a failed comment request shows.
  String commentsMessageFor(YtVerdict verdict) => ytMessageFor(verdict);

  /// The first page's token, once the page that carries it has landed.
  set commentsToken(String? token) => _commentsToken.value = token;

  @override
  void onInit() {
    super.onInit();
    // comments loaded while translation is on are translated too
    // (user 2026-09-25, 1A)
    ever(comments, (_) => translateLoadedComments());
  }

  @override
  void onClose() {
    CommentTranslator.release(commentsKey);
    super.onClose();
  }

  final comments = <YtComment>[].obs;
  final commentsLoading = false.obs;

  /// Null means "no more": either the video has comments off, or the last
  /// page was the last one.
  ///
  /// Observable, because the list's footer reads it: while it was a plain
  /// field, nothing told the footer's Obx to rebuild when a page turned out
  /// to be the last one, and the trailing spinner had no reason to go away.
  final _commentsToken = RxnString();
  // observable: `commentsPending` is read inside an Obx, and a plain bool
  // there is the same trap the continuation token was in
  final _commentsStarted = false.obs;

  /// Why the comments are not here, when they are not.
  ///
  /// Without it a failed request emptied into 「暂无评论」, which is what a
  /// video with comments turned off says — the two were indistinguishable,
  /// and since the attempt had already been marked as made, nothing ever
  /// tried again.
  final commentsError = RxnString();

  bool get hasMoreComments => _commentsToken.value != null;

  /// Fetches one page. The first call is made as soon as the token exists,
  /// so the tab is already populated when it is opened.
  Future<void> loadMoreComments() async {
    final token = _commentsToken.value;
    if (token == null || commentsLoading.value) return;
    commentsLoading.value = true;
    final result = await router.run((s) => fetchCommentsPage(s, token));
    if (isClosed) return;
    commentsLoading.value = false;
    if (result.ok && result.value != null) {
      comments.addAll(result.value!.items);
      _commentsToken.value = result.value!.continuation;
      commentsError.value = null;
    } else {
      // the token is kept: the page that failed is the page to retry
      commentsError.value = commentsMessageFor(result.verdict);
    }
  }

  void ensureCommentsStarted() {
    // The latch must not close on an attempt that could not have worked.
    // Opening the 评论 tab while the video is still loading called this
    // before the token existed: it did nothing, marked the comments as
    // started, and the call that arrives *with* the token then found the
    // latch already closed — so the tab stayed empty for good.
    if (_commentsStarted.value || _commentsToken.value == null) return;
    _commentsStarted.value = true;
    loadMoreComments();
  }

  /// True while there is nothing to show and nothing has failed: either a
  /// page is in flight or the token it needs has not arrived yet. Both are
  /// "wait", and neither is 「暂无评论」, which is what a video with
  /// comments turned off says.
  bool get commentsPending =>
      comments.isEmpty &&
      commentsError.value == null &&
      (commentsLoading.value || !_commentsStarted.value);

  /// Retries the page that failed, without losing the ones that did not.
  Future<void> retryComments() {
    commentsError.value = null;
    return loadMoreComments();
  }

  /// Pull to refresh: back to the first page, which means a fresh bootstrap
  /// token — the one this page holds belongs to a position in a list that is
  /// about to be thrown away.
  Future<void> refreshComments() async {
    if (commentsLoading.value) return;
    commentsLoading.value = true;
    final result = await fetchCommentsBootstrap();
    if (isClosed) {
      return;
    }
    commentsLoading.value = false;
    if (!result.ok) {
      commentsError.value = commentsMessageFor(result.verdict);
      return;
    }
    comments.clear();
    replies.clear();
    repliesLoading.clear();
    _moreReplies.clear();
    commentsError.value = null;
    _commentsToken.value = result.value;
    await loadMoreComments();
  }

  // ------------------------------------------------------------- replies
  //
  // A thread's replies are another page from the same endpoint, reached by
  // the token that came with the comment. They are kept per comment rather
  // than spliced into `comments`: a reply is not a comment that happens to
  // be lower down, and the list has to be able to collapse again.

  final replies = <String, RxList<YtComment>>{}.obs;
  final repliesLoading = <String>{}.obs;
  final _moreReplies = <String, String?>{};

  bool hasMoreReplies(String commentId) => _moreReplies[commentId] != null;

  /// Fetches the first page of a thread's replies so the list can show a
  /// preview of them, the way the bilibili one does.
  ///
  /// YouTube sends no replies with the comments — only a token and a count —
  /// so a preview is a request per thread. It is made when the row is built,
  /// which is when it is about to be seen, rather than for all twenty at
  /// once when the page opens.
  void ensureRepliesPreview(YtComment comment) {
    if (!comment.hasReplies) return;
    final id = comment.commentId;
    if (replies.containsKey(id) || repliesLoading.contains(id)) return;
    // This is called from a row's build. Marking the thread as loading
    // touches an observable, and doing that while the frame is being built
    // is a change-during-build — the error lands in an unawaited future and
    // vanishes, which is exactly what it did: no request, no entry, and
    // nothing on screen to say why. It waits for the frame to end instead.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (isClosed) return;
      if (replies.containsKey(id) || repliesLoading.contains(id)) return;
      unawaited(_fetchReplies(id, comment.replyToken));
    });
  }

  /// Pull to refresh inside a thread: back to its first page.
  Future<void> refreshReplies(YtComment comment) async {
    final id = comment.commentId;
    if (repliesLoading.contains(id)) return;
    replies
      ..remove(id)
      ..refresh();
    _moreReplies.remove(id);
    repliesError.remove(id);
    await _fetchReplies(id, comment.replyToken);
  }

  /// Why a thread's replies are not here, when they are not. Keyed by
  /// comment id, so one failed thread does not speak for the others.
  final repliesError = <String, String>{}.obs;

  Future<void> loadMoreReplies(String commentId) =>
      _fetchReplies(commentId, _moreReplies[commentId]);

  Future<void> _fetchReplies(String commentId, String? token) async {
    if (token == null || repliesLoading.contains(commentId)) return;
    repliesLoading.add(commentId);
    final result = await router.run((s) => fetchCommentsPage(s, token));
    if (isClosed) return;
    repliesLoading.remove(commentId);
    if (result.ok && result.value != null) {
      (replies[commentId] ??= <YtComment>[].obs).addAll(result.value!.items);
      translateLoadedComments();
      replies.refresh();
      _moreReplies[commentId] = result.value!.continuation;
      repliesError.remove(commentId);
    } else {
      // an empty list rather than nothing: the thread is open and has to say
      // something, and "nothing loaded" must not look like "not tried yet"
      replies[commentId] ??= <YtComment>[].obs;
      replies.refresh();
      _moreReplies[commentId] = null;
      repliesError[commentId] = commentsMessageFor(result.verdict);
    }
  }

  /// LibrePili: this section's on-device comment translation
  /// (research/comment-translation-design-2026-09-25.md, E4).
  late final commentTranslator = CommentTranslator.of(commentsKey);

  /// The comments loaded, and the replies previewed, as the translator
  /// takes them.
  Iterable<(String, String)> get loadedCommentTexts => [
    for (final c in comments) (c.commentId, c.content),
    for (final list in replies.values)
      for (final r in list) (r.commentId, r.content),
  ];

  void translateLoadedComments() =>
      commentTranslator.addTexts(loadedCommentTexts);
}
