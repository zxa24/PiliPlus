import 'dart:collection';
import 'dart:io' show File;

import 'package:PiliPlus/grpc/bilibili/community/service/dm/v1.pb.dart';
import 'package:PiliPlus/grpc/dm.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/plugin/pl_player/controller.dart';
import 'package:PiliPlus/plugin/pl_player/models/data_source.dart';
import 'package:PiliPlus/services/download/download_extras.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/danmaku_utils.dart';
import 'package:PiliPlus/utils/path_utils.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:path/path.dart' as path;

class PlDanmakuController {
  PlDanmakuController(
    this._cid,
    this._plPlayerController,
    this._isFileSource,
  ) : _mergeDanmaku = _plPlayerController.mergeDanmaku;

  final int _cid;
  final PlPlayerController _plPlayerController;
  final bool _mergeDanmaku;
  final bool _isFileSource;

  late final _isLogin = Accounts.main.isLogin;

  final Map<int, List<DanmakuElem>> _dmSegMap = HashMap();
  // 已请求的段落标记
  late final Set<int> _requestedSeg = HashSet();

  void dispose() {
    _dmSegMap.clear();
    _requestedSeg.clear();
  }

  Future<void> queryDanmaku(int segmentIndex) async {
    if (_isFileSource) {
      return;
    }
    if (_requestedSeg.contains(segmentIndex)) {
      return;
    }
    _requestedSeg.add(segmentIndex);
    final res = await DmGrpc.dmSegMobile(
      cid: _cid,
      segmentIndex: segmentIndex + 1,
    );

    if (res case Success(:final response)) {
      if (response.state == 1) {
        _plPlayerController.dmState.add(_cid);
      }
      handleDanmaku(response.elems);
    } else {
      _requestedSeg.remove(segmentIndex);
    }
  }

  /// Diagnostics (self test): size of the last danmaku batch handed over.
  static int lastLoadedCount = 0;

  void handleDanmaku(List<DanmakuElem> elems) {
    lastLoadedCount = elems.length;
    if (elems.isEmpty) return;
    final uniques = HashMap<String, DanmakuElem>();

    final filters = _plPlayerController.filters;
    final shouldFilter = filters.count != 0;
    for (final element in elems) {
      if (_isLogin) {
        element.isSelf = element.midHash == _plPlayerController.midHash;
      }

      if (!element.isSelf) {
        if (_mergeDanmaku) {
          final elem = uniques[element.content];
          if (elem == null) {
            uniques[element.content] = element..count = 1;
          } else {
            elem.count++;
            continue;
          }
        }

        if (shouldFilter && filters.remove(element)) {
          continue;
        }
      }

      final int pos = element.progress ~/ 100; //每0.1秒存储一次
      (_dmSegMap[pos] ??= []).add(element);
    }
  }

  List<DanmakuElem>? getCurrentDanmaku(int progress) {
    if (_isFileSource) {
      initFileDmIfNeeded();
    } else {
      final int segmentIndex = DmUtils.calcSegment(progress);
      if (!_requestedSeg.contains(segmentIndex)) {
        queryDanmaku(segmentIndex);
        return null;
      }
    }
    return _dmSegMap[progress ~/ 100];
  }

  bool _fileDmLoaded = false;

  void initFileDmIfNeeded() {
    if (_fileDmLoaded) return;
    _fileDmLoaded = true;
    _initFileDm();
  }

  @pragma('vm:notify-debugger-on-exception')
  Future<void> _initFileDm() async {
    try {
      final source = _plPlayerController.dataSource as FileSource;
      final file = File(path.join(source.dir, PathUtils.danmakuName));
      if (!file.existsSync()) {
        // LibrePili: videos opened from a folder carry XML danmaku
        if (source.mergedPath case final merged?) {
          final xml = File(
            path.join(
              path.dirname(merged),
              '${path.basenameWithoutExtension(merged)}'
              '${DownloadExtras.xmlSuffix}',
            ),
          );
          if (xml.existsSync()) {
            handleDanmaku(
              DownloadExtras.xmlToDanmaku(await xml.readAsString()),
            );
          }
        }
        return;
      }
      final bytes = await file.readAsBytes();
      if (bytes.isEmpty) return;
      final elem = DmSegMobileReply.fromBuffer(bytes).elems;
      handleDanmaku(elem);
    } catch (e, s) {
      Utils.reportError(e, s);
    }
  }
}
