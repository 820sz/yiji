import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/core/day.dart';
import 'package:yiji/data/chat_images.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/calendar_screen.dart';
import 'package:yiji/ui/status_curve.dart';

import 'support/fake_store.dart';

/// 会话隔离与提醒。
///
/// 这一组盯的是一个真实发生过的坏行为:新开的对话能"看到"以前聊过的内容,
/// AI 于是提起你从没在这个对话里说过的事——用户看到的就是"AI 在编记忆"。
/// 根因是发请求时把全局所有历史都拼进了上下文。
void main() {
  late FakeStore store;
  late AppState state;
  late _RecordingAi ai;

  final today = todayKey();

  Future<void> pumpApp(
    WidgetTester tester, {
    bool withKey = true,
    String reply = '好的。',
  }) async {
    SharedPreferences.setMockInitialValues(withKey ? {'ai_api_key': 'sk-test'} : {});
    ai = _RecordingAi(reply: reply);
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
    // 表情包清单在 widget 测试里读不出来:rootBundle 的 Future 永远不完成
    // (不报错也不返回),等它只会把用例挂死。直接喂一份图库进来,
    // 这样"提示词里有没有发图规则"和"指令能不能定位到图"这两条断言才是确定的。
    final catalog = MemeLibrary.fromIndex(const [
      Meme(
        file: 'happy/x.webp',
        tag: 'happy',
        caption: '摸着圆滚滚肚子，笑眯眯喊吃饱饱',
        keywords: '大肥鱼 开心 吃饱',
      ),
    ]);
    state.setMemeLibraryForTest(catalog);
    // 静态那份也要塞进去:解析引用、落库前的归一化都会走它。
    // 不塞的话,测试里去找真实 assets 的那一步会一直不返回(widget 测试的
    // 假时钟下等不到超时),表现成"回答永远不出来"——那是测试环境的性质。
    MemeLibrary.primeForTest(catalog);
  }

  setUp(() {
    store = FakeStore();
  });

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.widgetWithText(TextField, '说点什么'), text);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
  }

  group('表情包', () {
    testWidgets('模型要表情包时,指令不会显示、图会发出来', (tester) async {
      // 模型回一行 `[表情: 描述]`,那是给系统看的指令,不能显示给用户;
      // 系统按描述去图库里定位那张图,附在回答后面。
      //
      // 描述用的是**清单里真实存在的那一条**——现在挑图是闭集选择,
      // 模型抄哪条就定位哪条;用编出来的描述只会落到随机兜底上。
      await pumpApp(
        tester,
        reply: '好耶,那我也替你高兴。\n[表情: 摸着圆滚滚肚子，笑眯眯喊吃饱饱]',
      );
      await openTab(tester, '聊天');
      await send(tester, '今天任务全做完了');
      // 挑图 + 读字节是异步的:落库那一刻才算数,给它几帧。
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      // 指令行不能被用户看到。
      expect(find.textContaining('[表情'), findsNothing);
      expect(find.textContaining('摸着圆滚滚肚子'), findsNothing);
      // 正文照常显示。
      expect(find.textContaining('那我也替你高兴'), findsOneWidget);

      // 落库的消息里要带上挑出来的那张图。
      //
      // 生产环境写的是**自包含的 data URL**(字节直接在消息里),不依赖任何查找;
      // 拿不到字节时才退回引用。测试里的图库是注入的假库,拿不到字节,
      // 所以这里只断言"这一行在"——引用形式由 meme_bubble_render_test 专门盯着。
      final message = state.chat.where((m) => !m.isUser).last;
      expect(
        message.content,
        contains('![图]'),
        reason: '应该挑一张表情包并写进消息',
      );
    });

    testWidgets('模型没要表情包时不会硬塞一张', (tester) async {
      await pumpApp(tester, reply: '这周你码了 5k,比上周稳。');
      await openTab(tester, '聊天');
      await send(tester, '最近怎么样');

      final message = state.chat.where((m) => !m.isUser).last;
      expect(message.content.contains('![图]'), isFalse);
    });

    testWidgets('模型自己写的那行 ![图] 不会留在消息里(用户截图那个 bug)', (tester) async {
      // 用户截图里的占位框写着「引用:瘫成一团趴在鲸鱼抱枕上,眼都睁不开」——
      // 那不是路径,是一句描述:模型照着提示词里那个格式,自己写了一行
      // `![图] <清单里的描述>`。渲染层只认引用,于是显示「图不在了」。
      // 落库前要把这种行处理掉:认得出来就变成自包含字节,认不出来整行不留。
      await pumpApp(
        tester,
        reply: '今天又瘫了。\n\n![图] 摸着圆滚滚肚子，笑眯眯喊吃饱饱',
      );
      await openTab(tester, '聊天');
      await send(tester, '好累');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }

      final message = state.chat.where((m) => !m.isUser).last;
      expect(message.content, contains('今天又瘫了。'), reason: '正文一个字都不能丢');
      expect(
        message.content,
        isNot(contains('![图] 摸着圆滚滚肚子')),
        reason: '这一行渲染出来就是用户截图里的「图不在了」',
      );
    });

    testWidgets('历史再发给模型时,图片行换成一句人话', (tester) async {
      // 两个理由:内联字节一张图几十 KB 会挤爆上下文;而 `![图]` 这个格式
      // 出现在模型的上下文里,它会照着模仿——那正是上面那个 bug 的来源。
      await pumpApp(
        tester,
        reply: '好耶,那我也替你高兴。\n[表情: 摸着圆滚滚肚子，笑眯眯喊吃饱饱]',
      );
      await openTab(tester, '聊天');
      await send(tester, '今天任务全做完了');
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 25));
      }
      // 再发一句:这一轮的历史里就带着上一条 AI 消息(它含一张图)。
      await send(tester, '嗯嗯');

      final sent = ai.lastSentText();
      expect(sent.contains('![图]'), isFalse, reason: '模型照这个格式模仿就是那个 bug');
      expect(sent.contains('data:image'), isFalse, reason: '几十 KB 的 base64 不该进上下文');
      // 也不能改成方括号那种写法:模型会当成"发图的方式"照抄成一行文字。
      expect(sent.contains('[我发的图'), isFalse);
      expect(sent, contains('（你上一轮回了一张图'));
    });

    testWidgets('发图规则只在有图库时才发给模型', (tester) async {
      // 没有素材却允许它发,它就会写一行永远挑不到图的指令,还白占上下文。
      // 这个包里有 108 张,所以规则应该在。
      await pumpApp(tester);
      await openTab(tester, '聊天');
      await send(tester, '在吗');

      expect(ai.lastSentText(), contains('表情包'));
      expect(ai.lastSentText(), contains('[表情:'));
    });
  });

  group('会话隔离', () {
    testWidgets('新开的对话看不到上一个对话的内容', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '聊天');

      // 第一个对话里说一件具体的事。
      await send(tester, '我最近在练钢琴');
      expect(ai.lastSentText(), contains('我最近在练钢琴'));

      // 开一个新对话。
      await state.startNewConversation();
      await tester.pumpAndSettle();

      await send(tester, '你好');

      // 关键断言:新对话的上下文里不该出现上一轮说过的话。
      final sent = ai.lastSentText();
      expect(
        sent,
        isNot(contains('我最近在练钢琴')),
        reason: '把别的会话的历史发过去,AI 就会提起你在这个对话里从没说过的事',
      );
      expect(sent, contains('你好'));
    });

    testWidgets('同一个对话里的后续消息仍然带着之前的上下文', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '聊天');

      await send(tester, '我最近在练钢琴');
      await send(tester, '你觉得怎么样');

      // 同一会话内必须保持连续,否则就成了每次都在跟陌生人说话。
      final sent = ai.lastSentText();
      expect(sent, contains('我最近在练钢琴'));
      expect(sent, contains('你觉得怎么样'));
    });

    testWidgets('切回旧对话能看到当时的内容', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '聊天');

      await send(tester, '第一段对话');
      final first = state.currentConversationId;

      await state.startNewConversation();
      await tester.pumpAndSettle();
      await send(tester, '第二段对话');
      expect(find.text('第一段对话'), findsNothing);

      // 切回第一个对话,内容应该还在。
      await state.openConversation(first);
      await tester.pumpAndSettle();

      expect(find.text('第一段对话'), findsWidgets);
      expect(find.text('第二段对话'), findsNothing);
    });

    testWidgets('会话用首条用户消息自动起名', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '聊天');
      await send(tester, '帮我看看这周的进度');
      await tester.pumpAndSettle();

      // 侧边栏里显示的是这条标题,而不是一堆"新对话"。
      expect(state.conversations.single.title, contains('帮我看看这周的进度'));
    });

    testWidgets('每个对话的头像互相独立', (tester) async {
      // 用户要求:头像设置挪到每个聊天里,不同对话可以是不同的人设。
      //
      // 这一条只盯"互相独立"这个契约,**不碰头像文件的读写**:
      // 文件那层由 avatar_store_test.dart 单独覆盖(存了能读回来、
      // 换图会删掉旧文件、不同位置互不影响)。两层混在一条用例里的话,
      // 一条失败就说不清是哪层坏的。
      await pumpApp(tester);
      await openTab(tester, '聊天');
      await send(tester, '第一个对话');
      final first = state.currentConversationId;

      // 直接给第一个会话挂一条头像引用。
      await store.setConversationAvatar(first, 'conversation_1_1.png');
      await state.loadConversations();
      await tester.pumpAndSettle();

      // 开一个新对话:它不该继承上一个的头像。
      await state.startNewConversation();
      await tester.pumpAndSettle();
      await send(tester, '第二个对话');
      expect(state.currentConversationId, isNot(first), reason: '新对话是另一个会话');

      final original = state.conversations.firstWhere((c) => c.id == first);
      expect(
        original.avatar,
        contains('conversation_1_'),
        reason: '原来那个会话的头像引用不该被新会话顶掉',
      );
      final fresh = state.conversations.firstWhere((c) => c.id != first);
      expect(fresh.avatar, isEmpty, reason: '新会话不该继承别的会话的头像');
    });

    testWidgets('删掉会话之后不会再发它的历史', (tester) async {
      await pumpApp(tester);
      await openTab(tester, '聊天');
      await send(tester, '要删掉的对话');

      await state.deleteConversation(state.currentConversationId);
      await tester.pumpAndSettle();

      await send(tester, '全新的开始');
      final sent = ai.lastSentText();
      expect(sent, isNot(contains('要删掉的对话')));
    });

    testWidgets('重开 app 之后历史对话还在', (tester) async {
      // 这条盯着一个真实发生过的疏漏:bootstrap 只读了消息、没读会话列表,
      // 结果重开 app 后侧边栏是空的、历史对话看着像丢了。
      await pumpApp(tester);
      await openTab(tester, '聊天');
      await send(tester, '上次聊过的内容');
      await tester.pumpAndSettle();

      // 用同一个库重新造一个 AppState,模拟重启。
      final restarted = AppState(
        store: store,
        reports: ReportService(store),
        settings: await SettingsStore.load(),
        aiClient: AiClient(httpClient: _RecordingAi()),
      );
      await restarted.bootstrap();

      expect(restarted.conversations, hasLength(1));
      expect(restarted.chat.map((m) => m.content), contains('上次聊过的内容'));
      // 当前会话应被自动选中,而不是停在"没有会话"的状态。
      expect(restarted.currentConversationId, isNot(0));
    });
  });

  group('提醒', () {
    testWidgets('编辑页能给任务设提醒', (tester) async {
      store.seedTask(today, '晚上 交作业');
      await pumpApp(tester);

      await tester.tap(find.text('晚上 交作业'));
      await tester.pumpAndSettle();

      expect(find.text('提醒'), findsOneWidget);

      await tester.tap(find.text('提醒'));
      await tester.pumpAndSettle();

      // 自建的滚轮选择器(系统的 24 小时钟面会把 0-23 挤成一团、容易点错)。
      expect(find.text('提醒时间'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final reminders = await store.remindersOn(today);
      expect(reminders, hasLength(1));
      // 按钮上直接显示设好的时刻。
      expect(find.text(reminders.single.at), findsOneWidget);
    });

    testWidgets('已设提醒时能取消', (tester) async {
      final task = store.seedTask(today, '晚上 交作业');
      await store.addReminder(taskId: task.id, day: today, at: '20:00');
      await pumpApp(tester);

      await tester.tap(find.text('晚上 交作业'));
      await tester.pumpAndSettle();
      expect(find.text('20:00'), findsOneWidget);

      await tester.tap(find.text('20:00'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消提醒'));
      await tester.pumpAndSettle();

      expect(await store.remindersOn(today), isEmpty);
      expect(find.text('提醒'), findsOneWidget);
    });
  });

  group('日历完成度', () {
    List<DayProgress> progressOf(int total, int done) => [
          CalendarDayDot(total: total, done: done).progress,
        ];

    test('全做完是勾', () {
      expect(progressOf(3, 3).single, DayProgress.all);
    });

    test('一半以上是半勾', () {
      expect(progressOf(4, 2).single, DayProgress.half);
      expect(progressOf(3, 2).single, DayProgress.half);
    });

    test('不到一半是叉', () {
      expect(progressOf(4, 1).single, DayProgress.few);
      expect(progressOf(3, 0).single, DayProgress.few);
    });

    test('没有安排就不显示任何标记', () {
      expect(progressOf(0, 0).single, DayProgress.none);
    });

    testWidgets('日历上按完成度显示对应标记', (tester) async {
      // 今天三件事全做完 → 勾。
      for (var i = 1; i <= 3; i++) {
        store.seedTask(today, '任务$i', done: true);
      }
      await pumpApp(tester, withKey: false);
      await openTab(tester, '日历');

      final dots = tester
          .widgetList<CalendarDayDot>(find.byType(CalendarDayDot))
          .where((d) => d.total > 0);
      expect(dots, isNotEmpty);
      expect(dots.first.progress, DayProgress.all);
    });

    testWidgets('完成标记不能太小', (tester) async {
      // 用户原话:"'✓'这种标记太小了"。原来是 12,在 1080p 上只有几毫米,
      // 嵌在日期下面分不清是勾还是点——而它承载的是"这天做完没有"
      // 这个核心信息。
      store.seedTask(today, '任务', done: true);
      await pumpApp(tester, withKey: false);
      await openTab(tester, '日历');

      final mark = tester.getSize(
        find
            .descendant(
              of: find.byType(CalendarDayDot),
              matching: find.byType(Icon),
            )
            .first,
      );
      expect(
        mark.width,
        greaterThanOrEqualTo(16),
        reason: '标记只有 ${mark.width} 像素,太小了',
      );
    });

    testWidgets('记过的想法能在日历里看到(默认折叠)', (tester) async {
      // 用户原话:"日历里,无法看到记录过的'今日感想'"。
      // 后来又补了一条:"这月记的想法(默认折叠收起)"——日历的主体是日期,
      // 一屏里先看到的应该是格子。
      await store.saveJournal(today, '今天想通了一件事:情节是为了展现人物。');
      await pumpApp(tester, withKey: false);
      await openTab(tester, '日历');

      // 标题和天数要看得见,不然用户不知道这里有东西。
      expect(find.textContaining('这月记的想法'), findsOneWidget);
      // 正文默认不展开。
      expect(
        find.textContaining('情节是为了展现人物'),
        findsNothing,
        reason: '默认应当是折叠的',
      );

      // 点标题展开。
      await tester.tap(find.textContaining('这月记的想法'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('情节是为了展现人物'),
        findsOneWidget,
        reason: '展开后应当能看到想法正文',
      );
    });

    testWidgets('状态曲线在日历底部,默认近七天', (tester) async {
      // 用户要求:"根据近期每日任务完成率绘制曲线,纵轴 0/25/50/75/100%,
      // 横轴日期,范围自选,默认近七天"。
      store.seedTask(today, '任务', done: true);
      await pumpApp(tester, withKey: false);
      await openTab(tester, '日历');

      expect(find.text('状态曲线'), findsOneWidget);
      expect(find.text('近 7 天'), findsOneWidget, reason: '默认范围应当是近七天');
      expect(find.byType(StatusCurve), findsOneWidget);
    });

    testWidgets('没记过想法的月份不显示那一块', (tester) async {
      await pumpApp(tester, withKey: false);
      await openTab(tester, '日历');
      expect(find.textContaining('这月记的想法'), findsNothing);
    });

    testWidgets('换月有过渡动画,不是一帧换掉', (tester) async {
      // 用户原话:"日历月份切换之间没有动画过渡"。
      await pumpApp(tester, withKey: false);
      await openTab(tester, '日历');

      // AnimatedSwitcher 在换月时会同时挂着新旧两个孩子。
      expect(find.byType(AnimatedSwitcher), findsWidgets);
      await tester.tap(find.byTooltip('下个月'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 60));

      // 动画进行中:新旧两个月份同时存在。
      final switchers = tester.widgetList<AnimatedSwitcher>(
        find.byType(AnimatedSwitcher),
      );
      expect(switchers, isNotEmpty);
      await tester.pumpAndSettle();
      // 结束后只剩一个。
      expect(find.byTooltip('下个月'), findsOneWidget);
    });
  });

  group('没有目标值的推进条', () {
    testWidgets('只填标题就能建,不需要目标值和单位', (tester) async {
      await pumpApp(tester, withKey: false);
      await openTab(tester, '进度');

      await tester.tap(find.byIcon(Icons.add_circle_outline));
      await tester.pumpAndSettle();

      // 只填"推进什么",目标值和单位都留空。
      await tester.enterText(find.byType(TextField).at(1), '读《义忆》');
      await tester.ensureVisible(find.text('建好'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('建好'));
      await tester.pumpAndSettle();

      final goal = (await store.goals()).single;
      expect(goal.title, '读《义忆》');
      expect(goal.target, isNull, reason: '不知道要读几页时不该逼用户填一个数字');
      expect(goal.unit, '');
      expect(goal.hasTarget, isFalse);
    });

    testWidgets('没有目标值时显示"已推进"而不是百分比和"还差多少"', (tester) async {
      final goal = store.seedGoal(title: '读《义忆》', unit: '页', current: 0);
      await store.updateGoal(
        // seedGoal 总会给 target,这里显式清掉,模拟"没设目标值"。
        goal.copyWith(target: 0),
      );
      await store.addProgress(goalId: goal.id, amount: 46, day: today, note: '读了46页');

      await pumpApp(tester, withKey: false);
      await openTab(tester, '进度');

      expect(find.text('已推进 46 页'), findsOneWidget);
      expect(find.text('未设目标值'), findsOneWidget);
      // 没有终点就不该显示百分比。
      expect(find.textContaining('%'), findsNothing);
      expect(find.textContaining('还差'), findsNothing);
    });
  });

  group('目标的周期', () {
    testWidgets('周目标只算本周的推进量', (tester) async {
      // 上周推进过 5 次,本周 1 次。目标是"每周 3 次"。
      store.seedGoal(
        title: '力量训练',
        unit: '次',
        target: 3,
        current: 5,
        entryDay: addDays(today, -7),
      );
      final goal = (await store.goals()).single;
      await store.addProgress(goalId: goal.id, amount: 1, day: today, note: '今天练了');

      await pumpApp(tester, withKey: false);
      await openTab(tester, '进度');

      // 关键:不能把上周的 5 次算进来,否则这条进度条永远满着、再练也不动
      // ——那正是用户看到的"进度是死的"。
      expect(find.text('1 / 3 次'), findsOneWidget);
      expect(find.text('还差 2 次'), findsOneWidget);
    });

    testWidgets('月目标只算本月的推进量', (tester) async {
      store.seedGoal(
        title: '读书',
        unit: '本',
        target: 4,
        current: 9,
        period: GoalPeriod.monthly,
        entryDay: addDays(firstDayOfMonth(today), -3),
      );
      final goal = (await store.goals()).single;
      await store.addProgress(goalId: goal.id, amount: 2, day: today, note: '读了两本');

      await pumpApp(tester, withKey: false);
      await openTab(tester, '进度');

      expect(find.text('2 / 4 本'), findsOneWidget);
    });

    testWidgets('本期没有推进时显示 0,而不是历史累计', (tester) async {
      store.seedGoal(
        title: '力量训练',
        unit: '次',
        target: 3,
        current: 12,
        entryDay: addDays(today, -30),
      );

      await pumpApp(tester, withKey: false);
      await openTab(tester, '进度');

      expect(find.text('0 / 3 次'), findsOneWidget);
      expect(find.text('还差 3 次'), findsOneWidget);
    });
  });
}

/// 一个会记下"这次到底发了什么上下文"的假客户端。
///
/// 别的测试只关心回什么,这一组关心的是**发出去的东西**——
/// 会话隔离的 bug 正是发错了内容,不记下来就测不到。
class _RecordingAi extends http.BaseClient {
  _RecordingAi({this.reply = '好的。'});

  /// 这次要回什么。默认一句"好的。",测表情包时传带指令的内容。
  final String reply;

  List<AiMessage> lastMessagesSent = const [];

  /// 这次发出去的全部文本,拼成一段方便断言。
  String lastSentText() => lastMessagesSent.map((m) => m.text).join('\n');

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      final body = jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
      final messages = body['messages'];
      if (messages is List) {
        lastMessagesSent = [
          for (final item in messages)
            AiMessage.user(
              (item as Map)['content'] is String
                  ? item['content'] as String
                  : '${item['content']}',
            ),
        ];
      }
    }
    final body = 'data: ${jsonEncode({
          'choices': [
            {
              'delta': {'content': reply},
            }
          ],
        })}\n\ndata: [DONE]\n\n';
    return http.StreamedResponse(
      Stream.fromIterable([utf8.encode(body)]),
      200,
      headers: {'content-type': 'text/event-stream'},
    );
  }
}
