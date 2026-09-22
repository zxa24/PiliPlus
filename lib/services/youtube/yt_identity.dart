/// LibrePili — YouTube support, stage 1 (data layer).
///
/// THE ONE PLACE where YouTube's InnerTube client identities live. Everything
/// here is a magic constant lifted out of NewPipeExtractor (GPL-3.0, the same
/// licence as this app) — `services/youtube/ClientsConstants.java`,
/// `InnertubeClientRequestInfo.java`, `YoutubeParsingHelper.java`. Credit is
/// theirs; none of it was guessed.
///
/// ## These constants ARE EXPECTED TO ROT
///
/// `clientVersion` in particular. YouTube retires client versions, and when it
/// retires ours the player endpoint answers **HTTP 404 with a Google-RPC error
/// envelope** (`{"error":{"code":404,"message":"Requested entity was not
/// found.","status":"NOT_FOUND"}}`) — measured 2026-09-20 by sending
/// `VISIONOS 0.01`. The classifier turns that into [Cause.clientBroken], never
/// into "this video is gone", so the breakage is loud instead of silent.
///
/// ### How to re-derive them
///
/// 1. **Preferred — read them off NewPipeExtractor HEAD.** The clone used for
///    this port is at `_refs/NewPipeExtractor`; the values live in
///    `extractor/src/main/java/org/schabi/newpipe/extractor/services/youtube/
///    ClientsConstants.java`. Every field below has a same-named counterpart
///    there. NewPipe bumps them when YouTube breaks them, which is the cheapest
///    signal we get.
/// 2. **WEB `clientVersion` can also be scraped live**: GET
///    `https://www.youtube.com/` (or `/sw.js_data`) and pull
///    `"INNERTUBE_CLIENT_VERSION":"2.YYYYMMDD.NN.NN"` out of the page. NewPipe
///    does exactly this and falls back to a hardcoded value; we currently only
///    hardcode. Stage 1 does not scrape — see the uncertainty list in the
///    stage report.
/// 3. **Verify a candidate** by minting a visitorData (§[visitorIdEndpoint])
///    and making one `player` call for a known-good public id. `NOT_FOUND`
///    means the version is retired; `FAILED_PRECONDITION` / `INVALID_ARGUMENT`
///    mean the *context shape* is wrong, not the version.
///
/// ### Measured, 2026-09-20 (research/youtube-direct-spike.md §1.4)
///
/// | identity | player | adaptiveFormats | plain `url` |
/// |---|---|---|---|
/// | VISIONOS 1.04 | 200 | 120 | **120/120** |
/// | IOS 20.03.02  | 200 | 125 | 125/125 |
/// | ANDROID 21.03.36 | 200 | 103 | **0/103** (SABR-only) |
/// | WEB 2.20260805.01.00 | 200 | 0 | `UNPLAYABLE / "Video unavailable"` |
///
/// So: **VISIONOS for streams, WEB for search/next/browse.** ANDROID and WEB
/// are kept below only because the classifier's SABR and generic-unavailable
/// branches are defined against what they return; nothing routes to them.
library;

/// One InnerTube client identity: the `context.client` block plus the headers
/// that identity sends.
class YtClientIdentity {
  const YtClientIdentity({
    required this.name,
    required this.version,
    required this.id,
    required this.headers,
    this.clientScreen,
    this.platform,
    this.deviceMake,
    this.deviceModel,
    this.osName,
    this.osVersion,
    this.gapis = false,
  });

  /// `context.client.clientName`, e.g. `VISIONOS`.
  final String name;

  /// `context.client.clientVersion`. **This is the field that rots.**
  final String version;

  /// The numeric client id. Only the WEB identity actually sends it (as the
  /// `X-YouTube-Client-Name` header); kept for all of them so a new identity
  /// can be added without hunting for it.
  final String id;

  final String? clientScreen;
  final String? platform;
  final String? deviceMake;
  final String? deviceModel;
  final String? osName;
  final String? osVersion;

  /// Whether this identity's calls go to `youtubei.googleapis.com` (`true`) or
  /// `www.youtube.com` (`false`). NewPipe sends VISIONOS to the gapis host.
  /// Note the `visitor_id` bootstrap is on `www.youtube.com` for *every*
  /// identity — that is what NewPipe does (`YoutubeStreamHelper.java:87`
  /// passes `YOUTUBEI_V1_URL`) and it works.
  final bool gapis;

  /// The headers this identity sends, built for a region code.
  final Map<String, String> Function(String gl) headers;

  /// The `context.client` map. Ported verbatim from
  /// `YoutubeParsingHelper.prepareJsonBuilder`.
  Map<String, dynamic> clientContext({
    String? visitorData,
    String hl = defaultHl,
    String gl = defaultGl,
  }) => <String, dynamic>{
    'clientName': name,
    'clientVersion': version,
    'clientScreen': ?clientScreen,
    'platform': ?platform,
    'visitorData': ?visitorData,
    'deviceMake': ?deviceMake,
    'deviceModel': ?deviceModel,
    'osName': ?osName,
    'osVersion': ?osVersion,
    'hl': hl,
    'gl': gl,
    'utcOffsetMinutes': 0,
  };

  @override
  String toString() => '$name/$version';
}

/// The language YouTube answers in.
///
/// Every string this app shows that it did not write itself comes from here:
/// '22.9万位订阅者', '5 天前', '962 条回复', the publish date. While this was
/// 'en-GB' the interface was Chinese and everything inside it was English,
/// and no amount of work on the Dart side could have fixed that — the words
/// are chosen by the server.
///
/// [defaultGl] stays neutral on purpose. `hl` picks the language of the
/// text; `gl` picks the *content region*, and pointing that at a specific
/// country invites that country's availability rules onto videos that would
/// otherwise play. They are different questions and only one of them is
/// about what language to read in.
///
/// The trade-off this makes: a locale is a (weak) fingerprint, and one
/// hardcoded value for everyone is the least distinguishing thing to send.
/// Sending the interface's own language is more distinguishing — and is
/// what makes the app usable in that language.
const String defaultHl = 'zh-CN';
const String defaultGl = 'GB';

const String youtubeiWebBase = 'https://www.youtube.com/youtubei/v1/';
const String youtubeiGapisBase = 'https://youtubei.googleapis.com/youtubei/v1/';

/// The bootstrap endpoint. Always on the www host, for every identity.
const String visitorIdEndpoint = 'visitor_id';

const String _desktopUa =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) '
    'Gecko/20100101 Firefox/140.0';

/// Consent cookie. Without it, EU egress IPs are 302'd to
/// `consent.youtube.com`. It is a fixed literal, carries no user state, and is
/// the ONLY cookie this layer ever sends — see `yt_transport.dart`.
const String socsConsentCookie = 'SOCS=CAISAiAD';

String _visionOsUa(String gl) =>
    'com.google.visionos.youtube/1.04(RealityDevice17,1; U; '
    'CPU visionOS 26_6_0 like Mac OS X; $gl)';

Map<String, String> _visionOsHeaders(String gl) => {
  'User-Agent': _visionOsUa(gl),
  'X-Goog-Api-Format-Version': '2',
};

Map<String, String> _webHeaders(String gl) => {
  'User-Agent': _desktopUa,
  'Origin': 'https://www.youtube.com',
  'Referer': 'https://www.youtube.com',
  'X-YouTube-Client-Name': '1',
  'X-YouTube-Client-Version': YtClients.webVersion,
  'Cookie': socsConsentCookie,
};

Map<String, String> _iosHeaders(String gl) => {
  'User-Agent':
      'com.google.ios.youtube/20.03.02(iPhone16,2; U; '
      'CPU iOS 18_2_1 like Mac OS X; $gl)',
  'X-Goog-Api-Format-Version': '2',
};

Map<String, String> _androidHeaders(String gl) => {
  'User-Agent':
      'com.google.android.youtube/21.03.36 (Linux; U; Android 15; $gl) gzip',
  'X-Goog-Api-Format-Version': '2',
};

/// The identities themselves. Add one here and nowhere else.
abstract final class YtClients {
  /// WEB's version is also the value of the `X-YouTube-Client-Version` header,
  /// so it is named once and referenced twice.
  static const String webVersion = '2.20260805.01.00';

  /// Stream extraction. NewPipeExtractor HEAD uses this and only this since
  /// `9ed62db` (2026-08-06) deleted ANDROID / IOS / WEB_EMBEDDED_PLAYER.
  static const YtClientIdentity visionOs = YtClientIdentity(
    name: 'VISIONOS',
    version: '1.04',
    id: '101',
    clientScreen: 'WATCH',
    platform: 'MOBILE',
    deviceMake: 'Apple',
    deviceModel: 'RealityDevice17,1',
    osName: 'visionOS',
    osVersion: '26.6.0.23O770',
    gapis: true,
    headers: _visionOsHeaders,
  );

  /// Metadata, search, next (related + comments), browse.
  static const YtClientIdentity web = YtClientIdentity(
    name: 'WEB',
    version: webVersion,
    id: '1',
    clientScreen: 'WATCH',
    platform: 'DESKTOP',
    headers: _webHeaders,
  );

  /// Second stream identity. Measured 2026-09-20 to still serve plain URLs
  /// (125/125) with no poToken. NewPipe deleted it on the stated grounds that
  /// nobody can generate poTokens for it. Stage 1 does not route to it; it is
  /// here so a later stage can try it before conceding an IP block, which
  /// distinguishes "our identity went stale" from "our network is walled off".
  static const YtClientIdentity ios = YtClientIdentity(
    name: 'IOS',
    version: '20.03.02',
    id: '5',
    clientScreen: 'WATCH',
    platform: 'MOBILE',
    deviceMake: 'Apple',
    deviceModel: 'iPhone16,2',
    osName: 'iOS',
    osVersion: '18.2.1.22C161',
    gapis: true,
    headers: _iosHeaders,
  );

  /// NOT used. Measured to return a full `adaptiveFormats` array in which not
  /// one entry carries a `url` or a `signatureCipher` — the SABR-only shape the
  /// classifier has a dedicated branch for. Kept as the reference for that
  /// branch and for the fixture that tests it.
  static const YtClientIdentity android = YtClientIdentity(
    name: 'ANDROID',
    version: '21.03.36',
    id: '3',
    clientScreen: 'WATCH',
    platform: 'MOBILE',
    osName: 'Android',
    osVersion: '15',
    gapis: true,
    headers: _androidHeaders,
  );
}
