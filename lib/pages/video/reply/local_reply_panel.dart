import 'dart:convert';
import 'dart:io';

import 'package:PiliPlus/utils/date_utils.dart';
import 'package:PiliPlus/utils/num_utils.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;

/// LibrePili: read-only comments saved with a download
/// (`<base>.comments.json`, format `librepili-comments-1`). Fully offline:
/// no avatars, pictures and emotes come from the files saved with it.
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

  File _file(String relative) => File(p.join(widget.dir, relative));

  static final _emoteReg = RegExp(r'\[[^\[\]]+\]');

  /// Text with the saved emotes inline.
  Widget _content(Map c) {
    const style = TextStyle(fontSize: 14, height: 1.5);
    final text = '${c['content'] ?? ''}';
    final emotes = (c['emotes'] as Map?)?.cast<String, String>();
    if (emotes == null || emotes.isEmpty) {
      return SelectableText(text, style: style);
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
    return Text.rich(TextSpan(children: spans), style: style);
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
