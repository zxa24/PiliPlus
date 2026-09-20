final _regExp = RegExp("^(http:)?//", caseSensitive: false);

extension NullableStringExt on String? {
  String get http2https => this?.replaceFirst(_regExp, "https://") ?? '';

  bool get isNullOrEmpty => this == null || this!.isEmpty;
}

extension RegExpExt on RegExp {
  /// Whether this ban-word pattern filters anything. A pattern that matches
  /// the empty string (a stray `|`, as in `测试|`) would filter out every
  /// item, so it counts as no filter. Single definition on purpose: the
  /// `enableFilter` flags and the settings dialog that writes them must not
  /// end up with two meanings of "the filter is on".
  bool get isUsableFilter => pattern.isNotEmpty && !hasMatch('');
}

extension StringExt on String {
  /// Whether this may be opened in the in-app WebView / handed to the OS.
  /// A deep link (`bilibili://browser/?url=…`) is attacker-controlled, and
  /// `file:` / `content:` would render app-private files (hive/account.hive),
  /// `javascript:` would run in the page that is already loaded.
  bool get isHttpUrl {
    final scheme = Uri.tryParse(this)?.scheme.toLowerCase();
    return scheme == 'http' || scheme == 'https';
  }

  String subLength(int length) {
    if (this.length < length) return this;
    return substring(0, length);
  }

  String get substring1 {
    return substring(1, length - 1);
  }

  String get emote {
    int start = 0;
    int end = length;

    loop:
    for (int index = length - 1; index >= 0; index--) {
      switch (codeUnitAt(index)) {
        case 0x5F || 0x7C: // `_`, `|`
          start = index + 1;
          break loop;
        case 0x5B: // `[`
          start = index + 1;
        case 0x5D: // `]`
          end = index;
      }
    }

    return substring(start, end);
  }
}
