/// LibrePili: the subtitle menu, shared by the bilibili and YouTube pages
/// (research/subtitle-switch-design-2026-09-26.md, 9; rows in
/// subtitle_menu.dart).
///
/// By language, the source second: each language row has an icon for the
/// device's subtitle and, when the video has one in that language, the
/// platform's. Tapping the name uses the default source (设置 → 默认来源);
/// tapping an icon, that source for this video only. What is picked is
/// remembered for every video — the menu says so at the top — except a
/// track picked by hand from the video's own list (更多字幕轨…).
library;

import 'package:PiliPlus/models/common/setting_type.dart';
import 'package:PiliPlus/models/common/subtitle_source_preference.dart';
import 'package:PiliPlus/pages/setting/common_setting.dart';
import 'package:PiliPlus/pages/video/widgets/asr_entry.dart';
import 'package:PiliPlus/pages/video/widgets/translate_entry.dart';
import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_choice.dart';
import 'package:PiliPlus/services/subtitle_choice/subtitle_menu.dart';
import 'package:PiliPlus/services/translate/translation_languages.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

abstract final class OnDeviceMenu {
  /// Popup values of the rows that are not languages.
  static const off = -101;
  static const original = -100;
  static const other = -98;
  static const more = -97;
  static const note = -96;
  static const englishModel = -95;

  static const _languageBase = -1000;

  /// Every language that can be translated into, the app's first.
  static List<String> get _languages => [
    ...listedLanguages(null, const []),
    ...otherTranslationLanguages,
  ];

  static int valueOf(String code) => code == 'asr'
      ? original
      : _languageBase - _languages.indexOf(code).clamp(0, 999);

  /// The languages listed by name for [host]: the app's, those kept in the
  /// menu, and the one picked when it is neither.
  static List<String> listedFor(SubtitleMenuHost host) =>
      listedLanguages(host.menuPicked, pinnedTranslationLanguages);

  /// The rows for [host] (see [menuRowsOf]).
  static List<SubtitleMenuRow> rowsFor(SubtitleMenuHost host) => menuRowsOf(
    host,
    canTranslate: TranslateEntry.available,
    languages: listedFor(host),
  );

  /// The popup value of what [host] shows, for the menu to open at.
  static int initialValue(SubtitleMenuHost host) => switch (host.menuPicked) {
    null => off,
    pickedTrack => more,
    final code => valueOf(code),
  };

  /// Room for a language row's name, where it stands and its two icons:
  /// wider than a popup menu's default at most.
  static const constraints = BoxConstraints(minWidth: 220, maxWidth: 360);

  /// The whole menu for [host], in the dark popup both players use.
  static List<PopupMenuEntry<int>> items(
    BuildContext context,
    SubtitleMenuHost host,
  ) {
    final picked = host.menuPicked;
    final shownTrack = host.shownPlatformTrack;
    final names = host.platformTrackNames;
    return [
      const PopupMenuItem<int>(
        value: note,
        enabled: false,
        height: 28,
        child: Text(
          '选择会用于所有视频',
          style: TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ),
      PopupMenuItem<int>(
        value: off,
        height: 36,
        onTap: host.chooseOff,
        child: _RowText(label: '关闭字幕', checked: picked == null),
      ),
      for (final row in rowsFor(host))
        PopupMenuItem<int>(
          value: valueOf(row.code),
          height: 40,
          onTap: () => pick(context, host, row.code),
          child: _LanguageRow(
            host: host,
            row: row,
            onSource: (source) => pick(context, host, row.code, via: source),
          ),
        ),
      // the speech is English and the English model is not here: offered,
      // never fetched by itself (design 2026-09-26, 14⑤)
      // (a service never created has no session to offer it for)
      if (Get.isRegistered<AsrService>() &&
          !Get.isPrepared<AsrService>() &&
          AsrService.to.offersEnglishModelNow)
        PopupMenuItem<int>(
          value: englishModel,
          height: 36,
          onTap: () => downloadEnglishModel(context),
          child: Obx(() {
            final progress = AsrService.to.englishDownload.value;
            return _RowText(
              label: progress == null
                  ? '下载英语识别模型（更准确）'
                  : '英语识别模型下载中 '
                        '${progress.total == 0 ? 0 : progress.received * 100 ~/ progress.total}%',
              checked: false,
            );
          }),
        ),
      if (TranslateEntry.available)
        PopupMenuItem<int>(
          value: other,
          height: 36,
          onTap: () async {
            final code = await pickOther(context);
            if (code != null && context.mounted) pick(context, host, code);
          },
          child: const _RowText(label: '其他语言…', checked: false),
        ),
      if (names.isNotEmpty)
        PopupMenuItem<int>(
          value: more,
          height: 36,
          onTap: () async {
            final index = await pickTrack(context, names, shownTrack);
            if (index != null) host.choosePlatformTrack(index);
          },
          child: _RowText(
            label: picked == pickedTrack && shownTrack != null
                ? '更多字幕轨… · ${names[shownTrack]}'
                : '更多字幕轨…',
            checked: picked == pickedTrack,
          ),
        ),
    ];
  }

  /// Picks [code] — `asr` or a language — from [via], or the default
  /// source: asking first for a model the device would need, as any first
  /// start asks. What is picked is remembered only once it goes ahead.
  static Future<void> pick(
    BuildContext context,
    SubtitleMenuHost host,
    String code, {
    SubtitleSourcePreference? via,
  }) {
    final plan = host.planFor(code, via: via);
    if (plan.action != OpenAction.onDevice) {
      return host.chooseLanguage(code, plan);
    }
    if (code == 'asr') {
      return AsrEntry.startFor(context, () => host.chooseLanguage(code, plan));
    }
    if (host.hasTranslationInto(code)) {
      return host.chooseLanguage(code, plan);
    }
    return TranslateEntry.startFor(
      context,
      ({mayTranscribe}) =>
          host.chooseLanguage(code, plan, mayTranscribe: mayTranscribe),
      needsTranscript:
          !host.hasTranscription && host.captionToTranslateInto(code) == null,
    );
  }

  /// Asks, then downloads the English model in the background; the session
  /// going switches to it once it is here.
  static Future<void> downloadEnglishModel(BuildContext context) async {
    final service = AsrService.to;
    if (service.englishDownloading) return;
    if (!await AsrEntry.confirmEnglishModel(context)) return;
    await service.downloadEnglishModel();
    final error = service.englishDownloadError.value;
    SmartDialog.showToast(
      error == null
          ? (service.store.isEnglishReady ? '英语识别模型已就绪' : '已取消')
          : '英语识别模型下载失败：$error',
    );
  }

  /// Asks which of the other languages to show; the last entry opens the
  /// settings where languages are kept in the menu. Null when dismissed or
  /// sent to the settings.
  static Future<String?> pickOther(BuildContext context) async {
    final picked = await showDialog<String>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('其他语言'),
        children: [
          for (final code in otherTranslationLanguages)
            SimpleDialogOption(
              onPressed: () => Get.back(result: code),
              child: Text(translationLanguageLabel(code)),
            ),
          const Divider(height: 1),
          SimpleDialogOption(
            onPressed: () => Get.back(result: _settings),
            child: const Text('设置常驻语言…'),
          ),
        ],
      ),
    );
    if (picked == _settings) {
      await Get.to(
        () => const CommonSetting(settingType: SettingType.asrSetting),
      );
      return null;
    }
    return picked;
  }

  static const _settings = '#settings';

  /// The video's own tracks, all of them ([names]), for one picked by hand:
  /// for this video only. [shown] is the one on screen.
  static Future<int?> pickTrack(
    BuildContext context,
    List<String> names,
    int? shown,
  ) => showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('视频自带字幕'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
          child: Text(
            '只用于这个视频',
            style: TextStyle(
              fontSize: 13,
              color: ColorScheme.of(context).outline,
            ),
          ),
        ),
        for (final (i, name) in names.indexed)
          SimpleDialogOption(
            onPressed: () => Get.back(result: i),
            child: Row(
              children: [
                SizedBox(
                  width: 24,
                  child: i == shown ? const Icon(Icons.check, size: 16) : null,
                ),
                Expanded(child: Text(name)),
              ],
            ),
          ),
      ],
    ),
  );
}

const _white = TextStyle(color: Colors.white, fontSize: 13);

class _RowText extends StatelessWidget {
  const _RowText({
    required this.label,
    required this.checked,
    this.inRow = false,
  });

  final String label;
  final bool checked;

  /// Laid out inside another row, which gives it no width to fill.
  final bool inRow;

  @override
  Widget build(BuildContext context) {
    final text = Text(
      label,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: _white,
    );
    return Row(
      mainAxisSize: inRow ? MainAxisSize.min : MainAxisSize.max,
      children: [
        SizedBox(
          width: 20,
          child: checked
              ? const Icon(Icons.check, size: 14, color: Colors.white)
              : null,
        ),
        if (inRow) text else Flexible(child: text),
      ],
    );
  }
}

/// A language row: its name, where it stands, and an icon per source.
class _LanguageRow extends StatelessWidget {
  const _LanguageRow({
    required this.host,
    required this.row,
    required this.onSource,
  });

  final SubtitleMenuHost host;
  final SubtitleMenuRow row;
  final ValueChanged<SubtitleSourcePreference> onSource;

  @override
  Widget build(BuildContext context) {
    Widget icon(SubtitleSourcePreference source) {
      final active = row.active == source;
      final device = source == SubtitleSourcePreference.device;
      return IconButton(
        tooltip: device ? '本机生成（只用于这个视频）' : '平台字幕（只用于这个视频）',
        visualDensity: VisualDensity.compact,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints.tightFor(width: 30, height: 30),
        iconSize: 17,
        isSelected: active,
        icon: Icon(
          device ? Icons.memory_outlined : Icons.cloud_outlined,
          color: Colors.white54,
        ),
        selectedIcon: Icon(
          device ? Icons.memory : Icons.cloud,
          color: Colors.white,
        ),
        onPressed: () {
          // the menu goes first, as a tap on the row closes it
          Navigator.of(context).pop();
          onSource(source);
        },
      );
    }

    return Row(
      children: [
        _RowText(label: row.label, checked: row.checked, inRow: true),
        const SizedBox(width: 8),
        Expanded(
          // follows the run while the menu is open
          child: Obx(() => _Status(host.menuStatus(row.code))),
        ),
        if (row.device) icon(SubtitleSourcePreference.device),
        if (row.platform) icon(SubtitleSourcePreference.platform),
      ],
    );
  }
}

class _Status extends StatelessWidget {
  const _Status(this.status);

  final SubtitleStatus? status;

  @override
  Widget build(BuildContext context) {
    final status = this.status;
    if (status == null) return const SizedBox.shrink();
    final color = status.error ? Colors.orangeAccent : Colors.white60;
    return Row(
      children: [
        if (status.busy) ...[
          SizedBox.square(
            dimension: 10,
            child: CircularProgressIndicator(strokeWidth: 1.5, color: color),
          ),
          const SizedBox(width: 5),
        ],
        Flexible(
          child: Text(
            status.text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: color, fontSize: 11),
          ),
        ),
      ],
    );
  }
}
