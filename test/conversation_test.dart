import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/core/day.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/main.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/ui/calendar_screen.dart';

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

  Future<void> pumpApp(WidgetTester tester, {bool withKey = true}) async {
    SharedPreferences.setMockInitialValues(withKey ? {'ai_api_key': 'sk-test'} : {});
    ai = _RecordingAi();
    state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: ai),
    );
    await tester.pumpWidget(YijiApp(state: state, enableSplash: false));
    await tester.pumpAndSettle();
  }

  setUp(() => store = FakeStore());

  Future<void> openTab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> send(WidgetTester tester, String text) async {
    await tester.enterText(find.widgetWithText(TextField, '说点什么'), text);
    await tester.tap(find.byIcon(Icons.arrow_upward));
    await tester.pumpAndSettle();
  }

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

      // 时间选择器弹出。用结构定位而不是中文文案:按钮文字取决于设备语言。
      expect(find.byType(TimePickerDialog), findsOneWidget);
      await tester.tap(find.text('OK'));
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
              'delta': {'content': '好的。'},
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
