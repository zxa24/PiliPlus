import 'package:PiliPlus/models/common/subtitle_source.dart';

class Subtitle implements Comparable<Subtitle> {
  late String lan;
  String? lanDoc;
  String? subtitleUrl;
  String? subtitleUrlV2;
  bool isAi = false;

  /// Who made this track. Defaults from [isAi]; the on-device recogniser
  /// passes [SubtitleSource.device] when it adds its own.
  SubtitleSource source = SubtitleSource.author;

  Subtitle({
    required this.lan,
    this.lanDoc,
    this.subtitleUrl,
    this.isAi = false,
    this.source = SubtitleSource.author,
  });

  Subtitle.fromJson(Map<String, dynamic> json) {
    lan = json["lan"];
    isAi = json["type"] == 1;
    // the source note used to be baked into the name as '（AI）'; it is a
    // property of the track now, and rendered the same way on both platforms
    lanDoc = '${json["lan_doc"]}';
    source = isAi ? SubtitleSource.platform : SubtitleSource.author;
    subtitleUrl = json["subtitle_url"];
    subtitleUrlV2 = json["subtitle_url_v2"];
  }

  /// The name to show in a menu, with the source note where there is one.
  String get displayName => source.annotate(lanDoc ?? lan);

  @override
  int compareTo(Subtitle other) {
    final thisHasZh = lan.contains('zh');
    final otherHasZh = other.lan.contains('zh');
    if (thisHasZh != otherHasZh) return thisHasZh ? -1 : 1;
    if (isAi != other.isAi) return isAi ? 1 : -1;
    return 0;
  }
}
