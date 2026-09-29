import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/goal_matcher.dart';
import 'package:yiji/ai/prompts.dart';
import 'package:yiji/ai/settings_store.dart';
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
      day: '2026-09-29',
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
    Future<List<ProgressSuggestion>> matchWith(
      String reply, {
      String unit = '',
    }) {
      final matcher = GoalMatcher(AiClient(httpClient: _JsonAi(reply)));
      return matcher.match(
        config: _flash,
        goals: [readingGoal(unit: unit)],
        tasks: [readingTask()],
      );
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
      final task = store.seedTask('2026-09-29', '读到第 30 页');
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
      final task = store.seedTask('2026-09-29', '读到第 30 页');
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
      final task = store.seedTask('2026-09-29', '读到第 30 页');
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

    test('一条待办只会被算一次', () async {
      // 用户最可能做的动作是取消勾选再勾回来。那样不该又加 30 页。
      store.seedGoal(title: '读《义忆》', unit: '页', current: 0);
      final task = store.seedTask('2026-09-29', '读到第 30 页');
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
