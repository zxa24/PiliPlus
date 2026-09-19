import 'dart:io';

import 'package:PiliPlus/utils/json_file_handler.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:catcher_2/utils/log_printer.dart';
import 'package:flutter/foundation.dart';
import 'package:logger/logger.dart';
import 'package:path/path.dart' as p;

final logger = Logger(
  filter: ProductionFilter(),
  printer: PrettyLogPrinter(
    dateTimeFormat: PrettyLogPrinter.toEncodableFallback,
  ),
  level: kDebugMode ? .trace : .warning,
);

abstract final class LoggerUtils {
  static File? _logFile;

  /// Logs above this size are dropped at start-up.
  static const _maxLogSize = 2 * 1024 * 1024;

  static Future<File> getLogsPath() async {
    if (_logFile != null) return _logFile!;

    // the app's own data dir (per profile), not the shared, often synced
    // Documents folder, and a name of its own (upstream uses .pili_logs.json)
    final String filename = p.join(appSupportDirPath, 'librepili_logs.json');
    final File file = File(filename);
    if (!file.existsSync()) {
      await file.create(recursive: true);
    } else if (await file.length() > _maxLogSize) {
      await file.writeAsBytes(const [], flush: true);
    }
    return _logFile = file;
  }

  static Future<bool> clearLogs() async {
    try {
      if (Pref.enableLog) {
        await JsonFileHandler.add(
          (raf) => raf.setPosition(0).then((raf) => raf.truncate(0)),
        );
      } else {
        final file = await getLogsPath();
        await file.writeAsBytes(const [], flush: true);
      }
    } catch (e) {
      // if (kDebugMode) debugPrint('Error clearing file: $e');
      return false;
    }
    return true;
  }
}
