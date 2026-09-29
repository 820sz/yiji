import 'package:sqflite/sqflite.dart';

import 'goals.dart';
import 'models.dart';
import 'palette.dart';
import 'reminder.dart';
import 'record_store.dart';

/// [RecordStore] 的 SQLite 实现。安卓上就是这个在用。
class SqliteRecordStore implements RecordStore {
  SqliteRecordStore(this._db);

  final Database _db;

  // ---------- 待办 ----------

  @override
  Future<List<Task>> tasksOfDay(String day) async {
    final rows = await _db.query(
      'tasks',
      where: 'day = ?',
      whereArgs: [day],
      orderBy: 'sort_order ASC, created_at ASC',
    );
    return rows.map(Task.fromMap).toList();
  }

  @override
  Future<List<Task>> tasksBetween(String startDay, String endDay) async {
    final rows = await _db.query(
      'tasks',
      where: 'day >= ? AND day <= ?',
      whereArgs: [startDay, endDay],
      orderBy: 'day ASC, sort_order ASC, created_at ASC',
    );
    return rows.map(Task.fromMap).toList();
  }

  @override
  Future<Map<String, DayCount>> taskCountsByDay(String startDay, String endDay) async {
    // 一天一行,而不是把当天所有待办拉回来再在 Dart 里数:
    // 日历一次要覆盖整月,聚合放在 SQL 里省掉大量来回。
    final rows = await _db.rawQuery(
      'SELECT day, COUNT(*) AS total, SUM(done) AS done FROM tasks '
      'WHERE day >= ? AND day <= ? GROUP BY day',
      [startDay, endDay],
    );
    return {
      for (final row in rows)
        row['day'] as String: DayCount(
          total: (row['total'] as num?)?.toInt() ?? 0,
          done: (row['done'] as num?)?.toInt() ?? 0,
        ),
    };
  }

  @override
  Future<int> addTask(String day, String text, {TaskColor? color}) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) {
      throw ArgumentError.value(text, 'text', '待办内容不能为空');
    }
    return _db.insert(
      'tasks',
      Task.insertMap(
        day: day,
        text: trimmed,
        sortOrder: await _maxSortOrder(day, _db) + 1,
        createdAt: DateTime.now(),
        color: color ?? TaskColor.blue,
      ),
    );
  }

  @override
  Future<int> addTasks(String day, List<String> texts, {TaskColor? color}) async {
    final cleaned = texts.map(stripTaskMarkers).where((t) => t.isNotEmpty).toList();
    if (cleaned.isEmpty) return 0;

    // 全部在一个事务里,避免中途失败留下半批数据。
    await _db.transaction((txn) async {
      var order = await _maxSortOrder(day, txn);
      final createdAt = DateTime.now();
      for (final text in cleaned) {
        order += 1;
        await txn.insert(
          'tasks',
          Task.insertMap(
            day: day,
            text: text,
            sortOrder: order,
            createdAt: createdAt,
            color: color ?? TaskColor.blue,
          ),
        );
      }
    });
    return cleaned.length;
  }

  @override
  Future<void> setTaskDone(int id, bool done) async {
    await _db.update(
      'tasks',
      {
        'done': done ? 1 : 0,
        'completed_at': done ? DateTime.now().millisecondsSinceEpoch : null,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> updateTaskText(int id, String text) async {
    await _db.update('tasks', {'text': text.trim()}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> updateTaskColor(int id, TaskColor color) async {
    await _db.update('tasks', {'color': color.key}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> updateTaskDay(int id, String day) async {
    await _db.update('tasks', {'day': day}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteTask(int id) async {
    // 连带删掉这条任务的提醒:留着孤儿提醒会在通知栏冒出一条"点进去什么都没有"的消息。
    await _db.transaction((txn) async {
      await txn.delete('reminders', where: 'task_id = ?', whereArgs: [id]);
      await txn.delete('tasks', where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<void> deleteTasks(List<int> ids) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.transaction((txn) async {
      await txn.delete('reminders', where: 'task_id IN ($placeholders)', whereArgs: ids);
      await txn.delete('tasks', where: 'id IN ($placeholders)', whereArgs: ids);
    });
  }

  @override
  Future<void> updateTasksColor(List<int> ids, TaskColor color) async {
    if (ids.isEmpty) return;
    final placeholders = List.filled(ids.length, '?').join(',');
    await _db.update(
      'tasks',
      {'color': color.key},
      where: 'id IN ($placeholders)',
      whereArgs: ids,
    );
  }

  @override
  Future<void> reorderTasks(String day, List<int> orderedIds) async {
    if (orderedIds.isEmpty) return;
    // 一次事务里全部写完:中途失败会留下"顺序写了一半"的状态,比不排更糟。
    await _db.transaction((txn) async {
      for (var index = 0; index < orderedIds.length; index++) {
        await txn.update(
          'tasks',
          {'sort_order': index},
          where: 'id = ? AND day = ?',
          whereArgs: [orderedIds[index], day],
        );
      }
    });
  }

  @override
  Future<int> moveUndoneTasks(String fromDay, String targetDay) async {
    final undone = await _db.query(
      'tasks',
      where: 'day = ? AND done = 0',
      whereArgs: [fromDay],
    );
    if (undone.isEmpty) return 0;

    // 是"移动"而非"复制":原日期上不再留下记录,所以周报统计的是最终归属日。
    await _db.transaction((txn) async {
      var order = await _maxSortOrder(targetDay, txn);
      for (final row in undone) {
        order += 1;
        await txn.update(
          'tasks',
          {'day': targetDay, 'sort_order': order},
          where: 'id = ?',
          whereArgs: [row['id']],
        );
      }
    });
    return undone.length;
  }

  // ---------- 日记 ----------

  @override
  Future<Journal?> journalOfDay(String day) async {
    final rows = await _db.query('journals', where: 'day = ?', whereArgs: [day], limit: 1);
    return rows.isEmpty ? null : Journal.fromMap(rows.first);
  }

  @override
  Future<List<Journal>> journalsBetween(String startDay, String endDay) async {
    final rows = await _db.query(
      'journals',
      where: 'day >= ? AND day <= ?',
      whereArgs: [startDay, endDay],
      orderBy: 'day ASC',
    );
    return rows.map(Journal.fromMap).where((j) => !j.isEmpty).toList();
  }

  @override
  Future<void> saveJournal(String day, String text) async {
    if (text.trim().isEmpty) {
      await _db.delete('journals', where: 'day = ?', whereArgs: [day]);
      return;
    }
    await _db.insert(
      'journals',
      Journal.upsertMap(day: day, text: text.trim(), updatedAt: DateTime.now()),
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
  }

  // ---------- 聊天记录 ----------

  @override
  Future<List<Conversation>> conversations() async {
    // 一次查出每个会话的消息数,避免每个会话一条查询。
    final counts = await _db.rawQuery(
      'SELECT conversation_id, COUNT(*) AS n FROM messages GROUP BY conversation_id',
    );
    final byConversation = {
      for (final row in counts)
        (row['conversation_id'] as num).toInt(): (row['n'] as num).toInt(),
    };

    final rows = await _db.query('conversations', orderBy: 'updated_at DESC');
    return rows
        .map(
          (row) => Conversation.fromMap(
            row,
            messageCount: byConversation[row['id'] as int] ?? 0,
          ),
        )
        .toList();
  }

  @override
  Future<int> createConversation({String title = ''}) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    return _db.insert('conversations', {
      'title': title.trim(),
      'created_at': now,
      'updated_at': now,
    });
  }

  @override
  Future<void> renameConversation(int id, String title) async {
    await _db.update(
      'conversations',
      {'title': title.trim()},
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> deleteConversation(int id) async {
    // 消息是会话的从属数据,一起删掉;不留孤儿行。
    await _db.transaction((txn) async {
      await txn.delete('messages', where: 'conversation_id = ?', whereArgs: [id]);
      await txn.delete('conversations', where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<List<ChatMessage>> messagesOf(int conversationId, {int limit = 200}) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'created_at DESC, id DESC',
      limit: limit,
    );
    return rows.map(ChatMessage.fromMap).toList().reversed.toList();
  }

  @override
  Future<int> addMessage(
    int conversationId,
    String role,
    String content, {
    String reasoning = '',
  }) async {
    final id = await _db.insert(
      'messages',
      ChatMessage.insertMap(
        conversationId: conversationId,
        role: role,
        content: content,
        reasoning: reasoning,
        createdAt: DateTime.now(),
      ),
    );
    // 会话的"最近更新"跟着消息走,侧边栏才能按活跃度排序。
    await _db.update(
      'conversations',
      {'updated_at': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [conversationId],
    );
    return id;
  }

  // ---------- 提醒 ----------

  @override
  Future<List<Reminder>> remindersOn(String day) async {
    final rows = await _db.query(
      'reminders',
      where: 'day = ?',
      whereArgs: [day],
      orderBy: 'at ASC',
    );
    return rows.map(Reminder.fromMap).toList();
  }

  @override
  Future<List<Reminder>> remindersBetween(String startDay, String endDay) async {
    final rows = await _db.query(
      'reminders',
      where: 'day >= ? AND day <= ?',
      whereArgs: [startDay, endDay],
      orderBy: 'day ASC, at ASC',
    );
    return rows.map(Reminder.fromMap).toList();
  }

  @override
  Future<int> addReminder({
    required int taskId,
    required String day,
    required String at,
    String note = '',
  }) async {
    return _db.insert(
      'reminders',
      Reminder.insertMap(
        taskId: taskId,
        day: day,
        at: at,
        note: note,
        createdAt: DateTime.now(),
      ),
    );
  }

  @override
  Future<void> deleteReminder(int id) async {
    await _db.delete('reminders', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteRemindersOfTask(int taskId) async {
    await _db.delete('reminders', where: 'task_id = ?', whereArgs: [taskId]);
  }

  // ---------- 目标与进度推进条 ----------

  @override
  Future<List<Goal>> goals() async {
    final goalRows = await _db.query('goals', orderBy: 'created_at ASC');
    if (goalRows.isEmpty) return const [];

    // 一次查出所有目标的进度合计,避免每个目标一条查询。
    final sums = await _db.rawQuery(
      'SELECT goal_id, SUM(amount) AS total FROM progress_entries GROUP BY goal_id',
    );
    final totals = {
      for (final row in sums)
        (row['goal_id'] as num).toInt(): (row['total'] as num?)?.toDouble() ?? 0,
    };

    return goalRows
        .map((row) => Goal.fromMap(row, current: totals[row['id'] as int] ?? 0))
        .toList();
  }

  @override
  Future<int> addGoal({
    required String title,
    String unit = '',
    double? target,
    required GoalPeriod period,
    required GoalDirection direction,
    required TaskColor color,
    String? startDay,
    String? endDay,
  }) async {
    return _db.insert('goals', {
      'title': title.trim(),
      'unit': unit.trim(),
      // 可以是 null:不知道要推进到多少时只记推进量。
      'target': target,
      'period': period.name,
      'direction': direction.name,
      'color': color.key,
      'active': 1,
      'start_day': startDay,
      'end_day': endDay,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> updateGoal(Goal goal) async {
    await _db.update(
      'goals',
      {
        'title': goal.title.trim(),
        'unit': goal.unit.trim(),
        'target': goal.target,
        'period': goal.period.name,
        'direction': goal.direction.name,
        'color': goal.color.key,
        'active': goal.active ? 1 : 0,
        'start_day': goal.startDay,
        'end_day': goal.endDay,
      },
      where: 'id = ?',
      whereArgs: [goal.id],
    );
  }

  @override
  Future<void> setGoalActive(int id, bool active) async {
    await _db.update('goals', {'active': active ? 1 : 0}, where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<void> deleteGoal(int id) async {
    // 条目是目标的从属数据,一起删掉;不留孤儿行。
    await _db.transaction((txn) async {
      await txn.delete('progress_entries', where: 'goal_id = ?', whereArgs: [id]);
      await txn.delete('goals', where: 'id = ?', whereArgs: [id]);
    });
  }

  @override
  Future<List<ProgressEntry>> progressEntriesBetween(String startDay, String endDay) async {
    final rows = await _db.query(
      'progress_entries',
      where: 'day >= ? AND day <= ?',
      whereArgs: [startDay, endDay],
      orderBy: 'day ASC, created_at ASC',
    );
    return rows.map(ProgressEntry.fromMap).toList();
  }

  @override
  Future<List<ProgressEntry>> progressEntriesOfGoal(int goalId) async {
    final rows = await _db.query(
      'progress_entries',
      where: 'goal_id = ?',
      whereArgs: [goalId],
      orderBy: 'day DESC, created_at DESC',
    );
    return rows.map(ProgressEntry.fromMap).toList();
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
    return _db.insert('progress_entries', {
      'goal_id': goalId,
      'amount': amount,
      'day': day,
      'note': note.trim(),
      'task_id': taskId,
      'source': source,
      'created_at': DateTime.now().millisecondsSinceEpoch,
    });
  }

  @override
  Future<void> updateProgress(int id, {double? amount, String? note, String? day}) async {
    await _db.update(
      'progress_entries',
      {
        'amount': ?amount,
        if (note != null) 'note': note.trim(),
        'day': ?day,
      },
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  @override
  Future<void> deleteProgress(int id) async {
    await _db.delete('progress_entries', where: 'id = ?', whereArgs: [id]);
  }

  @override
  Future<Set<int>> tasksWithProgress() async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT task_id FROM progress_entries WHERE task_id IS NOT NULL',
    );
    return rows.map((row) => (row['task_id'] as num).toInt()).toSet();
  }

  @override
  Future<List<Task>> unprocessedDoneTasks(String startDay, String endDay) async {
    final rows = await _db.rawQuery(
      'SELECT t.* FROM tasks t '
      'WHERE t.day >= ? AND t.day <= ? AND t.done = 1 '
      'AND NOT EXISTS (SELECT 1 FROM progress_entries p WHERE p.task_id = t.id) '
      'ORDER BY t.day ASC',
      [startDay, endDay],
    );
    return rows.map(Task.fromMap).toList();
  }

  static Future<int> _maxSortOrder(String day, DatabaseExecutor exec) async {
    final result = await exec.rawQuery(
      'SELECT MAX(sort_order) AS m FROM tasks WHERE day = ?',
      [day],
    );
    return (result.first['m'] as int?) ?? 0;
  }
}
