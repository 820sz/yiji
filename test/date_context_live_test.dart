import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/ai/ai_client.dart';
import 'package:yiji/ai/goal_matcher.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/models.dart';
import 'package:yiji/data/palette.dart';

/// 真实接口验证:**日期上下文有没有让模型规矩起来**。
///
/// 用户报的两条:
/// - "ai 会重复计算已经算过的任务进度"
/// - "没有日期时间变化概念"
///
/// 修法是给每条待办带上日期,并明确告诉它"列表里的都是还没算过的"。
/// 这里拿真接口验两件事:
/// 1. 上周的记录不会被算进"本周"目标;
/// 2. 它不会凭记忆补出列表里没有的量。
///
/// 手动开:
/// ```
/// $env:DEEPSEEK_API_KEY="sk-..."; $env:DATE_LIVE="1"
/// flutter test test/date_context_live_test.dart
/// ```
void main() {
  final apiKey = Platform.environment['DEEPSEEK_API_KEY'] ?? '';
  final enabled = Platform.environment['DATE_LIVE'] == '1';

  if (apiKey.trim().isEmpty || !enabled) {
    test('跳过日期上下文验证', () {
      expect(enabled && apiKey.isNotEmpty, isFalse);
    }, skip: '需要同时设置 DEEPSEEK_API_KEY 与 DATE_LIVE=1');
    return;
  }

  final matcher = GoalMatcher(AiClient());
  final config = AiConfig(apiKey: apiKey);

  Goal weeklyWriting() => Goal(
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

  Task task(int id, String day, String text) => Task(
        id: id,
        day: day,
        text: text,
        done: true,
        sortOrder: id,
        createdAt: DateTime(2026, 9, 25),
      );

  test('上周的记录不会被算进本周目标', () async {
    // 今天是 10-03(周五);本周是 9-29 ~ 10-05。
    // 混进一条 9-20 的记录(上一周),它不该被算。
    final result = await matcher.match(
      config: config,
      goals: [weeklyWriting()],
      tasks: [
        task(1, '2026-09-20', '码字 5000 字'),
        task(2, '2026-10-01', '码字 2000 字'),
      ],
      suggestNewGoals: false,
      today: '2026-10-03',
    );

    // ignore: avoid_print
    print('=== 跨周 → '
        '${result.matches.map((m) => '${m.taskText}=>${m.amount}${m.unit}(${m.reason})').toList()}');

    // 本周那条应当被算上。
    expect(
      result.matches.any((m) => m.taskText.contains('2000')),
      isTrue,
      reason: '本周的记录必须算进去',
    );
    // 上周那条不该出现。
    expect(
      result.matches.any((m) => m.taskText.contains('5000')),
      isFalse,
      reason: '上周的记录不该算进周目标,实际:${result.matches.map((m) => m.taskText).toList()}',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));

  test('不会凭记忆补出列表里没有的量', () async {
    // 只给一条小量记录,看它会不会"顺手"补成一个大数。
    final result = await matcher.match(
      config: config,
      goals: [weeklyWriting()],
      tasks: [task(1, '2026-10-01', '码字 800 字')],
      suggestNewGoals: false,
      today: '2026-10-03',
    );

    // ignore: avoid_print
    print('=== 单条 → '
        '${result.matches.map((m) => '${m.taskText}=>${m.amount}${m.unit}').toList()}');

    expect(result.matches, hasLength(1));
    expect(
      result.matches.single.amount,
      800,
      reason: '列表里只写了 800,就该是 800;多出来的都是编的',
    );
  }, timeout: const Timeout(Duration(minutes: 4)));
}
