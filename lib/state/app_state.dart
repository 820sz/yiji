/// 参数用公开名、字段用私有名,所以构造处无法写成 initializing formal。
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../ai/ai_client.dart';
import '../ai/goal_matcher.dart';
import '../ai/prompts.dart';
import '../ai/settings_store.dart';
import '../core/day.dart';
import '../data/database.dart';
import '../data/chat_attachment.dart';
import '../data/chat_images.dart';
import '../data/meme_directive.dart';
import '../data/data_range.dart';
import '../data/goals.dart';
import '../data/models.dart';
import '../data/palette.dart';
import '../data/record_store.dart';
import '../data/reminder.dart';
import '../data/reminder_notifier.dart';
import '../ui/image_cropper.dart';
import '../data/report_service.dart';
import '../data/sqlite_record_store.dart';
import '../update/apk_installer.dart';
import '../update/app_updater.dart';

/// 全应用的状态与业务动作。
///
/// 界面只读这里的字段、调这里的方法,不直接碰数据库——
/// 这样"写库之后谁要刷新"这件事只有一处需要维护。
///
/// 规模说明:这个 app 的界面状态总量很小,所以用 `ChangeNotifier` 手写,
/// 不引状态管理库。
class AppState extends ChangeNotifier {
  /// 依赖全部注入,所以测试可以塞内存库和假的 AI 客户端进来。
  AppState({
    required RecordStore store,
    required ReportService reports,
    required SettingsStore settings,
    AiClient? aiClient,
    AppUpdater? updater,
    ApkInstaller installer = const ApkInstaller(),
    ReminderNotifier? notifier,
  })  : _store = store,
        _reports = reports,
        _settings = settings,
        _ai = aiClient ?? AiClient(),
        _updater = updater ?? AppUpdater(),
        _installer = installer,
        _matcher = GoalMatcher(aiClient ?? AiClient()),
        _notifier = notifier ?? ReminderNotifier();

  final RecordStore _store;
  final ReportService _reports;
  final SettingsStore _settings;
  final AiClient _ai;
  final AppUpdater _updater;
  final ApkInstaller _installer;
  final GoalMatcher _matcher;
  final ReminderNotifier _notifier;

  // ---------- 今天页 ----------

  /// 正在查看的日期(`YYYY-MM-DD`)。今天页和报告页共用。
  String _currentDay = todayKey();
  String get currentDay => _currentDay;

  List<Task> _dayTasks = const [];
  List<Task> get dayTasks => _dayTasks;

  Journal? _dayJournal;
  Journal? get dayJournal => _dayJournal;

  bool _loading = true;
  bool get loading => _loading;

  /// 多选模式下被选中的待办 id。
  final Set<int> _selected = {};
  Set<int> get selected => _selected;

  bool get selecting => _selected.isNotEmpty;

  // ---------- 目标与进度 ----------

  List<Goal> _goals = const [];
  List<Goal> get goals => _goals;

  List<Goal> get activeGoals => _goals.where((g) => g.active).toList();

  /// 已完成但还没同步进度的待办条数(进度页的角标)。
  int _pendingSyncCount = 0;
  int get pendingSyncCount => _pendingSyncCount;

  /// 上一次 AI 匹配给出的建议,等用户确认。
  List<ProgressSuggestion> _suggestions = const [];
  List<ProgressSuggestion> get suggestions => _suggestions;

  /// AI 建议新建的目标(做完的事里有一些还没被任何推进条覆盖)。
  List<NewGoalSuggestion> _newGoalSuggestions = const [];
  List<NewGoalSuggestion> get newGoalSuggestions => _newGoalSuggestions;

  bool _matching = false;
  bool get matching => _matching;

  /// 正在自动同步(打钩之后后台跑的那次)。
  bool _autoSyncing = false;

  // ---------- 日历 ----------

  /// 日历当前显示的月份(该月任意一天即可)。
  String _calendarMonth = todayKey();
  String get calendarMonth => _calendarMonth;

  Map<String, DayCount> _monthCounts = const {};
  Map<String, DayCount> get monthCounts => _monthCounts;

  // ---------- 聊天 ----------

  List<ChatMessage> _chat = const [];
  List<ChatMessage> get chat => _chat;

  /// 正在流式接收的思考过程与回答(收完才落库)。
  String _streamingReasoning = '';
  String get streamingReasoning => _streamingReasoning;

  String _streamingAnswer = '';
  String get streamingAnswer => _streamingAnswer;

  /// 流式回答里"能给用户看"的那部分。
  ///
  /// 模型要表情包时会写一行 `[表情: 情绪 | 描述]`,那是给系统的指令,
  /// 不该出现在气泡里。流式是一段一段到的,这一行可能刚收到半个,
  /// 所以渲染时裁:遇到未闭合的标记就把标记之后的部分藏起来,
  /// 等它收完整了再连同标记一起去掉。
  String get visibleStreamingAnswer => stripMemeDirective(_streamingAnswer).text;

  /// 流式内容的变更通知。
  ///
  /// 单独一个 notifier,而不是每收一个字就 [notifyListeners]:
  /// 后者会把整个聊天页(消息列表、输入框、头部)每帧重建一遍,
  /// 长回答下就是持续抖动。只让那一块正在长的气泡监听这个,其余部分不动。
  final ValueNotifier<int> streamTick = ValueNotifier<int>(0);

  /// 正在生成的这次回答属于哪个会话。落库时用它,而不是当前选中的会话。
  int _streamingConversationId = 0;

  bool get streaming => _streamingAnswer.isNotEmpty || _streamingReasoning.isNotEmpty;

  // ---------- 设置 ----------

  AiConfig get aiConfig => _settings.aiConfig;
  String get displayName => _settings.displayName;
  Uint8List? get avatarBytes => _settings.avatarBytes;
  bool get darkMode => _settings.darkMode;

  /// 用户自己的头像(AI 头像旁边那侧)。
  Uint8List? get userAvatarBytes => _settings.userAvatarBytes;

  /// 身份卡片的自定义背景。
  Uint8List? get cardBackgroundBytes => _settings.cardBackgroundBytes;

  /// 个性签名。
  String get bio => _settings.bio;

  /// 身份卡片上显示的 ID。没设过名字时不显示空白,给一个中性称呼。
  String get identityLabel {
    final name = _settings.displayName.trim();
    return name.isEmpty ? '我' : name;
  }

  /// 开屏那句话。
  String get splashText => _settings.splashText;

  /// 报告草稿:AI 生成后缓存在这里,导出优先用它。
  String _weekDraft = '';
  String get weekDraft => _weekDraft;

  /// 首次进页面时把要用的数据读出来。
  Future<void> bootstrap() async {
    await _loadDay();
    // 待同步角标要在启动时就算出来。以前它只在增删改之后刷新,
    // 于是**打开 app 时那个数字永远是 0**,直到用户碰一下任务才出现。
    await _refreshPendingSync();
    // 必须走 loadConversations 而不是 _loadChat:前者会把会话列表也读出来,
    // 并挑一个有效的当前会话。只读消息的话,重开 app 后侧边栏是空的、
    // 历史对话也像是丢了。
    await loadConversations();
    await refreshGoals();
    await loadCalendarMonth(_calendarMonth);
    // 系统重启或用户清理后定时通知会消失,启动时重排一次。
    // 失败不影响别的功能(notifier 内部已经把异常吞掉了)。
    unawaited(syncReminders());
    unawaited(_checkUpdateQuietly());
  }

  // ---------- 更新 ----------

  /// 当前安装的 versionCode,用于判断有没有新版本。
  int _versionCode = 0;
  int get versionCode => _versionCode;

  /// 当前版本号,「我的」页显示用。
  String _versionName = '';
  String get versionName => _versionName;

  /// 查到的新版本;null 表示已是最新(或还没查过)。
  UpdateInfo? _availableUpdate;
  UpdateInfo? get availableUpdate => _availableUpdate;

  /// 正在检查或下载。
  bool _updating = false;
  bool get updating => _updating;

  /// 下载进度 0..1。
  double _updateProgress = 0;
  double get updateProgress => _updateProgress;

  /// 已下载 / 总大小(字节)。总大小未知时为 0。
  ///
  /// 百分比会被 Content-Length 缺失或网络卡顿骗到,字节数是用户能自己
  /// 判断"还在动没有"的证据,所以两个都往界面上送。
  int _updateReceived = 0;
  int _updateTotal = 0;
  int get updateReceived => _updateReceived;
  int get updateTotal => _updateTotal;

  /// 启动时静默查一次。
  ///
  /// 失败就什么都不做:检查更新不该在开机时弹网络错误打断用户。
  Future<void> _checkUpdateQuietly() async {
    try {
      await refreshVersion();
      await checkForUpdate();
    } on Exception {
      // 静默:离线、GitHub 挂了、还没有 release,都不值得打扰用户。
    }
  }

  /// 读出当前安装包的版本信息。
  Future<void> refreshVersion() async {
    final info = await PackageInfo.fromPlatform();
    _versionName = info.version;
    _versionCode = int.tryParse(info.buildNumber) ?? 0;
    notifyListeners();
  }

  /// 查有没有新版本。返回新版本;null 表示已是最新。
  Future<UpdateInfo?> checkForUpdate() async {
    if (_versionCode == 0) await refreshVersion();
    _updating = true;
    notifyListeners();
    try {
      _availableUpdate = await _updater.checkForUpdate(currentVersionCode: _versionCode);
      return _availableUpdate;
    } finally {
      _updating = false;
      notifyListeners();
    }
  }

  /// 下载并交给系统安装。
  Future<void> installUpdate() async {
    final info = _availableUpdate;
    if (info == null) return;

    _updating = true;
    _updateProgress = 0;
    _updateReceived = 0;
    _updateTotal = info.sizeBytes;
    notifyListeners();
    try {
      await _installer.downloadAndInstall(
        _updater,
        info,
        onProgress: (value) {
          _updateProgress = value;
          notifyListeners();
        },
        onBytes: (received, total) {
          _updateReceived = received;
          if (total > 0) _updateTotal = total;
          notifyListeners();
        },
      );
    } finally {
      _updating = false;
      notifyListeners();
    }
  }

  void dismissUpdate() {
    _availableUpdate = null;
    notifyListeners();
  }

  // ---------- 今天页 ----------

  /// 切换查看的日期,并重新加载该天数据。
  Future<void> goToDay(String day) async {
    _currentDay = day;
    _weekDraft = '';
    _clearSelection();
    await _loadDay();
    // 待同步计数是"当前这一周"的,换天可能跨周,必须跟着重算。
    // 以前只在增删改之后刷新,于是切到另一周时角标还是上一周的数字。
    await _refreshPendingSync();
  }

  Future<void> shiftDay(int delta) => goToDay(addDays(_currentDay, delta));

  /// 回到今天。
  Future<void> goToToday() => goToDay(todayKey());

  Future<void> _loadDay() async {
    _loading = true;
    notifyListeners();
    try {
      _dayTasks = await _store.tasksOfDay(_currentDay);
      _dayJournal = await _store.journalOfDay(_currentDay);
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> addTask(String text, {TaskColor? color}) async {
    if (text.trim().isEmpty) return;
    _justAddedId = await _store.addTask(_currentDay, text, color: color);
    await _loadDay();
    await _refreshPendingSync();
  }

  /// 刚加进来的那条待办的 id,只用于给它一次入场动画。
  int? _justAddedId;
  int? get justAddedId => _justAddedId;

  /// 动画放完就清掉,避免重建时又滑一次。
  void clearJustAdded() {
    if (_justAddedId == null) return;
    _justAddedId = null;
  }

  /// 粘贴导入,返回实际加了几条(0 表示粘贴内容里没有有效行)。
  Future<int> addTasksFromPaste(String raw) async {
    final added = await _store.addTasks(_currentDay, parseTaskLines(raw));
    if (added > 0) await _loadDay();
    return added;
  }

  Future<void> toggleTask(Task task) async {
    final nowDone = !task.done;
    await _store.setTaskDone(task.id, nowDone);
    await _loadDay();
    await _refreshPendingSync();
    // 刚打完钩就顺手让 AI 量化一次,用户不用记得去点同步按钮。
    if (nowDone) unawaited(_autoSyncProgress());
  }

  /// 标记"这件事做得怎么样"。
  ///
  /// 只有"做了但没做好"需要用户主动标:周报的"不足"那一栏要读它,
  /// 但那是**用户的判断**,不能让 AI 去猜。
  Future<void> setTaskOutcome(Task task, TaskOutcome outcome) async {
    await _store.setTaskOutcome(task.id, outcome);
    await _loadDay();
  }

  /// 同上,但用在"正在看别的某一天"的场景(日历)。
  Future<void> setTaskOutcomeOn(
    String day,
    Task task,
    TaskOutcome outcome,
  ) async {
    await _store.setTaskOutcome(task.id, outcome);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
  }

  Future<void> editTask(Task task, String text) async {
    if (text.trim().isEmpty) {
      await _store.deleteTask(task.id);
    } else {
      await _store.updateTaskText(task.id, text);
    }
    await _loadDay();
  }

  Future<void> deleteTask(Task task) async {
    await _store.deleteTask(task.id);
    await _loadDay();
    // 任务没了,它排出去的系统通知也要跟着撤掉。不撤的话手机还会到点弹一条
    // 指向已删除任务的通知,点进去什么都没有。
    unawaited(syncReminders());
  }

  /// 把刚删掉的一条加回来(右滑删除的"撤回")。
  ///
  /// 撤回是**重建**一条同内容的任务,而不是把原来的行恢复:主键会变,
  /// 挂在它上面的进度条目和提醒不会自动跟回来。所以这里会明确说清楚
  /// "内容回来了,但提醒要重设",不要假装什么都没发生。
  Future<void> restoreTask(Task task) async {
    await _store.addTask(task.day, task.text, color: task.color);
    if (task.done) {
      final restored = (await _store.tasksOfDay(task.day))
          .where((t) => t.text == task.text)
          .lastOrNull;
      if (restored != null) await _store.setTaskDone(restored.id, true);
    }
    await _loadDay();
    await loadCalendarMonth(_calendarMonth);
  }

  /// 把某条待办挪到另一天。
  ///
  /// 提醒的日期是独立存的,挪日子时必须一起挪——否则提醒还留在原来那天响。
  Future<void> moveTask(Task task, String day) async {
    await _store.updateTaskDay(task.id, day);
    await _store.moveRemindersOfTask(task.id, day);
    await _loadDay();
    await loadCalendarMonth(_calendarMonth);
    unawaited(syncReminders());
  }

  Future<void> saveJournal(String text) async {
    await _store.saveJournal(_currentDay, text);
    await _loadDay();
  }

  /// 把今天没完成的顺延到明天。
  Future<int> carryOverUndone() async {
    final moved = await _store.moveUndoneTasks(_currentDay, addDays(_currentDay, 1));
    if (moved > 0) await _loadDay();
    return moved;
  }

  // ---------- 多选 ----------

  void toggleSelection(int taskId) {
    if (!_selected.remove(taskId)) _selected.add(taskId);
    notifyListeners();
  }

  void _clearSelection() => _selected.clear();

  void clearSelection() {
    _clearSelection();
    notifyListeners();
  }

  /// 批量改配色。
  Future<void> setSelectedColor(TaskColor color) async {
    await _store.updateTasksColor(_selected.toList(), color);
    _clearSelection();
    await _loadDay();
  }

  /// 批量删除。
  Future<void> deleteSelected() async {
    await _store.deleteTasks(_selected.toList());
    _clearSelection();
    await _loadDay();
    await _refreshPendingSync();
    unawaited(syncReminders());
  }

  /// 按拖拽后的顺序落库。
  Future<void> reorderTasks(List<int> orderedIds) async {
    await _store.reorderTasks(_currentDay, orderedIds);
    await _loadDay();
  }

  // ---------- 日历 ----------

  /// 载入某个月的每日计数(用于打点与"全部完成"标记)。
  Future<void> loadCalendarMonth(String monthAnchor) async {
    _calendarMonth = monthAnchor;
    _monthCounts = await _store.taskCountsByDay(
      firstDayOfMonth(monthAnchor),
      lastDayOfMonth(monthAnchor),
    );
    notifyListeners();
  }

  Future<void> shiftCalendarMonth(int delta) {
    final date = parseDayKey(_calendarMonth);
    return loadCalendarMonth(dayKey(DateTime(date.year, date.month + delta, 1)));
  }

  /// 日历里某个日期上的待办(点开弹层时用)。
  Future<List<Task>> tasksOn(String day) => _store.tasksOfDay(day);

  /// 在指定日期上加一条待办(用于提前规划未来)。
  /// 往指定的某一天加一条任务。返回新任务的 id(设提醒时要拿它挂上去)。
  Future<int> addTaskOn(String day, String text, {TaskColor? color}) async {
    if (text.trim().isEmpty) return 0;
    final id = await _store.addTask(day, text, color: color);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
    return id;
  }

  Future<void> toggleTaskOn(String day, Task task) async {
    final nowDone = !task.done;
    await _store.setTaskDone(task.id, nowDone);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
    await _refreshPendingSync();
    if (nowDone) unawaited(_autoSyncProgress());
  }

  Future<void> deleteTaskOn(String day, Task task) async {
    await _store.deleteTask(task.id);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
    unawaited(syncReminders());
  }

  Future<void> setTaskColorOn(String day, Task task, TaskColor color) async {
    await _store.updateTaskColor(task.id, color);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
  }

  /// 覆盖某条待办的内容/颜色/完成状态(编辑页整条提交时用)。
  Future<void> updateTaskOn(String day, Task task) async {
    await _store.updateTaskText(task.id, task.text);
    await _store.updateTaskColor(task.id, task.color);
    await _store.setTaskDone(task.id, task.done);
    await _store.setTaskOutcome(task.id, task.outcome);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
    await _refreshPendingSync();
  }

  /// 把某条待办从 [fromDay] 挪到 [targetDay]。
  Future<void> moveTaskOn(String fromDay, Task task, String targetDay) async {
    await _store.updateTaskDay(task.id, targetDay);
    await loadCalendarMonth(_calendarMonth);
    if (fromDay == _currentDay || targetDay == _currentDay) await _loadDay();
  }

  // ---------- 目标与进度 ----------

  Future<void> refreshGoals() async {
    // 目标的"当前值"只算**本周期内**的推进量。
    //
    // 以前是把所有历史条目加起来,于是"每周跑3次"累积到 20 次之后
    // 进度条永远满着、再练也不动;"每周"这个周期形同不存在。
    // 现在每个目标按它自己的周期取区间:周目标看本周,月目标看本月,
    // 自定义目标看它自己设的起止日期。
    final today = todayKey();
    final goals = await _store.goals();

    final totals = <int, double>{};
    for (final goal in goals) {
      final (start, end) = _periodRangeOf(goal, today);
      final entries = await _store.progressEntriesBetween(start, end);
      totals[goal.id] = entries
          .where((entry) => entry.goalId == goal.id)
          .fold(0.0, (sum, entry) => sum + entry.amount);
    }

    _goals = [
      for (final goal in goals) goal.copyWithCurrent(totals[goal.id] ?? 0),
    ];
    await _refreshPendingSync();
    notifyListeners();
  }

  /// 某个目标在当前时刻对应的统计区间(含首尾)。
  static (String, String) _periodRangeOf(Goal goal, String today) {
    switch (goal.period) {
      case GoalPeriod.weekly:
        return (mondayOf(today), sundayOf(today));
      case GoalPeriod.monthly:
        return (firstDayOfMonth(today), lastDayOfMonth(today));
      case GoalPeriod.custom:
        final start = goal.startDay ?? addDays(today, -29);
        final end = goal.endDay ?? today;
        // 区间整个已经过去时退回"最近 30 天",否则它会永远显示 0。
        if (end.compareTo(today) < 0) return (addDays(today, -29), today);
        return (start, end);
    }
  }

  Future<void> _refreshPendingSync() async {
    // 用"这一周"作为同步窗口:进度条是周/月尺度的,没必要回扫全部历史。
    _pendingSyncCount =
        (await _store.unprocessedDoneTasks(mondayOf(_currentDay), sundayOf(_currentDay)))
            .length;
    notifyListeners();
  }

  Future<void> createGoal({
    required String title,
    String unit = '',
    double? target,
    required GoalPeriod period,
    required GoalDirection direction,
    required TaskColor color,
    String? startDay,
    String? endDay,
  }) async {
    await _store.addGoal(
      title: title,
      unit: unit,
      target: target,
      period: period,
      direction: direction,
      color: color,
      startDay: startDay,
      endDay: endDay,
    );
    await refreshGoals();
  }

  Future<void> updateGoal(Goal goal) async {
    await _store.updateGoal(goal);
    await refreshGoals();
  }

  Future<void> archiveGoal(Goal goal) async {
    await _store.setGoalActive(goal.id, !goal.active);
    await refreshGoals();
  }

  Future<void> deleteGoal(Goal goal) async {
    await _store.deleteGoal(goal.id);
    await refreshGoals();
  }

  /// 把一句自然语言拆成目标字段。
  ///
  /// 只做解析、不落库:结果填回表单,用户看着改,确认后才建。
  /// 返回 null 表示模型没看懂(而不是"建了个空目标")。
  Future<GoalDraft?> parseGoal(String description) async {
    final raw = await _ai.complete(
      config: aiConfig.copyWith(thinking: ThinkingLevel.off),
      jsonMode: true,
      history: [
        AiMessage.system(
          goalParsePrompt(),
        ),
        AiMessage.user(description),
      ],
    );
    return GoalDraft.parse(raw);
  }

  /// 手动加一次进度。
  Future<void> addProgress(Goal goal, double amount, String note) async {
    await _store.addProgress(
      goalId: goal.id,
      amount: amount,
      day: _currentDay,
      note: note,
    );
    await refreshGoals();
  }

  Future<void> updateProgressEntry(
    int id, {
    double? amount,
    String? note,
  }) async {
    await _store.updateProgress(id, amount: amount, note: note);
    await refreshGoals();
  }

  Future<void> deleteProgressEntry(int id) async {
    await _store.deleteProgress(id);
    await refreshGoals();
  }
  Future<List<ProgressEntry>> progressHistory(Goal goal) =>
      _store.progressEntriesOfGoal(goal.id);

  /// 让 AI 读本周已完成的待办,给出进度推进建议。
  ///
  /// 只出建议、不落库:确认这一步留给用户,见 [confirmSuggestions]。
  /// 除了"匹配到已有推进条",还会带回"建议新建目标"那一类——用户常常是
  /// 先做事、后想起来要追踪,让他自己去建等于把 AI 该干的活推回给他。
  Future<int> requestProgressSuggestions() async {
    if (!aiConfig.isUsable) {
      throw AiException('还没填 API key,去设置里填一下');
    }
    // 一条目标都没有时也要问:那正是"要不要建第一条"的时机,不能提前返回。

    _matching = true;
    notifyListeners();
    try {
      final tasks = await _store.unprocessedDoneTasks(
        mondayOf(_currentDay),
        sundayOf(_currentDay),
      );
      if (tasks.isEmpty) {
        _suggestions = const [];
        _newGoalSuggestions = const [];
        _readTaskIds = const [];
        return 0;
      }
      _readTaskIds = [for (final task in tasks) task.id];
      final result = await _matcher.match(
        config: aiConfig,
        goals: activeGoals,
        tasks: tasks,
      );
      _suggestions = result.matches;
      _newGoalSuggestions = result.newGoals;
      return result.length;
    } finally {
      _matching = false;
      notifyListeners();
    }
  }

  /// 上一次让 AI 读过的那批待办 id。
  ///
  /// 确认阶段要把它们标成"处理过了",角标才会掉。**不管用户勾了几条**都要标:
  /// 「取快递」这类永远匹配不上推进条的事,处理结果就是"没有结果"——
  /// 那也算处理过了,否则它永远留在待同步计数里,角标怎么都清不掉。
  List<int> _readTaskIds = const [];

  /// 把用户确认过的建议落库。
  Future<int> confirmSuggestions(List<ProgressSuggestion> accepted) async {
    for (final suggestion in accepted) {
      await _store.addProgress(
        goalId: suggestion.goalId,
        amount: suggestion.amount,
        day: _currentDay,
        note: suggestion.taskText,
        taskId: suggestion.taskId,
        source: 'ai',
      );
      // 建目标时没填单位的(AI 当时也可能读不出来),在这里补上:
      // 判断这一次推进时模型已经看到了具体的量,它给的单位比建目标时猜的准。
      final goal = _goals.where((g) => g.id == suggestion.goalId).firstOrNull;
      if (goal != null && goal.unit.isEmpty && suggestion.unit.isNotEmpty) {
        await _store.updateGoal(goal.copyWith(unit: suggestion.unit));
      }
    }
    _suggestions = const [];
    await _markReadTasksSynced([
      for (final suggestion in accepted) suggestion.taskId,
    ]);
    await refreshGoals();
    return accepted.length;
  }

  /// 把用户**看过并确认过**的这一批都标成已处理,并刷新角标。
  ///
  /// 由界面在审阅面板确认后调用一次——**不管用户勾了几条**。
  /// 「取快递」这类永远匹配不上推进条的事,处理结果就是"没有结果",
  /// 那同样算处理过了;只把勾选的算进去的话,角标会永远挂着,
  /// 而那正是用户报的问题("用 ai 整理了后还是有")。
  Future<void> markReviewedSuggestionsSynced() async {
    final ids = {
      ..._readTaskIds,
      for (final suggestion in _suggestions) suggestion.taskId,
      for (final suggestion in _newGoalSuggestions) suggestion.taskId,
    };
    _readTaskIds = const [];
    _suggestions = const [];
    _newGoalSuggestions = const [];
    if (ids.isNotEmpty) await _store.markTasksSynced(ids);
    await _refreshPendingSync();
  }

  /// 把这批被读过的待办标成已处理,并刷新角标。
  ///
  /// 传入本次审阅涉及到的任务 id(建议里带的那些)。之所以不依赖
  /// [requestProgressSuggestions] 记下的那份 id:用户可能在别的入口
  /// 直接确认,或者中途切了周,那份 id 会对不上,而**角标清不掉正是
  /// 用户报的问题**,不能让它依赖一个容易失效的中间状态。
  Future<void> _markReadTasksSynced(Iterable<int> taskIds) async {
    final ids = {..._readTaskIds, ...taskIds}.toList();
    _readTaskIds = const [];
    if (ids.isNotEmpty) await _store.markTasksSynced(ids);
    await _refreshPendingSync();
  }

  /// 把用户勾选的"建议新建的目标"建出来,并把这次已完成的推进量一并记上。
  ///
  /// 建完之后立刻记进度,而不是建一个空目标:这些量的来源是**已经做完的事**,
  /// 让用户建完再手动补一遍,正是这个功能想省掉的那步。
  Future<int> confirmNewGoals(List<NewGoalSuggestion> accepted) async {
    for (final suggestion in accepted) {
      final goalId = await _store.addGoal(
        title: suggestion.title,
        unit: suggestion.unit,
        // 不设目标值:他做这件事之前并没有定过要推进到多少,
        // 硬填一个数是替用户做决定,而且会凭空出现一个"进度条"。
        // 没有目标值就是推进条——正是用户要的那种。
        target: null,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      await _store.addProgress(
        goalId: goalId,
        amount: suggestion.amount,
        day: _currentDay,
        note: suggestion.taskText,
        taskId: suggestion.taskId,
        source: 'ai',
      );
    }
    _newGoalSuggestions = const [];
    await _markReadTasksSynced([
      for (final suggestion in accepted) suggestion.taskId,
    ]);
    await refreshGoals();
    return accepted.length;
  }

  /// 打完钩之后自动跑一次 AI 量化。
  ///
  /// 这是这个功能的正常路径:用户不需要记得去点什么按钮,勾完就有进度。
  /// 出错的代价很低——落库前会把结果摆出来给他确认,判断错了也能改。
  /// 没配 key、正在跑,都安静地跳过。
  ///
  /// **一条目标都没有时也要跑**:那种情况正是"要不要建第一条推进条"的时机,
  /// 提前返回等于让新用户永远看不到这个功能。
  Future<void> _autoSyncProgress() async {
    if (_autoSyncing || _matching) return;
    if (!aiConfig.isUsable) return;
    _autoSyncing = true;
    try {
      final count = await requestProgressSuggestions();
      if (count > 0) notifyListeners();
    } on Exception {
      // AI 暂时不可用不该打扰打钩这个动作,进度页上还有手动同步的入口。
    } finally {
      _autoSyncing = false;
    }
  }

  void dismissSuggestions() {
    _suggestions = const [];
    _newGoalSuggestions = const [];
    notifyListeners();
  }

  // ---------- 报告页 ----------

  /// 取某一周的统计(周一至周日)。
  Future<PeriodReport> weekReport(String anyDayInWeek) => _reports.weekOf(anyDayInWeek);

  /// 取某一月的统计。
  Future<PeriodReport> monthReport(String anyDayInMonth) => _reports.monthOf(anyDayInMonth);

  /// 周报区间标签,如 `2026年9月14日 - 9月20日`。
  String weekLabel(String anyDayInWeek) {
    final start = mondayOf(anyDayInWeek);
    final end = sundayOf(anyDayInWeek);
    final startDate = parseDayKey(start);
    final endDate = parseDayKey(end);
    if (startDate.year != endDate.year) {
      return '${startDate.year}年${startDate.month}月${startDate.day}日'
          ' - ${endDate.year}年${endDate.month}月${endDate.day}日';
    }
    return '${startDate.year}年${startDate.month}月${startDate.day}日'
        ' - ${endDate.month}月${endDate.day}日';
  }

  /// 月报区间标签,如 `2026年9月`。
  String monthLabel(String anyDayInMonth) {
    final date = parseDayKey(anyDayInMonth);
    return '${date.year}年${date.month}月';
  }

  /// 没配 AI 时的兜底报告:纯统计,不需要网络。
  Future<String> plainWeekReport(String anyDayInWeek) async {
    final report = await weekReport(anyDayInWeek);
    return _reports.plainReport(report, periodLabel: '${weekLabel(anyDayInWeek)} 周总结');
  }

  /// 让 AI 基于真实打卡数据写周报。产出同时缓存为导出用草稿。
  ///
  /// 返回增量文本流;调用方负责把结果拼起来。失败时抛 [AiException]。
  Stream<String> generateWeekReport(String anyDayInWeek) async* {
    final report = await weekReport(anyDayInWeek);
    final context = _reports.aiContext(report, periodLabel: weekLabel(anyDayInWeek));
    final buffer = StringBuffer();

    await for (final chunk in _ai.streamChat(
      config: aiConfig,
      history: [
        AiMessage.system(
          reportPrompt(
            periodLabel: '${weekLabel(anyDayInWeek)} 的周总结',
            userContext: displayName,
          ),
        ),
        AiMessage.user(context),
      ],
    )) {
      // 报告只取最终回答,思考过程不进正文。
      if (chunk.isReasoning) continue;
      buffer.write(chunk.text);
      _weekDraft = buffer.toString();
      yield chunk.text;
    }
  }

  /// 生成月报,同样返回增量流(不缓存草稿,月报目前只用于阅读和分享)。
  Stream<String> generateMonthReport(String anyDayInMonth) async* {
    final report = await monthReport(anyDayInMonth);
    final context = _reports.aiContext(report, periodLabel: monthLabel(anyDayInMonth));
    await for (final chunk in _ai.streamChat(
      config: aiConfig,
      history: [
        AiMessage.system(
          reportPrompt(
            periodLabel: '${monthLabel(anyDayInMonth)} 的月总结',
            userContext: displayName,
          ),
        ),
        AiMessage.user(context),
      ],
    )) {
      if (chunk.isReasoning) continue;
      yield chunk.text;
    }
  }

  // ---------- 聊天页 ----------

  /// 全部会话,最近活跃的在前。
  List<Conversation> _conversations = const [];
  List<Conversation> get conversations => _conversations;

  /// 当前正在聊的会话 id。0 表示还没有任何会话。
  int _currentConversationId = 0;
  int get currentConversationId => _currentConversationId;

  /// 当前会话的标题(空串表示还没起名)。
  String get currentConversationTitle {
    for (final conversation in _conversations) {
      if (conversation.id == _currentConversationId) return conversation.title;
    }
    return '';
  }

  /// 当前会话的 AI 头像。空表示用默认的模型标志。
  ///
  /// 头像是**每个会话各自**的:不同对话可以是不同的人设。
  Uint8List? get currentConversationAvatar =>
      _avatarFor(currentConversation?.avatar ?? '');

  /// 某个会话的头像;它自己没设过就回落到全局那个。
  ///
  /// 侧边栏要在每条对话上显示头像,所以这里按会话取,而不是只看当前那个。
  Uint8List? avatarOf(Conversation conversation) =>
      _avatarFor(conversation.avatar) ?? _settings.avatarBytes;

  Conversation? get currentConversation {
    for (final conversation in _conversations) {
      if (conversation.id == _currentConversationId) return conversation;
    }
    return null;
  }

  /// 头像字节缓存,键是存进库的那个引用。
  ///
  /// 头像是**文件**而不是库里的 base64(见 [ChatImages.saveAvatar]):
  /// 512×512 的 PNG 编码成 base64 有几百 KB,塞进一行里写起来又慢又容易失败,
  /// 用户报的"调完大小形状就保存不上"就是这么来的。文件名进库,内容进磁盘。
  ///
  /// 缓存是为了让界面能同步取到图:读文件是异步的,而 `build` 不能等。
  final Map<String, Uint8List> _avatarCache = {};
  final Set<String> _avatarLoading = {};

  /// 取头像字节。缓存里没有就返回 null 并**安排**一次异步加载。
  ///
  /// 这个方法是可能在 `build` 期间被调用的(界面渲染时会读它),
  /// 所以加载完成后**不能直接 notifyListeners()**——在 build 里发通知会让
  /// 同一帧再次标脏,重建、又发通知,`pumpAndSettle` 永远等不到静止
  /// (表现为测试挂死几十分钟)。改成排到帧后再通知。
  Uint8List? _avatarFor(String ref) {
    final trimmed = ref.trim();
    if (trimmed.isEmpty) return null;
    final cached = _avatarCache[trimmed];
    if (cached != null) return cached;
    if (_avatarLoading.add(trimmed)) {
      unawaited(
        ChatImages.readAvatar(trimmed).then(
          (bytes) {
            _avatarLoading.remove(trimmed);
            if (bytes == null) return;
            _avatarCache[trimmed] = bytes;
            _notifyAfterBuild();
          },
          // 读不到就算了(文件被清理、平台通道不可用等)。必须在这里兜住:
          // 未处理的异步异常会让整页测试挂死,而不是给一个有意义的失败。
          onError: (Object _) => _avatarLoading.remove(trimmed),
        ),
      );
    }
    return null;
  }

  /// 把通知排到当前帧之后。正在 build 时直接通知会造成重建循环。
  void _notifyAfterBuild() {
    final binding = WidgetsBinding.instance;
    if (binding.schedulerPhase == SchedulerPhase.persistentCallbacks) {
      binding.addPostFrameCallback((_) {
        if (!_disposed) notifyListeners();
      });
      return;
    }
    notifyListeners();
  }
  bool _disposed = false;

  /// 给当前会话换一张 AI 头像。传 null 恢复默认。
  Future<void> saveConversationAvatar(Uint8List? bytes) async {
    final id = _currentConversationId;
    if (id == 0) return;
    if (bytes == null) {
      await _store.setConversationAvatar(id, '');
      await loadConversations();
      return;
    }
    final name = await ChatImages.saveAvatar('conversation_$id', bytes);
    if (name == null) {
      // 写文件失败就**报出来**。以前这里出错是静默的:用户点完确认、
      // 调整页也正常退出,头像却没变——"改不了"就是这么来的。
      throw const AvatarSaveException('头像没保存上,可能是存储空间不够,再试一次');
    }
    _avatarCache[name] = bytes;
    await _store.setConversationAvatar(id, name);
    await loadConversations();
  }

  /// 载入会话列表,并保证当前会话有效。
  ///
  /// 首次打开、或删掉了当前会话时,自动选中最近活跃的那个;
  /// 一个都没有就什么都不做——第一次发消息时再建。
  Future<void> loadConversations() async {
    _conversations = await _store.conversations();
    final stillExists = _conversations.any((c) => c.id == _currentConversationId);
    if (!stillExists) {
      _currentConversationId = _conversations.isEmpty ? 0 : _conversations.first.id;
    }
    await _loadChat();
  }

  /// 切到某个会话。
  Future<void> openConversation(int id) async {
    _currentConversationId = id;
    await _loadChat();
  }

  /// 开一个新对话。不立刻落库——第一次发消息时才建,免得留下一堆空会话。
  Future<void> startNewConversation() async {
    _currentConversationId = 0;
    _chat = const [];
    notifyListeners();
  }

  Future<void> deleteConversation(int id) async {
    await _store.deleteConversation(id);
    if (_currentConversationId == id) _currentConversationId = 0;
    await loadConversations();
  }

  Future<void> renameConversation(int id, String title) async {
    await _store.renameConversation(id, title);
    await loadConversations();
  }

  Future<void> _loadChat() async {
    _chat = _currentConversationId == 0
        ? const []
        : await _store.messagesOf(_currentConversationId);
    notifyListeners();
  }

  /// 发一条消息并把回复流式追加到界面状态。
  ///
  /// [range] 不为 null 时,把该区间的打卡数据作为 system 附加上下文——
  /// 相当于他平时"把总结贴给 AI"的动作自动化,范围由他自己选。
  /// [attachments] 是本次带上的图片/文件:图片走多模态,文本文件拼进消息正文。
  /// [thinking] 只影响这一次请求,不动全局设置。
  ///
  /// **只发本会话的历史**:以前这里把全局所有消息都拼进上下文,
  /// 结果是新开的对话能"看到"以前聊过的内容,表现得像无中生有的记忆。
  Stream<AiChunk> sendChat(
    String text, {
    DataRange? range,
    List<ChatAttachment> attachments = const [],
    ThinkingLevel? thinking,
  }) async* {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;

    // 首次发消息时才把会话落库;标题先留空,发完用它起名。
    var conversationId = _currentConversationId;
    if (conversationId == 0) {
      conversationId = await _store.createConversation();
      _currentConversationId = conversationId;
    }
    // 记下这次回答属于哪个会话。生成期间用户可能去侧边栏翻到别的对话,
    // 落库时必须写回原来那个——否则回答会挂到另一个对话下面,原来那个
    // 对话则悄悄少了一次回答。
    _streamingConversationId = conversationId;

    // 图片先落盘再记引用:消息里存 base64 会让每条消息膨胀几百 KB,
    // 回看历史和查库都会变慢。存不下来就退化成文件名——至少不丢信息。
    final resolved = <ChatAttachment>[];
    for (final file in attachments) {
      if (!file.isImage || file.imageRef.isNotEmpty || file.imageBytes == null) {
        resolved.add(file);
        continue;
      }
      final saved = await ChatImages.save(file.imageBytes!, file.name);
      resolved.add(
        saved == null
            ? file
            : ChatAttachment(
                name: file.name,
                isImage: true,
                imageBytes: file.imageBytes,
                imageRef: saved,
                sizeBytes: file.sizeBytes,
              ),
      );
    }

    // 附件也写进消息文本:回看聊天记录时要知道当时发了什么。
    // 图片写成 `![图] <引用>` 而不是文件名——界面上要真的把图渲染出来。
    final shown = [
      trimmed,
      for (final file in resolved) file.describe,
    ].where((line) => line.isNotEmpty).join('\n');
    await _store.addMessage(conversationId, 'user', shown);
    await _loadChat();

    final images = <String>[
      for (final file in resolved)
        if (file.isImage && file.imageBytes != null)
          'data:image/${_imageMime(file.name)};base64,'
              '${base64Encode(file.imageBytes!)}',
    ];
    final fileTexts = [
      for (final file in resolved)
        if (!file.isImage && file.text != null)
          '--- 文件:${file.name} ---\n${file.text}',
    ];

    // 表情包库非空时才把发图规则写进提示词:没有素材却允许它发,
    // 它就会写一行永远挑不到图的指令,还白占上下文。
    final memes = await MemeLibrary.load();
    final memeHint = memes.isEmpty ? '' : memeHintPrompt(memes.tags.join(' / '));

    final history = <AiMessage>[
      AiMessage.system(chatSystemPrompt(memeHint: memeHint)),
    ];
    if (range != null) {
      // 按选中区间现取数据,而不是复用周报/月报的边界——范围是他自己选的。
      final period = PeriodReport(
        startDay: range.startDay,
        endDay: range.endDay,
        tasks: await _store.tasksBetween(range.startDay, range.endDay),
        journals: await _store.journalsBetween(range.startDay, range.endDay),
      );
      history.add(
        AiMessage.system(
          '以下是用户 ${range.label} 的真实打卡数据,回答时可以引用:\n\n'
          '${_reports.aiContext(period, periodLabel: range.label)}',
        ),
      );
    }
    // 历史里不含刚写进去的这一条——它要单独带上图片和文件内容放在最后。
    final past = _chat.isNotEmpty ? _chat.sublist(0, _chat.length - 1) : _chat;
    for (final message in past.length > 20
        ? past.sublist(past.length - 20)
        : past) {
      history.add(
        message.isUser
            ? AiMessage.user(message.content)
            : AiMessage.assistant(message.content),
      );
    }

    // 本轮消息:正文 + 文本文件内容,图片作为多模态部分。
    final turnText = [
      if (trimmed.isNotEmpty) trimmed,
      ...fileTexts,
    ].join('\n\n');
    history.add(AiMessage.user(turnText, images: images));

    _streamingReasoning = '';
    _streamingAnswer = '';
    notifyListeners();

    final config = thinking == null ? aiConfig : aiConfig.copyWith(thinking: thinking);

    // 第一个分片到达时**必须** notifyListeners 一次。
    //
    // 只看 streamTick 是不够的:列表里那个"正在生成"的槽位由 `streaming`
    // 这个开关决定插不插入,而页面级重建只有 notifyListeners 才会触发。
    // 少了这一次通知,槽位永远不插入,正文就一个字都不显示——直到最后
    // commitAssistantMessage 落库才整段冒出来。用户看到的正是
    // "闪烁没了,但流式输出也没了";旧版本之所以看着有流式,是因为每个分片
    // 都在 setState 整页(那才是抖动的来源)。
    //
    // 只通知这一次,后续分片仍然只走 streamTick:槽位已经在树上了,
    // 让它自己重绘即可,不必每次重排整页。
    var announced = streaming;
    await for (final chunk in _ai.streamChat(config: config, history: history)) {
      if (chunk.isReasoning) {
        _streamingReasoning += chunk.text;
      } else {
        // 正文和"要哪张表情包"的指令混在一条流里。指令那行是给系统看的,
        // 不能显示给用户,而流是一段段来的、标记可能被切在两个字中间,
        // 所以交给 [visibleStreamingAnswer] 在渲染时裁掉,不在这里判断。
        _streamingAnswer += chunk.text;
      }
      if (!announced) {
        announced = true;
        notifyListeners();
      }
      // 只惊动正在长的那个气泡。整页 notifyListeners 会让每一帧都重排
      // 全部消息,看上去就是抖。
      streamTick.value++;
      yield chunk;
    }
  }

  /// 从文件名推图片 MIME 类型。
  ///
  /// 服务端要的是 `data:image/<type>;base64,...`;推错类型会被拒,
  /// 所以只认已知扩展名,其余按 png 兜底(jpeg/webp 之外最常见的位图)。
  static String _imageMime(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'jpg' || 'jpeg' => 'jpeg',
      'webp' => 'webp',
      'gif' => 'gif',
      'bmp' => 'bmp',
      _ => 'png',
    };
  }

  /// 流式回复结束后落库,让下次打开还能看到。
  Future<void> commitAssistantMessage() async {
    final raw = _streamingAnswer.trim();
    final reasoning = _streamingReasoning.trim();
    _streamingAnswer = '';
    _streamingReasoning = '';
    streamTick.value++;
    // 写回**发起时那个**会话,而不是当前选中的那个:生成期间用户可能已经
    // 翻到别的对话去了。
    final target = _streamingConversationId;
    _streamingConversationId = 0;

    // 模型可能要求了一张表情包。挑图在这里做:挑到了就把它作为一行
    // `![图] asset:...` 追加到正文后面,回看历史时能直接渲染出来。
    final directive = stripMemeDirective(raw);
    var answer = directive.text.trim();
    if (directive.hasMeme) {
      final meme = await _pickMeme(directive);
      if (meme != null) answer = '$answer\n\n${memeLineFor(meme.assetPath)}';
    }

    if (answer.isEmpty || target == 0) {
      notifyListeners();
      return;
    }
    await _store.addMessage(target, 'assistant', answer, reasoning: reasoning);
    // 还没起名的会话用首条用户消息当标题——侧边栏里一堆"新对话"没法分辨。
    await _autoTitleConversation(target);
    await loadConversations();
  }

  /// 按模型给的情绪和画面描述挑一张表情包。
  Future<Meme?> _pickMeme(MemeDirective directive) async {
    final library = await MemeLibrary.load();
    if (library.isEmpty) return null;
    final tag = library.tagForEmotion(directive.emotion);
    // 用情绪+描述一起检索;同一个对话里同一句话应该挑到同一张,
    // 所以拿整段指令当种子,而不是随机。
    return library.pick(
      tag: tag,
      query: '${directive.emotion} ${directive.query}'.trim(),
      seed: directive.emotion.hashCode ^ directive.query.hashCode,
    );
  }

  /// 会话还没标题时,拿首条用户消息命名。
  Future<void> _autoTitleConversation([int? conversationId]) async {
    final id = conversationId ?? _currentConversationId;
    if (id == 0) return;
    final existing = _conversations.where((c) => c.id == id).firstOrNull;
    if (existing != null && existing.title.trim().isNotEmpty) return;

    final messages = await _store.messagesOf(id);
    final firstUser = messages.where((m) => m.isUser).firstOrNull;
    if (firstUser == null) return;

    // 标题取前 20 个字:够分辨就行,太长在侧边栏里也会被截断。
    final raw = firstUser.content.replaceAll('\n', ' ').trim();
    final title = raw.length <= 20 ? raw : '${raw.substring(0, 20)}…';
    await _store.renameConversation(id, title);
  }

  // ---------- 提醒 ----------

  /// 某天的提醒。
  Future<List<Reminder>> remindersOn(String day) => _store.remindersOn(day);

  /// 给某条任务加一个提醒。
  ///
  /// 加完立刻重排系统通知:用户设了提醒却要等下次开 app 才生效是不可接受的。
  Future<void> addReminder({
    required Task task,
    required String day,
    required String at,
    String note = '',
  }) async {
    await _store.addReminder(taskId: task.id, day: day, at: at, note: note);
    await syncReminders();
    notifyListeners();
  }

  Future<void> deleteReminder(int id) async {
    await _store.deleteReminder(id);
    await syncReminders();
    notifyListeners();
  }

  /// 系统通知开关是不是开着的。查不出来时为 null。
  ///
  /// 设提醒的界面上要问这个:开关关着的话,提醒排了也不会响,
  /// 用户只会觉得"设了没用"。
  Future<bool?> notificationsEnabled() => _notifier.notificationsEnabled();

  /// 把未来一周的提醒重新排进系统通知。
  ///
  /// 只排未来一段而不是全部:Android 的定时通知数量有限,
  /// 而且排太远的提醒意义不大(那时 app 早被打开过很多次了)。
  Future<void> syncReminders() async {
    final today = todayKey();
    final upcoming = await _store.remindersBetween(today, addDays(today, 7));
    await _notifier.sync(upcoming, taskTextOf: await _taskTextIndex());
  }

  /// 提醒通知的正文要用任务内容,这里一次性把 id→内容 取出来。
  Future<Map<int, String>> _taskTextIndex() async {
    final today = todayKey();
    final tasks = await _store.tasksBetween(addDays(today, -1), addDays(today, 8));
    return {for (final task in tasks) task.id: task.text};
  }

  // ---------- 设置 ----------

  Future<void> saveAiConfig(AiConfig config) async {
    await _settings.saveAiConfig(config);
    notifyListeners();
  }

  Future<void> saveDisplayName(String name) async {
    await _settings.saveDisplayName(name);
    notifyListeners();
  }

  Future<void> saveAvatar(Uint8List? bytes) async {
    await _settings.saveAvatar(bytes);
    notifyListeners();
  }

  Future<void> saveUserAvatar(Uint8List? bytes) async {
    await _settings.saveUserAvatar(bytes);
    notifyListeners();
  }

  /// 用户头像的形状。跟着头像一起存,换头像时用户可以重新选。
  AvatarShape get userAvatarShape => switch (_settings.userAvatarShape) {
        'rounded' => AvatarShape.rounded,
        'square' => AvatarShape.square,
        _ => AvatarShape.circle,
      };

  Future<void> saveUserAvatarShape(AvatarShape shape) async {
    await _settings.saveUserAvatarShape(shape.name);
    notifyListeners();
  }

  Future<void> saveCardBackground(Uint8List? bytes) async {
    await _settings.saveCardBackground(bytes);
    notifyListeners();
  }

  Future<void> saveBio(String text) async {
    await _settings.saveBio(text);
    notifyListeners();
  }

  Future<void> saveDarkMode(bool value) async {
    await _settings.saveDarkMode(value);
    notifyListeners();
  }

  Future<void> saveSplashText(String text) async {
    await _settings.saveSplashText(text);
    notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _ai.dispose();
    super.dispose();
  }
}

/// 头像没能保存。
///
/// 单独一个类型是为了让界面能区分"用户取消"和"真的没存上"——
/// 后者必须报出来。以前失败是静默的:调整页正常退出、什么都没变,
/// 用户只会觉得"这个功能坏了"。
class AvatarSaveException implements Exception {
  const AvatarSaveException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 从 [AppDatabase] 一行装好所有依赖,供 `main` 使用。
Future<AppState> createAppState() async {
  final database = await AppDatabase.open();
  final store = SqliteRecordStore(database.db);
  return AppState(
    store: store,
    reports: ReportService(store),
    settings: await SettingsStore.load(),
  );
}

/// 把 [AppState] 传给整棵组件树。
class AppScope extends InheritedNotifier<AppState> {
  const AppScope({super.key, required AppState state, required super.child})
      : super(notifier: state);

  static AppState of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope?.notifier != null, '组件树上没有 AppScope');
    return scope!.notifier!;
  }
}
