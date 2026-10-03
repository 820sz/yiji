import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cross_file/cross_file.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/core/day.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/ai_avatar.dart';
import 'package:yiji/ui/calendar_screen.dart';
import 'package:yiji/ui/image_cropper.dart';
import 'package:yiji/ui/task_card.dart';
import 'package:yiji/ui/theme.dart';

import 'support/fake_store.dart';

/// 界面测试:验证页面真的画得出来、点得动。
///
/// 用内存存储,不碰 SQLite——SQL 的行为由 `tool/sqltest` 那个独立包负责验。
void main() {
  late FakeStore store;
  late AppState state;
  late _FakeAi ai;
  late Directory tempDir;

  /// 在 pumpApp 之前就要定好的假回复(JSON 匹配结果)。
  ///
  /// 不能在 pumpApp 之后设,因为那时界面可能已经发过请求了。
  String? presetReply;

  /// 在 pumpApp 之前就要定好的流式分片(思考过程 + 回答)。
  List<AiChunk>? presetChunks;

  /// 让假客户端慢一点回复,好观察"正在读"这类中间状态。
  Duration? replyDelay;

  /// 界面默认打开"今天",所以场景数据要挂在真实今天上;
  /// 写死日期会让测试随运行日期飘。
  final today = todayKey();
  final monday = mondayOf(today);

  Future<void> pumpApp(WidgetTester tester, {bool withKey = false, bool withDarkMode = false}) async {
    SharedPreferences.setMockInitialValues({
      if (withKey) 'ai_api_key': 'sk-test',
      if (withDarkMode) 'ui_dark_mode': true,
    });
    ai = _FakeAi(
      presetReply: presetReply,
      presetChunks: presetChunks,
      replyDelay: replyDelay,
    );
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));    await tester.pumpAndSettle();
  }

  setUp(() {
    store = FakeStore();
    presetReply = null;
    presetChunks = null;
    // 这几条是**跨用例的全局量**,每条用例自己会按需要设置;
    // 忘了在这里清掉的话,上一条留的延迟会把后面每条都拖慢,
    // 表现为一批互不相关的用例一起失败(踩过一次)。
    replyDelay = null;
    // 聊天图片/头像要落盘,而测试环境没有 path_provider 的平台通道:
    // 异步取目录的 Future 永远不会完成,`pumpAndSettle` 于是直接超时
    // (表现是一批聊天用例一起挂,原因却和聊天毫无关系)。
    // 给一个真临时目录,读写都走真实文件系统。
    tempDir = Directory.systemTemp.createTempSync('yiji_app_test');
    ChatImages.directoryOverride = tempDir;
  });

  tearDown(() {
    ChatImages.directoryOverride = null;
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
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

      // 选中数量始终在(拖动提示是附加信息,不挤掉它)。
      expect(find.textContaining('已选择 1 项'), findsOneWidget);
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

      // 先问"读多久",再开始同步——以前写死本周,攒了几周的人永远读不到。
      expect(find.text('让 AI 读多久的记录?'), findsOneWidget);
      await tester.tap(find.text('近 14 天'));
      await tester.pumpAndSettle();

      expect(find.text('AI 读到的推进'), findsOneWidget);
      expect(find.text('小说推进  +2000 字'), findsOneWidget);
      expect(find.textContaining('待办写了码字2k'), findsOneWidget);
      // 此刻还没落库。
      expect(find.text('0 / 1万 字'), findsOneWidget);

      await tester.tap(find.text('确认这 1 项'));
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
      await tester.tap(find.text('本周'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('小说推进  +2000 字'));
      await tester.pumpAndSettle();

      expect(find.text('确认这 0 项'), findsOneWidget);
      final button = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, '确认这 0 项'),
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
      await tester.tap(find.text('本周'));
      await tester.pumpAndSettle();

      expect(find.textContaining('没有能对上目标的数字'), findsOneWidget);
      expect(find.text('0 / 1万 字'), findsOneWidget);
    });

    testWidgets('同步走的是"选范围 → 读 → 审阅"这条路,不再写死本周', (tester) async {
      // 用户明确要求过"需增加进度用户选取范围"。这里盯住这条路是通的:
      // 选了范围之后,建议照常出来、确认后才落库。
      //
      // **不在这里盯"对话框里逐字增长"**:假客户端瞬时返回,对话框一帧就
      // 关了,为此调慢假客户端又会把假时钟搅乱(转圈动画永不停止,
      // pumpAndSettle 必超时)。流式那段由 pending_sync_test 在状态层验证。
      final goal = store.seedGoal(title: '小说推进', unit: '字', target: 10000);
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

      // 五档范围都在。
      for (final label in ['本周', '近 7 天', '近 14 天', '近 30 天', '近 90 天']) {
        expect(find.text(label), findsOneWidget, reason: '缺少「$label」这一档');
      }

      await tester.tap(find.text('近 30 天'));
      await tester.pumpAndSettle();

      expect(find.text('小说推进  +2000 字'), findsOneWidget);
      await tester.tap(find.text('确认这 1 项'));
      await tester.pumpAndSettle();
      expect((await store.goals()).firstWhere((g) => g.id == goal.id).current, 2000);
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
      // 最后一条的思考过程保持展开:生成时它本来就是展开的,
      // 落库时如果突然收起,整列消息会跳一下。
      expect(find.text('思考过程'), findsOneWidget);
      expect(find.text('先看他这周的记录,再决定怎么回。'), findsOneWidget);

      // 想看干净的正文就自己点一下收起。
      await tester.tap(find.text('思考过程'));
      await tester.pumpAndSettle();
      expect(find.text('先看他这周的记录,再决定怎么回。'), findsNothing);
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

  // ---------- 任务页的滑动与拖动 ----------

  group('任务卡片的手势', () {
    testWidgets('左滑是标记完成,不是删除', (tester) async {
      // 用户明确要求过:向左划应该是"完成",删除是另一个方向。
      final task = store.seedTask(today, '待办甲');
      await pumpApp(tester);

      // 左滑 = 从右往左拖。
      await tester.drag(find.text('待办甲'), const Offset(-400, 0));
      await tester.pumpAndSettle();

      final updated = (await store.tasksOfDay(today))
          .firstWhere((t) => t.id == task.id);
      expect(updated.done, isTrue, reason: '左滑应该把它标成完成');
      // 而且不能删掉。
      expect(await store.tasksOfDay(today), hasLength(1));
    });

    testWidgets('右滑删除,并且能撤回', (tester) async {
      store.seedTask(today, '待办甲');
      await pumpApp(tester);

      // 右滑 = 从左往右拖。
      await tester.drag(find.text('待办甲'), const Offset(400, 0));
      await tester.pumpAndSettle();

      expect(await store.tasksOfDay(today), isEmpty);
      // 删除是破坏性的,要给一次撤回的机会。
      expect(find.text('撤回'), findsOneWidget);

      await tester.tap(find.text('撤回'));
      await tester.pumpAndSettle();

      final back = await store.tasksOfDay(today);
      expect(back, hasLength(1));
      expect(back.single.text, '待办甲');
    });

    testWidgets('长按进多选,拖住就排序', (tester) async {
      // 用户明确要求不要把拖动做成单独的功能:
      // "我说的是长按住任务项,就有选中的逻辑(包含现有的功能上,支持拖住排序),
      // 而不是现在把拖住单独分出一个功能"。
      store.seedTask(today, '待办甲');
      await pumpApp(tester);

      await tester.longPress(find.text('待办甲'));
      await tester.pumpAndSettle();
      // 选中数量必须始终在:拖动只是多出来的能力,不该把"选了几条"挤掉。
      expect(find.textContaining('已选择 1 项'), findsOneWidget);
      expect(find.textContaining('按住可拖动排序'), findsOneWidget);
    });

    testWidgets('选中之后继续按住就能拖', (tester) async {
      // 同一条：拖动不再需要先点表头的「调整顺序」，而是在选中态里直接按住拖。
      store.seedTask(today, '待办甲');
      store.seedTask(today, '待办乙');
      await pumpApp(tester);

      // 长按其中一条进入多选（也就是选中它）。
      await tester.longPress(find.text('待办乙'));
      await tester.pumpAndSettle();
      expect(find.textContaining('已选择 1 项'), findsOneWidget);

      // 选中态下整张卡片按住就能拖。
      //
      // ReorderableDelayedDragStartListener 要等长按超时才认(约 500ms),
      // 按下的时间不够就只是一次普通轻触,不会触发拖动。
      final first = tester.getCenter(find.text('待办甲'));
      final second = tester.getCenter(find.text('待办乙'));
      final gesture = await tester.startGesture(second);
      await tester.pump(const Duration(milliseconds: 700));
      // 分几步移动:一次跳到位的话拖动识别器看不到中间帧。
      for (var i = 1; i <= 4; i++) {
        await gesture.moveTo(second + (first - second) * (i / 4));
        await tester.pump(const Duration(milliseconds: 60));
      }
      await gesture.up();
      await tester.pumpAndSettle();

      final ordered = await store.tasksOfDay(today);
      expect(
        ordered.first.text,
        '待办乙',
        reason: '拖到前面之后顺序应该落库;实际 ${ordered.map((t) => t.text).toList()}',
      );
    });
  });

  // ---------- 我的页 ----------

  group('我的页', () {
    testWidgets('未配置 key 时明确标出来', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      expect(find.text('还没配 API key'), findsOneWidget);
    });

    // ---------- 身份卡片:每一项都要能点着改 ----------

    testWidgets('点名字能改称呼', (tester) async {
      // 用户反馈"没有地方改用户名"——设置页有输入框,但名片上点不进去。
      await pumpApp(tester);
      await openTab(tester, '我的');

      // 默认称呼是「我」;先设一个,避免和底部页签上的字撞。
      await state.saveDisplayName('旧名字');
      await tester.pumpAndSettle();

      await tester.tap(find.text('旧名字'));
      await tester.pumpAndSettle();

      expect(find.text('怎么称呼你'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, 'xi283');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(state.displayName, 'xi283');
      // 名片上要立刻显示新称呼。
      expect(find.text('xi283'), findsWidgets);
    });

    testWidgets('点签名能改签名', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      await tester.tap(find.text('点这里写一句签名'));
      await tester.pumpAndSettle();

      expect(find.text('个性签名'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '每天推进一点点');
      await tester.tap(find.text('保存'));
      await tester.pumpAndSettle();

      expect(state.bio, '每天推进一点点');
      expect(find.text('每天推进一点点'), findsOneWidget);
    });

    testWidgets('名片上有明确的换背景入口', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      // 以前只有一个不显眼的小图标,用户找不到。
      expect(find.byTooltip('换背景图'), findsOneWidget);
      // 点它会去相册选图;测试环境没有相册,这里只确认入口在、并且是可点的。
      expect(find.byIcon(Icons.brush_outlined), findsOneWidget);
      final entry = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(Icons.brush_outlined),
          matching: find.byType(IconButton),
        ),
      );
      expect(entry.onPressed, isNotNull);
    });

    testWidgets('点相机角标能换头像', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '我的');

      // 头像上有个相机角标,说明它是可点的;点进去是"选图 → 调整"。
      expect(find.byIcon(Icons.photo_camera), findsOneWidget);
      final button = tester.widget<InkWell>(
        find
            .ancestor(
              of: find.byIcon(Icons.photo_camera),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(button.onTap, isNotNull);
    });

    testWidgets('调整图片的页面能缩放、能选形状', (tester) async {
      // 用户明确说过头像和背景"全都没法调整"。这一条盯着调整页真的在:
      // 有缩放滑杆、有形状选择、有完成按钮。
      await tester.pumpWidget(
        MaterialApp(
          home: _CropperHost(bytes: _tinyPng()),
        ),
      );
      await tester.tap(find.text('打开'));
      await tester.pumpAndSettle();

      expect(find.text('调整图片'), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('形状'), findsOneWidget);
      expect(find.text('完成'), findsOneWidget);
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

    testWidgets('深色模式下总结页的字看得见', (tester) async {
      // 曾经这里写死了浅色主题的字色(近黑),深色卡片上等于隐身:
      // 统计数字、逐天任务、AI 说明全都读不出来。
      // 用一条**未完成**的任务来断言:它走的是正文色那条分支,
      // 正是当初被写死成 lightTextPrimary 的地方。
      final task = store.seedTask(monday, '还没做的事');

      await pumpApp(tester, withDarkMode: true);
      await openTab(tester, '我的');
      await tester.tap(find.text('周报 / 月报'));
      await tester.pumpAndSettle();

      final text = tester.widget<Text>(find.byKey(Key('report-task-${task.id}')));
      final color = text.style!.color!;
      final surface = AppTheme.darkSurface;

      expect(
        color.computeLuminance(),
        greaterThan(surface.computeLuminance() + 0.3),
        reason: '深色底上的正文要明显更亮,实际字色 $color / 卡片底色 $surface',
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

    testWidgets('打钩时卡片颜色是过渡的,不是一下就换掉', (tester) async {
      store.seedTask(today, '待办甲');
      await pumpApp(tester);

      Color cardColor() {
        // TaskCard 里只有一层 Material(卡片底),取它就是要看的那块颜色。
        // 用 Key('task-...') 定位而不是找文字:文字节点每帧都会被重建。
        final card = find.byType(TaskCard);
        final material = find.descendant(of: card, matching: find.byType(Material));
        return (tester.widget(material.first) as Material).color!;
      }

      final before = cardColor();
      await tester.tap(find.byIcon(Icons.radio_button_unchecked));
      // 只推进一帧 + 40ms:这时候应该已经离开起始色,但还没到终色。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 40));
      final early = cardColor();
      await tester.pump(const Duration(milliseconds: 40));
      final late = cardColor();
      await tester.pumpAndSettle();
      final after = cardColor();

      expect(early, isNot(before), reason: '打钩后第一帧就该开始变色');
      expect(late, isNot(after), reason: '过渡没结束就不该到终色,否则等于没有过渡');
      expect(after, isNot(before), reason: '最终要变成完成态的配色');
    });
  });

  // ---------- 发送附件 ----------

  group('带附件发送', () {
    testWidgets('选好的文件真的会跟着这次请求发出去', (tester) async {
      // 这一条盯的是一个真实存在过的 bug:输入区在把附件交出去之前就清空了,
      // 于是选了图、点了发送、什么都没带上,而且一声不吭。
      final picked = _PickedFile('笔记.md', utf8.encode('今天读了 30 页'));
      FilePickerPlatform.instance = _StubPicker([picked]);
      addTearDown(() => FilePickerPlatform.instance = _defaultPicker);

      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      // 附件按钮在输入框左边(带图标的那个)。点它 → 选「文件」。
      await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件').last);
      await tester.pumpAndSettle();

      // 附件先出现在输入区的待发列表里。
      expect(find.text('笔记.md'), findsOneWidget);

      await tester.enterText(find.widgetWithText(TextField, '说点什么'), '看看这个');
      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      expect(
        ai.lastSentText(),
        contains('今天读了 30 页'),
        reason: '文件内容必须出现在发给模型的请求里',
      );
      expect(ai.lastSentText(), contains('看看这个'));
    });

    testWidgets('只发附件、不写字也能发出去', (tester) async {
      final picked = _PickedFile('笔记.md', utf8.encode('只有文件'));
      FilePickerPlatform.instance = _StubPicker([picked]);
      addTearDown(() => FilePickerPlatform.instance = _defaultPicker);

      await pumpApp(tester, withKey: true);
      await openTab(tester, '聊天');

      await tester.tap(find.byIcon(Icons.add_photo_alternate_outlined));
      await tester.pumpAndSettle();
      await tester.tap(find.text('文件').last);
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(Icons.arrow_upward));
      await tester.pumpAndSettle();

      // 以前这种情况会被"空消息"的判断拦掉:输入框清了,什么都没发生。
      expect(ai.lastBody, isNotNull, reason: '只有附件也该真的发一次请求');
      expect(ai.lastSentText(), contains('只有文件'));
    });
  });

  // ---------- 提醒 ----------
  group('日历里设提醒', () {
    testWidgets('点日期进的那一页可以直接设提醒,不用先建任务', (tester) async {
      // 这一页是点日历上的日期进来的。提醒的入口必须在这一层:
      // 让他先建任务、再钻进任务里设提醒,是把一步的事拆成三步。
      store.seedTask(today, '待办甲');
      await pumpApp(tester);
      await openTab(tester, '日历');

      await tester.tap(find.text('${DateTime.now().day}').first);
      await tester.pumpAndSettle();

      expect(find.byTooltip('加提醒'), findsOneWidget);
    });

    testWidgets('设完提醒会在这一页列出来,并且能取消', (tester) async {
      store.seedTask(today, '待办甲');
      await pumpApp(tester);
      await openTab(tester, '日历');

      await tester.tap(find.text('${DateTime.now().day}').first);
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('加提醒'));
      await tester.pumpAndSettle();
      // 自建的滚轮时刻选择器:滚动不需要瞄准,直接点确定用默认的 08:00。
      expect(find.text('提醒时间'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      // 列表里出现这个时刻。
      expect(find.text('08:00'), findsOneWidget);

      await tester.tap(find.byTooltip('取消这个提醒'));
      await tester.pumpAndSettle();
      expect(find.text('08:00'), findsNothing);
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

/// 一个最小的合法 PNG(1×1 透明),给裁剪页当输入用。
Uint8List _tinyPng() => Uint8List.fromList(const [
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, //
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
      0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
      0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
      0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
      0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
      0x42, 0x60, 0x82,
    ]);

/// 一个能打开裁剪页的小宿主:裁剪页是 push 出来的,得有 Navigator。
class _CropperHost extends StatelessWidget {
  const _CropperHost({required this.bytes});

  final Uint8List bytes;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          onPressed: () =>
              showImageCropper(context, bytes: bytes, withShape: true),
          child: const Text('打开'),
        ),
      ),
    );
  }
}

/// 一个假的"选好的文件"。///
/// 直接用内存字节,不走磁盘:这一组要验的是"选完之后有没有真的发给模型",
/// 不是插件的取文件逻辑。
base class _PickedFile extends PlatformFile {
  _PickedFile(this.name, this.bytes);

  @override
  final String name;

  final List<int> bytes;

  @override
  Uri get uri => Uri.file(name);

  @override
  XFile get xFile => XFile(name);

  @override
  int? lengthSync() => bytes.length;

  @override
  Future<int?> length() async => bytes.length;

  @override
  Future<Uint8List> readAsBytes() async => Uint8List.fromList(bytes);

  @override
  Stream<Uint8List> readAsByteStream() =>
      Stream.value(Uint8List.fromList(bytes));
}

/// 替换掉系统文件选择器:点"文件"之后直接返回预设的文件。
class _StubPicker extends FilePickerPlatform {
  _StubPicker(this.files);

  final List<PlatformFile> files;

  @override
  Future<List<PlatformFile>> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async {
    return files;
  }
}

/// 真机上本来装着的那个实例,测试结束后要还回去。
final _defaultPicker = FilePickerPlatform.instance;

/// 一个按脚本回答的假 HTTP 客户端。
///
/// 测的是"拿到这些流式分片之后界面怎么表现",所以不联网、也不依赖真实模型。
class _FakeAi extends http.BaseClient {
  _FakeAi({this.presetReply, this.presetChunks, this.replyDelay});

  /// 被调用了几次。用来确认"请求到底发出去了没有"。
  int calls = 0;

  /// 一次性返回的完整回答(用于 JSON 匹配这类要整段的场景)。
  final String? presetReply;

  /// 指定时按这些分片依次流式返回。
  final List<AiChunk>? presetChunks;

  /// 回复前先等一会儿。
  ///
  /// 给"正在读"这类**中间状态**的用例用:客户端瞬时返回的话,对话框
  /// 弹出来又立刻关掉,根本观察不到。默认 null(不拖慢其他用例)。
  final Duration? replyDelay;

  /// 最近一次请求体。用来断言"发出去的东西里到底有没有附件"。
  Map<String, Object?>? lastBody;

  /// 最近一次请求的全部文本内容拼在一起,方便直接找子串。
  String lastSentText() {
    final messages = lastBody?['messages'];
    if (messages is! List) return '';
    final buffer = StringBuffer();
    for (final item in messages) {
      if (item is! Map) continue;
      final content = item['content'];
      if (content is String) {
        buffer.writeln(content);
      } else if (content is List) {
        for (final part in content) {
          if (part is Map && part['text'] is String) buffer.writeln(part['text']);
        }
      }
    }
    return buffer.toString();
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    calls++;
    if (request is http.Request) {
      lastBody = jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
    }
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
      replyDelay == null
          ? Stream.fromIterable([utf8.encode('$body\n\ndata: [DONE]\n\n')])
          : Stream.fromIterable([utf8.encode('$body\n\ndata: [DONE]\n\n')])
              .asyncExpand(
              (frame) => Stream.fromIterable([frame]).asyncMap((f) async {
                await Future<void>.delayed(replyDelay!);
                return f;
              }),
            ),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
