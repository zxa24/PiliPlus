import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:PiliPlus/common/widgets/autospace_text.dart';
import 'package:PiliPlus/common/widgets/comments/comment_chrome.dart';
import 'package:PiliPlus/common/widgets/scaffold/mini_scaffold.dart';
import 'package:PiliPlus/common/widgets/simple_colored_box.dart';
import 'package:PiliPlus/common/widgets/sliver/sliver_floating_header.dart';
import 'package:PiliPlus/pages/video/reply/local_comments.dart';
import 'package:PiliPlus/pages/video/reply/widgets/reply_item_grpc.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:easy_debounce/easy_throttle.dart';
import 'package:fixnum/fixnum.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// LibrePili: read-only comments saved with a download
/// (`<base>.comments.json`). Fully offline. A file of format 2 has each
/// comment as bilibili sent it: shown with the online comment's widget
/// (ReplyItemGrpc, read-only), its avatar, pictures and emotes the copies
/// saved with it ([LocalComments]). One of format 1 has the plain words
/// only, shown as plainly as they are.
class LocalReplyPanel extends StatefulWidget {
  const LocalReplyPanel({super.key, required this.path, this.heroTag});

  final String path;

  /// The video page's, for a time in a comment to seek its player.
  final String? heroTag;

  @override
  State<LocalReplyPanel> createState() => _LocalReplyPanelState();
}

class _LocalReplyPanelState extends State<LocalReplyPanel>
    with AutomaticKeepAliveClientMixin {
  late final Future<({Map<String, dynamic> data, LocalComments? local})> _data =
      _load();

  @override
  bool get wantKeepAlive => true;

  /// Read and parsed once, not on every build; a format-2 file that does
  /// not decode (bad base64 or protobuf) shows as format 1, its plain
  /// words, not an error.
  Future<({Map<String, dynamic> data, LocalComments? local})> _load() async {
    final data = jsonDecode(
      await File(widget.path).readAsString(),
    ) as Map<String, dynamic>;
    LocalComments? local;
    try {
      local = LocalComments.parse(data, p.dirname(widget.path));
    } catch (_) {}
    return (data: data, local: local);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return FutureBuilder<({Map<String, dynamic> data, LocalComments? local})>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('评论文件读取失败：${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final (:data, :local) = snapshot.data!;
        if (local != null) {
          return _LocalCommentList(local: local, heroTag: widget.heroTag);
        }
        final comments = (data['comments'] as List).cast<Map>();
        final fetched = DateTime.tryParse('${data['fetchedAt']}');
        return ListView.builder(
          padding: const EdgeInsets.only(bottom: 80),
          itemCount: comments.length + 1,
          itemBuilder: (context, index) {
            if (index == 0) {
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '离线评论：下载时保存的 ${comments.length} 条热门评论'
                  '${fetched == null ? '' : '（${fetched.year}-${fetched.month.toString().padLeft(2, '0')}-${fetched.day.toString().padLeft(2, '0')}）'}',
                  style: TextStyle(
                    fontSize: 12,
                    color: theme.colorScheme.outline,
                  ),
                ),
              );
            }
            return _CommentTile(
              comment: comments[index - 1],
              dir: p.dirname(widget.path),
            );
          },
        );
      },
    );
  }
}

String _date(DateTime at) =>
    '${at.year}-${at.month.toString().padLeft(2, '0')}-${at.day.toString().padLeft(2, '0')}';

/// The online list, of what was saved.
class _LocalCommentList extends StatelessWidget {
  const _LocalCommentList({required this.local, required this.heroTag});

  final LocalComments local;
  final String? heroTag;

  void _open(BuildContext context, LocalComment comment) {
    EasyThrottle.throttle('replyReply', const Duration(milliseconds: 500), () {
      Widget panel(BuildContext context) => _LocalReplyDetail(
        comment: comment,
        upMid: local.upMid,
        heroTag: heroTag,
      );
      // as the online list: over the comments, in the page's own scaffold
      if (MiniScaffold.maybeOf(context) case final scaffold?) {
        scaffold.showBottomSheet(constraints: const BoxConstraints(), panel);
      } else {
        showModalBottomSheet<void>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          builder: panel,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final comments = local.comments;
    final bottom = MediaQuery.viewPaddingOf(context).bottom;
    final fetchedAt = local.fetchedAt;
    return CustomScrollView(
      physics: const AlwaysScrollableScrollPhysics(),
      key: const PageStorageKey(_LocalCommentList),
      slivers: [
        SliverFloatingHeaderWidget(
          backgroundColor: colorScheme.surface,
          child: Padding(
            padding: const .fromLTRB(12, 2.5, 12, 2.5),
            child: SizedBox(
              height: 32,
              child: Row(
                children: [
                  const Text('热门评论', style: TextStyle(fontSize: 13)),
                  const Spacer(),
                  Text(
                    '下载时保存的 ${comments.length} 条'
                    '${fetchedAt == null ? '' : '（${_date(fetchedAt)}）'}',
                    style: TextStyle(fontSize: 12, color: colorScheme.outline),
                  ),
                ],
              ),
            ),
          ),
        ),
        SliverList.builder(
          itemCount: comments.length + 1,
          itemBuilder: (context, index) {
            if (index == comments.length) {
              return CommentChrome.pagingFooter(
                theme,
                isEnd: true,
                margin: .only(bottom: bottom),
              );
            }
            final comment = comments[index];
            return ReplyItemGrpc(
              replyItem: comment.root,
              replyLevel: 1,
              readOnly: true,
              upMid: local.upMid,
              getTag: heroTag == null ? null : () => heroTag,
              replyReply: (_, _) => _open(context, comment),
            );
          },
        ),
      ],
    );
  }
}

/// 评论详情 of a saved comment: it, then the replies saved with it.
class _LocalReplyDetail extends StatelessWidget {
  const _LocalReplyDetail({
    required this.comment,
    required this.upMid,
    required this.heroTag,
  });

  final LocalComment comment;
  final Int64? upMid;
  final String? heroTag;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final root = comment.root;
    final replies = comment.replies;
    final total = math.max(root.count.toInt(), replies.length);
    final getTag = heroTag == null ? null : () => heroTag;
    return SimpleColoredBox(
      color: theme.canvasColor,
      child: Column(
        children: [
          CommentChrome.panelHeader(theme, title: '评论详情'),
          Expanded(
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: ReplyItemGrpc(
                    replyItem: root,
                    replyLevel: 2,
                    needDivider: false,
                    readOnly: true,
                    upMid: upMid,
                    getTag: getTag,
                  ),
                ),
                SliverToBoxAdapter(child: CommentChrome.thickDivider(theme)),
                SliverToBoxAdapter(
                  child: CommentChrome.countLine(
                    '相关回复共${NumUtils.numFormat(total)}条',
                    trailing: replies.length < total
                        ? Text(
                            '已保存 ${replies.length} 条',
                            style: TextStyle(
                              fontSize: 12,
                              color: theme.colorScheme.outline,
                            ),
                          )
                        : null,
                  ),
                ),
                SliverList.builder(
                  itemCount: replies.length + 1,
                  itemBuilder: (context, index) {
                    if (index == replies.length) {
                      return CommentChrome.pagingFooter(
                        theme,
                        isEnd: true,
                        margin: .only(
                          bottom: MediaQuery.viewPaddingOf(context).bottom,
                        ),
                      );
                    }
                    return ReplyItemGrpc(
                      replyItem: replies[index],
                      replyLevel: 2,
                      readOnly: true,
                      upMid: upMid,
                      getTag: getTag,
                    );
                  },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({required this.comment, required this.dir});

  final Map comment;

  /// Folder of the comments file; image paths are relative to it.
  final String dir;

  @override
  State<_CommentTile> createState() => _CommentTileState();
}

class _CommentTileState extends State<_CommentTile> {
  static const _collapsed = 3;
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final c = widget.comment;
    final replies = ((c['replies'] as List?) ?? const []).cast<Map>();
    final shown = _expanded ? replies : replies.take(_collapsed).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _body(theme, c, avatarSize: 34),
          if (replies.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(left: 44, top: 6),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 6),
              decoration: BoxDecoration(
                color: theme.colorScheme.onInverseSurface,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final r in shown)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: _body(theme, r, avatarSize: 22),
                    ),
                  if (replies.length > _collapsed && !_expanded)
                    TextButton(
                      onPressed: () => setState(() => _expanded = true),
                      child: Text('展开其余 ${replies.length - _collapsed} 条回复'),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _body(ThemeData theme, Map c, {required double avatarSize}) {
    final outline = theme.colorScheme.outline;
    final ctime = c['ctime'] as int? ?? 0;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // no avatar: it would be a network request
        CircleAvatar(
          radius: avatarSize / 2,
          backgroundColor: theme.colorScheme.onInverseSurface,
          child: Icon(Icons.person, size: avatarSize * 0.6, color: outline),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '${c['uname'] ?? ''}',
                style: TextStyle(fontSize: 13, color: outline),
              ),
              const SizedBox(height: 2),
              _content(c),
              if ((c['pictures'] as List?)?.cast<String>() case final pics?
                  when pics.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final pic in pics) _picture(context, pic),
                    ],
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                '${ctime == 0 ? '' : DateFormatUtils.dateFormat(ctime)}'
                '   赞 ${NumUtils.numFormat(c['like'] ?? 0)}'
                '${(c['replyCount'] ?? 0) > 0 ? '   回复 ${c['replyCount']}' : ''}',
                style: TextStyle(fontSize: 12, color: outline),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // nothing outside the download's folder (see [LocalComments.inside])
  File _file(String relative) =>
      File(LocalComments.inside(widget.dir, relative) ?? '');

  static final _emoteReg = RegExp(r'\[[^\[\]]+\]');

  /// Text with the saved emotes inline.
  Widget _content(Map c) {
    const style = TextStyle(fontSize: 14, height: 1.5);
    final text = '${c['content'] ?? ''}';
    final emotes = (c['emotes'] as Map?)?.cast<String, String>();
    if (emotes == null || emotes.isEmpty) {
      return Builder(
        builder: (context) => SelectableText.rich(
          AutospaceText.apply(context, TextSpan(text: text), style: style)
              as TextSpan,
          style: style,
        ),
      );
    }
    final spans = <InlineSpan>[];
    var last = 0;
    for (final m in _emoteReg.allMatches(text)) {
      final local = emotes[m[0]];
      if (local == null) continue;
      if (m.start > last) {
        spans.add(TextSpan(text: text.substring(last, m.start)));
      }
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: Image.file(
            _file(local),
            width: 20,
            height: 20,
            errorBuilder: (_, _, _) => Text(m[0]!),
          ),
        ),
      );
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return AutospaceText.rich(TextSpan(children: spans), style: style);
  }

  Widget _picture(BuildContext context, String relative) {
    final file = _file(relative);
    return GestureDetector(
      onTap: () => showDialog<void>(
        context: context,
        builder: (context) => GestureDetector(
          onTap: Navigator.of(context).pop,
          child: InteractiveViewer(child: Image.file(file)),
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Image.file(
          file,
          width: 96,
          height: 96,
          fit: BoxFit.cover,
          cacheWidth: 288,
          errorBuilder: (_, _, _) => const SizedBox(
            width: 96,
            height: 96,
            child: Icon(Icons.broken_image_outlined),
          ),
        ),
      ),
    );
  }
}
