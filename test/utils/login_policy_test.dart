import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/models/common/member/profile_type.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/accounts/login_policy.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';

RequestOptions _req(
  String path, {
  Map<String, dynamic>? query,
  Object? data,
  String? method,
}) => RequestOptions(
  path: path,
  queryParameters: query,
  data: data,
  method: method,
);

void main() {
  group('LoginPolicy.requiresAccount — stays anonymous', () {
    for (final path in [
      Api.searchAll,
      Api.searchByType,
      Api.searchSuggest,
      Api.searchDefault,
      Api.hotSearchList,
      Api.searchTrending,
      Api.hotList,
      Api.liveList,
      Api.getRankApi,
      Api.relatedList,
      Api.videoIntro,
      Api.replyList,
      Api.memberInfo,
      Api.searchArchive,
      HttpString.appBaseUrl + GrpcUrl.dmSegMobile,
      HttpString.appBaseUrl + GrpcUrl.mainList,
      HttpString.appBaseUrl + GrpcUrl.view,
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
      Api.favResourceList,
      Api.mediaList,
      Api.setLiveFavTag,
      '${HttpString.appBaseUrl}/x/v2/account/myinfo',
      for (final type in ProfileType.values)
        '/x/member/app/${type.name}/update',
      HttpString.appBaseUrl + GrpcUrl.sendMsg,
      HttpString.appBaseUrl + GrpcUrl.sessionMain,
      HttpString.appBaseUrl + GrpcUrl.audioPlayUrl,
      HttpString.appBaseUrl + GrpcUrl.dynRed,
    ]) {
      test(path, () => expect(LoginPolicy.requiresAccount(_req(path)), true));
    }

    test('csrf-protected write in body (map)', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(
            Api.relationMod,
            data: {'fid': 1, 'act': 1, 'csrf': 'x'},
            method: 'POST',
          ),
        ),
        true,
      );
    });

    test('csrf-protected write in query', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(Api.replyAdd, query: {'csrf': 'x'}, method: 'POST'),
        ),
        true,
      );
    });

    test('csrf-protected write in form data', () {
      expect(
        LoginPolicy.requiresAccount(
          _req(
            Api.shootDanmaku,
            data: FormData.fromMap({'csrf': 'x'}),
            method: 'POST',
          ),
        ),
        true,
      );
    });
  });

  group('LoginPolicy.bind — home 推荐 feed follows the recommend role', () {
    final account = LoginAccount(
      BiliCookieJar.fromJson({'DedeUserID': '123', 'bili_jct': 'csrf'}),
      'access-key',
      'refresh-token',
    );
    final recommend = [
      Api.recommendListApp,
      Api.recommendListWeb,
      Api.feedDislike,
      Api.feedDislikeCancel,
    ];

    for (final path in recommend) {
      test('login mode + recommend role account -> account: $path', () {
        expect(
          LoginPolicy.bind(account, _req(path), loginMode: true),
          same(account),
        );
      });

      test('login mode + anonymous recommend role -> anonymous: $path', () {
        expect(
          LoginPolicy.bind(AnonymousAccount(), _req(path), loginMode: true),
          isA<AnonymousAccount>(),
        );
      });

      test('incognito -> anonymous: $path', () {
        expect(
          LoginPolicy.bind(account, _req(path), loginMode: false),
          isA<AnonymousAccount>(),
        );
      });
    }

    test('explicit account: kept in login mode (comment check)', () {
      final options = _req(Api.replyReplyList, query: {'csrf': 'csrf'})
        ..extra[LoginPolicy.explicitAccount] = true;
      expect(
        LoginPolicy.bind(account, options, loginMode: true),
        same(account),
      );
    });

    test('explicit account: still anonymous in incognito', () {
      final options = _req(Api.replyReplyList)
        ..extra[LoginPolicy.explicitAccount] = true;
      expect(
        LoginPolicy.bind(account, options, loginMode: false),
        isA<AnonymousAccount>(),
      );
    });

    test('the same read without the flag stays anonymous (other half)', () {
      expect(
        LoginPolicy.bind(
          account,
          _req(Api.replyReplyList, query: {'csrf': 'csrf'}),
          loginMode: true,
        ),
        isA<AnonymousAccount>(),
      );
    });

    test('other home tabs stay anonymous in login mode', () {
      for (final path in [Api.hotList, Api.liveList, Api.getRankApi]) {
        expect(
          LoginPolicy.bind(account, _req(path), loginMode: true),
          isA<AnonymousAccount>(),
          reason: path,
        );
      }
    });
  });
}
