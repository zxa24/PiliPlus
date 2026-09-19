import 'package:PiliPlus/grpc/url.dart';
import 'package:PiliPlus/http/api.dart';
import 'package:PiliPlus/http/constants.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/account.dart';
import 'package:PiliPlus/utils/storage_pref.dart';
import 'package:dio/dio.dart';

/// LibrePili privacy model: incognito by default, login is opt-in, and even
/// in login mode the account is attached only to requests that need it.
///
/// In login mode the home "推荐" feed (and its "不感兴趣" feedback) uses the
/// account assigned to the recommend role, so the feed is personalised; with
/// that role left anonymous it stays anonymous. Everything else (search,
/// other home tabs, video info, comments, spaces...) is sent anonymously so
/// it cannot be tied to the account. Incognito: everything is anonymous.
abstract final class LoginPolicy {
  /// Opt-in switch. Off: every account role is anonymous (stored accounts
  /// stay dormant). On: see [requiresAccount].
  static bool get loginMode => Pref.loginMode;

  /// Account-private reads, app-API writes (signed with access_key instead of
  /// csrf), login-flow calls and stream URLs (high quality needs an account).
  static const Set<String> _accountApis = {
    // stream (1080P+ / VIP quality)
    Api.ugcUrl, Api.pgcUrl, Api.pugvUrl, Api.tvPlayUrl,
    // account info
    Api.userInfo, Api.userStatOwner, Api.getCoin, Api.coinLog, Api.loginLog,
    Api.expLog, Api.moralLog, Api.loginDevices, Api.userRealName,
    Api.myEmote, Api.spaceSetting,
    // own profile (账号资料) page: read + app-API edits (access_key, no csrf)
    '${HttpString.appBaseUrl}/x/v2/account/myinfo',
    '/x/member/app/uname/update', '/x/member/app/sign/update',
    '/x/member/app/sex/update', '/x/member/app/birthday/update',
    // relation to the current user
    Api.pgcLikeCoinFav,
    Api.videoRelation, Api.seasonStatus, Api.relation, Api.relations,
    Api.sameFollowing, Api.followedUp, Api.followSearch, Api.blackLst,
    Api.followUpTag, Api.followUpGroup, Api.danmakuFilter,
    Api.replyInteraction, Api.danmakuEditState,
    // own favorites / later / history
    Api.favFolder, Api.userFavFolder, Api.favFolderInfo, Api.userSubFolder,
    Api.favPgc, Api.favArticle, Api.favPugv, Api.favTopicList,
    Api.favSeasonList, Api.seeYouLater, Api.historyList, Api.historyStatus,
    // folder contents (private folders) and watch-later / fav "play all"
    Api.favResourceList, Api.mediaList,
    Api.searchHistory, Api.noteList, Api.archiveNote, Api.userNoteList,
    // playback history reporting
    Api.heartBeat, Api.historyReport, Api.roomEntryAction,
    Api.mediaListHistory, Api.liveLikeReport,
    // followed feed
    Api.followUp, Api.dynUplist, Api.followDynamic, Api.getUnreadDynamic,
    Api.liveFollow, Api.getLiveFavTag, Api.followeeVotes,
    // saving the favourite live areas (app-API write, access_key only)
    Api.setLiveFavTag,
    // messages
    Api.msgUnread, Api.msgFeedUnread, Api.msgFeedReply, Api.msgFeedAt,
    Api.msgFeedLike, Api.msgLikeDetail, Api.msgSysNotify,
    Api.msgSysUpdateCursor, Api.sessionList, Api.sessionAccountList,
    Api.sessionMsg, Api.ackSessionMsg, Api.imUserInfos, Api.getSessionSs,
    Api.getMsgDnd,
    // app-API writes (access_key, no csrf)
    Api.likeVideo, Api.dislikeVideo, Api.coinVideo,
    // login flow
    Api.qrcodeConfirm, Api.logout, Api.activateBuvidApi,
  };

  /// The home "推荐" feed and its dislike feedback (user decision: not
  /// anonymous in login mode). Bound to the recommend role's account (see
  /// ApiType), which may itself be anonymous.
  static const Set<String> _recommendApis = {
    Api.recommendListApp,
    Api.recommendListWeb,
    Api.feedDislike,
    Api.feedDislikeCancel,
  };

  static const Set<String> _grpcAccountApis = {
    GrpcUrl.dynRed,
    GrpcUrl.audioPlayUrl,
    GrpcUrl.audioThumbUp,
    GrpcUrl.audioTripleLike,
    GrpcUrl.audioCoinAdd,
  };

  static const List<String> _grpcAccountPrefixes = [GrpcUrl.im, GrpcUrl.im2];

  static const _csrfKeys = {'csrf', 'biliCSRF', 'csrf_token'};
  static const _selfKeys = ['mid', 'vmid', 'up_mid'];

  /// Whether UI that writes (comments, replies, danmaku, live chat) is
  /// shown: it needs a logged-in account and the "hide interaction" switch
  /// off. Existing comments and danmaku are displayed either way.
  static bool get canInteract => Accounts.main.isLogin && !Pref.hideInteraction;

  /// The account [options] goes out with: [account] is the one its role
  /// resolved to (see ApiType), kept only when login mode is on and the
  /// request needs it; otherwise anonymous. [loginMode] defaults to the
  /// setting (tests pass it).
  static Account bind(
    Account account,
    RequestOptions options, {
    bool? loginMode,
  }) {
    if (account is LoginAccount &&
        (!(loginMode ?? LoginPolicy.loginMode) || !requiresAccount(options))) {
      return AnonymousAccount();
    }
    return account;
  }

  /// Whether [options] may carry the logged-in account. False means it is
  /// sent anonymously even in login mode.
  static bool requiresAccount(RequestOptions options) {
    final path = options.path;
    // gRPC requests are sent as `appBaseUrl + GrpcUrl.x`
    final grpcPath = path.startsWith(HttpString.appBaseUrl)
        ? path.substring(HttpString.appBaseUrl.length)
        : path;
    if (_accountApis.contains(path) ||
        _recommendApis.contains(path) ||
        _grpcAccountApis.contains(grpcPath) ||
        _grpcAccountPrefixes.any(grpcPath.startsWith)) {
      return true;
    }
    final query = options.queryParameters;
    final data = options.data;
    // web writes are csrf-protected (some GET reads also carry csrf; they
    // are not writes and stay anonymous)
    if (options.method.toUpperCase() != 'GET' &&
        (query.keys.any(_csrfKeys.contains) ||
            (data is Map && data.keys.any(_csrfKeys.contains)) ||
            (data is FormData &&
                data.fields.any((e) => _csrfKeys.contains(e.key))))) {
      return true;
    }
    // reads scoped to the user themself (own space, own followings...)
    final mid = Accounts.main.mid;
    if (mid != 0) {
      for (final key in _selfKeys) {
        final v = query[key] ?? (data is Map ? data[key] : null);
        if (v != null && '$v' == '$mid') return true;
      }
    }
    return false;
  }
}
