/// LibrePili: moving the YouTube subscription list in and out of the app.
///
/// In: a NewPipe subscriptions export, PipePipe's (the same JSON — read off
/// PipePipeClient's `ImportExportJsonHelper.java`, whose YouTube is also
/// service 0 in `ServiceList.java`, 2026-10-19), or Google Takeout's
/// `subscriptions.csv`. Out: the NewPipe JSON, which both of those import.
///
/// Not read: NewPipe's full backup `.zip` — its subscriptions sit in a
/// SQLite database, and reading one would mean a new dependency. Nothing
/// here touches the network; a channel the file names by `@handle` instead
/// of its `UC…` id cannot be resolved offline and is skipped as invalid.
library;

import 'dart:convert';

/// `UC` plus 22 characters of YouTube's id alphabet.
final ytChannelIdPattern = RegExp(r'^UC[A-Za-z0-9_-]{22}$');

/// The channel id in [s]: either the bare id or a `…/channel/UC…` URL.
String? ytChannelIdFrom(String s) {
  final t = s.trim();
  if (ytChannelIdPattern.hasMatch(t)) return t;
  final m = RegExp(r'/channel/(UC[A-Za-z0-9_-]{22})(?:[/?#]|$)').firstMatch(t);
  return m?.group(1);
}

/// What one file held: the channels it names (first time each), and what
/// was left out and why.
class YtSubscriptionFile {
  const YtSubscriptionFile({
    required this.channels,
    this.invalid = 0,
    this.otherService = 0,
    this.duplicates = 0,
  });

  final List<({String channelId, String name})> channels;

  /// Rows with no readable `UC…` id.
  final int invalid;

  /// NewPipe / PipePipe rows of another service (SoundCloud, BiliBili, …).
  final int otherService;

  /// Rows naming a channel an earlier row already named.
  final int duplicates;
}

/// Reads [text] as whichever of the supported files it is. Throws a
/// [FormatException] when it is none of them.
YtSubscriptionFile parseYtSubscriptionFile(String text) {
  final t = text.startsWith('﻿') ? text.substring(1) : text;
  final trimmed = t.trimLeft();
  if (trimmed.startsWith('{')) {
    final Object? json;
    try {
      json = jsonDecode(trimmed);
    } catch (e) {
      throw FormatException('无法解析 JSON：$e');
    }
    return parseNewPipeSubscriptions(json);
  }
  return parseTakeoutSubscriptionsCsv(t);
}

/// NewPipe's / PipePipe's
/// `{"app_version":…, "subscriptions":[{"service_id":0,"url":…,"name":…}]}`.
/// A row without `service_id` counts as YouTube, as their own reader does.
YtSubscriptionFile parseNewPipeSubscriptions(Object? json) {
  final list = json is Map ? json['subscriptions'] : null;
  if (list is! List) {
    throw const FormatException('不是 NewPipe / PipePipe 的订阅导出文件');
  }
  final out = _Collector();
  for (final row in list) {
    if (row is! Map) {
      out.invalid++;
      continue;
    }
    final service = row['service_id'] ?? 0;
    if (service != 0) {
      out.otherService++;
      continue;
    }
    out.add(row['url']?.toString(), row['name']?.toString());
  }
  return out.result();
}

/// Google Takeout's `subscriptions.csv`: a `Channel Id,Channel Url,Channel
/// Title` header (in the account's language — so the columns are taken by
/// position), then one channel a row.
YtSubscriptionFile parseTakeoutSubscriptionsCsv(String text) {
  final rows = [
    for (final line in const LineSplitter().convert(text))
      if (line.trim().isNotEmpty) _csvRow(line),
  ];
  final out = _Collector();
  for (final (i, row) in rows.indexed) {
    final id = ytChannelIdFrom(row.first) ?? (row.length > 1 ? row[1] : '');
    // the header, however it is worded
    if (i == 0 && ytChannelIdFrom(id) == null) continue;
    out.add(id, row.length > 2 ? row[2] : null);
  }
  // a file of nothing but unreadable rows is not a subscription list (a
  // header alone is: an account that followed no one — but only a row that
  // reads as one, not any one line, such as a minified JSON array)
  if (out.channels.isEmpty &&
      (rows.length != 1 || !_looksLikeTakeoutHeader(rows.single))) {
    throw const FormatException('不是可识别的订阅文件');
  }
  return out.result();
}

/// Takeout's header, in whatever language: three named columns, none of
/// them a channel or a URL.
bool _looksLikeTakeoutHeader(List<String> row) =>
    row.length == 3 &&
    row.every(
      (c) =>
          c.trim().isNotEmpty &&
          !c.contains('://') &&
          ytChannelIdFrom(c) == null,
    );

/// The NewPipe JSON for [channels]; `app_version` names this app, which
/// neither reader checks.
String toNewPipeSubscriptionsJson(
  Iterable<({String channelId, String name})> channels, {
  required String appVersion,
  required int appVersionInt,
}) => const JsonEncoder.withIndent('  ').convert({
  'app_version': appVersion,
  'app_version_int': appVersionInt,
  'subscriptions': [
    for (final c in channels)
      {
        'service_id': 0,
        'url': 'https://www.youtube.com/channel/${c.channelId}',
        'name': c.name.isEmpty ? c.channelId : c.name,
      },
  ],
});

class _Collector {
  final channels = <({String channelId, String name})>[];
  final _seen = <String>{};
  var invalid = 0;
  var otherService = 0;
  var duplicates = 0;

  void add(String? urlOrId, String? name) {
    final id = urlOrId == null ? null : ytChannelIdFrom(urlOrId);
    if (id == null) {
      invalid++;
    } else if (!_seen.add(id)) {
      duplicates++;
    } else {
      channels.add((channelId: id, name: (name ?? '').trim()));
    }
  }

  YtSubscriptionFile result() => YtSubscriptionFile(
    channels: channels,
    invalid: invalid,
    otherService: otherService,
    duplicates: duplicates,
  );
}

/// One CSV line: commas split fields, `"…"` quotes them, `""` is a quote.
List<String> _csvRow(String line) {
  final fields = <String>[];
  final cur = StringBuffer();
  var quoted = false;
  for (var i = 0; i < line.length; i++) {
    final c = line[i];
    if (quoted) {
      if (c == '"') {
        if (i + 1 < line.length && line[i + 1] == '"') {
          cur.write('"');
          i++;
        } else {
          quoted = false;
        }
      } else {
        cur.write(c);
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == ',') {
      fields.add(cur.toString());
      cur.clear();
    } else {
      cur.write(c);
    }
  }
  fields.add(cur.toString());
  return [for (final f in fields) f.trim()];
}
