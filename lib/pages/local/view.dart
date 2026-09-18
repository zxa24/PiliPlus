import 'package:PiliPlus/pages/local/favs.dart';
import 'package:PiliPlus/pages/local/feed.dart';
import 'package:PiliPlus/pages/local/follows.dart';
import 'package:material_ui/material_ui.dart';

/// "本地" navigation tab (LibrePili): account-free follows, their latest
/// uploads, and favorite folders, all stored on this device.
class LocalPage extends StatefulWidget {
  const LocalPage({super.key});

  @override
  State<LocalPage> createState() => _LocalPageState();
}

class _LocalPageState extends State<LocalPage>
    with AutomaticKeepAliveClientMixin, SingleTickerProviderStateMixin {
  late final _tabController = TabController(length: 3, vsync: this);

  @override
  bool get wantKeepAlive => true;

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          TabBar(
            controller: _tabController,
            tabs: const [
              Tab(text: '动态'),
              Tab(text: '关注'),
              Tab(text: '收藏'),
            ],
          ),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: const [
                LocalFeedTab(),
                LocalFollowsTab(),
                LocalFavsTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
