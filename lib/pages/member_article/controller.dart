import 'package:PiliPlus/http/loading_state.dart';
import 'package:PiliPlus/http/member.dart';
import 'package:PiliPlus/models_new/space/space_article/data.dart';
import 'package:PiliPlus/models_new/space/space_article/item.dart';
import 'package:PiliPlus/pages/common/common_list_controller.dart';

class MemberArticleCtr
    extends CommonListController<SpaceArticleData, SpaceArticleItem> {
  MemberArticleCtr({
    required this.mid,
  });

  final int mid;

  int count = -1;

  @override
  void onInit() {
    super.onInit();
    queryData();
  }

  @override
  List<SpaceArticleItem>? getDataList(SpaceArticleData response) {
    count = response.count ?? -1;
    return response.item;
  }

  @override
  void checkIsEnd(int length) {
    // no count (-1) is unknown: an empty page ends the list instead
    if (count != -1 && length >= count) {
      isEnd = true;
    }
  }

  @override
  Future<LoadingState<SpaceArticleData>> customGetData() =>
      MemberHttp.spaceArticle(mid: mid, page: page);
}
