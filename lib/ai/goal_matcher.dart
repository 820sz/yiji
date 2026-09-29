import 'dart:convert';

import '../data/goals.dart';
import '../data/models.dart';
import 'ai_client.dart';
import 'prompts.dart';
/// 把已完成的待办匹配到进度推进条上。
///
/// 匹配结果只是**建议**:界面把它展示出来、由用户确认后才落库。
/// 这样 AI 理解错(把"健身"算进"每周码字")时,代价是多看一眼,而不是进度条悄悄跑偏。
class GoalMatcher {
  GoalMatcher(this._ai);

  final AiClient _ai;

  /// 向模型要一次匹配结果。
  ///
  /// [goals] 与 [tasks] 的**下标 + 1** 就是提示词里的编号,回包按编号引用,
  /// 所以这里的顺序必须和拼进提示词的顺序完全一致。
  Future<List<ProgressSuggestion>> match({
    required AiConfig config,
    required List<Goal> goals,
    required List<Task> tasks,
  }) async {
    if (goals.isEmpty || tasks.isEmpty) return const [];

    final goalsBlock = [
      for (var i = 0; i < goals.length; i++)
        // 没有目标值的推进条把"目标"写成"未设定":提示词里也说明这一点,
        // 免得模型把 "-" 当成数字去凑。
        '${i + 1} | ${goals[i].title} | '
            '${goals[i].hasTarget ? Goal.formatAmount(goals[i].target!) : '未设定'} '
            '| ${goals[i].unit.isEmpty ? '(未定)' : goals[i].unit} '
            '| ${goals[i].period.label}',
    ].join('\n');
    final tasksBlock = [
      for (var i = 0; i < tasks.length; i++) '${i + 1} | ${tasks[i].text}',
    ].join('\n');

    final raw = await _ai.complete(
      config: config,
      jsonMode: true,
      history: [
        AiMessage.system(
          goalMatchPrompt(goalsBlock: goalsBlock, tasksBlock: tasksBlock),
        ),
        AiMessage.user('请给出 json 格式的匹配结果。'),
      ],
    );

    return _parse(raw, goals: goals, tasks: tasks);
  }

  /// 解析模型回包。
  ///
  /// 对模型输出做**宽松解析、严格校验**:JSON 外面可能裹着 ``` 代码块或多余文字,
  /// 编号必须落在真实范围内,amount 必须是正数。任何一条不合法就丢掉那一条,
  /// 而不是让整次同步失败——宁少不多,错一条比全崩更糟。
  static List<ProgressSuggestion> _parse(
    String raw, {
    required List<Goal> goals,
    required List<Task> tasks,
  }) {
    final json = _extractJsonObject(raw);
    if (json == null) {
      throw AiException('模型的返回不是有效 JSON,再试一次看看');
    }

    final matches = json['matches'];
    if (matches is! List) return const [];

    final result = <ProgressSuggestion>[];
    final usedTasks = <int>{};
    for (final entry in matches) {
      if (entry is! Map) continue;

      final taskIndex = _asInt(entry['task']);
      final goalIndex = _asInt(entry['goal']);
      final amount = _asDouble(entry['amount']);
      if (taskIndex == null || goalIndex == null || amount == null) continue;
      if (amount <= 0) continue;
      if (taskIndex < 1 || taskIndex > tasks.length) continue;
      if (goalIndex < 1 || goalIndex > goals.length) continue;
      // 一条待办最多算一次,模型偶尔会给同一编号两条。
      if (!usedTasks.add(taskIndex)) continue;

      final goal = goals[goalIndex - 1];
      final task = tasks[taskIndex - 1];
      result.add(
        ProgressSuggestion(
          goalId: goal.id,
          goalTitle: goal.title,
          unit: goal.unit,
          amount: amount,
          reason: (entry['reason'] as String?)?.trim() ?? '',
          taskId: task.id,
          taskText: task.text,
        ),
      );
    }
    return result;
  }

  /// 从可能带杂质的文本里抠出第一个 JSON 对象。
  static Map<String, Object?>? _extractJsonObject(String raw) {
    var text = raw.trim();
    // 去掉 ```json ... ``` 包裹。
    if (text.startsWith('```')) {
      final firstBreak = text.indexOf('\n');
      if (firstBreak > 0) text = text.substring(firstBreak + 1);
      final fence = text.lastIndexOf('```');
      if (fence >= 0) text = text.substring(0, fence);
      text = text.trim();
    }

    final start = text.indexOf('{');
    final end = text.lastIndexOf('}');
    if (start < 0 || end <= start) return null;

    try {
      final decoded = jsonDecode(text.substring(start, end + 1));
      return decoded is Map<String, Object?> ? decoded : null;
    } on FormatException {
      return null;
    }
  }

  static int? _asInt(Object? value) => switch (value) {
        final int v => v,
        final double v => v.round(),
        final String v => int.tryParse(v.trim()),
        _ => null,
      };

  static double? _asDouble(Object? value) => switch (value) {
        final int v => v.toDouble(),
        final double v => v,
        final String v => double.tryParse(v.trim().replaceAll(RegExp(r'[^\d.\-]'), '')),
        _ => null,
      };
}
