import 'dart:convert';

import 'package:PiliPlus/build_config.dart';
import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/http/init.dart';
import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/sponsor_block_api.dart';
import 'package:PiliPlus/models/common/sponsor_block/post_segment_model.dart';
import 'package:PiliPlus/models/common/sponsor_block/segment_type.dart';
import 'package:PiliPlus/models_new/sponsor_block/segment_item.dart';
import 'package:PiliPlus/models_new/sponsor_block/user_info.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:PiliPlus/utils/utils.dart';
import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart' show kDebugMode, visibleForTesting;

/// https://github.com/hanydd/BilibiliSponsorBlock/wiki/API
abstract final class SponsorBlock {
  static String get blockServer => Pref.blockServer;
  static final options = Options(
    followRedirects: true,
    // https://github.com/hanydd/BilibiliSponsorBlock/wiki/API#1-%E5%85%AC%E7%94%A8%E5%8F%82%E6%95%B0
    headers: kDebugMode
        ? null
        : {
            'origin': Constants.appName,
            'x-ext-version': BuildConfig.versionName,
          },
    validateStatus: (status) => true,
  );

  static Error getErrMsg(Response res) {
    String statusMessage = switch (res.statusCode) {
      200 => '意料之外的响应',
      400 => '参数错误',
      403 => '被自动审核机制拒绝',
      404 => '未找到数据',
      409 => '重复提交',
      429 => '提交太快（触发速率控制）',
      500 => '服务器无法获取信息',
      -1 => res.data['message'].toString(), // DioException
      _ => res.statusMessage ?? res.statusCode.toString(),
    };
    if (res.statusCode != null && res.statusCode != -1) {
      final data = res.data;
      if (res.statusCode == 200 ||
          (data is String && data.isNotEmpty && data.length < 200)) {
        statusMessage = '$statusMessage：$data';
      }
    }
    return Error(statusMessage, code: res.statusCode);
  }

  static String _api(String url) => '$blockServer/api/$url';

  /// Servers known to lack the hash-prefix lookup: asked the plain way for
  /// the rest of the run.
  static final _noPrefix = <String>{};

  /// Servers known to have it, having answered a prefix with 200 or refused
  /// [probePrefix] as malformed: their 404 means no video under the prefix,
  /// and the plain query is not sent.
  static final _withPrefix = <String>{};

  /// The check of a server whose support is not known yet, one per server.
  static final _probes = <String, Future<bool?>>{};

  /// Asked once per server on a 404 while its support is unknown: not hex,
  /// so it matches no video and says nothing of the user's. A server with
  /// the lookup refuses it as malformed (400); one without has no such
  /// route (404). The default server, probed 2026-10-20: `zzzz` 400, `0000`
  /// 200, an unknown route 404. A prefix that is hex may simply be empty,
  /// which a 404 cannot tell from a missing route.
  @visibleForTesting
  static const probePrefix = 'zzzz';

  /// The first four hex digits of the SHA-256 of [bvid]: all the server is
  /// told of the video (oct-pass3-D6). It answers with every video sharing
  /// them, and the one asked for is picked out here.
  @visibleForTesting
  static String hashPrefix(String bvid) =>
      sha256.convert(utf8.encode(bvid)).toString().substring(0, 4);

  /// The segments of [bvid]'s part [cid] in a hash-prefix answer: the entry
  /// for [bvid], and of its segments those of [cid] — or with no cid, which
  /// belong to the video as a whole. Null when [data] is not such an answer.
  @visibleForTesting
  static List<Map<String, dynamic>>? pickSegments(
    Object? data, {
    required String bvid,
    required int cid,
  }) {
    if (data is! List) return null;
    for (final entry in data) {
      if (entry is! Map || entry['videoID'] != bvid) continue;
      final segments = entry['segments'];
      if (segments is! List) return null;
      return [
        for (final segment in segments)
          if (segment is Map<String, dynamic>)
            if (switch (segment['cid']) {
              null || '' => true,
              final of => '$of' == '$cid',
            })
              // the model reads the cid as text, as this server sends it
              segment['cid'] is String?
                  ? segment
                  : {...segment, 'cid': '${segment['cid']}'},
      ];
    }
    return const [];
  }

  static Future<LoadingState<List<SegmentItemModel>>> getSkipSegments({
    required String bvid,
    required int cid,
  }) => lookup(
    server: blockServer,
    bvid: bvid,
    cid: cid,
    get: (url, query) =>
        Request().get(url, queryParameters: query, options: options),
  );

  /// [getSkipSegments] on [server], each request made through [get].
  @visibleForTesting
  static Future<LoadingState<List<SegmentItemModel>>> lookup({
    required String server,
    required String bvid,
    required int cid,
    required Future<Response> Function(String url, Map<String, dynamic>? query)
    get,
  }) async {
    final base = '$server/api/${SponsorBlockApi.skipSegments}';
    Future<LoadingState<List<SegmentItemModel>>> plain() async {
      final res = await get(base, {'videoID': bvid, 'cid': cid});
      if (res.statusCode == 200) {
        if (res.data case final List list) {
          return Success(
            list.map((i) => SegmentItemModel.fromJson(i)).toList(),
          );
        }
      }
      return getErrMsg(res);
    }

    if (_noPrefix.contains(server)) return plain();
    final res = await get('$base/${hashPrefix(bvid)}', null);
    if (res.statusCode == 200) {
      _withPrefix.add(server);
      if (pickSegments(res.data, bvid: bvid, cid: cid) case final picked?) {
        return Success(picked.map(SegmentItemModel.fromJson).toList());
      }
      return getErrMsg(res);
    }
    if (res.statusCode != 404 && res.statusCode != 400) return getErrMsg(res);
    // A server without the lookup — or, on one with it, no video at all
    // under the prefix (404), or a refusal of a prefix it should take (400:
    // four hex digits are valid where the lookup is, upstream takes 4 to
    // 32). The plain query, which names the video, only once the lookup is
    // known missing.
    LoadingState<List<SegmentItemModel>> withLookup() =>
        res.statusCode == 404 ? const Success([]) : getErrMsg(res);
    if (_withPrefix.contains(server)) return withLookup();
    final supported = await (_probes[server] ??= _probe(base, get));
    if (supported == null) {
      // not learnt (the check itself failed): asked again next time
      _probes.remove(server);
      return getErrMsg(res);
    }
    if (supported) {
      _withPrefix.add(server);
      return withLookup();
    }
    _noPrefix.add(server);
    return plain();
  }

  /// Whether the server at [base] has the prefix lookup, by [probePrefix]:
  /// 400 yes, 404 no, anything else (no answer included) not learnt.
  static Future<bool?> _probe(
    String base,
    Future<Response> Function(String url, Map<String, dynamic>? query) get,
  ) async {
    final res = await get('$base/$probePrefix', null);
    return switch (res.statusCode) {
      400 => true,
      404 => false,
      _ => null,
    };
  }

  @visibleForTesting
  static void resetServers() {
    _noPrefix.clear();
    _withPrefix.clear();
    _probes.clear();
  }

  static Future<LoadingState<void>> voteOnSponsorTime({
    required String uuid,
    int? type,
    SegmentType? category,
  }) async {
    assert((type == null) != (category == null));
    final res = await Request().post(
      _api(SponsorBlockApi.voteOnSponsorTime),
      queryParameters: {
        'UUID': uuid,
        'type': ?type,
        'category': ?category?.name,
        'userID': Pref.blockUserID,
      },
      options: options,
    );
    return res.statusCode == 200 ? const Success(null) : getErrMsg(res);
  }

  static Future<LoadingState<void>> viewedVideoSponsorTime(String uuid) async {
    final res = await Request().post(
      _api(SponsorBlockApi.viewedVideoSponsorTime),
      data: {'UUID': uuid},
      options: options,
    );
    return res.statusCode == 200 ? const Success(null) : getErrMsg(res);
  }

  static Future<LoadingState<void>> uptimeStatus() async {
    final res = await Request().get(
      _api(SponsorBlockApi.uptimeStatus),
      options: options,
    );
    if (res.statusCode == 200 &&
        res.data is String &&
        Utils.isStringNumeric(res.data)) {
      return const Success(null);
    }
    return getErrMsg(res);
  }

  static Future<LoadingState<UserInfo>> userInfo(
    List<String> query, {
    String? userId,
  }) async {
    final res = await Request().get(
      _api(SponsorBlockApi.userInfo),
      queryParameters: {
        'userID': userId ?? Pref.blockUserID,
        'values': jsonEncode(query),
      },
      options: options,
    );
    // a 200 that is not the JSON object (a proxy's page, a plain string)
    // is 意料之外的响应, not a cast error
    if (res.statusCode == 200 && res.data is Map) {
      return Success(UserInfo.fromJson(res.data));
    }
    return getErrMsg(res);
  }

  static Future<LoadingState<List<SegmentItemModel>>> postSkipSegments({
    required String bvid,
    required int cid,
    required double videoDuration,
    required List<PostSegmentModel> segments,
  }) async {
    final res = await Request().post(
      _api(SponsorBlockApi.skipSegments),
      data: {
        'videoID': bvid,
        'cid': cid.toString(),
        'userID': Pref.blockUserID,
        'userAgent': kDebugMode
            ? Constants.userAgent
            : '${Constants.appName}/${BuildConfig.versionName}',
        'videoDuration': videoDuration,
        'segments': segments
            .map(
              (item) => {
                'segment': [item.segment.first, item.segment.second],
                'category': item.category.name,
                'actionType': item.actionType.name,
              },
            )
            .toList(),
      },
      options: options,
    );

    if (res.statusCode == 200) {
      if (res.data case final List list) {
        return Success(list.map((i) => SegmentItemModel.fromJson(i)).toList());
      }
    }
    return getErrMsg(res);
  }

  /// {
  ///   "bvID": string,     // B站视频BVID
  ///   "cid": string,      // 视频CID
  ///   "ytbID": string,    // YouTube视频ID
  ///   "UUID": string,     // 绑定记录的UUID（不是视频中片段的UUID，是绑定记录本身的UUID）
  ///   "votes": int,       // 绑定记录的投票数
  ///   "locked": int,      // 绑定记录是否锁定
  /// }
  /// TODO: show port video info dialog
  static Future<LoadingState<String>> getPortVideo({
    required String bvid,
    required int cid,
  }) async {
    final res = await Request().get(
      _api(SponsorBlockApi.portVideo),
      queryParameters: {
        'videoID': bvid,
        'cid': cid.toString(),
      },
      options: options,
    );

    if (res.statusCode == 200) {
      if (res.data case final Map<String, dynamic> data) {
        if (data['ytbID'] case String ytbId) {
          return Success(ytbId);
        }
      }
    }
    return getErrMsg(res);
  }

  static Future<LoadingState<String>> postPortVideo({
    required String bvid,
    required int cid,
    required String ytbId,
    required int videoDuration,
  }) async {
    final res = await Request().post(
      _api(SponsorBlockApi.portVideo),
      data: {
        'bvID': bvid,
        'cid': cid.toString(),
        'ytbID': ytbId,
        'userID': Pref.blockUserID,
        'biliDuration': videoDuration,
      },
      options: options,
    );

    if (res.statusCode == 200) {
      if (res.data case final Map<String, dynamic> data) {
        if (data['UUID'] case String uuid) {
          return Success(uuid);
        }
      }
    }
    return getErrMsg(res);
  }
}
