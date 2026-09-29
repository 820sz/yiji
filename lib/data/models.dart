/// 待办、日记、聊天三类记录的数据模型。
///
/// 时间统一用两种表示:`day` 是本地日期字符串 `YYYY-MM-DD`(跨时区不会漂移,
/// 便于按周/月做字符串范围查询),`created_at`/`completed_at` 是毫秒时间戳
/// (只用于排序和展示具体时刻)。
///
/// 目标与进度推进条在 [goals.dart]。
library;

import 'palette.dart';
/// 一条待办 = 某一天计划做的一件事。
class Task {
  const Task({
    required this.id,
    required this.day,
    required this.text,
    required this.done,
    required this.sortOrder,
    required this.createdAt,
    this.completedAt,
    this.color = TaskColor.blue,
  });

  final int id;

  /// 计划执行的本地日期,`YYYY-MM-DD`。
  final String day;
  final String text;
  final bool done;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime? completedAt;

  /// 卡片配色。用户按"每类事一个颜色"来分。
  final TaskColor color;

  /// 从数据库行还原。
  ///
  /// [id] 用 `as int` 而非可空,是因为 sqflite 的 `insert` 才可能返回 null,
  /// 从 `query` 读出来的行一定带主键。
  factory Task.fromMap(Map<String, Object?> map) {
    final completedAt = map['completed_at'] as int?;
    return Task(
      id: map['id'] as int,
      day: map['day'] as String,
      text: map['text'] as String,
      done: (map['done'] as int) != 0,
      sortOrder: map['sort_order'] as int,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      completedAt: completedAt == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(completedAt),
      color: TaskColor.fromKey(map['color'] as String?),
    );
  }

  /// 写入数据库用的行。不含 `id`,交给 SQLite 自增。
  static Map<String, Object?> insertMap({
    required String day,
    required String text,
    required int sortOrder,
    required DateTime createdAt,
    TaskColor color = TaskColor.blue,
  }) {
    return {
      'day': day,
      'text': text,
      'done': 0,
      'sort_order': sortOrder,
      'created_at': createdAt.millisecondsSinceEpoch,
      'color': color.key,
    };
  }

  Task copyWith({
    String? text,
    bool? done,
    DateTime? completedAt,
    int? sortOrder,
    TaskColor? color,
  }) {
    return Task(
      id: id,
      day: day,
      text: text ?? this.text,
      done: done ?? this.done,
      sortOrder: sortOrder ?? this.sortOrder,
      createdAt: createdAt,
      completedAt: completedAt ?? this.completedAt,
      color: color ?? this.color,
    );
  }
}

/// 一天的一段想法/收获。一天最多一条。
class Journal {
  const Journal({required this.day, required this.text, required this.updatedAt});

  final String day;
  final String text;
  final DateTime updatedAt;

  factory Journal.fromMap(Map<String, Object?> map) {
    return Journal(
      day: map['day'] as String,
      text: map['text'] as String,
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    );
  }

  /// 判空用:只有空白字符的日记等同没写。
  bool get isEmpty => text.trim().isEmpty;

  static Map<String, Object?> upsertMap({
    required String day,
    required String text,
    required DateTime updatedAt,
  }) {
    return {
      'day': day,
      'text': text,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }
}

/// AI 聊天的一条消息。
/// 一个会话(聊天侧边栏里的一条)。
///
/// 消息必须挂在会话下:否则每次请求都会把历史上所有对话拼进上下文,
/// AI 就会像"记得"你从没在这个对话里提过的事。
class Conversation {
  const Conversation({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.updatedAt,
    this.messageCount = 0,
  });

  final int id;

  /// 会话标题。空串表示还没起名,界面用首条用户消息兜底。
  final String title;

  final DateTime createdAt;
  final DateTime updatedAt;

  /// 消息条数,侧边栏用来判断这个会话是不是空的。
  final int messageCount;

  bool get isEmpty => messageCount == 0;

  factory Conversation.fromMap(Map<String, Object?> map, {int messageCount = 0}) {
    return Conversation(
      id: map['id'] as int,
      title: (map['title'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
      messageCount: messageCount,
    );
  }
}

class ChatMessage {
  const ChatMessage({
    required this.id,
    required this.conversationId,
    required this.role,
    required this.content,
    required this.createdAt,
    this.reasoning = '',
  });

  final int id;

  /// 属于哪个会话。发请求时只取本会话的历史。
  final int conversationId;

  /// `user` 或 `assistant`。
  final String role;
  final String content;

  /// 思考过程(reasoning_content)。空串表示这轮没有思考内容。
  ///
  /// 存下来而不是只显示一次:回头看"当时它为什么这么答"是有用的,
  /// 而且思考过程不进后续请求的上下文(未带 tools 时官方会忽略)。
  final String reasoning;

  final DateTime createdAt;

  bool get isUser => role == 'user';

  bool get hasReasoning => reasoning.trim().isNotEmpty;

  factory ChatMessage.fromMap(Map<String, Object?> map) {
    return ChatMessage(
      id: map['id'] as int,
      conversationId: (map['conversation_id'] as int?) ?? 0,
      role: map['role'] as String,
      content: map['content'] as String,
      reasoning: (map['reasoning'] as String?) ?? '',
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    );
  }

  static Map<String, Object?> insertMap({
    required int conversationId,
    required String role,
    required String content,
    required DateTime createdAt,
    String reasoning = '',
  }) {
    return {
      'conversation_id': conversationId,
      'role': role,
      'content': content,
      'reasoning': reasoning,
      'created_at': createdAt.millisecondsSinceEpoch,
    };
  }
}

/// 一个时间区间(周或月)的**统计结果**,不是存储对象。
///
/// 报告永远由 [tasks] 现算得出:原始打卡记录是唯一事实源,
/// 报告只是它的一种投影,所以这里不存库、可随时重算。
class PeriodReport {
  const PeriodReport({
    required this.startDay,
    required this.endDay,
    required this.tasks,
    required this.journals,
  });

  /// 区间起始日(含),`YYYY-MM-DD`。
  final String startDay;

  /// 区间结束日(含)。
  final String endDay;

  /// 区间内全部待办,按日期、排序号升序。
  final List<Task> tasks;

  /// 区间内有内容的日记,按日期升序。
  final List<Journal> journals;

  List<Task> get doneTasks => tasks.where((t) => t.done).toList();

  List<Task> get undoneTasks => tasks.where((t) => !t.done).toList();

  int get total => tasks.length;

  int get doneCount => doneTasks.length;

  /// 完成率;计划数为 0 时返回 0(而不是 NaN)。
  double get completionRate => total == 0 ? 0 : doneCount / total;

  /// 有打卡记录的天数。
  int get activeDayCount => tasks.map((t) => t.day).toSet().length;

  /// 按日期分组,供报告逐天列出。
  Map<String, List<Task>> get tasksByDay {
    final grouped = <String, List<Task>>{};
    for (final task in tasks) {
      grouped.putIfAbsent(task.day, () => []).add(task);
    }
    return grouped;
  }
}
