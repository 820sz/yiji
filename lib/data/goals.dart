/// 进度推进条:目标、方向、周期,以及一次推进的记录。
library;

import 'dart:convert';

import 'palette.dart';

/// 目标进度的推进方向。
///
/// 有方向之分是因为他既追踪"每周码字 1w"(越多越好),
/// 也可能追踪"体重降到 59kg"(越少越好)。同一个数字,含义相反。
enum GoalDirection {
  increase('增加'),
  decrease('减少');

  const GoalDirection(this.label);

  final String label;

  static GoalDirection fromKey(String? key) =>
      key == 'decrease' ? GoalDirection.decrease : GoalDirection.increase;
}

/// 目标的周期。
enum GoalPeriod {
  weekly('每周'),
  monthly('每月'),
  custom('自定义');

  const GoalPeriod(this.label);

  final String label;

  static GoalPeriod fromKey(String? key) {
    for (final period in GoalPeriod.values) {
      if (period.name == key) return period;
    }
    return GoalPeriod.weekly;
  }
}

/// 一个"进度推进条":某个周期内要推进到多少。
class Goal {
  const Goal({
    required this.id,
    required this.title,
    required this.unit,
    required this.current,
    required this.period,
    required this.direction,
    required this.color,
    required this.active,
    required this.createdAt,
    this.target,
    this.startDay,
    this.endDay,
  });

  final int id;

  /// 如"小说推进"。
  final String title;

  /// 计量单位,如"字""kg""次"。可以是空串(用户没写)。
  final String unit;

  /// 目标值。**可以为 null**:很多事情一开始根本不知道该推进到多少,
  /// 「读这本书」要读几页是读着读着才知道的。那时它只是一条推进记录,
  /// 而不是一个有待完成比例的进度条。
  final double? target;

  /// 当前值 = 所有进度条目之和。由存储层现算,不单独持久化,
  /// 避免"总数和明细对不上"这个最容易腐烂的地方。
  final double current;

  final GoalPeriod period;
  final GoalDirection direction;
  final TaskColor color;

  /// 归档的目标不再出现在进度页,但历史条目保留。
  final bool active;

  final DateTime createdAt;

  /// 仅 [GoalPeriod.custom] 使用,含首尾。
  final String? startDay;
  final String? endDay;

  /// 有没有预设目标值。没有时界面画一条纯推进条,不画"还差多少"。
  bool get hasTarget => target != null && target! > 0;

  /// 完成比例,夹在 0..1。没有目标值时返回 0——那种情况下这个比例没有意义。
  double get ratio {
    final goal = target;
    if (goal == null || goal <= 0) return 0;
    return (current / goal).clamp(0.0, 1.0);
  }

  /// 是否已达标。没有目标值时永远是 false(没有终点就谈不上到达)。
  bool get reached => hasTarget && current >= target!;

  /// 还差多少(已达标或没有目标值时为 0)。
  double get remaining {
    final goal = target;
    if (goal == null) return 0;
    final left = goal - current;
    return left > 0 ? left : 0;
  }

  /// `1.2万 / 3万 字`(有目标)或 `已推进 320 页`(没有目标)。
  String get progressLabel {
    final goal = target;
    if (goal == null || goal <= 0) {
      final amount = formatAmount(current);
      return unit.isEmpty ? '已推进 $amount' : '已推进 $amount $unit';
    }
    final text = '${formatAmount(current)} / ${formatAmount(goal)}';
    return unit.isEmpty ? text : '$text $unit';
  }

  /// 把数字按中文习惯缩略:过万显示"x.x万",否则去掉多余小数。
  static String formatAmount(double value) {
    final rounded = (value * 100).round() / 100;
    if (rounded.abs() >= 10000) {
      final wan = rounded / 10000;
      final text =
          wan == wan.roundToDouble() ? wan.round().toString() : wan.toStringAsFixed(1);
      return '$text万';
    }
    if (rounded == rounded.roundToDouble()) return rounded.round().toString();
    return rounded.toStringAsFixed(1);
  }

  Goal copyWith({
    String? title,
    String? unit,
    double? target,
    GoalPeriod? period,
    GoalDirection? direction,
    TaskColor? color,
    bool? active,
    String? startDay,
    String? endDay,
  }) {
    return Goal(
      id: id,
      title: title ?? this.title,
      unit: unit ?? this.unit,
      target: target ?? this.target,
      current: current,
      period: period ?? this.period,
      direction: direction ?? this.direction,
      color: color ?? this.color,
      active: active ?? this.active,
      createdAt: createdAt,
      startDay: startDay ?? this.startDay,
      endDay: endDay ?? this.endDay,
    );
  }

  /// 换掉当前值,其余不变。
  ///
  /// 存储实现按明细汇总出当前值后用它回填;这是 [copyWith] 之外单独一个方法,
  /// 因为 current 是由进度条目算出来的、不该被调用方随手改。
  Goal copyWithCurrent(double value) {
    return Goal(
      id: id,
      title: title,
      unit: unit,
      target: target,
      current: value,
      period: period,
      direction: direction,
      color: color,
      active: active,
      createdAt: createdAt,
      startDay: startDay,
      endDay: endDay,
    );
  }

  /// 从数据库行还原。[current] 由调用方查进度条目汇总后传入。
  factory Goal.fromMap(Map<String, Object?> map, {double current = 0}) {
    return Goal(
      id: map['id'] as int,
      title: map['title'] as String,
      unit: (map['unit'] as String?) ?? '',
      // target 列允许为 NULL,所以这里不能用 `as num`。
      target: (map['target'] as num?)?.toDouble(),
      current: current,
      period: GoalPeriod.fromKey(map['period'] as String?),
      direction: GoalDirection.fromKey(map['direction'] as String?),
      color: TaskColor.fromKey(map['color'] as String?),
      active: (map['active'] as int? ?? 1) != 0,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      startDay: map['start_day'] as String?,
      endDay: map['end_day'] as String?,
    );
  }
}

/// 一次进度推进。目标当前值 = 该目标所有条目的 amount 之和。
class ProgressEntry {
  const ProgressEntry({
    required this.id,
    required this.goalId,
    required this.amount,
    required this.day,
    required this.note,
    required this.taskId,
    required this.source,
    required this.createdAt,
  });

  final int id;
  final int goalId;
  final double amount;

  /// 推进发生在哪一天(用于按周期统计与展示)。
  final String day;

  /// 说明,如"码字2k"。
  final String note;

  /// 来自哪条待办;手动加时为 null。
  final int? taskId;

  /// `manual` 或 `ai`。记录来源是为了能筛出 AI 的判断、必要时批量撤销。
  final String source;

  final DateTime createdAt;

  bool get fromAi => source == 'ai';

  factory ProgressEntry.fromMap(Map<String, Object?> map) {
    return ProgressEntry(
      id: map['id'] as int,
      goalId: map['goal_id'] as int,
      amount: (map['amount'] as num).toDouble(),
      day: map['day'] as String,
      note: (map['note'] as String?) ?? '',
      taskId: map['task_id'] as int?,
      source: (map['source'] as String?) ?? 'manual',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }
}

/// AI 从一句自然语言里拆出来的目标草稿。
///
/// 用来**预填表单**,不直接建目标:AI 理解错了用户还能当场改。
/// [target] 可以为 null:说不清要推进到多少的目标照样能建。
class GoalDraft {
  const GoalDraft({
    required this.title,
    required this.unit,
    required this.period,
    required this.direction,
    required this.color,
    this.target,
  });

  final String title;
  final double? target;
  final String unit;
  final GoalPeriod period;
  final GoalDirection direction;
  final TaskColor color;

  /// 从模型回包里解析。
  ///
  /// 宽松解析、严格校验:外面可能裹着代码块,字段可能是字符串数字。
  /// **只有标题是必需的**——没有目标值、没有单位都能建,不能因为
  /// 模型没给出数字就整条丢掉(那正是"读这本书"建不出来的原因)。
  static GoalDraft? parse(String raw) {
    var text = raw.trim();
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

    final Object? decoded;
    try {
      decoded = jsonDecode(text.substring(start, end + 1));
    } on FormatException {
      return null;
    }
    if (decoded is! Map) return null;
    if (decoded['ok'] == false) return null;

    final title = (decoded['title'] as String?)?.trim();
    if (title == null || title.isEmpty) return null;

    final target = _asDouble(decoded['target']);
    final unit = (decoded['unit'] as String?)?.trim();
    return GoalDraft(
      title: title,
      // 模型没给出正数就当没有目标值,而不是判为解析失败。
      target: (target != null && target > 0) ? target : null,
      unit: unit ?? '',
      period: GoalPeriod.fromKey(decoded['period'] as String?),
      direction: GoalDirection.fromKey(decoded['direction'] as String?),
      color: TaskColor.fromKey(decoded['color'] as String?),
    );
  }

  static double? _asDouble(Object? value) => switch (value) {
        final int v => v.toDouble(),
        final double v => v,
        final String v => double.tryParse(v.trim().replaceAll(RegExp(r'[^\d.\-]'), '')),
        _ => null,
      };
}

/// AI 建议的一次进度推进(尚未落库)。
class ProgressSuggestion {
  const ProgressSuggestion({
    required this.goalId,
    required this.goalTitle,
    required this.unit,
    required this.amount,
    required this.reason,
    required this.taskId,
    required this.taskText,
  });

  final int goalId;
  final String goalTitle;
  final String unit;
  final double amount;

  /// AI 给出的判断依据,展示给用户看,让"为什么算这么多"可核对。
  final String reason;

  final int taskId;
  final String taskText;

  /// 展示用:`+2000 字`。
  String get amountLabel => '+${Goal.formatAmount(amount)} $unit';
}
