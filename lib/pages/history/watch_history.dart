import 'package:PiliPlus/common/widgets/keep_alive_wrapper.dart';
import 'package:PiliPlus/pages/history/local.dart';
import 'package:PiliPlus/pages/history/view.dart';
import 'package:PiliPlus/utils/accounts.dart';
import 'package:material_ui/material_ui.dart';

/// 观看记录: 「本机」, the history kept on this device, always; and 「B 站账号」,
/// bilibili's own history as it has always been shown, only while an
/// account is in use for it (login mode). User decision 2026-09-28.
///
/// Each tab keeps its own app bar (the account one has its multi-select bar
/// and menus); the tabs sit in whichever app bar is shown. Switched by tap
/// only: the account tab has swipeable tabs of its own.
class WatchHistoryPage extends StatelessWidget {
  const WatchHistoryPage({super.key});

  @override
  Widget build(BuildContext context) {
    if (!Accounts.history.isLogin) return const LocalHistoryPage();
    const switcher = TabBar(
      tabs: [
        Tab(text: '本机'),
        Tab(text: 'B 站账号'),
      ],
    );
    return const DefaultTabController(
      length: 2,
      child: TabBarView(
        physics: NeverScrollableScrollPhysics(),
        children: [
          KeepAliveWrapper(child: LocalHistoryPage(switcher: switcher)),
          KeepAliveWrapper(child: HistoryPage(switcher: switcher)),
        ],
      ),
    );
  }
}
