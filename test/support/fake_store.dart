import 'package:yiji/data/goals.dart';
import 'package:yiji/data/models.dart';
import 'package:yiji/data/palette.dart';
import 'package:yiji/data/record_store.dart';

/// 内存版存储,只给测试用。
///
/// 界面测试要验证的是"给定这些记录,界面画出什么、点了之后变成什么",
/// 用内存实现就够了,也不必在 app 包里引入桌面版 SQLite。
/// SQL 本身的行为由 `tool/sqltest` 那个独立包负责验。
class FakeStore implements RecordStore {
  final List<Task> _tasks = [];
  final Map<String, String> _journals = {};
  final List<ChatMessage> _messages = [];
  final List<Goal> _goals = [];
  final List<ProgressEntry> _entries = [];

  int _nextId = 1;

  /// 直接塞一条已存在的待办(搭建测试场景用)。
  Task seedTask(
    String day,
    String text, {
    bool done = false,
    int? id,
    TaskColor color = TaskColor.blue,
  }) {
    final taskId = id ?? _nextId++;
    final task = Task(
      id: taskId,
      day: day,
      text: text,
      done: done,
      sortOrder: taskId,
      createdAt: DateTime(2026, 9, 14, 8, 0),
      completedAt: done ? DateTime(2026, 9, 14, 20, 0) : null,
      color: color,
    );
    _tasks.add(task);
    return task;
  }

  void seedJournal(String day, String text) => _journals[day] = text;

  /// 直接塞一个目标和它的进度(搭测试场景用)。
  Goal seedGoal({
    required String title,
    String unit = '字',
    double target = 10000,
    double current = 0,
    GoalPeriod period = GoalPeriod.weekly,
    GoalDirection direction = GoalDirection.increase,
    bool active = true,
    TaskColor color = TaskColor.blue,
  }) {
    final id = _nextId++;
    if (current != 0) {
      _entries.add(
        ProgressEntry(
          id: _nextId++,
          goalId: id,
          amount: current,
          day: '2026-09-14',
          note: '初始',
          taskId: null,
          source: 'manual',
          createdAt: DateTime(2026, 9, 14, 9, 0),
        ),
      );
    }
    final goal = Goal(
      id: id,
      title: title,
      unit: unit,
      target: target,
      current: current,
      period: period,
      direction: direction,
      color: color,
      active: active,
      createdAt: DateTime(2026, 9, 14, 9, 0),
    );
    _goals.add(goal);
    return goal;
  }

  double _totalOf(int goalId) =>
      _entries.where((e) => e.goalId == goalId).fold(0.0, (sum, e) => sum + e.amount);

  @override
  Future<List<Task>> tasksOfDay(String day) async {
    return _tasks.where((t) => t.day == day).toList()
      ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
  }

  @override
  Future<List<Task>> tasksBetween(String startDay, String endDay) async {
    return _tasks
        .where((t) => t.day.compareTo(startDay) >= 0 && t.day.compareTo(endDay) <= 0)
        .toList()
      ..sort((a, b) {
        final byDay = a.day.compareTo(b.day);
        return byDay != 0 ? byDay : a.sortOrder.compareTo(b.sortOrder);
      });
  }

  @override
  Future<Map<String, DayCount>> taskCountsByDay(String startDay, String endDay) async {
    final inRange = _tasks.where(
      (t) => t.day.compareTo(startDay) >= 0 && t.day.compareTo(endDay) <= 0,
    );
    final grouped = <String, List<Task>>{};
    for (final task in inRange) {
      grouped.putIfAbsent(task.day, () => []).add(task);
    }
    return {
      for (final entry in grouped.entries)
        entry.key: DayCount(
          total: entry.value.length,
          done: entry.value.where((t) => t.done).length,
        ),
    };
  }

  @override
  Future<int> addTask(String day, String text, {TaskColor? color}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', '待办内容不能为空');
    }
    return seedTask(day, trimmed, color: color ?? TaskColor.blue).id;
  }

  @override
  Future<int> addTasks(String day, List<String> texts, {TaskColor? color}) async {
    final cleaned = texts.map(stripTaskMarkers).where((t) => t.isNotEmpty).toList();
    for (final text in cleaned) {
      seedTask(day, text, color: color ?? TaskColor.blue);
    }
    return cleaned.length;
  }

  @override
  Future<void> setTaskDone(int id, bool done) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index < 0) return;
    _tasks[index] = _tasks[index].copyWith(
      done: done,
      completedAt: done ? DateTime(2026, 9, 14, 21, 0) : null,
    );
  }

  @override
  Future<void> updateTaskText(int id, String text) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index < 0) return;
    _tasks[index] = _tasks[index].copyWith(text: text.trim());
  }

  @override
  Future<void> updateTaskColor(int id, TaskColor color) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index < 0) return;
    _tasks[index] = _tasks[index].copyWith(color: color);
  }

  @override
  Future<void> reorderTasks(String day, List<int> orderedIds) async {
    for (var order = 0; order < orderedIds.length; order++) {
      final index = _tasks.indexWhere(
        (t) => t.id == orderedIds[order] && t.day == day,
      );
      if (index < 0) continue;
      final old = _tasks[index];
      _tasks[index] = Task(
        id: old.id,
        day: old.day,
        text: old.text,
        done: old.done,
        sortOrder: order,
        createdAt: old.createdAt,
        completedAt: old.completedAt,
        color: old.color,
      );
    }
  }

  @override
  Future<void> updateTaskDay(int id, String day) async {
    final index = _tasks.indexWhere((t) => t.id == id);
    if (index < 0) return;
    final old = _tasks[index];
    _tasks[index] = Task(
      id: old.id,
      day: day,
      text: old.text,
      done: old.done,
      sortOrder: old.sortOrder,
      createdAt: old.createdAt,
      completedAt: old.completedAt,
      color: old.color,
    );
  }

  @override
  Future<void> deleteTask(int id) async {
    _tasks.removeWhere((t) => t.id == id);
  }

  @override
  Future<void> deleteTasks(List<int> ids) async {
    _tasks.removeWhere((t) => ids.contains(t.id));
  }

  @override
  Future<void> updateTasksColor(List<int> ids, TaskColor color) async {
    for (final id in ids) {
      await updateTaskColor(id, color);
    }
  }

  @override
  Future<int> moveUndoneTasks(String fromDay, String targetDay) async {
    final undone = _tasks.where((t) => t.day == fromDay && !t.done).toList();
    for (final task in undone) {
      final index = _tasks.indexWhere((t) => t.id == task.id);
      _tasks[index] = Task(
        id: task.id,
        day: targetDay,
        text: task.text,
        done: false,
        sortOrder: task.sortOrder + 1000,
        createdAt: task.createdAt,
        color: task.color,
      );
    }
    return undone.length;
  }

  @override
  Future<Journal?> journalOfDay(String day) async {
    final text = _journals[day];
    return text == null
        ? null
        : Journal(day: day, text: text, updatedAt: DateTime(2026, 9, 14, 22, 0));
  }

  @override
  Future<List<Journal>> journalsBetween(String startDay, String endDay) async {
    final days = _journals.keys
        .where((d) => d.compareTo(startDay) >= 0 && d.compareTo(endDay) <= 0)
        .toList()
      ..sort();
    return days
        .map((d) => Journal(day: d, text: _journals[d]!, updatedAt: DateTime(2026, 9, 14)))
        .toList();
  }

  @override
  Future<void> saveJournal(String day, String text) async {
    if (text.trim().isEmpty) {
      _journals.remove(day);
    } else {
      _journals[day] = text.trim();
    }
  }

  @override
  Future<List<ChatMessage>> recentMessages({int limit = 200}) async {
    final tail =
        _messages.length > limit ? _messages.sublist(_messages.length - limit) : _messages;
    return List.of(tail);
  }

  @override
  Future<int> addMessage(String role, String content, {String reasoning = ''}) async {
    final id = _nextId++;
    _messages.add(
      ChatMessage(
        id: id,
        role: role,
        content: content,
        reasoning: reasoning,
        createdAt: DateTime(2026, 9, 14, 22, 0).add(Duration(seconds: id)),
      ),
    );
    return id;
  }

  @override
  Future<void> clearMessages() async => _messages.clear();

  @override
  Future<List<Goal>> goals() async {
    return [for (final goal in _goals) goal.copyWithCurrent(_totalOf(goal.id))];
  }

  @override
  Future<int> addGoal({
    required String title,
    required String unit,
    required double target,
    required GoalPeriod period,
    required GoalDirection direction,
    required TaskColor color,
    String? startDay,
    String? endDay,
  }) async {
    final id = _nextId++;
    _goals.add(
      Goal(
        id: id,
        title: title,
        unit: unit,
        target: target,
        current: 0,
        period: period,
        direction: direction,
        color: color,
        active: true,
        createdAt: DateTime(2026, 9, 14, 9, 0),
        startDay: startDay,
        endDay: endDay,
      ),
    );
    return id;
  }

  @override
  Future<void> updateGoal(Goal goal) async {
    final index = _goals.indexWhere((g) => g.id == goal.id);
    if (index < 0) return;
    _goals[index] = goal;
  }

  @override
  Future<void> setGoalActive(int id, bool active) async {
    final index = _goals.indexWhere((g) => g.id == id);
    if (index < 0) return;
    _goals[index] = _goals[index].copyWith(active: active);
  }

  @override
  Future<void> deleteGoal(int id) async {
    _goals.removeWhere((g) => g.id == id);
    _entries.removeWhere((e) => e.goalId == id);
  }

  @override
  Future<List<ProgressEntry>> progressEntriesBetween(String startDay, String endDay) async {
    return _entries
        .where((e) => e.day.compareTo(startDay) >= 0 && e.day.compareTo(endDay) <= 0)
        .toList();
  }

  @override
  Future<List<ProgressEntry>> progressEntriesOfGoal(int goalId) async {
    return _entries.where((e) => e.goalId == goalId).toList().reversed.toList();
  }

  @override
  Future<int> addProgress({
    required int goalId,
    required double amount,
    required String day,
    required String note,
    int? taskId,
    String source = 'manual',
  }) async {
    final id = _nextId++;
    _entries.add(
      ProgressEntry(
        id: id,
        goalId: goalId,
        amount: amount,
        day: day,
        note: note,
        taskId: taskId,
        source: source,
        createdAt: DateTime(2026, 9, 14, 23, 0),
      ),
    );
    return id;
  }

  @override
  Future<void> updateProgress(int id, {double? amount, String? note, String? day}) async {
    final index = _entries.indexWhere((e) => e.id == id);
    if (index < 0) return;
    final old = _entries[index];
    _entries[index] = ProgressEntry(
      id: old.id,
      goalId: old.goalId,
      amount: amount ?? old.amount,
      day: day ?? old.day,
      note: note ?? old.note,
      taskId: old.taskId,
      source: old.source,
      createdAt: old.createdAt,
    );
  }

  @override
  Future<void> deleteProgress(int id) async {
    _entries.removeWhere((e) => e.id == id);
  }

  @override
  Future<Set<int>> tasksWithProgress() async {
    return _entries.where((e) => e.taskId != null).map((e) => e.taskId!).toSet();
  }

  @override
  Future<List<Task>> unprocessedDoneTasks(String startDay, String endDay) async {
    final processed = await tasksWithProgress();
    return _tasks
        .where(
          (t) =>
              t.done &&
              !processed.contains(t.id) &&
              t.day.compareTo(startDay) >= 0 &&
              t.day.compareTo(endDay) <= 0,
        )
        .toList();
  }
}
