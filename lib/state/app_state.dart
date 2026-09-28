/// 参数用公开名、字段用私有名,所以构造处无法写成 initializing formal。
library;

// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../ai/ai_client.dart';
import '../ai/goal_matcher.dart';
import '../ai/prompts.dart';
import '../ai/settings_store.dart';
import '../core/day.dart';
import '../data/database.dart';
import '../data/chat_attachment.dart';
import '../data/data_range.dart';
import '../data/goals.dart';
import '../data/models.dart';
import '../data/palette.dart';
import '../data/record_store.dart';
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
  })  : _store = store,
        _reports = reports,
        _settings = settings,
        _ai = aiClient ?? AiClient(),
        _updater = updater ?? AppUpdater(),
        _installer = installer,
        _matcher = GoalMatcher(aiClient ?? AiClient());

  final RecordStore _store;
  final ReportService _reports;
  final SettingsStore _settings;
  final AiClient _ai;
  final AppUpdater _updater;
  final ApkInstaller _installer;
  final GoalMatcher _matcher;

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

  bool _matching = false;
  bool get matching => _matching;

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

  bool get streaming => _streamingAnswer.isNotEmpty || _streamingReasoning.isNotEmpty;

  // ---------- 设置 ----------

  AiConfig get aiConfig => _settings.aiConfig;
  String get displayName => _settings.displayName;
  Uint8List? get avatarBytes => _settings.avatarBytes;
  bool get darkMode => _settings.darkMode;

  /// 开屏那句话。
  String get splashText => _settings.splashText;

  /// 报告草稿:AI 生成后缓存在这里,导出优先用它。
  String _weekDraft = '';
  String get weekDraft => _weekDraft;

  /// 首次进页面时把要用的数据读出来。
  Future<void> bootstrap() async {
    await _loadDay();
    await _loadChat();
    await refreshGoals();
    await loadCalendarMonth(_calendarMonth);
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
    notifyListeners();
    try {
      await _installer.downloadAndInstall(
        _updater,
        info,
        onProgress: (value) {
          _updateProgress = value;
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
    await _store.setTaskDone(task.id, !task.done);
    await _loadDay();
    await _refreshPendingSync();
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
  }

  /// 把某条待办挪到另一天。
  Future<void> moveTask(Task task, String day) async {
    await _store.updateTaskDay(task.id, day);
    await _loadDay();
    await loadCalendarMonth(_calendarMonth);
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
  Future<void> addTaskOn(String day, String text, {TaskColor? color}) async {
    if (text.trim().isEmpty) return;
    await _store.addTask(day, text, color: color);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
  }

  Future<void> toggleTaskOn(String day, Task task) async {
    await _store.setTaskDone(task.id, !task.done);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
    await _refreshPendingSync();
  }

  Future<void> deleteTaskOn(String day, Task task) async {
    await _store.deleteTask(task.id);
    await loadCalendarMonth(_calendarMonth);
    if (day == _currentDay) await _loadDay();
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
    _goals = await _store.goals();
    await _refreshPendingSync();
    notifyListeners();
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
    required String unit,
    required double target,
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
  Future<int> requestProgressSuggestions() async {
    if (!aiConfig.isUsable) {
      throw AiException('还没填 API key,去设置里填一下');
    }
    if (activeGoals.isEmpty) return 0;

    _matching = true;
    notifyListeners();
    try {
      final tasks = await _store.unprocessedDoneTasks(
        mondayOf(_currentDay),
        sundayOf(_currentDay),
      );
      if (tasks.isEmpty) {
        _suggestions = const [];
        return 0;
      }
      _suggestions = await _matcher.match(
        config: aiConfig,
        goals: activeGoals,
        tasks: tasks,
      );
      return _suggestions.length;
    } finally {
      _matching = false;
      notifyListeners();
    }
  }

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
    }
    _suggestions = const [];
    await refreshGoals();
    return accepted.length;
  }

  void dismissSuggestions() {
    _suggestions = const [];
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

  Future<void> _loadChat() async {
    _chat = await _store.recentMessages();
    notifyListeners();
  }

  /// 发一条消息并把回复流式追加到界面状态。
  ///
  /// [range] 不为 null 时,把该区间的打卡数据作为 system 附加上下文——
  /// 相当于他平时"把总结贴给 AI"的动作自动化,范围由他自己选。
  /// [attachments] 是本次带上的图片/文件:图片走多模态,文本文件拼进消息正文。
  /// [thinking] 只影响这一次请求,不动全局设置。
  Stream<AiChunk> sendChat(
    String text, {
    DataRange? range,
    List<ChatAttachment> attachments = const [],
    ThinkingLevel? thinking,
  }) async* {
    final trimmed = text.trim();
    if (trimmed.isEmpty && attachments.isEmpty) return;

    // 附件也写进消息文本:回看聊天记录时要知道当时发了什么。
    final shown = [
      trimmed,
      for (final file in attachments) file.describe,
    ].where((line) => line.isNotEmpty).join('\n');
    await _store.addMessage('user', shown);
    await _loadChat();

    final images = <String>[
      for (final file in attachments)
        if (file.isImage && file.imageBytes != null)
          'data:image/${_imageMime(file.name)};base64,'
              '${base64Encode(file.imageBytes!)}',
    ];
    final fileTexts = [
      for (final file in attachments)
        if (!file.isImage && file.text != null)
          '--- 文件:${file.name} ---\n${file.text}',
    ];

    final history = <AiMessage>[
      AiMessage.system(chatSystemPrompt),
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
    await for (final chunk in _ai.streamChat(config: config, history: history)) {
      if (chunk.isReasoning) {
        _streamingReasoning += chunk.text;
      } else {
        _streamingAnswer += chunk.text;
      }
      notifyListeners();
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
    final answer = _streamingAnswer.trim();
    final reasoning = _streamingReasoning.trim();
    _streamingAnswer = '';
    _streamingReasoning = '';
    if (answer.isEmpty) {
      notifyListeners();
      return;
    }
    await _store.addMessage('assistant', answer, reasoning: reasoning);
    await _loadChat();
  }

  Future<void> clearChat() async {
    await _store.clearMessages();
    await _loadChat();
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
    _ai.dispose();
    super.dispose();
  }
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
