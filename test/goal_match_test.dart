import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/goal_matcher.dart';
import 'package:yiji/ai/prompts.dart';
import 'package:yiji/ai/settings_store.dart';
import 'package:yiji/core/day.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/models.dart';
import 'package:yiji/data/palette.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/state/app_state.dart';
import 'package:yiji/update/app_updater.dart';

import 'support/fake_store.dart';

/// AI 量化「做完的事 → 推进条」。
///
/// 这一组盯的是这个功能的**通用性**:用户设「读xx书」,做完的事里写着
/// 「读到第 30 页」,进度条就该自己往前走到 30 页——不需要用户为这件事去补
/// 一条对应关系,也不需要他事先知道要读多少页。
///
/// 以前这里是靠提示词列举语义("健身(胸+三头)算一次力量训练")实现的,
/// 模型只会照搬那几个词,换个领域就不动了。所以下面有一条测试专门盯住
/// 「提示词里不许再出现具体领域的词表」。
///
/// 一个只会回固定内容的假 AI。
///
/// 量化走 `complete`,而它内部仍然是流式请求(只是把分片拼起来),所以这里
/// 必须按 SSE 的 `data: {...}` 帧回:回一段裸 JSON 会被当成空内容,
/// 触发"空回复重试"然后报错。
class _JsonAi extends http.BaseClient {
  _JsonAi(this.reply);

  final String reply;

  /// 最近一次发出去的请求体,用来断言提示词里塞了什么。
  Map<String, Object?>? lastBody;

  String lastPrompt() {
    final messages = lastBody?['messages'];
    if (messages is! List) return '';
    return [
      for (final item in messages) '${(item as Map)['content']}',
    ].join('\n');
  }

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (request is http.Request) {
      lastBody = jsonDecode(utf8.decode(request.bodyBytes)) as Map<String, Object?>;
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

const _flash = AiConfig(apiKey: 'sk-test', model: 'deepseek-flash');

/// 一条"没有目标值"的推进条:用户设了「读《义忆》」,但没说读到多少页。
Goal readingGoal({String unit = '', double? target}) => Goal(
      id: 7,
      title: '读《义忆》',
      unit: unit,
      target: target,
      current: 0,
      period: GoalPeriod.weekly,
      direction: GoalDirection.increase,
      color: TaskColor.blue,
      active: true,
      createdAt: DateTime(2026, 9, 29, 8, 0),
    );

Task readingTask() => Task(
      id: 3,
      // 用真实的今天:写死日期的话,一旦运行日期走出那一周,
      // `mondayOf(今天)` 算出的窗口就把这条任务挡在外面,用例会自己烂掉(踩过)。
      day: todayKey(),
      text: '读到第 30 页',
      done: true,
      sortOrder: 0,
      createdAt: DateTime(2026, 9, 29, 8, 0),
    );

void main() {
  // 这一组不走 pumpWidget,但要 bootstrap 一个真的 AppState——它会去问
  // 平台层要版本号,没有 binding 时那一步抛的是 StateError。
  TestWidgetsFlutterBinding.ensureInitialized();

  group('提示词是概念,不是词表', () {
    test('待办带上日期,并且说清哪段是这次要看的', () {
      // 用户报的两个问题都出在这里:
      // - "没有日期时间变化概念":以前每行只有「编号 | 内容」,模型看不到
      //   这件事是哪天做的,没法判断属不属于本周;
      // - "重复计算已经算过的任务":同一件事在多周数据里长得一样,
      //   它没有任何依据分辨"这条算过了"。
      final prompt = goalMatchPrompt(
        goalsBlock: '1 | 小说推进 | 1万 | 字 | 每周',
        tasksBlock: '1 | 2026-09-29 | 码字2k',
        spanBlock: '这段记录的日期范围:2026-09-29 到 2026-10-02;今天是 2026-10-03',
      );

      expect(prompt, contains('日期'));
      expect(prompt, contains('2026-09-29'));
      expect(prompt, contains('今天是 2026-10-03'));
      // 必须明确告诉它"列表里的都是没算过的"——这是防重复计算的关键一句。
      expect(prompt, contains('已经算过进度的记录不会出现在列表里'));
      // 也必须提醒它按周期过滤:周目标只算本周的。
      expect(prompt, contains('只算**落在这一周里**'));
    });

    test('聊天提示词不许声称自己记得他的记录', () {
      // 用户看到过 AI 提起他根本没记过的事。根因就是这句"长期陪伴者,
      // 读过你所有打卡记录"——模型顺着它编。没有附带数据时必须直说不知道。
      for (final claim in ['长期陪伴者', '读过你所有', '大学生']) {
        expect(
          chatSystemPrompt().contains(claim),
          isFalse,
          reason: '提示词里不该有「$claim」这种它做不到的设定',
        );
      }
      expect(chatSystemPrompt(), contains('这个对话'));
      expect(chatSystemPrompt(), contains('假装'));
    });

    test('不再列举具体领域的对应关系', () {
      // 块内容用中性占位符:这里如果塞进「健身」「力量训练」,测试就成了
      // 自己给自己喂答案,永远绿的。
      final prompt = goalMatchPrompt(goalsBlock: '1 | A', tasksBlock: '1 | B');

      for (final leaked in ['力量训练', '码字2k', '义忆', '早起']) {
        expect(
          prompt.contains(leaked),
          isFalse,
          reason: '提示词里不该出现「$leaked」这种举例词,判断要靠语义而不是词表',
        );
      }
    });

    test('要求它按意思判断,不要求字面重合', () {
      final prompt = goalMatchPrompt(goalsBlock: '1 | x', tasksBlock: '1 | y');
      expect(prompt, contains('意思'));
      expect(prompt, contains('一个词都没重合'));
    });

    test('允许推进条没有目标值', () {
      final prompt = goalMatchPrompt(goalsBlock: '1 | x', tasksBlock: '1 | y');
      expect(prompt, contains('未设定'));
    });
  });

  group('解析模型回包', () {
    /// 只取"匹配到已有推进条"那部分;这一组不测"建议新建"。
    Future<List<ProgressSuggestion>> matchWith(
      String reply, {
      String unit = '',
    }) async {
      final matcher = GoalMatcher(AiClient(httpClient: _JsonAi(reply)));
      final result = await matcher.match(
        config: _flash,
        goals: [readingGoal(unit: unit)],
        tasks: [readingTask()],
        suggestNewGoals: false,
      );
      return result.matches;
    }

    test('没有目标值的推进条也能拿到推进量', () async {
      final result = await matchWith(
        '{"matches":[{"task":1,"goal":1,"amount":30,"unit":"页",'
        '"reason":"待办里写了读到第 30 页"}]}',
      );

      expect(result, hasLength(1));
      expect(result.single.goalId, 7);
      expect(result.single.amount, 30);
      // 目标自己没定单位,就用模型这次判断里读出来的单位。
      // 否则界面上只会显示"推进 30",看不出是 30 个什么。
      expect(result.single.unit, '页');
      expect(result.single.taskId, 3);
    });

    test('用户定过单位时以用户的为准', () async {
      final result = await matchWith(
        '{"matches":[{"task":1,"goal":1,"amount":30,"unit":"页"}]}',
        unit: '章',
      );
      expect(result.single.unit, '章');
    });

    test('越界的编号被丢掉,不会连带整次失败', () async {
      final result = await matchWith(
        '{"matches":[{"task":9,"goal":1,"amount":30},{"task":1,"goal":9,"amount":5},'
        '{"task":1,"goal":1,"amount":12,"unit":"页"}]}',
      );
      expect(result, hasLength(1));
      expect(result.single.amount, 12);
    });
  });

  group('建目标', () {
    test('可以把目标值清掉,变回纯推进条', () {
      // 用户把「目标值」删掉再保存,意思是他不想再定这个数了。
      // 以前 copyWith 用的是 `target ?? this.target`,清空等于没清:
      // 进度条上还挂着旧目标,也就永远变不回推进条。
      final goal = Goal(
        id: 1,
        title: '读《义忆》',
        unit: '页',
        target: 300,
        current: 30,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
        active: true,
        createdAt: DateTime(2026, 9, 29, 8, 0),
      );
      final cleared = goal.copyWith(
        target: null,
        clear: {GoalField.target},
      );
      expect(cleared.target, isNull);
      expect(cleared.hasTarget, isFalse);
      // 清空目标值不该顺手把单位也丢了。
      expect(cleared.unit, '页');

      // 不声明 clear 时仍然是"不改"。
      expect(goal.copyWith(title: '改个名').target, 300);
    });

    test('没有目标值也能建出来', () {
      // 「我说不清要读多少页」是最常见的情形,不能因此建不了目标。
      final draft = GoalDraft.parse(
        '{"ok":true,"title":"读《义忆》","unit":"页","period":"weekly",'
        '"direction":"increase","color":"blue"}',
      );
      expect(draft, isNotNull);
      expect(draft!.title, '读《义忆》');
      expect(draft.target, isNull);
    });

    test('真正读不出目标时才失败', () {
      expect(GoalDraft.parse('{"ok":false}'), isNull);
      expect(GoalDraft.parse('{"ok":true}'), isNull);
    });

    test('建目标的提示词里 target 是可选的', () {
      final prompt = goalParsePrompt();
      expect(prompt, contains('只有用户明确说了数量才填'));
      expect(prompt, contains('不要为了凑数编一个'));
      // 不能再出现"读不出数值就失败"这种把没目标值的目标挡在门外的条件。
      expect(prompt.contains('根本读不出目标数值或目标事物'), isFalse);
    });
  });

  group('AI 建议补充新目标', () {
    late FakeStore store;
    late _JsonAi ai;

    Future<AppState> boot(String reply) async {
      SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
      ai = _JsonAi(reply);
      final state = AppState(
        store: store,
        reports: ReportService(store),
        settings: await SettingsStore.load(),
        aiClient: AiClient(httpClient: ai),
        updater: AppUpdater(
          httpClient: _JsonAi('{"matches":[]}'),
          owner: 'o',
          repo: 'r',
        ),
      );
      await state.bootstrap();
      return state;
    }

    Future<void> settle(AppState state) async {
      for (var i = 0; i < 30 && state.newGoalSuggestions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    setUp(() => store = FakeStore());

    test('做完的事没被追踪时,会建议建一个新目标', () async {
      // 用户改了名字但没建目标的典型情形:读了一周的书,进度里一片空白。
      final task = store.seedTask(todayKey(), '读书 30 页');
      final state = await boot(
        '{"matches":[],"newGoals":[{"task":1,"title":"读书",'
        '"unit":"页","reason":"这周在读,但没在追踪"}]}',
      );

      await state.toggleTask(task);
      await settle(state);

      expect(state.newGoalSuggestions, hasLength(1));
      final suggestion = state.newGoalSuggestions.single;
      expect(suggestion.title, '读书');
      expect(suggestion.unit, '页');
      // 建议里要带上这次已完成的数量,确认后一起记进去。
      expect(suggestion.amount, greaterThan(0));
    });

    test('确认后目标被建出来,并且这次的数量已经记上', () async {
      final task = store.seedTask(todayKey(), '读书 30 页');
      final state = await boot(
        '{"matches":[],"newGoals":[{"task":1,"title":"读书",'
        '"unit":"页","reason":"在读了"}]}',
      );

      await state.toggleTask(task);
      await settle(state);
      final created = await state.confirmNewGoals(
        List.of(state.newGoalSuggestions),
      );

      expect(created, 1);
      final goal = state.activeGoals.firstWhere((g) => g.title == '读书');
      // 记住:用户没定过目标值,所以这应该是一条**推进条**而不是进度条。
      expect(goal.hasTarget, isFalse);
      expect(goal.unit, '页');
      // 已经完成的量要跟着记进去,不用他再手动补一遍。
      expect(goal.current, greaterThan(0));
    });

    test('不勾选就不会建', () async {
      final task = store.seedTask(todayKey(), '读书 30 页');
      final state = await boot(
        '{"matches":[],"newGoals":[{"task":1,"title":"读书","unit":"页"}]}',
      );

      await state.toggleTask(task);
      await settle(state);
      expect(state.newGoalSuggestions, hasLength(1));

      // 面板上点"都不算"= 什么都不确认。
      await state.confirmNewGoals(const []);
      expect(state.activeGoals.where((g) => g.title == '读书'), isEmpty);
    });

    test('已经算进某条推进条的事,不会再被建议新建', () async {
      // 否则同一件事会被记两次:一次算进老目标,一次算进新建的。
      store.seedGoal(title: '小说推进', unit: '字', target: 10000, current: 0);
      final task = store.seedTask(todayKey(), '码字2k');
      final state = await boot(
        '{"matches":[{"task":1,"goal":1,"amount":2000,"unit":"字"}],'
        '"newGoals":[{"task":1,"title":"写作","unit":"字"}]}',
      );

      await state.toggleTask(task);
      await settle(state);

      expect(state.suggestions, hasLength(1));
      expect(
        state.newGoalSuggestions,
        isEmpty,
        reason: '同一条待办不能既算进已有目标又被建议新建',
      );
    });

    test('越界或没标题的建议被丢掉', () async {
      final task = store.seedTask(todayKey(), '读书 30 页');
      final state = await boot(
        '{"matches":[],"newGoals":['
        '{"task":9,"title":"不存在的待办"},'
        '{"task":1,"title":"   "},'
        '{"task":1,"title":"读书","unit":"页"}]}',
      );

      await state.toggleTask(task);
      await settle(state);
      expect(state.newGoalSuggestions, hasLength(1));
      expect(state.newGoalSuggestions.single.title, '读书');
    });
  });

  group('打完钩自动量化', () {
    late FakeStore store;
    late _JsonAi ai;

    Future<AppState> boot({String reply = '{"matches":[]}'}) async {
      SharedPreferences.setMockInitialValues({'ai_api_key': 'sk-test'});
      ai = _JsonAi(reply);
      final state = AppState(
        store: store,
        reports: ReportService(store),
        settings: await SettingsStore.load(),
        aiClient: AiClient(httpClient: ai),
        // 启动时会顺手查一次更新。测试里必须把它挡住:真去打 GitHub
        // 会让这组测试依赖网络,还会在测试结束后留下未完成的异步操作。
        updater: AppUpdater(
          httpClient: _JsonAi('{"matches":[]}'),
          owner: 'o',
          repo: 'r',
        ),
      );
      await state.bootstrap();
      return state;
    }

    /// 等后台那次自动同步落地。
    ///
    /// 它是 unawaited 跑起来的(打钩这个动作不该等网络),所以测试必须等它。
    /// 固定 sleep 会在机器慢的时候假失败,这里改成等结果出现。
    Future<void> settleAutoSync(AppState state) async {
      for (var i = 0; i < 30 && state.suggestions.isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    }

    setUp(() => store = FakeStore());

    test('勾完待办就自动给出建议,不用用户去点同步', () async {
      // 目标是「读《义忆》」,没有目标值——就是用户说的那种推进条。
      store.seedGoal(title: '读《义忆》', unit: '', target: 0, current: 0);
      final task = store.seedTask(todayKey(), '读到第 30 页');
      final state = await boot(
        reply: '{"matches":[{"task":1,"goal":1,"amount":30,"unit":"页",'
            '"reason":"写了读到第 30 页"}]}',
      );

      await state.toggleTask(task);
      await settleAutoSync(state);

      expect(state.suggestions, hasLength(1), reason: '勾完就该自动出现建议');
      expect(state.suggestions.single.amount, 30);
      expect(state.suggestions.single.unit, '页');
    });

    test('确认后进度真的前进,并补上缺的单位', () async {
      store.seedGoal(title: '读《义忆》', unit: '', target: 0, current: 0);
      final task = store.seedTask(todayKey(), '读到第 30 页');
      final state = await boot(
        reply: '{"matches":[{"task":1,"goal":1,"amount":30,"unit":"页"}]}',
      );

      await state.toggleTask(task);
      await settleAutoSync(state);
      await state.confirmSuggestions(List.of(state.suggestions));

      final goal = state.activeGoals.first;
      expect(goal.current, 30);
      // 用户当初没定单位,这次判断补上了——界面上才不会只写一个数字。
      expect(goal.unit, '页');
    });

    test('没配 key 时不发请求', () async {
      SharedPreferences.setMockInitialValues({});
      store.seedGoal(title: '读《义忆》', unit: '页', current: 0);
      final task = store.seedTask(todayKey(), '读到第 30 页');
      ai = _JsonAi('{"matches":[]}');
      final state = AppState(
        store: store,
        reports: ReportService(store),
        settings: await SettingsStore.load(),
        aiClient: AiClient(httpClient: ai),
        updater: AppUpdater(
          httpClient: _JsonAi('{"matches":[]}'),
          owner: 'o',
          repo: 'r',
        ),
      );
      await state.bootstrap();

      await state.toggleTask(task);
      await settleAutoSync(state);

      expect(state.suggestions, isEmpty);
      expect(ai.lastBody, isNull, reason: '没 key 就不该发请求');
    });

    test('只是关掉建议面板不会把结果丢掉', () async {
      // 这份建议是一次付费 API 调用的产物。误触遮罩/下拉关掉面板就把它清空的话,
      // 用户只能再花钱重跑一遍。
      store.seedGoal(title: '读《义忆》', unit: '页', current: 0);
      final task = store.seedTask(todayKey(), '读到第 30 页');
      final state = await boot(
        reply: '{"matches":[{"task":1,"goal":1,"amount":30,"unit":"页"}]}',
      );

      await state.toggleTask(task);
      await settleAutoSync(state);
      expect(state.suggestions, hasLength(1));

      // 界面上"关掉面板"对应的是什么都不做——结果应该还在。
      expect(state.suggestions.single.amount, 30);
    });

    test('一条待办只会被算一次', () async {      // 用户最可能做的动作是取消勾选再勾回来。那样不该又加 30 页。
      store.seedGoal(title: '读《义忆》', unit: '页', current: 0);
      final task = store.seedTask(todayKey(), '读到第 30 页');
      final state = await boot(
        reply: '{"matches":[{"task":1,"goal":1,"amount":30,"unit":"页"}]}',
      );

      await state.toggleTask(task);
      await settleAutoSync(state);
      await state.confirmSuggestions(List.of(state.suggestions));
      expect(state.activeGoals.first.current, 30);

      // 取消勾选,再勾回来。
      await state.toggleTask(task);
      await state.toggleTask(task);
      await settleAutoSync(state);

      expect(
        state.suggestions,
        isEmpty,
        reason: '已经计入过进度的待办不该再次出现',
      );
    });
  });
}
