import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'state/app_state.dart';
import 'ui/calendar_screen.dart';
import 'ui/chat_screen.dart';
import 'ui/profile_screen.dart';
import 'ui/progress_screen.dart';
import 'ui/splash_screen.dart';
import 'ui/theme.dart';
import 'ui/today_screen.dart';

Future<void> main() async {
  // 读设置和开数据库都要走平台通道,先确保绑定初始化完成。
  WidgetsFlutterBinding.ensureInitialized();
  runApp(YijiApp(state: await createAppState()));
}

class YijiApp extends StatefulWidget {
  const YijiApp({super.key, required this.state, this.enableSplash = true});

  final AppState state;

  /// 界面测试传 false:开屏遮罩会挡住点击,而测试要验的是页面本身。
  final bool enableSplash;

  @override
  State<YijiApp> createState() => _YijiAppState();
}

class _YijiAppState extends State<YijiApp> {
  @override
  void initState() {
    super.initState();
    widget.state.bootstrap();
  }

  @override
  Widget build(BuildContext context) {
    return AppScope(
      state: widget.state,
      // 主题跟着设置里的开关走:AnimatedBuilder 让切换深色时整棵树重建,
      // MaterialApp 的 theme 变化自带补间,不需要额外做过渡。
      child: AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) {
          final dark = widget.state.darkMode;
          return AnnotatedRegion<SystemUiOverlayStyle>(
            // 状态栏图标颜色跟着主题走,否则浅色底上会出现看不见的白色图标。
            value: dark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
            child: MaterialApp(
              title: '忆记',
              debugShowCheckedModeBanner: false,
              theme: AppTheme.build(dark: dark),
              home: SplashGate(
                enabled: widget.enableSplash,
                child: const HomeShell(),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// 五个页签的外壳。
///
/// 用 [IndexedStack] 而不是每次重建:切回来时滚动位置、已载入的月份和报告都还在,
/// 符合"一天里反复来回看"的使用方式。
///
/// 加待办的浮动按钮挂在各页自己身上而不是这里:日历页和进度页各有自己的动作,
/// 一个共享按钮会让"这个加号到底加什么"变得含糊。
class HomeShell extends StatefulWidget {
  const HomeShell({super.key});

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      // 上下都让开系统栏:上面是状态栏/刘海,下面是手势条——
      // 不让下面的话,待办页的浮动按钮会压在手势条上,点起来别扭。
      body: SafeArea(
        child: IndexedStack(
          index: _index,
          children: const [
            TodayScreen(),
            CalendarScreen(),
            ProgressScreen(),
            ChatScreen(),
            ProfileScreen(),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (index) => setState(() => _index = index),
        height: 64,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.check_circle_outline),
            selectedIcon: Icon(Icons.check_circle),
            label: '待办',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_month_outlined),
            selectedIcon: Icon(Icons.calendar_month),
            label: '日历',
          ),
          NavigationDestination(
            icon: Icon(Icons.trending_up_outlined),
            selectedIcon: Icon(Icons.trending_up),
            label: '进度',
          ),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: '聊天',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline),
            selectedIcon: Icon(Icons.person),
            label: '我的',
          ),
        ],
      ),
    );
  }
}
