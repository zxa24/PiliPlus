import 'package:PiliPlus/common/constants.dart';
import 'package:PiliPlus/models/common/account_type.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:PiliPlus/utils/accounts/grpc_headers.dart';
import 'package:PiliPlus/utils/id_utils.dart';
import 'package:cookie_jar/cookie_jar.dart';
import 'package:hive_ce/hive.dart';

sealed class Account {
  Map<String, dynamic>? toJson() => null;

  Future<void>? onChange() => null;

  Set<AccountType> get type => const {};

  bool get activated => false;

  set activated(bool value) => throw UnimplementedError();

  String? get accessKey => throw UnimplementedError();

  DefaultCookieJar get cookieJar => throw UnimplementedError();

  String get csrf => throw UnimplementedError();

  Future<void> delete() => throw UnimplementedError();

  Map<String, String> get headers => throw UnimplementedError();

  Map<String, String> get grpcHeaders => throw UnimplementedError();

  bool get isLogin => throw UnimplementedError();

  int get mid => throw UnimplementedError();

  String? get refresh => throw UnimplementedError();

  const Account();
}

@HiveType(typeId: 9)
class LoginAccount extends Account {
  @override
  final bool isLogin = true;
  @override
  @HiveField(0)
  final DefaultCookieJar cookieJar;
  @override
  @HiveField(1)
  String? accessKey;
  @override
  @HiveField(2)
  String? refresh;
  @override
  @HiveField(3)
  final Set<AccountType> type;

  @override
  bool activated = false;

  /// The server answered "not logged in" for a request that carried this
  /// account. It is kept (the user may re-login or remove it) but not used
  /// for requests; see [Accounts.markExpired].
  @HiveField(4)
  bool expired = false;

  @override
  late final int mid = int.parse(_midStr);

  @override
  late final Map<String, String> headers = {
    ...Constants.baseHeaders,
    'x-bili-mid': _midStr,
    'x-bili-aurora-eid': IdUtils.genAuroraEid(mid),
  };

  @override
  late final Map<String, String> grpcHeaders = GrpcHeaders.newHeaders(
    accessKey,
  );

  @override
  // read from the jar each time, not cached, so it follows the jar rather
  // than whatever it happened to be at the first read: still the live token
  // while the record is (an expired account keeps its credentials), and
  // empty once [dropCredentials] has run
  String get csrf =>
      cookieJar
          .domainCookies['bilibili.com']?['/']?['bili_jct']
          ?.cookie
          .value ??
      '';

  /// Drops the credentials, keeping only what identifies the record in the
  /// account list. [Accounts.markExpired] deliberately does not call this —
  /// an expired account keeps its credentials until the user acts on the
  /// 已失效 entry — so the caller is [delete], which is that action. Call
  /// [onChange] to persist if the record itself is being kept.
  void dropCredentials() {
    // [_midStr] / the account list need DedeUserID; buvid3 is not a secret
    const keep = {'DedeUserID', 'buvid3'};
    cookieJar.domainCookies['bilibili.com']?['/']?.removeWhere(
      (name, _) => !keep.contains(name),
    );
    accessKey = null;
    refresh = null;
  }

  bool _hasDelete = false;

  @override
  Future<void> delete() {
    _hasDelete = true;
    // the user acted on this entry (logged it out or removed it): this is
    // where the credentials go, in memory as well as on disk — an expired
    // account keeps them until now, see [Accounts.markExpired]. The key is
    // read first because [dropCredentials] keeps DedeUserID but
    // [DefaultCookieJar.deleteAll] does not.
    final key = _midStr;
    dropCredentials();
    return Future.wait([cookieJar.deleteAll(), _box.delete(key)]);
  }

  @override
  Future<void>? onChange() {
    if (_hasDelete) return null;
    return _box.put(_midStr, this);
  }

  @override
  Map<String, dynamic>? toJson() => {
    'cookies': cookieJar.toJson(),
    'accessKey': accessKey,
    'refresh': refresh,
    'type': type.map((i) => i.index).toList(),
    if (expired) 'expired': true,
  };

  late final String _midStr = cookieJar
      .domainCookies['bilibili.com']!['/']!['DedeUserID']!
      .cookie
      .value;

  late final Box<LoginAccount> _box = Accounts.account;

  LoginAccount(
    this.cookieJar,
    this.accessKey,
    this.refresh, [
    Set<AccountType>? type,
  ]) : type = type ?? {} {
    cookieJar.setBuvid3();
  }

  factory LoginAccount.fromJson(Map json) => LoginAccount(
    BiliCookieJar.fromJson(json['cookies']),
    json['accessKey'],
    json['refresh'],
    (json['type'] as Iterable?)?.map((i) => AccountType.values[i]).toSet(),
  )..expired = json['expired'] == true;

  @override
  int get hashCode => mid.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is LoginAccount && mid == other.mid);
}

class AnonymousAccount extends Account {
  @override
  final bool isLogin = false;
  @override
  final DefaultCookieJar cookieJar = DefaultCookieJar()..setBuvid3();
  @override
  final String? accessKey = null;
  @override
  final String? refresh = null;
  @override
  final Set<AccountType> type = {};
  @override
  final int mid = 0;
  @override
  final String csrf = '';
  @override
  final Map<String, String> headers = Constants.baseHeaders;

  @override
  final Map<String, String> grpcHeaders = GrpcHeaders.newHeaders();

  @override
  bool activated = false;

  @override
  Future<void> delete() {
    grpcHeaders['x-bili-fawkes-req-bin'] = GrpcHeaders.fawkes;
    // the regenerated buvid3 is a new device id: it has to be activated again
    activated = false;
    return cookieJar.deleteAll().whenComplete(cookieJar.setBuvid3);
  }

  static final _instance = AnonymousAccount._();

  AnonymousAccount._();

  factory AnonymousAccount() => _instance;

  @override
  int get hashCode => cookieJar.hashCode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AnonymousAccount && cookieJar == other.cookieJar);
}

extension BiliCookie on Cookie {
  void setBiliDomain([String domain = '.bilibili.com']) {
    this.domain = domain;
    httpOnly = false;
    path = '/';
  }
}

extension BiliCookieJar on DefaultCookieJar {
  Map<String, String> toJson() {
    final cookies = domainCookies['bilibili.com']?['/'] ?? const {};
    return {for (final i in cookies.values) i.cookie.name: i.cookie.value};
  }

  List<Cookie> toList() =>
      domainCookies['bilibili.com']?['/']?.entries
          .map((i) => i.value.cookie)
          .toList() ??
      [];

  void setBuvid3() {
    (domainCookies['bilibili.com'] ??= {
      '/': {},
    })['/']!['buvid3'] ??= SerializableCookie(
      Cookie('buvid3', IdUtils.genBuvid3())..setBiliDomain(),
    );
  }

  static DefaultCookieJar fromJson(Map json) =>
      DefaultCookieJar(ignoreExpires: true)
        ..domainCookies['bilibili.com'] = {
          '/': {
            for (final i in json.entries)
              i.key: SerializableCookie(
                Cookie(i.key, i.value)..setBiliDomain(),
              ),
          },
        };

  static DefaultCookieJar fromList(List cookies) =>
      DefaultCookieJar(ignoreExpires: true)
        ..domainCookies['bilibili.com'] = {
          '/': {
            for (final i in cookies)
              i['name']!: SerializableCookie(
                Cookie(i['name']!, i['value']!)..setBiliDomain(),
              ),
          },
        };
}

final class NoAccount extends Account {
  const NoAccount();
}
