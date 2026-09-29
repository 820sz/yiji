/// 一条任务提醒。
///
/// [at] 是 `HH:mm`,和 [day] 拼起来才是完整时刻。分开存是为了按天查询方便:
/// 日历只需要"这一天有哪些提醒",不需要做时间戳范围扫描。
class Reminder {
  const Reminder({
    required this.id,
    required this.taskId,
    required this.day,
    required this.at,
    required this.note,
    required this.createdAt,
  });

  final int id;
  final int taskId;

  /// `YYYY-MM-DD`。
  final String day;

  /// `HH:mm`,24 小时制。
  final String at;

  /// 通知正文;空时用任务内容。
  final String note;

  final DateTime createdAt;

  /// 提醒时刻。
  ///
  /// 解析不出来时回退到当天 09:00 —— 宁可提醒得早一点,也不要因为一条坏数据
  /// 让整个通知调度抛异常。
  DateTime get when {
    final parts = at.split(':');
    final base = DateTime.tryParse(day);
    if (base == null) return DateTime.now();
    if (parts.length != 2) return DateTime(base.year, base.month, base.day, 9);
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) {
      return DateTime(base.year, base.month, base.day, 9);
    }
    return DateTime(base.year, base.month, base.day, hour, minute);
  }

  factory Reminder.fromMap(Map<String, Object?> map) {
    return Reminder(
      id: map['id'] as int,
      taskId: map['task_id'] as int,
      day: map['day'] as String,
      at: map['at'] as String,
      note: (map['note'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }

  static Map<String, Object?> insertMap({
    required int taskId,
    required String day,
    required String at,
    required String note,
    required DateTime createdAt,
  }) {
    return {
      'task_id': taskId,
      'day': day,
      'at': at,
      'note': note,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }
}
