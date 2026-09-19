import 'package:PiliPlus/models_new/article/article_info/stats.dart';
import 'package:PiliPlus/utils/extension/iterable_ext.dart';

class ArticleInfoData {
  bool? favorite;
  // the user's own like state (1: liked); stats.like is the total count
  int? like;
  Stats? stats;
  String? title;
  List<String>? originImageUrls;

  ArticleInfoData({
    this.favorite,
    this.like,
    this.stats,
    this.title,
    this.originImageUrls,
  });

  factory ArticleInfoData.fromJson(Map<String, dynamic> json) =>
      ArticleInfoData(
        favorite: json['favorite'] as bool?,
        like: json['like'] as int?,
        stats: json['stats'] == null
            ? null
            : Stats.fromJson(json['stats'] as Map<String, dynamic>),
        title: json['title'] as String?,
        originImageUrls: (json['origin_image_urls'] as List?)?.fromCast(),
      );
}
