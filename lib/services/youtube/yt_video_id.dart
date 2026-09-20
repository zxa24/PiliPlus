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
  final Uri u;
  try {
    u = Uri.parse(s);
  } catch (_) {
    return null;
  }
  final segments = u.pathSegments;
  final candidates = <String?>[
    u.queryParameters['v'],
    if (u.host.endsWith('youtu.be') && segments.isNotEmpty) segments.last,
    if (segments.length >= 2 &&
        (segments[0] == 'shorts' ||
            segments[0] == 'embed' ||
            segments[0] == 'live' ||
            segments[0] == 'v'))
      segments[1],
    if (segments.isNotEmpty) segments.last,
  ];
  for (final c in candidates) {
    if (c != null && _idRe.hasMatch(c)) return c;
  }
  return null;
}

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
