import 'dart:convert';

import 'package:PiliPlus/services/youtube/invidious_source.dart';
import 'package:PiliPlus/services/youtube/source_router.dart';
import 'package:PiliPlus/utils/storage.dart';
import 'package:PiliPlus/utils/storage_key.dart';

/// What the YouTube video sources learned, kept across launches in the
/// local cache (which 重置所有数据 clears): [YtInvidiousSource.shared]'s
/// instances, gates and googlevideo's refusal, and the cooldowns of
/// [YtSourceRouter.sharedHealth]. Read once, when the first video page
/// opens; written whenever they change.
abstract final class YtSourceStore {
  static var _loaded = false;

  static void load() {
    if (_loaded) return;
    _loaded = true;
    final box = GStorage.localCache;
    final invidious = YtInvidiousSource.shared;
    try {
      if (_read(box.get(LocalCacheKey.ytInvidious)) case final json?) {
        invidious.restore(json);
      }
      if (_read(box.get(LocalCacheKey.ytCooldowns)) case final json?) {
        YtSourceRouter.restoreSharedCooldowns(json);
      }
    } catch (_) {
      // a launch without them is what there was before they were kept
    }
    invidious.onChanged = () =>
        box.put(LocalCacheKey.ytInvidious, jsonEncode(invidious.toJson()));
    YtSourceRouter.onSharedCooldown = () => box.put(
      LocalCacheKey.ytCooldowns,
      jsonEncode(YtSourceRouter.sharedCooldowns()),
    );
  }

  static Map<dynamic, dynamic>? _read(Object? stored) =>
      stored is String ? jsonDecode(stored) as Map? : null;
}
