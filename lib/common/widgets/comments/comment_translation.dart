/// LibrePili: a comment's on-device translation as both comment lists show
/// it — the 翻译 / 原文 button on each comment, and the text block that
/// puts the translation first and the original under it (user 2026-10-01).
///
/// bilibili's comment and YouTube's are rendered by their own code (a
/// bilibili comment's text is a protobuf of emotes, names and links; a
/// YouTube one's is a string), so what is shared here is everything around
/// that rendering: which parts are shown, in what order and style, the
/// button and its states. Each side hands in how to draw its own text
/// ([CommentTextBuilder]) and how to ask its [CommentTranslator] about one
/// comment. Changing either widget changes both lists — the same rule as
/// [CommentChrome], for the same reason.
///
/// Any other comment list can take them the same way: a [CommentTranslator]
/// of its own (`CommentTranslator.of(key)`, released with the list), its
/// comments handed to `addTexts` / `add` as they load, and these two
/// widgets on each item.
library;

import 'package:PiliPlus/common/widgets/comments/comment_chrome.dart';
import 'package:PiliPlus/models/common/comment_translation_display.dart';
import 'package:PiliPlus/pages/video/widgets/translate_entry.dart';
import 'package:PiliPlus/services/translate/comment_translator.dart';
import 'package:PiliPlus/services/translate/translation_service.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// Draws one part of a comment's text: its translation ([translated]) or
/// its original, in [style]. [first] is the part on top — the one a
/// bilibili comment puts its TOP badge in front of.
typedef CommentTextBuilder = Widget Function(
  BuildContext context, {
  required bool translated,
  required bool first,
  required TextStyle style,
});

/// A comment's text as its [translator] says it is to be shown: the
/// original; or the translation, with the original under it, smaller and
/// paler, unless 评论翻译显示 is 仅译文. Emotes, names, links and times
/// are the builder's to render, so they work in both parts.
class CommentTranslatedText extends StatelessWidget {
  const CommentTranslatedText({
    super.key,
    required this.translator,
    required this.id,
    required this.builder,
  });

  /// The list's translator; none, and the text is only ever the original.
  final CommentTranslator? translator;

  /// The comment's id, as [translator] keeps it.
  final String id;

  final CommentTextBuilder builder;

  /// The comment's own text.
  static const bodyStyle = TextStyle(
    fontSize: CommentChrome.bodyFontSize,
    height: CommentChrome.bodyHeight,
  );

  /// The original under a translation: there to check the translation
  /// against, so it gives way to it.
  static TextStyle originalStyle(ThemeData theme) => TextStyle(
    fontSize: CommentChrome.bodyFontSize - 1,
    height: 1.6,
    color: theme.colorScheme.outline,
  );

  @override
  Widget build(BuildContext context) {
    final translator = this.translator;
    if (translator == null) {
      return builder(context, translated: false, first: true, style: bodyStyle);
    }
    return Obx(() {
      // every change to what a comment shows bumps it
      CommentTranslator.revision.value;
      final theme = Theme.of(context);
      if (!translator.showsTranslation(id)) {
        final original = builder(
          context,
          translated: false,
          first: true,
          style: bodyStyle,
        );
        if (!translator.failed(id)) return original;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            original,
            Text(
              '未能翻译',
              style: TextStyle(fontSize: 12, color: theme.colorScheme.outline),
            ),
          ],
        );
      }
      final translation = builder(
        context,
        translated: true,
        first: true,
        style: bodyStyle,
      );
      if (CommentTranslator.display ==
          CommentTranslationDisplay.translationOnly) {
        return translation;
      }
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          translation,
          const SizedBox(height: 2),
          builder(
            context,
            translated: false,
            first: false,
            style: originalStyle(theme),
          ),
        ],
      );
    });
  }
}

/// The 翻译 / 原文 button on one comment: shown only on a comment in a
/// language the viewer does not read, it turns that comment alone the
/// other way ([CommentTranslator.toggleReply] / `toggleText`) and leaves the
/// list's switch as it is. A small spinner while its translation is made.
class CommentTranslateButton extends StatelessWidget {
  const CommentTranslateButton({
    super.key,
    required this.translator,
    required this.id,
    required this.needs,
    required this.onToggle,
  });

  final CommentTranslator? translator;

  /// The comment's id, as [translator] keeps it.
  final String id;

  /// Whether the comment needs translating (`needsReply` / `needsText`).
  final bool Function(CommentTranslator translator) needs;

  /// Turns the comment the other way (`toggleReply` / `toggleText`).
  final void Function(CommentTranslator translator) onToggle;

  /// Whether a comment of [translator]'s gets the button, for a row that
  /// lays out other buttons around it.
  static bool shownFor(
    CommentTranslator? translator,
    bool Function(CommentTranslator translator) needs,
  ) => translator != null && TranslationService.supported && needs(translator);

  static const _buttonStyle = ButtonStyle(
    visualDensity: VisualDensity.compact,
    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    padding: WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 4)),
  );

  @override
  Widget build(BuildContext context) {
    final translator = this.translator;
    if (translator == null || !shownFor(translator, needs)) {
      return const SizedBox.shrink();
    }
    final colorScheme = ColorScheme.of(context);
    return Obx(() {
      CommentTranslator.revision.value;
      final showing = translator.shows(id);
      final pending = translator.pending(id);
      final color = showing
          ? colorScheme.primary
          : colorScheme.outline.withValues(alpha: 0.8);
      return SizedBox(
        height: 32,
        child: TextButton(
          style: _buttonStyle,
          onPressed: () async {
            if (!showing && !await TranslateEntry.ensureModel(context)) {
              return;
            }
            onToggle(translator);
          },
          child: Row(
            spacing: 3,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (pending)
                SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    color: color,
                  ),
                )
              else
                Icon(Icons.translate, size: 16, color: color),
              Text(
                pending
                    ? '翻译中'
                    : showing
                    ? '原文'
                    : '翻译',
                style: TextStyle(height: 1, fontSize: 12, color: color),
              ),
            ],
          ),
        ),
      );
    });
  }
}
