import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/palette.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/state/app_state.dart';

import 'support/fake_store.dart';

/// 一个只会回固定 JSON 的假 AI。
///
/// 量化走 `complete`,它内部仍是流式请求(只是把分片拼起来),所以必须按
/// SSE 的 `data: {...}` 帧回:回一段裸 JSON 会被当成空内容,触发"空回复重试"
/// 然后报错,最后表现为测试去打了真接口、被测试绑定拦下。
class _JsonAi extends http.BaseClient {
  _JsonAi(this.reply);

  final String reply;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
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

/// 进度页右上角那个待同步角标,处理完必须能清掉。
///
/// 用户报的问题:"现在的右上角一直有数字角标残留(即便用 ai 整理了后,还是有,
/// 强迫症看着非常不舒服)"。
///
/// 根因是**计数定义错了**:以前数的是"本周做完的事里没有进度记录的条数",
/// 而「取快递」这种永远匹配不上任何推进条的事,永远没有进度记录,
/// 于是永远留在计数里——用户整理完、确认完,角标照样挂着。
///
/// 现在数的是"还没被 AI 读过并处理过的条数"。这一组盯的就是那件事。
void main() {
  // SharedPreferences 需要绑定。这一组不渲染界面,用普通的 test 就行。
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeStore store;

  setUp(() {
    store = FakeStore();
    SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
  });

  Future<AppState> boot({String aiReply = '{"matches":[],"newGoals":[]}'}) async {
    final state = AppState(
      store: store,
      reports: ReportService(store),
      settings: await SettingsStore.load(),
      aiClient: AiClient(httpClient: _JsonAi(aiReply)),
    );
    await state.bootstrap();
    return state;
  }

  test('没有推进条可匹配的事,处理完也要清掉角标', () async {
    // 「取快递」不会有任何进度记录,但它同样"被处理过了"。
    store.seedTask('2026-09-25', '取快递', done: true);
    store.seedTask('2026-09-25', '交作业', done: true);

    final state = await boot();
    await state.goToDay('2026-09-25');

    expect(
      state.pendingSyncCount,
      2,
      reason: '刚做完的两件事都还没被 AI 读过,角标应该是 2',
    );

    // 走一遍真实流程:AI 读过这批待办,用户在面板上一条都没勾就确认。
    final count = await state.requestProgressSuggestions();
    expect(count, 0, reason: '没有推进条可匹配,应当给 0 条建议');
    await state.markReviewedSuggestionsSynced();

    expect(
      state.pendingSyncCount,
      0,
      reason: '处理过之后角标必须归零,否则它永远清不掉',
    );
  });

  test('匹配上推进条的那条,确认后也不再计数', () async {
    store.seedTask('2026-09-25', '码字2k', done: true);
    final goalId = await store.addGoal(
      title: '小说推进',
      unit: '字',
      target: 10000,
      period: GoalPeriod.weekly,
      direction: GoalDirection.increase,
      color: TaskColor.blue,
    );

    final state = await boot();
    await state.goToDay('2026-09-25');
    expect(state.pendingSyncCount, 1);

    final task = (await store.unprocessedDoneTasks('2026-09-20', '2026-09-26')).single;
    await state.confirmSuggestions([
      ProgressSuggestion(
        goalId: goalId,
        goalTitle: '小说推进',
        amount: 2000,
        unit: '字',
        taskId: task.id,
        taskText: '码字2k',
        reason: '写了 2k',
      ),
    ]);

    expect(state.pendingSyncCount, 0);
    // 进度要真的记上,而不是只把角标抹掉。
    final entries = await store.progressEntriesOfGoal(goalId);
    expect(entries.single.amount, 2000);
  });

  test('新建目标的确认路径也会清角标', () async {
    store.seedTask('2026-09-25', '读《人物》30页', done: true);
    final state = await boot();
    await state.goToDay('2026-09-25');
    expect(state.pendingSyncCount, 1);

    final task = (await store.unprocessedDoneTasks('2026-09-20', '2026-09-26')).single;
    await state.confirmNewGoals([
      NewGoalSuggestion(
        title: '读书',
        unit: '页',
        amount: 30,
        reason: '读了两天书',
        taskId: task.id,
        taskText: '读《人物》30页',
      ),
    ]);

    expect(state.pendingSyncCount, 0);
  });
}
