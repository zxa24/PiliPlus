import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

/// LibrePili: delete confirmation for downloads. Returns null when
/// cancelled, else whether the exported video folder is deleted too.
/// Unchecked by default: the exported files are the user's own copy and
/// deleting them cannot be undone.
Future<bool?> showDeleteDownloadDialog(
  BuildContext context, {
  String title = '确定删除该视频？',
  bool exportOption = true,
}) {
  var deleteExported = false;
  return showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text(title),
        content: exportOption
            ? CheckboxListTile(
                value: deleteExported,
                onChanged: (value) =>
                    setState(() => deleteExported = value ?? false),
                title: const Text('同时删除导出的视频文件'),
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                dense: true,
              )
            : null,
        actions: [
          TextButton(
            onPressed: Get.back,
            child: Text(
              '取消',
              style: TextStyle(color: ColorScheme.of(context).outline),
            ),
          ),
          TextButton(
            onPressed: () => Get.back(result: deleteExported),
            child: const Text('确认'),
          ),
        ],
      ),
    ),
  );
}
