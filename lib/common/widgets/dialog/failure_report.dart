/// LibrePili: how the app says a feature has stopped working altogether.
///
/// Things the app works around by itself — a slow network, a host left for
/// another, a lower quality, a stream handed over — are not announced: a
/// notice for every one of them is noise about something already dealt
/// with. What is announced is the end of that road ("the video cannot be
/// played", "the transcription failed"), once, as a dialog with the recent
/// [EventLog] under it, which can be copied or saved to go with a report.
library;

import 'dart:convert' show utf8;
import 'dart:io' show Platform;

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/services/event_log.dart';
import 'package:PiliPlus/utils/storage_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:intl/intl.dart' show DateFormat;

abstract final class FailureReport {
  /// Titles on screen: one dialog per failure, not one per error line.
  static final _open = <String>{};

  /// Shows that [title] ("视频无法播放") has stopped working, with [detail]
  /// and the recent events.
  static void show(String title, String detail) {
    EventLog.add('failure', '$title: $detail');
    if (!_open.add(title)) return;
    final report = [
      'LibrePili ${BuildConfig.versionName}+${BuildConfig.versionCode} '
          '(${BuildConfig.commitHash}) ${Platform.operatingSystem}',
      '${DateTime.now()}',
      '$title: $detail',
      '',
      ...EventLog.recent,
    ].join('\n');
    SmartDialog.show(
      tag: 'failure:$title',
      onDismiss: () => _open.remove(title),
      builder: (context) {
        final theme = Theme.of(context);
        return AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 560,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(detail),
                const SizedBox(height: 12),
                Text('最近记录', style: theme.textTheme.labelMedium),
                const SizedBox(height: 4),
                Flexible(
                  child: Container(
                    constraints: const BoxConstraints(maxHeight: 320),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: SingleChildScrollView(
                      // newest at the bottom, where it opens
                      reverse: true,
                      child: SelectableText(
                        EventLog.recent.join('\n'),
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 11,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Utils.copyText(report),
              child: const Text('复制'),
            ),
            TextButton(
              onPressed: () => StorageUtils.saveBytes2File(
                name:
                    'librepili_failure_'
                    '${DateFormat('yyyyMMddHHmmss').format(DateTime.now())}.txt',
                bytes: utf8.encode(report),
                allowedExtensions: const ['txt'],
              ),
              child: const Text('保存'),
            ),
            TextButton(
              onPressed: () => SmartDialog.dismiss(tag: 'failure:$title'),
              child: const Text('关闭'),
            ),
          ],
        );
      },
    );
  }
}
