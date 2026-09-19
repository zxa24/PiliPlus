import 'package:PiliPlus/common/widgets/loading_widget/http_error.dart';
import 'package:PiliPlus/common/widgets/loading_widget/loading_widget.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/models_new/fav/fav_folder/list.dart';
import 'package:PiliPlus/pages/common/common_intro_controller.dart';
import 'package:PiliPlus/pages/local/fav_sheet.dart';
import 'package:PiliPlus/services/local_library.dart';
import 'package:PiliPlus/utils/bili_utils.dart';
import 'package:PiliPlus/utils/feed_back.dart';
import 'package:get/get.dart';
import 'package:material_ui/material_ui.dart';

class FavPanel extends StatefulWidget {
  const FavPanel({
    super.key,
    required this.ctr,
    this.scrollController,
  });

  final FavMixin ctr;
  final ScrollController? scrollController;

  @override
  State<FavPanel> createState() => _FavPanelState();
}

class _FavPanelState extends State<FavPanel> {
  LoadingState loadingState = LoadingState.loading();

  // LibrePili: local folders are listed separately above account folders
  late final String? _localKey = widget.ctr.localFavKey;
  late final Map<String, dynamic>? _localData = widget.ctr.localFavData;
  late List<LocalFavFolder> _localFolders = LocalLibrary.folders();
  late final Set<int> _localSelected = _localKey == null
      ? <int>{}
      : LocalLibrary.foldersOf(_localKey);

  bool get _hasLocal => _localKey != null && _localData != null;

  Future<void> _createLocalFolder() async {
    final name = await showFolderNameDialog(context);
    if (name == null) return;
    final folder = await LocalLibrary.createFolder(name);
    if (!mounted) return;
    setState(() {
      _localFolders = LocalLibrary.folders();
      _localSelected.add(folder.id);
    });
  }

  Widget _sectionHeader(String title, {Widget? trailing}) => Padding(
    padding: const .fromLTRB(16, 10, 8, 2),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: TextStyle(
              fontSize: 13,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ?trailing,
      ],
    ),
  );

  List<Widget> get _localSection => [
    _sectionHeader(
      '本地收藏夹',
      trailing: TextButton(
        onPressed: _createLocalFolder,
        child: const Text('新建'),
      ),
    ),
    for (final folder in _localFolders)
      ListTile(
        dense: true,
        onTap: () => setState(() {
          _localSelected.contains(folder.id)
              ? _localSelected.remove(folder.id)
              : _localSelected.add(folder.id);
        }),
        leading: const Icon(Icons.phone_android_outlined),
        minLeadingWidth: 0,
        title: Text(folder.title),
        subtitle: Text('${LocalLibrary.folderCount(folder.id)}个内容 . 仅本机'),
        trailing: Transform.scale(
          scale: 0.9,
          child: Checkbox(
            value: _localSelected.contains(folder.id),
            onChanged: (_) => setState(() {
              _localSelected.contains(folder.id)
                  ? _localSelected.remove(folder.id)
                  : _localSelected.add(folder.id);
            }),
          ),
        ),
      ),
    _sectionHeader('账号收藏夹'),
  ];

  Future<void> _saveLocal() async {
    if (_hasLocal) {
      await LocalLibrary.setFolders(_localKey!, _localData!, _localSelected);
    }
  }

  @override
  void initState() {
    super.initState();
    _queryVideoInFolder();
  }

  Future<void> _queryVideoInFolder() async {
    final res = await widget.ctr.queryVideoInFolder();
    if (mounted) {
      loadingState = res;
      setState(() {});
    }
  }

  Widget get _buildBody {
    switch (loadingState) {
      case Loading():
        return m3eLoading;
      case Success():
        final list = widget.ctr.favFolderData.value.list!;
        final header = _hasLocal ? _localSection : const <Widget>[];
        return ListView.builder(
          controller: widget.scrollController,
          itemCount: header.length + list.length,
          itemBuilder: (context, index) {
            if (index < header.length) return header[index];
            FavFolderInfo item = list[index - header.length];
            return Material(
              type: .transparency,
              child: Builder(
                builder: (context) {
                  final isChecked = item.favState == 1;

                  void onTap() {
                    item
                      ..favState = isChecked ? 0 : 1
                      ..mediaCount += isChecked ? -1 : 1;
                    (context as Element).markNeedsBuild();
                  }

                  return ListTile(
                    onTap: onTap,
                    dense: true,
                    leading: BiliUtils.isPublicFav(item.attr)
                        ? const Icon(Icons.folder_outlined)
                        : const Icon(Icons.lock_outline),
                    minLeadingWidth: 0,
                    title: Text(item.title),
                    subtitle: Text(
                      '${item.mediaCount}个内容 . ${BiliUtils.isPublicFavText(item.attr)}',
                    ),
                    trailing: Transform.scale(
                      scale: 0.9,
                      child: Checkbox(
                        value: isChecked,
                        onChanged: (bool? checkValue) => onTap(),
                      ),
                    ),
                  );
                },
              ),
            );
          },
        );
      case Error(:final errMsg):
        // the device-only folders do not depend on the account query
        if (_hasLocal) {
          return CustomScrollView(
            controller: widget.scrollController,
            slivers: [
              SliverList.list(children: _localSection),
              HttpError(errMsg: errMsg, onReload: _queryVideoInFolder),
            ],
          );
        }
        return scrollErrorWidget(
          errMsg: errMsg,
          controller: widget.scrollController,
          onReload: _queryVideoInFolder,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context).colorScheme;
    return Column(
      children: [
        AppBar(
          backgroundColor: Colors.transparent,
          leading: IconButton(
            tooltip: '关闭',
            onPressed: Get.back,
            icon: const Icon(Icons.close_outlined),
          ),
          title: const Text('添加到收藏夹'),
          actions: [
            TextButton.icon(
              onPressed: () => Get.toNamed('/createFav')?.then((data) {
                if (data is FavFolderInfo && mounted) {
                  widget.ctr.favFolderData.value.list?.insert(
                    1,
                    data
                      ..favState = 1
                      ..mediaCount = 1,
                  );
                  setState(() {});
                }
              }),
              icon: Icon(Icons.add, color: theme.primary),
              label: const Text('新建收藏夹'),
              style: const ButtonStyle(
                visualDensity: .compact,
                padding: WidgetStatePropertyAll(
                  .symmetric(horizontal: 18, vertical: 14),
                ),
              ),
            ),
            const SizedBox(width: 16),
          ],
        ),
        Expanded(child: _buildBody),
        Divider(
          height: 1,
          color: theme.outline.withValues(alpha: 0.1),
        ),
        Padding(
          padding: .only(
            left: 20,
            right: 20,
            top: 12,
            bottom: MediaQuery.viewPaddingOf(context).bottom + 12,
          ),
          child: Row(
            spacing: 25,
            mainAxisAlignment: .end,
            children: [
              FilledButton.tonal(
                onPressed: Get.back,
                style: FilledButton.styleFrom(
                  visualDensity: .compact,
                  foregroundColor: theme.outline,
                  backgroundColor: theme.onInverseSurface,
                ),
                child: const Text('取消'),
              ),
              FilledButton.tonal(
                onPressed: () async {
                  feedBack();
                  await _saveLocal();
                  // account folders failed to load: only the local choice
                  if (loadingState is Error) {
                    Get.back();
                    return;
                  }
                  widget.ctr.actionFavVideo();
                },
                style: const ButtonStyle(visualDensity: .compact),
                child: const Text('完成'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
