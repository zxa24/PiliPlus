/// Small JSON helpers shared by the models and the parsers.
///
/// The one non-obvious decision here is [collectByKey]. InnerTube response
/// shapes move between YouTube versions, and a hardcoded path
/// (`contents.twoColumnSearchResultsRenderer.primaryContents…`) breaks silently
/// when a wrapper appears or disappears. Searching the tree for the renderer
/// key we actually want survives that, and was measurably more robust in the
/// spike. The cost is that we cannot tell *where* in the document a hit came
/// from, so ordering is the document's own order — which is what we want for a
/// result list anyway.
library;

/// Numbers arrive as int, double or decimal string depending on the field.
int? asInt(Object? v) => switch (v) {
  final int i => i,
  final double d => d.toInt(),
  final String s => int.tryParse(s) ?? double.tryParse(s)?.toInt(),
  _ => null,
};

/// Flatten one of InnerTube's several text shapes into a plain string:
/// `"text"`, `{simpleText}`, `{runs:[{text}]}`, `{content}`.
String readText(Object? o) {
  if (o is String) return o;
  if (o is Map) {
    if (o['simpleText'] is String) return o['simpleText'] as String;
    if (o['runs'] is List) {
      return (o['runs'] as List)
          .whereType<Map>()
          .map((r) => r['text']?.toString() ?? '')
          .join();
    }
    if (o['content'] is String) return o['content'] as String;
  }
  return '';
}

/// Map a JSON array of objects, skipping anything that is not an object.
List<T> mapList<T>(Object? list, T Function(Map<String, dynamic>) f) {
  if (list is! List) return const [];
  return list
      .whereType<Map>()
      .map((m) => f(m.cast<String, dynamic>()))
      .toList(growable: false);
}

/// Every value stored under [key] anywhere in [node], in document order.
List<Object?> collectByKey(Object? node, String key, {int maxDepth = 40}) {
  final out = <Object?>[];
  void walk(Object? n, int depth) {
    if (depth > maxDepth) return;
    if (n is Map) {
      for (final e in n.entries) {
        if (e.key == key) out.add(e.value);
        walk(e.value, depth + 1);
      }
    } else if (n is List) {
      for (final x in n) {
        walk(x, depth + 1);
      }
    }
  }

  walk(node, 0);
  return out;
}

/// [collectByKey] narrowed to JSON objects.
List<Map<String, dynamic>> collectObjects(
  Object? node,
  String key, {
  int maxDepth = 40,
}) => collectByKey(node, key, maxDepth: maxDepth)
    .whereType<Map>()
    .map((m) => m.cast<String, dynamic>())
    .toList(growable: false);

/// Every `continuationCommand.token` in [node], de-duplicated, document order.
///
/// A `next` response carries several: the related-videos one, the comments one,
/// and per-panel ones. Callers pick by probing, not by position — the order is
/// not a contract.
List<String> collectContinuationTokens(Object? node) {
  final seen = <String>{};
  for (final c in collectObjects(node, 'continuationCommand')) {
    final t = c['token'];
    if (t is String && t.isNotEmpty) seen.add(t);
  }
  return seen.toList(growable: false);
}

/// Parse `4:13` / `1:02:30` / `13` into a [Duration]. Returns null for
/// anything else, including the "LIVE" label.
Duration? parseClockDuration(String? s) {
  if (s == null) return null;
  final parts = s.trim().split(':');
  if (parts.isEmpty || parts.length > 3) return null;
  var total = 0;
  for (final p in parts) {
    final n = int.tryParse(p.trim());
    if (n == null || n < 0) return null;
    total = total * 60 + n;
  }
  return Duration(seconds: total);
}
