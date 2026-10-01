import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/goal_matcher.dart';
import 'package:yiji/ai/prompts.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/models.dart';
import 'package:yiji/data/palette.dart';

/// 真实 API 测试:验证"AI 读懂灵活表述"这件事真的成立。
///
/// 其余测试都用假客户端,只验"拿到这些分片之后界面怎么表现";
/// 但"码字2k 能不能被算进每周1万字"是**模型行为**,假客户端证明不了。
/// 所以这一组必须打真接口。
///
/// 跑法:
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; flutter test test/ai_live_test.dart
/// ```
/// 没配 key 时整组自动跳过,不会让日常 `flutter test` 红。
void main() {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final baseUrl = Platform.environment['DEEPSEEK_BASE_URL'] ?? AiConfig.defaultBaseUrl;

  if (apiKey.trim().isEmpty) {
    // 没 key 就整组跳过:这不是"测试通过",是"这次没验"。
    test('跳过真实 API 测试(没配 DEEPSEEK_API_KEY)', () {
      expect(apiKey, isEmpty);
    }, skip: '没配 DEEPSEEK_API_KEY,真实 API 行为未验证');
    return;
  }

  final config = AiConfig(apiKey: apiKey, baseUrl: baseUrl);
  final matcher = GoalMatcher(AiClient());

  /// 造一个"每周小说推进 1万字"的目标。
  Goal writingGoal() => Goal(
        id: 1,
        title: '小说推进',
        unit: '字',
        target: 10000,
        current: 0,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
        active: true,
        createdAt: DateTime(2026, 9, 25),
      );

  Task doneTask(int id, String text) => Task(
        id: id,
        day: '2026-09-25',
        text: text,
        done: true,
        sortOrder: id,
        createdAt: DateTime(2026, 9, 25),
      );

  group('真实 API:进度匹配', () {
    /// 只取"匹配到已有推进条"的那部分结果。
    ///
    /// `match` 现在还会带回"建议新建的目标"(那是另一条处置路径),
    /// 这一组测的是匹配本身,所以取 `.matches`。
    Future<List<ProgressSuggestion>> matchOnly({
      required List<Goal> goals,
      required List<Task> tasks,
    }) async {
      final result = await matcher.match(
        config: config,
        goals: goals,
        tasks: tasks,
        // 这一组不测"建议新建",关掉免得噪音混进来。
        suggestNewGoals: false,
      );
      return result.matches;
    }

    test('常规写法:码字2k → +2000 字', () async {
      final result = await matchOnly(
        goals: [writingGoal()],
        tasks: [doneTask(1, '上午 码字2k')],
      );

      expect(result, hasLength(1));
      expect(result.single.goalId, 1);
      expect(result.single.amount, 2000);
    });

    test('灵活写法:码了两千字 → 也能算出 2000', () async {
      final result = await matchOnly(
        goals: [writingGoal()],
        tasks: [doneTask(1, '上午寝室 码了两千字')],
      );

      expect(result, hasLength(1));
      expect(result.single.amount, 2000);
    });

    test('另一种灵活写法:写了 3k 字 → 3000', () async {
      final result = await matchOnly(
        goals: [writingGoal()],
        tasks: [doneTask(1, '下午 写了3k字')],
      );

      expect(result, hasLength(1));
      expect(result.single.amount, 3000);
    });

    test('没有数字、也不是"做一次算一个单位"的,不该硬算进进度', () async {
      final result = await matchOnly(
        goals: [writingGoal()],
        tasks: [
          doneTask(1, '下午 健身'),
          doneTask(2, '晚上 读《人物》'),
          doneTask(3, '上午 码字'),
        ],
      );

      // 目标是"每周1万字":这三条都没写多少字,正确答案是一条都不匹配。
      // 这条断言防的是"模型为了完成任务硬凑数字"。
      expect(result, isEmpty);
    });

    test('做一次就算一个单位的,即使没写数量也要算进去', () async {
      // 目标是"每周5次力量训练",待办只写"健身(胸+三头)"没写数量——
      // 这种情况必须算 1 次,否则用户设的进度条永远不会动。
      final strength = Goal(
        id: 3,
        title: '力量训练',
        unit: '次',
        target: 5,
        current: 0,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.green,
        active: true,
        createdAt: DateTime(2026, 9, 25),
      );
      final result = await matchOnly(
        goals: [strength],
        tasks: [doneTask(1, '下午 健身(胸+三头)')],
      );

      expect(result, hasLength(1));
      expect(result.single.goalId, 3);
      expect(result.single.amount, 1);
    });

    test('无关的事不会被算进来', () async {
      final result = await matchOnly(
        goals: [writingGoal()],
        tasks: [doneTask(1, '下午 跑了5公里')],
      );

      expect(result, isEmpty);
    });

    test('混合场景:只挑出该算的那些', () async {
      final result = await matchOnly(
        goals: [writingGoal()],
        tasks: [
          doneTask(1, '上午 码字2k'),
          doneTask(2, '下午 健身'),
          doneTask(3, '晚上 又写了 1500 字'),
          doneTask(4, '中午 吃饭'),
        ],
      );

      expect(result, hasLength(2));
      expect(
        result.map((s) => s.amount).reduce((a, b) => a + b),
        3500,
      );
      // 每条都要能被追回到具体待办,方便用户核对。
      expect(result.every((s) => s.taskId != 0), isTrue);
      expect(result.every((s) => s.taskText.isNotEmpty), isTrue);
    });

    test('多目标时能分清该进哪一条', () async {
      final goals = [
        writingGoal(),
        Goal(
          id: 2,
          title: '跑步',
          unit: '公里',
          target: 20,
          current: 0,
          period: GoalPeriod.weekly,
          direction: GoalDirection.increase,
          color: TaskColor.green,
          active: true,
          createdAt: DateTime(2026, 9, 25),
        ),
      ];
      final result = await matchOnly(
        goals: goals,
        tasks: [
          doneTask(1, '上午 码字2k'),
          doneTask(2, '傍晚 跑了5公里'),
        ],
      );

      expect(result, hasLength(2));
      expect(result.firstWhere((s) => s.goalId == 1).amount, 2000);
      expect(result.firstWhere((s) => s.goalId == 2).amount, 5);
    });
  });

  group('真实 API:思考模式', () {
    test('开启思考时能收到 reasoning_content,回答也正常', () async {
      final client = AiClient();
      final reasoning = StringBuffer();
      final answer = StringBuffer();

      await for (final chunk in client.streamChat(
        config: config,
        history: [
          AiMessage.system(chatSystemPrompt()),
          AiMessage.user('用一句话说明你为什么适合当我的记录助手。'),
        ],
      )) {
        if (chunk.isReasoning) {
          reasoning.write(chunk.text);
        } else {
          answer.write(chunk.text);
        }
      }
      client.dispose();

      expect(answer.toString().trim(), isNotEmpty);
      // 强度为默认的「中」,模型应该真的思考了。
      expect(reasoning.toString().trim(), isNotEmpty);
    });

    test('关掉思考时不返回 reasoning_content', () async {
      final client = AiClient();
      final reasoning = StringBuffer();
      final answer = StringBuffer();

      await for (final chunk in client.streamChat(
        config: config.copyWith(thinking: ThinkingLevel.off),
        history: [
          AiMessage.user('说一句早上好。'),
        ],
      )) {
        if (chunk.isReasoning) {
          reasoning.write(chunk.text);
        } else {
          answer.write(chunk.text);
        }
      }
      client.dispose();

      expect(answer.toString().trim(), isNotEmpty);
      expect(reasoning.toString().trim(), isEmpty);
    });

    test('JSON 输出模式能拿到可解析的结构', () async {
      final client = AiClient();
      final raw = await client.complete(
        config: config,
        jsonMode: true,
        history: [
          AiMessage.system(
            goalMatchPrompt(
              goalsBlock: '1 | 小说推进 | 1万 | 字 | 每周',
              tasksBlock: '1 | 上午 码字2k',
            ),
          ),
          AiMessage.user('请给出 json 格式的匹配结果。'),
        ],
      );
      client.dispose();

      // 即便外面裹了代码块,内容里也该有合法的 json 对象。
      expect(raw, contains('matches'));
      expect(() => jsonDecode(raw.substring(raw.indexOf('{'), raw.lastIndexOf('}') + 1)),
          returnsNormally);
    });
  });

  group('真实 API:周报成稿', () {
    test('能按「进度/不足/调整方向」的结构出稿', () async {
      final client = AiClient();
      final buffer = StringBuffer();

      await for (final chunk in client.streamChat(
        config: config,
        history: [
          AiMessage.system(
            reportPrompt(periodLabel: '9月14日 - 9月20日 的周总结', userContext: ''),
          ),
          AiMessage.user(
            '# 9月14日 - 9月20日 打卡数据\n\n'
            '统计:计划 5 条,完成 4 条,完成率 80%,有记录的天数 4 天。\n\n'
            '## 本周完成\n'
            '- 9月14日 上午 码字2k\n'
            '- 9月15日 下午下课 健身\n'
            '- 9月16日 读《人物》\n'
            '- 9月17日 家教备课\n\n'
            '## 没完成的\n'
            '- 9月18日 英语回译练习\n\n'
            '## 每天的想法/收获\n'
            '### 9月16日 周三\n'
            '今天读《人物》想通了:情节的目的是为了展现人物性格。\n',
          ),
        ],
      )) {
        if (!chunk.isReasoning) buffer.write(chunk.text);
      }
      client.dispose();

      final report = buffer.toString();
      expect(report.trim(), isNotEmpty);
      // 三个小标题是这份提示词存在的理由:他要把稿子直接贴进自己的 docx。
      expect(report, contains('进度方面'));
      expect(report, contains('不足'));
      expect(report, contains('调整方向'));
    });
  });
}
