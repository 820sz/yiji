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
  ///
  /// [suggestNewGoals] 为真时,还会让模型指出"哪些做完的事还没有对应的推进条",
  /// 一次给你一批可以一键补上的目标。不传就不问——那只在看历史数据时才有意义。
  ///
  /// [onProgress] 每收到一段就调一次,内容是**已经收到的原文**。
  /// 界面拿它显示"正在读"的过程,而不是干转圈——用户报过"ai的流式输出ui
  /// (而不是现在的转圈等待)"。
  Future<GoalMatchResult> match({
    required AiConfig config,
    required List<Goal> goals,
    required List<Task> tasks,
    bool suggestNewGoals = true,
    void Function(String partial)? onProgress,
  }) async {
    if (tasks.isEmpty) return const GoalMatchResult();
    // 一条目标都没有时更该问"要不要建":这正是新用户第一次同步的情形。
    if (goals.isEmpty && !suggestNewGoals) return const GoalMatchResult();

    final goalsBlock = goals.isEmpty
        ? '(还没有任何推进条)'
        : [
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

    final raw = await _complete(
      config: config,
      goalsBlock: goalsBlock,
      tasksBlock: tasksBlock,
      suggestNewGoals: suggestNewGoals,
      onProgress: onProgress,
    );

    return _parse(
      raw,
      goals: goals,
      tasks: tasks,
      suggestNewGoals: suggestNewGoals,
    );
  }

  /// 发一次请求并把分片拼成完整回复。
  ///
  /// 用 `streamChat` 而不是 `complete`,只为了能**边收边报进度**:
  /// `complete` 在拿到完整回复之前什么都给不出来,界面只能转圈。
  /// 这里自己拼 JSON,顺带把每次收到的内容交给 [onProgress]。
  ///
  /// 空回复重试一次的行为和 `complete` 保持一致:JSON 模式下服务端有概率
  /// 返回空 content,直接当失败会白白浪费一次调用。
  Future<String> _complete({
    required AiConfig config,
    required String goalsBlock,
    required String tasksBlock,
    required bool suggestNewGoals,
    void Function(String partial)? onProgress,
  }) async {
    final history = [
      AiMessage.system(
        goalMatchPrompt(
          goalsBlock: goalsBlock,
          tasksBlock: tasksBlock,
          suggestNewGoals: suggestNewGoals,
        ),
      ),
      AiMessage.user('请给出 json 格式的结果。'),
    ];

    for (var attempt = 0; attempt < 2; attempt++) {
      final buffer = StringBuffer();
      await for (final chunk in _ai.streamChat(
        config: config,
        history: history,
        jsonMode: true,
      )) {
        // 思考内容不算进度:用户要看的是它读出来了什么,不是它在想什么。
        if (chunk.isReasoning) continue;
        buffer.write(chunk.text);
        onProgress?.call(buffer.toString());
      }
      final text = buffer.toString().trim();
      if (text.isNotEmpty) return text;
    }
    throw AiException('模型没有返回内容,再试一次');
  }

  /// 解析模型回包。
  ///
  /// 对模型输出做**宽松解析、严格校验**:JSON 外面可能裹着 ``` 代码块或多余文字,
  /// 编号必须落在真实范围内,amount 必须是正数。任何一条不合法就丢掉那一条,
  /// 而不是让整次同步失败——宁少不多,错一条比全崩更糟。
  static GoalMatchResult _parse(
    String raw, {
    required List<Goal> goals,
    required List<Task> tasks,
    bool suggestNewGoals = false,
  }) {
    final json = _extractJsonObject(raw);
    if (json == null) {
      throw AiException('模型的返回不是有效 JSON,再试一次看看');
    }

    final matches = json['matches'];
    if (matches is! List && json['newGoals'] is! List) {
      return const GoalMatchResult();
    }

    final result = <ProgressSuggestion>[];
    final newGoals = <NewGoalSuggestion>[];
    final usedTasks = <int>{};
    if (matches is List) {
      _collectMatches(
        matches,
        goals: goals,
        tasks: tasks,
        into: result,
        usedTasks: usedTasks,
      );
    }
    if (suggestNewGoals && json['newGoals'] is List) {
      _collectNewGoals(
        json['newGoals'] as List,
        tasks: tasks,
        into: newGoals,
        usedTasks: usedTasks,
      );
    }
    return GoalMatchResult(matches: result, newGoals: newGoals);
  }

  static void _collectMatches(
    List<Object?> matches, {
    required List<Goal> goals,
    required List<Task> tasks,
    required List<ProgressSuggestion> into,
    required Set<int> usedTasks,
  }) {
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
      // 单位:模型在这次判断里用的那个优先。用户在目标上定过单位就听用户的,
      // 没定过(比如「读xx书」建的时候没填)则接受模型从待办里读出来的单位,
      // 否则"读了30页"会显示成光秃秃的"推进 30"。
      final suggestedUnit = (entry['unit'] as String?)?.trim() ?? '';
      into.add(
        ProgressSuggestion(
          goalId: goal.id,
          goalTitle: goal.title,
          unit: goal.unit.isNotEmpty ? goal.unit : suggestedUnit,
          amount: amount,
          reason: (entry['reason'] as String?)?.trim() ?? '',
          taskId: task.id,
          taskText: task.text,
        ),
      );
    }
  }

  /// 解析"建议新建"的那一批。
  ///
  /// 校验与匹配同样严格:标题不能空、任务编号必须在范围内、
  /// 一条待办不能既算进已有推进条又参与新建(否则会重复计数)。
  static void _collectNewGoals(
    List<Object?> entries, {
    required List<Task> tasks,
    required List<NewGoalSuggestion> into,
    required Set<int> usedTasks,
  }) {
    for (final entry in entries) {
      if (entry is! Map) continue;
      final title = (entry['title'] as String?)?.trim() ?? '';
      if (title.isEmpty) continue;
      final taskIndex = _asInt(entry['task']);
      if (taskIndex == null) continue;
      if (taskIndex < 1 || taskIndex > tasks.length) continue;
      if (!usedTasks.add(taskIndex)) continue;

      final task = tasks[taskIndex - 1];
      final amount = _asDouble(entry['amount']) ?? 1;
      final unit = (entry['unit'] as String?)?.trim() ?? '';
      into.add(
        NewGoalSuggestion(
          title: title,
          unit: unit,
          amount: amount > 0 ? amount : 1,
          reason: (entry['reason'] as String?)?.trim() ?? '',
          taskId: task.id,
          taskText: task.text,
        ),
      );
    }
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
