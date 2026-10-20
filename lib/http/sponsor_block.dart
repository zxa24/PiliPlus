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

  /// Servers that answered the hash-prefix lookup with 400, or with 404 for
  /// a video the plain query then found segments for: asked the plain way
  /// for the rest of the run.
  static final _noPrefix = <String>{};

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
  }) async {
    final server = blockServer;
    if (_noPrefix.contains(server)) return _segmentsByVideo(bvid, cid);
    final res = await Request().get(
      _api('${SponsorBlockApi.skipSegments}/${hashPrefix(bvid)}'),
      options: options,
    );
    if (res.statusCode == 200) {
      if (pickSegments(res.data, bvid: bvid, cid: cid) case final picked?) {
        return Success(picked.map(SegmentItemModel.fromJson).toList());
      }
      return getErrMsg(res);
    }
    if (res.statusCode != 404 && res.statusCode != 400) return getErrMsg(res);
    // A server without the lookup — or, on one with it, no video at all
    // under the prefix, which upstream answers with 404 too: asked the
    // plain way. Kept to that only once it is clear the lookup is missing,
    // not the video.
    final plain = await _segmentsByVideo(bvid, cid);
    if (res.statusCode == 400 ||
        (plain is Success<List<SegmentItemModel>> &&
            plain.response.isNotEmpty)) {
      _noPrefix.add(server);
    }
    return plain;
  }

  static Future<LoadingState<List<SegmentItemModel>>> _segmentsByVideo(
    String bvid,
    int cid,
  ) async {
    final res = await Request().get(
      _api(SponsorBlockApi.skipSegments),
      queryParameters: {
        'videoID': bvid,
        'cid': cid,
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
