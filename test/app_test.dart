import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/core/day.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/ai_avatar.dart';
import 'package:yiji/ui/calendar_screen.dart';

import 'support/fake_store.dart';

/// 界面测试:验证页面真的画得出来、点得动。
///
/// 用内存存储,不碰 SQLite——SQL 的行为由 `tool/sqltest` 那个独立包负责验。
void main() {
  late FakeStore store;
  late AppState state;
  late _FakeAi ai;

  /// 在 pumpApp 之前就要定好的假回复(JSON 匹配结果)。
  ///
  /// 不能在 pumpApp 之后设,因为那时界面可能已经发过请求了。
  String? presetReply;

  /// 在 pumpApp 之前就要定好的流式分片(思考过程 + 回答)。
  List<AiChunk>? presetChunks;

  /// 界面默认打开"今天",所以场景数据要挂在真实今天上;
  /// 写死日期会让测试随运行日期飘。
  final today = todayKey();
  final monday = mondayOf(today);

  Future<void> pumpApp(WidgetTester tester, {bool withKey = false}) async {
    SharedPreferences.setMockInitialValues(withKey ? {'ai_api_key': 'sk-test'} : {});
    ai = _FakeAi(presetReply: presetReply, presetChunks: presetChunks);
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
  }

  setUp(() {
    store = FakeStore();
    presetReply = null;
    presetChunks = null;
  });

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// 把「我的」页里的某个东西滚到可见。
  ///
  /// 必须指定这一页的 view:几个页签同时挂在组件树上,
  /// `scrollUntilVisible` 默认会找到多个可滚动组件而报错。
  Future<void> revealInProfile(WidgetTester tester, Finder target) async {
    await tester.scrollUntilVisible(
      target,
      120,
      scrollable: find.descendant(
        of: find.byKey(const Key('profile-list')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.pumpAndSettle();
  }

  // ---------- 待办页 ----------

  group('待办页', () {
    testWidgets('显示当天的待办和完成进度', (tester) async {
      store.seedTask(today, '早上 码字1h半', done: true);
      store.seedTask(today, '下午下课 健身');
      store.seedTask(today, '晚上回寝 洗澡 + 洗衣服');

      await pumpApp(tester);

      expect(find.text('早上 码字1h半'), findsOneWidget);
      expect(find.text('下午下课 健身'), findsOneWidget);
      expect(find.text('3 条任务 · 完成 1'), findsOneWidget);
    });

    testWidgets('点右边圆圈就变成已完成', (tester) async {
      store.seedTask(today, '下午下课 健身');
      await pumpApp(tester);

      expect(find.text('1 条任务 · 完成 0'), findsOneWidget);

      // 打钩点的是右边的圆圈,不是文字——点文字是进编辑。
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      await tester.pumpAndSettle();

      expect(find.text('1 条任务 · 完成 1'), findsOneWidget);
      final text = tester.widget<Text>(find.text('下午下课 健身'));
      expect(text.style?.decoration, TextDecoration.lineThrough);
    });

    testWidgets('点文字进编辑页,能改内容', (tester) async {
      store.seedTask(today, '写错的待办');
      await pumpApp(tester);

      await tester.tap(find.text('写错的待办'));
      await tester.pumpAndSettle();

      // 编辑页:右上角完成,底部有改期与删除。
      expect(find.text('完成'), findsOneWidget);
      expect(find.text('改到别的日子'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, '改好的待办');
      await tester.tap(find.text('完成'));
      await tester.pumpAndSettle();

      expect(find.text('改好的待办'), findsOneWidget);
      expect(find.text('写错的待办'), findsNothing);
    });

    testWidgets('编辑页里能删掉这条', (tester) async {
      store.seedTask(today, '要删的待办');
      await pumpApp(tester);

      await tester.tap(find.text('要删的待办'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('要删的待办'), findsNothing);
      expect(find.text('今天还没有任务'), findsOneWidget);
    });

    testWidgets('没有待办时给出下一步提示,而不是空白', (tester) async {
      await pumpApp(tester);

      expect(find.text('今天还没有任务'), findsOneWidget);
      expect(find.text('点右下角加一条'), findsOneWidget);
    });

    testWidgets('长按进入多选,出现底部操作栏', (tester) async {
      store.seedTask(today, '待办甲');
      store.seedTask(today, '待办乙');
      await pumpApp(tester);

      await tester.longPress(find.text('待办甲'));
      await tester.pumpAndSettle();

      expect(find.text('已选择 1 项'), findsOneWidget);
      expect(find.text('颜色'), findsOneWidget);
      expect(find.text('删除'), findsOneWidget);
    });

    testWidgets('多选后能批量删除', (tester) async {
      store.seedTask(today, '待办甲');
      store.seedTask(today, '待办乙');
      await pumpApp(tester);

      await tester.longPress(find.text('待办甲'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('删除'));
      await tester.pumpAndSettle();

      expect(find.text('待办甲'), findsNothing);
      expect(find.text('待办乙'), findsOneWidget);
    });

    testWidgets('粘贴多行能一次加完,并剥掉行首标记', (tester) async {
      await pumpApp(tester);

      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).last,
        '- 早上 码字1h半\n1. 上午 码完字 读《人物》\n☑ 下午下课 健身',
      );
      await tester.tap(find.text('添加'));
      await tester.pumpAndSettle();

      expect(find.text('早上 码字1h半'), findsOneWidget);
      expect(find.text('上午 码完字 读《人物》'), findsOneWidget);
      expect(find.text('下午下课 健身'), findsOneWidget);
      expect(find.text('3 条任务 · 完成 0'), findsOneWidget);
    });

    testWidgets('写过的想法显示在卡片上', (tester) async {
      store.seedJournal(today, '今天读完了《人物》12 页,对情节编排的理解更深了。');
      await pumpApp(tester);

      expect(find.textContaining('今天读完了《人物》12 页'), findsOneWidget);
    });
  });

  // ---------- 日历页 ----------

  group('日历页', () {
    testWidgets('显示当月标题和星期表头', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '日历');

      expect(find.text(monthTitle(today)), findsOneWidget);
      expect(find.text('一'), findsOneWidget);
      expect(find.text('日'), findsOneWidget);
    });

    testWidgets('有安排的日期会打点', (tester) async {
      store.seedTask(today, '今天的事');
      await pumpApp(tester);
      await openTab(tester, '日历');

      final dayNumber = parseDayKey(today).day.toString();
      expect(find.text(dayNumber), findsWidgets);
      expect(find.byType(CalendarDayDot), findsWidgets);
    });

    testWidgets('点某一天弹出当天待办,可以就地加一条', (tester) async {
      // 必须挑当前月内的日子:日历显示的是当月,点别的月的日期得先翻月。
      final todayDate = parseDayKey(today);
      final targetDate = DateTime(todayDate.year, todayDate.month, 28);
      final target = dayKey(targetDate);
      await pumpApp(tester);
      await openTab(tester, '日历');

      await tester.tap(find.text('28').first);
      await tester.pumpAndSettle();

      expect(find.text(fullDateLabel(target)), findsWidgets);
      expect(find.text('这一天还是空的'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, '加一条到这一天'),
        '提前安排的事',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(find.text('提前安排的事'), findsOneWidget);
    });

    testWidgets('能翻到下个月', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '日历');

      await tester.tap(find.byIcon(Icons.chevron_right));
      await tester.pumpAndSettle();

      final date = parseDayKey(today);
      final next = DateTime(date.year, date.month + 1, 1);
      expect(find.text(monthTitle(dayKey(next))), findsOneWidget);
    });
  });

  // ---------- 进度页 ----------

  group('进度页', () {
    testWidgets('没有目标时给出建目标的引导', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '进度');

      expect(find.text('还没有进度推进条'), findsOneWidget);
      expect(find.text('新建一个目标'), findsOneWidget);
    });

    testWidgets('显示进度条、百分比和还差多少', (tester) async {
      store.seedGoal(title: '小说推进', unit: '字', target: 10000, current: 2500);
      await pumpApp(tester);
      await openTab(tester, '进度');

      expect(find.text('小说推进'), findsOneWidget);
      expect(find.text('2500 / 1万 字'), findsOneWidget);
      expect(find.text('25%'), findsOneWidget);
      expect(find.text('还差 7500 字'), findsOneWidget);
    });

    testWidgets('能新建一个目标', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '进度');

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      // 字段顺序:一句话描述、推进什么、目标值、单位。
      await tester.enterText(find.byType(TextField).at(1), '英语精读');
      await tester.enterText(find.byType(TextField).at(2), '20');
      await tester.enterText(find.byType(TextField).at(3), '篇');
      // 表单在可滚动容器里,小窗口下按钮可能在屏幕外。
      await tester.ensureVisible(find.text('建好'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('建好'));
      await tester.pumpAndSettle();

      expect(await store.goals(), hasLength(1));
      expect(find.text('英语精读'), findsOneWidget);
      expect(find.text('0 / 20 篇'), findsOneWidget);
    });

    testWidgets('说一句话让 AI 拆成目标字段', (tester) async {
      presetReply = jsonEncode({
        'ok': true,
        'title': '跑步',
        'target': 3,
        'unit': '次',
        'period': 'weekly',
        'direction': 'increase',
        'color': 'green',
      });

      await pumpApp(tester, withKey: true);
      await openTab(tester, '进度');
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '每周跑3次');
      // 弹层里的那个;背后进度页的同步按钮也有同款图标。
      await tester.ensureVisible(find.byIcon(Icons.auto_awesome).last);
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.auto_awesome).last);
      await tester.pumpAndSettle();

      // AI 只是预填,字段上能看到它拆出来的东西。
      // "次"会同时命中填进去的值和输入框的 hint,所以用 findsWidgets。
      expect(find.text('跑步'), findsOneWidget);
      expect(find.text('3'), findsOneWidget);
      expect(find.text('次'), findsWidgets);

      // 表单在可滚动容器里,小窗口下按钮可能在屏幕外。
      await tester.ensureVisible(find.text('建好'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('建好'));
      await tester.pumpAndSettle();

      final goal = (await store.goals()).single;
      expect(goal.title, '跑步');
      expect(goal.target, 3);
      expect(goal.unit, '次');
    });

    testWidgets('单位留空也能建,不会卡住', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '进度');
      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      // 只填"推进什么"和"目标值",单位不管。
      await tester.enterText(find.byType(TextField).at(1), '早起');
      await tester.enterText(find.byType(TextField).at(2), '5');
      // 表单在可滚动容器里,小窗口下按钮可能在屏幕外。
      await tester.ensureVisible(find.text('建好'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('建好'));
      await tester.pumpAndSettle();

      final goal = (await store.goals()).single;
      expect(goal.title, '早起');
      expect(goal.unit, '', reason: '单位是可选填项,留空就留空,不该硬塞一个单位');
      expect(goal.target, 5);
    });

    testWidgets('手动加进度会推进进度条', (tester) async {
      store.seedGoal(title: '小说推进', unit: '字', target: 10000);
      await pumpApp(tester);
      await openTab(tester, '进度');

      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).first, '2000');
      await tester.tap(find.text('加上去'));
      await tester.pumpAndSettle();

      expect(find.text('2000 / 1万 字'), findsOneWidget);
      expect(find.text('20%'), findsOneWidget);
    });

    testWidgets('没配 key 时提示去填 key', (tester) async {
      store.seedGoal(title: '小说推进');
      await pumpApp(tester);
      await openTab(tester, '进度');

      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pumpAndSettle();

      expect(find.textContaining('还没填 API key'), findsOneWidget);
    });

    testWidgets('AI 同步:读完待办给出建议,确认后才计入进度', (tester) async {
      final goal = store.seedGoal(title: '小说推进', unit: '字', target: 10000);
      store.seedTask(today, '上午 码字2k', done: true);
      presetReply = jsonEncode({
        'matches': [
          {'task': 1, 'goal': 1, 'amount': 2000, 'reason': '待办写了码字2k,换算为2000字'},
        ],
      });

      await pumpApp(tester, withKey: true);
      await openTab(tester, '进度');
      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pumpAndSettle();

      expect(find.text('AI 读到的推进'), findsOneWidget);
      expect(find.text('小说推进  +2000 字'), findsOneWidget);
      expect(find.textContaining('待办写了码字2k'), findsOneWidget);
      // 此刻还没落库。
      expect(find.text('0 / 1万 字'), findsOneWidget);

      await tester.tap(find.text('计入这 1 条'));
      await tester.pumpAndSettle();

      final updated = (await store.goals()).firstWhere((g) => g.id == goal.id);
      expect(updated.current, 2000);
    });

    testWidgets('AI 建议可以逐条取消勾选', (tester) async {
      store.seedGoal(title: '小说推进', unit: '字', target: 10000);
      store.seedTask(today, '上午 码字2k', done: true);
      presetReply = jsonEncode({
        'matches': [
          {'task': 1, 'goal': 1, 'amount': 2000, 'reason': '码字2k'},
        ],
      });

      await pumpApp(tester, withKey: true);
      await openTab(tester, '进度');
      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pumpAndSettle();

      await tester.tap(find.text('小说推进  +2000 字'));
      await tester.pumpAndSettle();

      expect(find.text('计入这 0 条'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '计入这 0 条'),
      );
      expect(button.onPressed, isNull);
    });

    testWidgets('没有数字的待办不会被硬算进进度', (tester) async {
      store.seedGoal(title: '小说推进', unit: '字', target: 10000);
      store.seedTask(today, '下午 健身', done: true);
      presetReply = jsonEncode({'matches': []});

      await pumpApp(tester, withKey: true);
      await openTab(tester, '进度');
      await tester.tap(find.byIcon(Icons.auto_awesome));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有能对上目标的数字'), findsOneWidget);
      expect(find.text('0 / 1万 字'), findsOneWidget);
    });
  });

  // ---------- 聊天页 ----------

  group('聊天页', () {
    testWidgets('没配 key 时给出指引', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '聊天');

      expect(find.textContaining('先去「我的」填一个 API key'), findsOneWidget);
    });

    testWidgets('默认是「带上近期数据」,选完显示所选范围', (tester) async {
      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      expect(find.text('带上近期数据'), findsOneWidget);

      await tester.tap(find.text('带上近期数据'));
      await tester.pumpAndSettle();
      expect(find.text('带上哪段时间的数据'), findsOneWidget);

      await tester.tap(find.text('近 14 天'));
      await tester.pumpAndSettle();

      // 选完之后按钮上直接显示范围,状态看得见。
      expect(find.text('近 14 天'), findsOneWidget);
      expect(find.text('带上近期数据'), findsNothing);
    });

    testWidgets('可以清掉已选的近期数据', (tester) async {
      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      await tester.tap(find.text('带上近期数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('近 7 天'));
      await tester.pumpAndSettle();
      expect(find.text('近 7 天'), findsOneWidget);

      await tester.tap(find.byIcon(Icons.close));
      await tester.pumpAndSettle();

      expect(find.text('带上近期数据'), findsOneWidget);
    });

    testWidgets('显示模型名和思考强度', (tester) async {
      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      expect(find.text('deepseek-flash'), findsOneWidget);
      expect(find.text('中'), findsOneWidget);
    });

    testWidgets('思考过程先出现,回答随后出现', (tester) async {
      presetChunks = [
        const AiChunk.reasoning('先看他这周的记录'),
        const AiChunk.reasoning(',再决定怎么回。'),
        const AiChunk.content('这周你码了 5k,比上周稳。'),
      ];

      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      await tester.enterText(
        find.widgetWithText(TextField, '说点什么'),
        '最近怎么样',
      );
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(find.text('这周你码了 5k,比上周稳。'), findsOneWidget);
      // 思考过程折叠成一块,默认收起。
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.text('先看他这周的记录,再决定怎么回。'), findsNothing);

      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(find.text('先看他这周的记录,再决定怎么回。'), findsOneWidget);
    });

    testWidgets('发出去的消息会留在对话里', (tester) async {
      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      await tester.enterText(find.widgetWithText(TextField, '说点什么'), '在吗');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(find.text('在吗'), findsOneWidget);
      expect((await store.messagesOf(state.currentConversationId)).first.content, '在吗');
    });

    testWidgets('能临时改思考强度,不影响全局设置', (tester) async {
      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      await tester.tap(find.text('中'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('不思考').last);
      await tester.pumpAndSettle();

      // 全局设置没被动过。
      expect(state.aiConfig.thinking, ThinkingLevel.high);
    });
  });

  // ---------- 我的页 ----------

  group('我的页', () {
    testWidgets('未配置 key 时明确标出来', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      expect(find.text('还没配 API key'), findsOneWidget);
    });

    testWidgets('能保存 key 和称呼', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      await tester.tap(find.text('API key 与模型'));
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField).at(0), 'sk-test-123');
      // 设置页只有三个输入框:key、接口地址、称呼。
      await tester.enterText(find.byType(TextField).at(2), 'xi283');
      await tester.tap(find.text('保存').last);
      await tester.pumpAndSettle();

      expect(state.aiConfig.apiKey, 'sk-test-123');
      expect(state.aiConfig.isUsable, isTrue);
      expect(state.displayName, 'xi283');
    });

    testWidgets('能改思考强度', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      // 用 .first:`.last` 会命中弹层自己的标题,那个不可点。
      await tester.tap(find.text('思考强度').first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('深').last);
      await tester.pumpAndSettle();

      expect(state.aiConfig.thinking, ThinkingLevel.max);
    });

    testWidgets('能切深色模式', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      expect(state.darkMode, isFalse);
      await revealInProfile(tester, find.byType(Switch));
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();

      expect(state.darkMode, isTrue);
      final app = tester.widget<MaterialApp>(find.byType(MaterialApp));
      expect(app.theme?.brightness, Brightness.dark);
    });

    testWidgets('能从我的页进总结页', (tester) async {
      store.seedTask(monday, '周一完成的事', done: true);
      store.seedTask(addDays(monday, 1), '周二没做完的事');

      await pumpApp(tester);
      await openTab(tester, '我的');
      await tester.tap(find.text('周报 / 月报'));
      await tester.pumpAndSettle();

      expect(find.text('总结'), findsOneWidget);
      expect(find.text('50%'), findsOneWidget);
      expect(find.text('周一完成的事'), findsOneWidget);
      expect(find.text('周二没做完的事'), findsOneWidget);
    });

    testWidgets('总结页只给已完成的划线,没完成的不能划', (tester) async {
      // 这条盯着一个真实发生过的 bug:判断写反,导致报告里没做的事全被划掉,
      // 看着像都做完了。
      final done = store.seedTask(monday, '做完的事', done: true);
      final undone = store.seedTask(addDays(monday, 1), '没做的事');

      await pumpApp(tester);
      await openTab(tester, '我的');
      await tester.tap(find.text('周报 / 月报'));
      await tester.pumpAndSettle();

      final doneText = tester.widget<Text>(find.byKey(Key('report-task-${done.id}')));
      final undoneText = tester.widget<Text>(find.byKey(Key('report-task-${undone.id}')));

      expect(doneText.style?.decoration, TextDecoration.lineThrough);
      expect(
        undoneText.style?.decoration,
        isNot(TextDecoration.lineThrough),
        reason: '没完成的事被划掉会让人以为做完了',
      );
    });
  });

  testWidgets('五个页签都能切到,不报错', (tester) async {
    await pumpApp(tester);

    for (final tab in ['日历', '进度', '聊天', '我的', '任务']) {
      await openTab(tester, tab);
      expect(tester.takeException(), isNull);
    }
  });

  // ---------- 系统栏避让 ----------

  group('顶部不被状态栏压住', () {
    /// 造一个"状态栏高 44"的环境。
    ///
    /// 这是用户报过的真问题:标题顶到刘海、和状态栏时间叠在一起。
    /// 所以必须有一条测试盯着它——改布局的人不会记得这件事。
    Future<void> pumpWithStatusBar(WidgetTester tester, double top) async {
      SharedPreferences.setMockInitialValues({});
      final barStore = FakeStore()..seedTask(today, '一条待办');
      final appState = AppState(
        store: barStore,
        reports: ReportService(barStore),
        settings: await SettingsStore.load(),
      );
      await tester.pumpWidget(
        MediaQuery(
          data: MediaQueryData.fromView(tester.view)
              .copyWith(padding: EdgeInsets.only(top: top)),
          child: YijiApp(state: appState, enableSplash: false),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('待办页标题落在状态栏下面', (tester) async {
      await pumpWithStatusBar(tester, 44);

      final titleTop = tester.getTopLeft(find.text('今天')).dy;
      expect(
        titleTop,
        greaterThanOrEqualTo(44),
        reason: '标题不能顶到状态栏区域里',
      );
    });

    testWidgets('日历页标题也避让', (tester) async {
      await pumpWithStatusBar(tester, 44);
      await tester.tap(find.text('日历').last);
      await tester.pumpAndSettle();

      final titleTop = tester.getTopLeft(find.text(monthTitle(today))).dy;
      expect(titleTop, greaterThanOrEqualTo(44));
    });

    testWidgets('进度页标题也避让', (tester) async {
      await pumpWithStatusBar(tester, 44);
      await tester.tap(find.text('进度').last);
      await tester.pumpAndSettle();

      final titleTop = tester.getTopLeft(find.text('进度').first).dy;
      expect(titleTop, greaterThanOrEqualTo(44));
    });

    testWidgets('没有状态栏时标题仍然在顶部附近,不留多余空白', (tester) async {
      await pumpWithStatusBar(tester, 0);

      final titleTop = tester.getTopLeft(find.text('今天')).dy;
      expect(titleTop, lessThan(40));
    });
  });

  // ---------- 开屏 ----------

  group('开屏', () {
    /// 单独造一个开着开屏的 app;其余测试都关掉它,免得遮罩挡住点击。
    Future<void> pumpWithSplash(
      WidgetTester tester, {
      Map<String, Object> prefs = const {},
    }) async {
      SharedPreferences.setMockInitialValues(prefs);
      final splashStore = FakeStore();
      final appState = AppState(
        store: splashStore,
        reports: ReportService(splashStore),
        settings: await SettingsStore.load(),
      );
      await tester.pumpWidget(YijiApp(state: appState));
      await tester.pump();
    }

    testWidgets('先显示文案,之后让位给主界面', (tester) async {
      await pumpWithSplash(tester);

      expect(find.text(SettingsStore.defaultSplashText), findsOneWidget);

      // 等整段开屏走完(约 1.6s),遮罩该消失了。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();

      expect(find.text(SettingsStore.defaultSplashText), findsNothing);
      expect(find.text('今天还没有任务'), findsOneWidget);
    });

    testWidgets('文案可以改成自己的', (tester) async {
      await pumpWithSplash(tester, prefs: {'ui_splash_text': '日拱一卒'});

      expect(find.text('日拱一卒'), findsOneWidget);
      expect(find.text(SettingsStore.defaultSplashText), findsNothing);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    testWidgets('文案留空时回到默认,不会显示空白', (tester) async {
      await pumpWithSplash(tester, prefs: {'ui_splash_text': '   '});

      expect(find.text(SettingsStore.defaultSplashText), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });

    test('默认文案就是「小习惯、大不同」', () {
      expect(SettingsStore.defaultSplashText, '小习惯、大不同');
    });
  });

  // ---------- 已完成/未完成分界 ----------

  group('已完成与未完成的分界', () {
    testWidgets('有已完成项时出现分界与条数', (tester) async {
      store.seedTask(today, '做完的事', done: true);
      store.seedTask(today, '没做的事');
      await pumpApp(tester);

      expect(find.text('已完成 1'), findsOneWidget);
    });

    testWidgets('没有已完成项时不出现分界', (tester) async {
      store.seedTask(today, '还没做的事');
      await pumpApp(tester);

      expect(find.textContaining('已完成'), findsNothing);
    });

    testWidgets('未完成的排在已完成前面,不管创建顺序', (tester) async {
      // 先建的没做完,后建的做完了——渲染顺序仍应是"没做完的"在前。
      store.seedTask(today, '先建的没做完');
      store.seedTask(today, '后建的做完了', done: true);
      await pumpApp(tester);

      final unfinishedY = tester.getTopLeft(find.text('先建的没做完')).dy;
      final dividerY = tester.getTopLeft(find.text('已完成 1')).dy;
      final finishedY = tester.getTopLeft(find.text('后建的做完了')).dy;

      expect(unfinishedY, lessThan(dividerY));
      expect(dividerY, lessThan(finishedY));
    });

    testWidgets('打钩之后会自动归到分界下面', (tester) async {
      store.seedTask(today, '待办甲');
      store.seedTask(today, '待办乙');
      await pumpApp(tester);

      expect(find.textContaining('已完成'), findsNothing);

      // 点圆圈打钩(点文字是进编辑)。
      await tester.tap(find.byIcon(Icons.radio_button_unchecked).first);
      await tester.pumpAndSettle();

      expect(find.text('已完成 1'), findsOneWidget);
    });
  });

  // ---------- AI 厂商识别 ----------

  group('AI 头像跟随所配模型', () {
    test('deepseek 系列认成 DeepSeek', () {
      expect(
        AiProvider.from(model: 'deepseek-flash', baseUrl: 'https://api.deepseek.com'),
        AiProvider.deepseek,
      );
      expect(
        AiProvider.from(model: 'deepseek-v4-pro', baseUrl: 'https://api.deepseek.com'),
        AiProvider.deepseek,
      );
    });

    test('看模型名优先于看地址', () {
      // 自建代理常见:地址是自家的,模型名还是原来的。
      expect(
        AiProvider.from(model: 'deepseek-flash', baseUrl: 'https://my-proxy.example.com'),
        AiProvider.deepseek,
      );
      expect(
        AiProvider.from(model: 'gpt-4o-mini', baseUrl: 'https://api.deepseek.com'),
        AiProvider.openai,
      );
      expect(
        AiProvider.from(model: 'claude-sonnet-4', baseUrl: 'https://x.example.com'),
        AiProvider.anthropic,
      );
    });

    test('认不出模型名时退回看地址', () {
      expect(
        AiProvider.from(model: 'my-model', baseUrl: 'https://api.deepseek.com/v1'),
        AiProvider.deepseek,
      );
    });

    test('都认不出时给通用标记', () {
      expect(
        AiProvider.from(model: 'whatever', baseUrl: 'https://example.com'),
        AiProvider.unknown,
      );
    });

    testWidgets('配了 DeepSeek 后,聊天页头部显示 DeepSeek 而不是忆记', (tester) async {
      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      expect(find.text('DeepSeek'), findsOneWidget);
      expect(find.text('deepseek-flash'), findsOneWidget);
    });
  });
}

/// 一个按脚本回答的假 HTTP 客户端。
///
/// 测的是"拿到这些流式分片之后界面怎么表现",所以不联网、也不依赖真实模型。
class _FakeAi extends http.BaseClient {
  _FakeAi({this.presetReply, this.presetChunks});

  /// 一次性返回的完整回答(用于 JSON 匹配这类要整段的场景)。
  final String? presetReply;

  /// 指定时按这些分片依次流式返回。
  final List<AiChunk>? presetChunks;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final payloads = presetChunks ?? [AiChunk.content(presetReply ?? '好的。')];
    final body = payloads
        .map(
          (chunk) => 'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {
                      if (chunk.isReasoning) 'reasoning_content': chunk.text,
                      if (!chunk.isReasoning) 'content': chunk.text,
                    },
                  }
                ],
              })}',
        )
        .join('\n\n');
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode('$body\n\ndata: [DONE]\n\n')]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
