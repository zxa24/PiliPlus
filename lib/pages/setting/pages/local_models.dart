/// LibrePili: one place for every model the app can download and run on the
/// device.
///
/// Today that is speech recognition; translation is meant to land here too,
/// which is why this is its own page rather than a line inside the
/// transcription settings. Nothing here is bundled with the app and nothing
/// downloads by itself: this page is where the user decides.
library;

import 'dart:io';

import 'package:PiliPlus/services/asr/asr_service.dart';
import 'package:PiliPlus/services/asr/model_catalog.dart';
import 'package:PiliPlus/services/asr/model_store.dart';
import 'package:PiliPlus/utils/cache_manager.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class LocalModelsPage extends StatefulWidget {
  const LocalModelsPage({super.key, this.showAppBar = true});

  final bool showAppBar;

  @override
  State<LocalModelsPage> createState() => _LocalModelsPageState();
}

class _LocalModelsPageState extends State<LocalModelsPage> {
  AsrModelStore get _store => AsrService.to.store;

  AsrCancelToken? _token;
  AsrProgress? _progress;
  String? _error;

  bool get _busy => _token != null;

  @override
  void dispose() {
    // leaving the page does not abandon the download: it is the user's 240 MB
    // and finishing it in the background is what they asked for
    super.dispose();
  }

  Future<void> _download() async {
    final token = AsrCancelToken();
    setState(() {
      _token = token;
      _error = null;
      _progress = null;
    });
    try {
      await _store.ensureAll(
        token: token,
        onProgress: (progress) {
          if (mounted) setState(() => _progress = progress);
        },
      );
    } on AsrCancelled {
      // nothing to say: the user pressed cancel
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) {
        setState(() {
          _token = null;
          _progress = null;
        });
      }
    }
  }

  Future<void> _import() async {
    try {
      final picked = await FilePicker.pickFiles();
      final paths = [for (final file in picked) ?file.path];
      if (paths.isEmpty) return;
      SmartDialog.showLoading(msg: '校验中');
      var count = 0;
      final failures = <String>[];
      for (final path in paths) {
        try {
          await _store.importFile(File(path));
          count++;
        } catch (e) {
          failures.add('$e');
        }
      }
      SmartDialog.dismiss();
      if (mounted) {
        setState(() => _error = failures.isEmpty ? null : failures.first);
      }
      SmartDialog.showToast(count > 0 ? '已导入 $count 个文件' : '没有可用的文件');
    } catch (e) {
      SmartDialog.dismiss();
      SmartDialog.showToast('导入失败: $e');
    }
  }

  Future<void> _remove(AsrModel model) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('删除「${model.label}」？'),
        content: Text(
          '会释放 ${CacheManager.formatSize(model.totalSize)}，'
          '再次使用需要重新下载。',
        ),
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ),
          TextButton(
            onPressed: () => Get.back(result: true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _store.remove(model);
    if (mounted) setState(() {});
  }

  Future<void> _copyUrls() async {
    final urls = [
      for (final model in AsrModelCatalog.required)
        for (final file in model.files) file.sources.first.url,
    ];
    await Utils.copyText(
      urls.join('\n'),
      toastText: '已复制 ${urls.length} 个地址',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final ready = _store.isReady;
    final used = _store.installedBytes();
    final missing = AsrService.to.downloadSize;

    return Scaffold(
      backgroundColor: widget.showAppBar
          ? null
          : theme.colorScheme.surfaceContainerLow,
      appBar: widget.showAppBar
          ? AppBar(title: const Text('本地模型'))
          : null,
      body: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Text(
              '在本机运行的模型，用于语音转录等功能。'
              '模型不随应用分发，由你决定是否下载；'
              '文件存放在应用数据目录，每个文件都按 SHA-256 校验，'
              '下载不便时也可以自行下载后手动导入。',
              style: TextStyle(
                fontSize: 13,
                color: theme.colorScheme.outline,
              ),
            ),
          ),
          _group(
            theme,
            title: '语音转录',
            subtitle: ready
                ? '已就绪，占用 ${CacheManager.formatSize(used)}'
                : '未就绪，还需下载 ${CacheManager.formatSize(missing)}',
            models: AsrModelCatalog.required,
          ),
          if (_progress case final progress?) ...[
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    progress.verifying
                        ? progress.label
                        : '${progress.label}  '
                              '${CacheManager.formatSize(progress.received)}'
                              ' / ${CacheManager.formatSize(progress.total)}',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.outline,
                    ),
                  ),
                  const SizedBox(height: 6),
                  LinearProgressIndicator(
                    value: progress.total == 0
                        ? null
                        : progress.received / progress.total,
                  ),
                ],
              ),
            ),
          ],
          if (_error case final error?)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Text(
                error,
                style: TextStyle(
                  fontSize: 13,
                  color: theme.colorScheme.error,
                ),
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (_busy)
                  FilledButton.tonal(
                    onPressed: () => _token?.cancel(),
                    child: const Text('取消下载'),
                  )
                else if (!ready)
                  FilledButton(
                    onPressed: _download,
                    child: Text(
                      '下载（${CacheManager.formatSize(missing)}）',
                    ),
                  ),
                OutlinedButton(
                  onPressed: _busy ? null : _import,
                  child: const Text('手动导入'),
                ),
                TextButton(
                  onPressed: _copyUrls,
                  child: const Text('复制下载地址'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _group(
    ThemeData theme, {
    required String title,
    required String subtitle,
    required List<AsrModel> models,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ListTile(
          title: Text(title),
          subtitle: Text(subtitle),
          titleTextStyle: theme.textTheme.titleMedium,
        ),
        for (final model in models)
          ListTile(
            dense: true,
            contentPadding: const EdgeInsets.only(left: 32, right: 12),
            title: Text(model.label),
            subtitle: Text(
              '${CacheManager.formatSize(model.totalSize)}'
              '${model.languages.isEmpty ? '' : ' · ${model.languages.join("/")}'}',
            ),
            trailing: _store.isInstalled(model)
                ? IconButton(
                    tooltip: '删除',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: _busy ? null : () => _remove(model),
                  )
                : Text(
                    '未下载',
                    style: TextStyle(
                      fontSize: 12,
                      color: theme.colorScheme.outline,
                    ),
                  ),
          ),
      ],
    );
  }
}
