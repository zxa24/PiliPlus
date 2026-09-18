import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/utils/accounts/login_policy.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

RequestOptions _req(
  String path, {
  Map<String, dynamic>? query,
  Object? data,
}) => RequestOptions(path: path, queryParameters: query, data: data);

void main() {
  group('LoginPolicy.requiresAccount — stays anonymous', () {
    for (final path in [
      Api.searchAll,
      Api.searchByType,
      Api.searchSuggest,
      Api.searchDefault,
      Api.hotSearchList,
      Api.searchTrending,
      Api.recommendListApp,
      Api.recommendListWeb,
      Api.hotList,
      Api.relatedList,
      Api.videoIntro,
      Api.replyList,
      Api.memberInfo,
      Api.searchArchive,
      GrpcUrl.dmSegMobile,
      GrpcUrl.mainList,
      GrpcUrl.view,
    ]) {
      test(path, () => expect(LoginPolicy.requiresAccount(_req(path)), false));
    }

    test('public read with an unrelated mid', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(Api.followings, query: {'vmid': 123456}),
        ),
        false,
      );
    });
  });

  group('LoginPolicy.requiresAccount — uses the account', () {
    for (final path in [
      Api.ugcUrl,
      Api.pgcUrl,
      Api.userInfo,
      Api.historyList,
      Api.heartBeat,
      Api.followDynamic,
      Api.seeYouLater,
      Api.msgFeedReply,
      Api.likeVideo,
      Api.logout,
      GrpcUrl.sendMsg,
      GrpcUrl.sessionMain,
      GrpcUrl.audioPlayUrl,
    ]) {
      test(path, () => expect(LoginPolicy.requiresAccount(_req(path)), true));
    }

    test('csrf-protected write in body (map)', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(Api.relationMod, data: {'fid': 1, 'act': 1, 'csrf': 'x'}),
        ),
        true,
      );
    });

    test('csrf-protected write in query', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(Api.replyAdd, query: {'csrf': 'x'}),
        ),
        true,
      );
    });

    test('csrf-protected write in form data', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(Api.shootDanmaku, data: FormData.fromMap({'csrf': 'x'})),
        ),
        true,
      );
    });
  });
}
