/// 记录存储的读写接口。
///
/// 抽成接口的原因不是"以后可能换数据库",而是为了**测试能把数据层换成内存实现**:
/// 界面测试需要的是"给定这些记录,界面画出什么",不该被真正的 SQLite 拖进来。
library;

import 'goals.dart';
import 'models.dart';
import 'reminder.dart';
import 'palette.dart';

/// 待办、日记、聊天、目标与进度的读写。
abstract class RecordStore {
  // ---------- 待办 ----------

  /// 某天全部待办,按手动排序、再按创建时间。
  Future<List<Task>> tasksOfDay(String day);

  /// 区间内全部待办,`[startDay, endDay]` 两端都含。
  Future<List<Task>> tasksBetween(String startDay, String endDay);

  /// 区间内每天各有几条待办、完成几条(日历页打点用)。
  Future<Map<String, DayCount>> taskCountsByDay(String startDay, String endDay);

  /// 追加一条待办,排在当天末尾。内容为空白时抛 [ArgumentError]。
  Future<int> addTask(String day, String text, {TaskColor? color});

  /// 批量追加(粘贴导入用),保持传入顺序,返回实际写入条数。
  Future<int> addTasks(String day, List<String> texts, {TaskColor? color});

  /// 勾选/取消勾选。[done] 为真时记下完成时刻,为假时清掉。
  Future<void> setTaskDone(int id, bool done);

  /// 改内容。
  Future<void> updateTaskText(int id, String text);

  /// 改配色。
  Future<void> updateTaskColor(int id, TaskColor color);

  /// 标记这件事做得怎么样(做完 / 做了但没做好 / 没评价)。
  Future<void> setTaskOutcome(int id, TaskOutcome outcome);

  /// 改计划日期(把一条待办挪到另一天)。
  Future<void> updateTaskDay(int id, String day);

  /// 删一条。
  Future<void> deleteTask(int id);

  /// 批量删除。
  Future<void> deleteTasks(List<int> ids);

  /// 批量改配色。
  Future<void> updateTasksColor(List<int> ids, TaskColor color);

  /// 按给定顺序重排某天的待办。
  ///
  /// 传的是该天完整的 id 顺序,下标即新的 sort_order。整体覆盖而不是两两交换:
  /// 拖拽会一次挪动多条的相对位置,按最终顺序写一遍最不容易出错。
  Future<void> reorderTasks(String day, List<int> orderedIds);

  /// 把某天没完成的待办顺延到 [targetDay],返回搬运条数。
  Future<int> moveUndoneTasks(String fromDay, String targetDay);

  // ---------- 日记 ----------

  /// 某天的想法/收获,没写返回 null。
  Future<Journal?> journalOfDay(String day);

  /// 区间内所有非空日记,按日期升序。
  Future<List<Journal>> journalsBetween(String startDay, String endDay);

  /// 写入或覆盖某天的想法;写成空白**且没有照片**才等于删除。
  ///
  /// [photoRefs] 传 null 表示"不动已有的照片"——只改文字的场景不该
  /// 顺手把配图抹掉。传空列表才是明确要清空照片。
  Future<void> saveJournal(String day, String text, {List<String>? photoRefs});

  // ---------- 聊天记录 ----------

  /// 全部会话,最近更新的在前。
  Future<List<Conversation>> conversations();

  /// 新建一个空会话,返回它的 id。
  Future<int> createConversation({String title});

  /// 改某个会话的 AI 头像(base64 或空串表示恢复默认)。
  Future<void> setConversationAvatar(int id, String avatar);

  Future<void> renameConversation(int id, String title);

  /// 删除会话及其全部消息。
  Future<void> deleteConversation(int id);

  /// 某个会话的消息,按时间升序。
  Future<List<ChatMessage>> messagesOf(int conversationId, {int limit});

  Future<int> addMessage(
    int conversationId,
    String role,
    String content, {
    String reasoning,
  });

  // ---------- 提醒 ----------

  /// 某天的提醒,按时间升序。
  Future<List<Reminder>> remindersOn(String day);

  /// 区间内的提醒(重排系统通知时用)。
  Future<List<Reminder>> remindersBetween(String startDay, String endDay);

  Future<int> addReminder({
    required int taskId,
    required String day,
    required String at,
    String note,
  });

  Future<void> deleteReminder(int id);

  /// 删掉某条任务的所有提醒(任务被删时调用,避免留下孤儿提醒)。
  Future<void> deleteRemindersOfTask(int taskId);
  /// 把某条任务的提醒挪到另一天(任务被改期时调用)。
  ///
  /// 提醒的日期是独立存的:不一起挪的话,把带提醒的任务改到下周一,
  /// 提醒还会在原来那天响。
  Future<void> moveRemindersOfTask(int taskId, String day);

  // ---------- 目标与进度推进条 ----------

  /// 全部目标(含归档),每个都带现算的当前值。
  Future<List<Goal>> goals();

  /// 新建目标。[target] 可空:不知道要推进到多少时只记推进量。
  Future<int> addGoal({
    required String title,
    String unit,
    double? target,
    required GoalPeriod period,
    required GoalDirection direction,
    required TaskColor color,
    String? startDay,
    String? endDay,
  });

  Future<void> updateGoal(Goal goal);

  /// 归档/恢复目标。归档不动历史条目。
  Future<void> setGoalActive(int id, bool active);

  /// 彻底删除目标及其全部进度条目。
  Future<void> deleteGoal(int id);

  /// 区间内的进度条目,按日期升序。
  Future<List<ProgressEntry>> progressEntriesBetween(String startDay, String endDay);

  /// 某目标的全部条目,按日期倒序(最近的在前面)。
  Future<List<ProgressEntry>> progressEntriesOfGoal(int goalId);

  /// 记一次推进。
  Future<int> addProgress({
    required int goalId,
    required double amount,
    required String day,
    required String note,
    int? taskId,
    String source,
  });

  Future<void> updateProgress(int id, {double? amount, String? note, String? day});

  Future<void> deleteProgress(int id);

  /// 已经推进过进度的待办 id 集合。
  ///
  /// 用来判断"哪些已完成的待办还没同步过",避免同一条被重复计入。
  Future<Set<int>> tasksWithProgress();

  /// 区间内已完成、但**还没被 AI 读过**的待办。
  ///
  /// 判定用 `tasks.synced_at` 而不是"有没有进度记录":像「取快递」这种
  /// 永远匹配不上任何推进条的事,按后者算会永远留在待同步计数里——
  /// 用户整理完、确认完,角标照样挂着,怎么都清不掉。
  Future<List<Task>> unprocessedDoneTasks(String startDay, String endDay);

  /// 把这几条标记成"已经处理过了"。
  ///
  /// 用户在审阅面板点完确认(哪怕一条都没勾)就该调用:没有匹配结果也是一种
  /// 处理结果,它同样要能清掉角标。
  Future<void> markTasksSynced(Iterable<int> taskIds);
}

/// 某一天的待办计数。日历打点只需要这两个数。
class DayCount {
  const DayCount({required this.total, required this.done});

  final int total;
  final int done;

  bool get allDone => total > 0 && done == total;
}

/// 把粘贴进来的一段文本拆成多条待办。
///
/// 从原子笔记搬过来时,行首常带 `☑`、`-`、`1.` 这类标记,这里统一剥掉;
/// 空行丢弃。这是纯函数,便于单测覆盖各种粘贴格式。
List<String> parseTaskLines(String raw) {
  return raw
      .split(RegExp(r'\r?\n'))
      .map(stripTaskMarkers)
      .where((line) => line.isNotEmpty)
      .toList();
}

/// 剥掉行首的项目符号/序号/勾选框,并去掉首尾空白。
///
/// 只剥行首标记,不动正文里的符号——正文里的 `-` 和 `.` 是用户自己的表达。
String stripTaskMarkers(String line) {
  var text = line.trim();
  // 允许两层标记叠加(如 `- [ ] 读书`)。
  final marker = RegExp(
    r'^(?:[-*•·—–]|\[[ xX✓]\]|[\u2610\u2611\u2612\u2713\u2714]|\(?\d+[.)、]|\(?[一二三四五六七八九十]+[.)、])\s*',
  );
  var previous = '';
  while (previous != text) {
    previous = text;
    text = text.replaceFirst(marker, '').trim();
  }
  return text;
}
