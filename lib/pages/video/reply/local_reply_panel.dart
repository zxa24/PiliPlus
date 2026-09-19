import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/common/widgets/image/network_img_layer.dart';
import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: read-only comments saved with a download
/// (`<base>.comments.json`, format `librepili-comments-1`).
class LocalReplyPanel extends StatefulWidget {
  const LocalReplyPanel({super.key, required this.path});

  final String path;

  @override
  State<LocalReplyPanel> createState() => _LocalReplyPanelState();
}

class _LocalReplyPanelState extends State<LocalReplyPanel>
    with AutomaticKeepAliveClientMixin {
  late final Future<Map<String, dynamic>> _data = _load();

  @override
  bool get wantKeepAlive => true;

  Future<Map<String, dynamic>> _load() async =>
      jsonDecode(await File(widget.path).readAsString())
          as Map<String, dynamic>;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final theme = Theme.of(context);
    return FutureBuilder<Map<String, dynamic>>(
      future: _data,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Center(child: Text('评论文件读取失败：${snapshot.error}'));
        }
        if (!snapshot.hasData) {
          return const Center(child: CircularProgressIndicator());
        }
        final data = snapshot.data!;
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
            return _CommentTile(comment: comments[index - 1]);
          },
        );
      },
    );
  }
}

class _CommentTile extends StatefulWidget {
  const _CommentTile({required this.comment});

  final Map comment;

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
        NetworkImgLayer(
          src: c['avatar'] as String?,
          width: avatarSize,
          height: avatarSize,
          type: .avatar,
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
              SelectableText(
                '${c['content'] ?? ''}',
                style: const TextStyle(fontSize: 14, height: 1.5),
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
}
