/// LibrePili: the notice a Traditional Chinese translation started without
/// the model shows, once, when the speech turns to another language
/// (oct-pass1-D2): those lines stay in their own words until the model is
/// downloaded, and 下载 asks what any first download asks.
library;

import 'package:PiliPlus/pages/video/widgets/translate_entry.dart';
import 'package:PiliPlus/services/translate/translation_session.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class TranslateModelNotice {
  static const _tag = 'translate-model-offer';

  /// See TranslationService.offerModel. Shown over the page, not in the
  /// player: the player's own controls may be hidden.
  static void show(TranslationSession session) {
    SmartDialog.show(
      tag: _tag,
      keepSingle: true,
      clickMaskDismiss: true,
      usePenetrate: true,
      displayTime: const Duration(seconds: 10),
      alignment: Alignment.bottomCenter,
      builder: (context) {
        final theme = Theme.of(context);
        return ColoredBox(
          color: theme.colorScheme.secondaryContainer,
          child: Padding(
            padding: EdgeInsets.only(
              top: 8,
              left: 20,
              right: 8,
              bottom: MediaQuery.viewPaddingOf(context).bottom + 8,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '后面出现了其他语言，下载翻译模型后可翻译这些内容',
                    style: TextStyle(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                ),
                TextButton(
                  onPressed: () {
                    SmartDialog.dismiss(tag: _tag);
                    // the app's navigator: the dialog asking about the model
                    // is a route, which this overlay has none of
                    final navigator = Get.context;
                    if (navigator == null || !navigator.mounted) return;
                    TranslateEntry.offerModel(navigator);
                  },
                  child: const Text('下载'),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
