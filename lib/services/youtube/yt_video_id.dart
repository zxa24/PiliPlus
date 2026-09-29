/// Reducing whatever the user has in hand to the bare 11-character video id.
///
/// Privacy-load-bearing: the id is the ONLY thing about a video that this layer
/// is allowed to send. A pasted watch URL routinely carries `si=` (a share
/// token that identifies the sharing session), `pp=` (an opaque tracking blob),
/// `list=`, `t=`, UTM parameters — none of which we want to hand back to
/// YouTube. They are dropped by **extraction**, not by a denylist: we take the
/// 11 characters we recognise and throw the rest of the string away, so a
/// parameter nobody has heard of yet is discarded by default.
library;

final RegExp _idRe = RegExp(r'^[A-Za-z0-9_-]{11}$');

/// True when [s] is exactly an 11-char video id.
bool isYouTubeVideoId(String s) => _idRe.hasMatch(s);

/// The bare video id in [input], or null if there is none.
///
/// Accepts the id itself, `youtube.com/watch?v=`, `youtu.be/`, `/shorts/` and
/// `/embed/` forms, with or without extra query parameters.
String? tryParseYouTubeVideoId(String input) {
  final s = input.trim();
  if (_idRe.hasMatch(s)) return s;
  return _idInLink(s);
}

/// The video id in [input] only when it is a YouTube link — never a bare
/// 11-character string: typed into a search box, that is a word to search
/// for (`travisleon1` opened as a video, 2026-09-29).
String? tryParseYouTubeLink(String input) => _idInLink(input.trim());

/// A link on one of YouTube's own hosts, with or without its scheme. Every
/// link in the app is asked this before it is routed (PiliScheme), so any
/// other host's path — a bilibili space whose uid has 11 digits — must not
/// be read for an id.
String? _idInLink(String s) {
  if (s.isEmpty || s.contains(RegExp(r'\s'))) return null;
  final Uri u;
  try {
    u = Uri.parse(s.contains('://') ? s : 'https://$s');
  } catch (_) {
    return null;
  }
  final host = u.host.toLowerCase();
  if (!_youTubeHost(host)) return null;
  final segments = u.pathSegments;
  final candidates = <String?>[
    u.queryParameters['v'],
    if (host == 'youtu.be' && segments.isNotEmpty) segments.first,
    if (segments.length >= 2 &&
        (segments[0] == 'shorts' ||
            segments[0] == 'embed' ||
            segments[0] == 'live' ||
            segments[0] == 'v'))
      segments[1],
  ];
  for (final c in candidates) {
    if (c != null && _idRe.hasMatch(c)) return c;
  }
  return null;
}

bool _youTubeHost(String host) =>
    host == 'youtu.be' ||
    host == 'youtube.com' ||
    host.endsWith('.youtube.com') ||
    host == 'youtube-nocookie.com' ||
    host.endsWith('.youtube-nocookie.com');

/// Like [tryParseYouTubeVideoId] but throws instead of returning null. Use at
/// the boundary where a caller has promised an id.
String parseYouTubeVideoId(String input) {
  final id = tryParseYouTubeVideoId(input);
  if (id == null) {
    // Deliberately does NOT echo the input: it may be a URL carrying share
    // tokens, and an exception message ends up in logs.
    throw ArgumentError('not a YouTube video id or watch URL');
  }
  return id;
}
