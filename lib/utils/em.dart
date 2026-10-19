abstract final class Em {
  static final _exp = RegExp('<[^>]*>([^<]*)</[^>]*>');
  static final _htmlRegExp = RegExp(
    r'&(lt|gt|quot|apos|nbsp|amp|#[xX][a-fA-F\d]{1,6}|#\d{1,7});',
  );

  static String regCate(String origin) {
    final matches = _exp.firstMatch(origin);
    return matches?.group(1) ?? origin;
  }

  static String parseHtml(String str) {
    return str.replaceAllMapped(
      _htmlRegExp,
      (match) => switch (match.group(1)) {
        'lt' => '<',
        'gt' => '>',
        'quot' => '"',
        'apos' => "'",
        'nbsp' => ' ',
        'amp' => '&',
        // numeric: hex or decimal, any code point (emoji are above
        // U+FFFF); one that is not a character stays as written
        var i? when (i.startsWith('#')) => switch (i[1] == 'x' || i[1] == 'X'
            ? int.parse(i.substring(2), radix: 16)
            : int.parse(i.substring(1))) {
          final c when c <= 0x10FFFF && (c < 0xD800 || c > 0xDFFF) =>
            String.fromCharCode(c),
          _ => match.group(0)!,
        },
        _ => match.group(0)!,
      },
    );
  }

  static List<({bool isEm, String text})> regTitle(String origin) {
    List<({bool isEm, String text})> res = [];
    origin.splitMapJoin(
      _exp,
      onMatch: (Match match) {
        res.add((isEm: true, text: parseHtml(match[1] ?? match[0]!)));
        return '';
      },
      onNonMatch: (String str) {
        if (str != '') {
          res.add((isEm: false, text: parseHtml(str)));
        }
        return '';
      },
    );
    return res;
  }
}
