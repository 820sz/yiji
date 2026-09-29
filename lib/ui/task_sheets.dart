import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/day.dart';
import '../data/models.dart';
import '../data/palette.dart';
import '../data/record_store.dart';
import '../data/reminder.dart';
import '../state/app_state.dart';
import 'task_card.dart';
import 'theme.dart';

/// 新增待办的弹层。
///
/// 同一处支持两种输入:单行直接加一条;粘贴多行则整段拆成多条——
/// 对应他"从原子笔记搬今天的清单过来"这个动作。
/// 配色可当场选,默认沿用上一次选的颜色(见 [showAddTaskSheet] 的 lastColor 参数)。
Future<void> showAddTaskSheet(  BuildContext context, {
  String? day,
  TaskColor? initialColor,
}) async {
  final state = AppScope.of(context);
  final target = day ?? state.currentDay;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _AddTaskSheet(
      state: state,
      day: target,
      initialColor: initialColor ?? TaskColor.blue,
    ),
  );
}

class _AddTaskSheet extends StatefulWidget {
  const _AddTaskSheet({
    required this.state,
    required this.day,
    required this.initialColor,
  });

  final AppState state;
  final String day;
  final TaskColor initialColor;

  @override
  State<_AddTaskSheet> createState() => _AddTaskSheetState();
}

class _AddTaskSheetState extends State<_AddTaskSheet> {
  final _controller = TextEditingController();
  late TaskColor _color = widget.initialColor;
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final raw = _controller.text;
    if (raw.trim().isEmpty || _submitting) return;

    setState(() => _submitting = true);
    try {
      final isFuture = widget.day != widget.state.currentDay;
      if (raw.contains('\n')) {
        final added = isFuture
            ? await _addManyOnDay(raw)
            : await widget.state.addTasksFromPaste(raw);
        if (mounted && added > 0) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('加了 $added 条')),
          );
        }
      } else if (isFuture) {
        await widget.state.addTaskOn(widget.day, raw, color: _color);
      } else {
        await widget.state.addTask(raw, color: _color);
      }
      if (mounted) Navigator.pop(context);
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  /// 未来的日期上批量加:逐条走 addTaskOn,保持顺序。
  Future<int> _addManyOnDay(String raw) async {
    final lines = parseTaskLines(raw);
    for (final line in lines) {
      await widget.state.addTaskOn(widget.day, line, color: _color);
    }
    return lines.length;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    // 外层用可滚动容器而不是 Column:多行输入框自身高度随内容增长,
    // 直接放进 Column 会在内容变多时溢出(键盘弹起时更明显)。
    return SingleChildScrollView(
      padding: EdgeInsets.only(
        left: 18,
        right: 18,
        top: 18,
        bottom: MediaQuery.of(context).viewInsets.bottom + 18,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '加到 ${shortDateLabel(widget.day)}',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _controller,
            autofocus: true,
            maxLines: null,
            minLines: 3,
            textInputAction: TextInputAction.newline,
            keyboardType: TextInputType.multiline,
            style: const TextStyle(fontSize: 15.5, height: 1.5),
            decoration: const InputDecoration(hintText: '今天要做的事'),
          ),
          const SizedBox(height: 14),
          _ColorRow(
            current: _color,
            onPick: (color) => setState(() => _color = color),
          ),
          const SizedBox(height: 14),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _submit,
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(_submitting ? '加中…' : '添加'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 一排可选颜色。用在新增弹层里,比再弹一层选择器少一次点击。
class _ColorRow extends StatelessWidget {
  const _ColorRow({required this.current, required this.onPick});

  final TaskColor current;
  final ValueChanged<TaskColor> onPick;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        for (final color in TaskColor.selectable)
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: () => onPick(color),
              child: AnimatedContainer(
                duration: AppTheme.fast,
                curve: AppTheme.easeOut,
                width: 30,
                height: 30,
                decoration: BoxDecoration(
                  color: AppTheme.cardFill(color, done: false, dark: dark),
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: color == current ? AppTheme.accent : Colors.transparent,
                    width: 2.5,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 某一天的待办编辑弹层(日历和"看这一天"共用)。
///
/// 就地编辑:增、勾、删、改色、挪到另一天都在这里完成,不用跳页面。
Future<void> showDayEditor(BuildContext context, String day) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) => _DayEditorSheet(day: day),
  );
}

class _DayEditorSheet extends StatefulWidget {
  const _DayEditorSheet({required this.day});

  final String day;

  @override
  State<_DayEditorSheet> createState() => _DayEditorSheetState();
}

class _DayEditorSheetState extends State<_DayEditorSheet> {
  final _controller = TextEditingController();
  List<Task> _tasks = const [];
  List<Reminder> _reminders = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (!mounted) return;
    final state = AppScope.of(context);
    final tasks = await state.tasksOn(widget.day);
    final reminders = await state.remindersOn(widget.day);
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _reminders = reminders;
      _loading = false;
    });
  }

  /// 在选中的这一天加一个提醒。
  ///
  /// 提醒必须挂在某条任务上(通知正文也从任务内容里取),所以这里会顺手
  /// 建一条同名任务。用户想做的其实是"记一件事,到点提醒我"——让他先去
  /// 建任务、再点进任务里设提醒,是把一步的事拆成了三步。
  Future<void> _addReminder() async {
    final state = AppScope.of(context);
    final text = _controller.text.trim();
    final picked = await showTimePicker(
      context: context,
      initialTime: const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null || !mounted) return;

    final at = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    // 内容留空时用这句兜底,总比一条没有正文的通知好。
    final title = text.isEmpty ? '到点提醒' : text;
    final taskId = await state.addTaskOn(widget.day, title);
    final task = Task(
      id: taskId,
      day: widget.day,
      text: title,
      done: false,
      sortOrder: 0,
      createdAt: DateTime.now(),
    );
    await state.addReminder(task: task, day: widget.day, at: at, note: title);
    if (!mounted) return;
    _controller.clear();
    await _reload();
    await _warnIfNotificationsOff(state);
  }

  /// 通知开关关着的时候说清楚,并给一个直接去开的入口。
  ///
  /// 排程本身是成功的,但系统不会弹——不说的话用户只会觉得"设了没有用",
  /// 然后反复设、反复没用。
  Future<void> _warnIfNotificationsOff(AppState state) async {
    final enabled = await state.notificationsEnabled();
    if (enabled != false || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('提醒已设好,但系统通知权限没开,到点不会弹'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '去开启',
          onPressed: _openNotificationSettings,
        ),
      ),
    );
  }

  static const _settingsChannel = MethodChannel('com.xi283.yiji/app');

  static Future<void> _openNotificationSettings() async {
    try {
      await _settingsChannel.invokeMethod<void>('openNotificationSettings');
    } on PlatformException {
      // 打不开就只能靠用户自己去系统设置里找,不额外打扰。
    } on MissingPluginException {
      // 同上:没有这个原生实现(桌面/测试环境)。
    }
  }

  Future<void> _add() async {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    final state = AppScope.of(context);
    _controller.clear();
    if (text.contains('\n')) {
      for (final line in parseTaskLines(text)) {
        await state.addTaskOn(widget.day, line);
      }
    } else {
      await state.addTaskOn(widget.day, text);
    }
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final done = _tasks.where((t) => t.done).length;

    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        minChildSize: 0.35,
        maxChildSize: 0.92,
        builder: (context, scrollController) {
          return Column(
            children: [
              // 抓手:让"这是可以往下拖的"看得见。
              Container(
                margin: const EdgeInsets.only(top: 8, bottom: 6),
                width: 38,
                height: 4,
                decoration: BoxDecoration(
                  color: textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 6, 18, 10),
                child: Row(
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          fullDateLabel(widget.day),
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                            color: textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _tasks.isEmpty
                              ? '还没有安排'
                              : '${_tasks.length} 条 · 完成 $done',
                          style: TextStyle(fontSize: 12.5, color: textSecondary),
                        ),
                      ],
                    ),
                    const Spacer(),
                    // 提醒的入口放在这一层:点日期进来就能设,和系统日历一样,
                    // 不用先建任务再钻进任务里找。
                    IconButton(
                      onPressed: _addReminder,
                      icon: const Icon(Icons.add_alert_outlined, size: 20),
                      tooltip: '加提醒',
                    ),
                    if (widget.day != state.currentDay)
                      TextButton.icon(
                        onPressed: () async {
                          await state.goToDay(widget.day);
                          if (context.mounted) Navigator.pop(context);
                        },
                        icon: const Icon(Icons.open_in_new, size: 16),
                        label: const Text('完整打开'),
                      ),
                  ],
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator())
                    : ListView(
                        controller: scrollController,
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                        children: [
                          // 这一天设过的提醒。列在最上面:它是这一页里唯一
                          // "会主动打扰你"的东西,漏看了就会白设。
                          if (_reminders.isNotEmpty) ...[
                            for (final reminder in _reminders)
                              ListTile(
                                contentPadding: EdgeInsets.zero,
                                dense: true,
                                leading: Icon(
                                  Icons.notifications_active_outlined,
                                  size: 20,
                                  color: AppTheme.accent,
                                ),
                                title: Text(
                                  reminder.at,
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                    color: textPrimary,
                                  ),
                                ),
                                subtitle: Text(
                                  reminder.note.isEmpty ? '到点提醒' : reminder.note,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(fontSize: 12.5, color: textSecondary),
                                ),
                                trailing: IconButton(
                                  icon: Icon(
                                    Icons.close,
                                    size: 18,
                                    color: textSecondary,
                                  ),
                                  tooltip: '取消这个提醒',
                                  onPressed: () async {
                                    await state.deleteReminder(reminder.id);
                                    await _reload();
                                  },
                                ),
                              ),
                            const SizedBox(height: 4),
                          ],
                          if (_tasks.isEmpty)
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 28),
                              child: Center(
                                child: Text(
                                  '这一天还是空的',
                                  style: TextStyle(fontSize: 14, color: textSecondary),
                                ),
                              ),
                            )
                          else
                            for (final task in _tasks)
                              // 左滑删除。日历里也要能删——不然记错的事只能去别处清理。
                              Dismissible(
                                key: ValueKey('sheet-${task.id}'),
                                direction: DismissDirection.endToStart,
                                background: Container(
                                  alignment: Alignment.centerRight,
                                  padding: const EdgeInsets.only(
                                    right: 20,
                                    bottom: AppTheme.cardGap,
                                  ),
                                  child: const Icon(
                                    Icons.delete_outline,
                                    color: Color(0xFFE05252),
                                  ),
                                ),
                                onDismissed: (_) async {
                                  await state.deleteTaskOn(widget.day, task);
                                  await _reload();
                                },
                                child: TaskCard(
                                  task: task,
                                  dark: dark,
                                  // 点文字进编辑页:日历里的事件也要能改,
                                  // 不然记错了就只能干看着。
                                  onTap: () => showTaskEditor(
                                    context,
                                    task: task,
                                    day: widget.day,
                                  ),
                                  onToggleDone: () async {
                                    await state.toggleTaskOn(widget.day, task);
                                    await _reload();
                                  },
                                  onLongPress: () async {
                                    final color = await showColorPicker(
                                      context,
                                      current: task.color,
                                    );
                                    if (color == null) return;
                                    await state.setTaskColorOn(
                                      widget.day,
                                      task,
                                      color,
                                    );
                                    await _reload();
                                  },
                                ),
                              ),
                        ],
                      ),
              ),
              SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          minLines: 1,
                          maxLines: 3,
                          textInputAction: TextInputAction.newline,
                          keyboardType: TextInputType.multiline,
                          style: const TextStyle(fontSize: 15),
                          decoration: const InputDecoration(
                            hintText: '加一条到这一天',
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      IconButton.filled(
                        onPressed: _add,
                        icon: const Icon(Icons.arrow_upward, size: 20),
                        tooltip: '添加',
                      ),
                    ],
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 想法/收获的编辑器。想法通常比待办长,给足空间。
Future<void> showJournalEditor(BuildContext context, String day, String initial) async {
  final state = AppScope.of(context);
  final controller = TextEditingController(text: initial);
  final result = await Navigator.of(context).push<String>(
    MaterialPageRoute(
      builder: (context) => _JournalEditorPage(
        title: '${shortDateLabel(day)}的想法',
        controller: controller,
      ),
    ),
  );
  controller.dispose();
  if (result != null) {
    // 编辑器只对"当前查看的那天"生效;从日历进来时先切过去,避免写错天。
    if (day != state.currentDay) await state.goToDay(day);
    await state.saveJournal(result);
  }
}

class _JournalEditorPage extends StatelessWidget {
  const _JournalEditorPage({required this.title, required this.controller});

  final String title;
  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(title),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: TextField(
          controller: controller,
          autofocus: true,
          maxLines: null,
          expands: true,
          textAlignVertical: TextAlignVertical.top,
          keyboardType: TextInputType.multiline,
          style: const TextStyle(fontSize: 15.5, height: 1.65),
          decoration: const InputDecoration(
            hintText: '今天读到、想到、练到了什么',
          ),
        ),
      ),
    );
  }
}

/// 单条待办的编辑页。
///
/// 对应原子笔记里"点一条待办进编辑"的那个界面:正文直接改,
/// 底部一排动作(颜色 / 删除 / 改到别的日子),右上角完成。
///
/// 已完成的条目在这里也能打钩/取消——列表上点圆圈是快捷方式,
/// 这里才是"把这条彻底处理掉"的地方,包括删掉它。
Future<void> showTaskEditor(
  BuildContext context, {
  required Task task,
  required String day,
}) async {
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => _TaskEditorPage(task: task, day: day),
    ),
  );
}

class _TaskEditorPage extends StatefulWidget {
  const _TaskEditorPage({required this.task, required this.day});

  final Task task;
  final String day;

  @override
  State<_TaskEditorPage> createState() => _TaskEditorPageState();
}

class _TaskEditorPageState extends State<_TaskEditorPage> {
  late final _controller = TextEditingController(text: widget.task.text);
  late TaskColor _color = widget.task.color;
  late bool _done = widget.task.done;
  bool _saving = false;

  /// 这条任务已有的提醒时刻(`HH:mm`);null 表示没设。
  String? _reminderAt;

  /// 提醒只读一次,用这个标记避免 `didChangeDependencies` 反复触发时重复查库。
  bool _reminderLoaded = false;

  /// 必须在 `didChangeDependencies` 而不是 `initState` 里读 [AppScope]:
  /// 继承组件不允许在 initState 期间访问。
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reminderLoaded) return;
    _reminderLoaded = true;
    _loadReminder();
  }

  Future<void> _loadReminder() async {
    final state = AppScope.of(context);
    final reminders = await state.remindersOn(widget.day);
    final own = reminders.where((r) => r.taskId == widget.task.id).firstOrNull;
    if (!mounted || own == null) return;
    setState(() => _reminderAt = own.at);
  }

  /// 设/改/取消提醒。
  ///
  /// 走系统通知:提醒的意义在于"app 没开着也能响",应用内提示做不到这件事。
  Future<void> _setReminder() async {
    final state = AppScope.of(context);
    final current = _reminderAt;

    if (current != null) {
      // 已经有提醒:问是改时间还是取消。
      final action = await showModalBottomSheet<String>(
        context: context,
        builder: (context) => SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.schedule),
                title: const Text('改时间'),
                onTap: () => Navigator.pop(context, 'change'),
              ),
              ListTile(
                leading: const Icon(Icons.notifications_off_outlined),
                title: const Text('取消提醒'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
            ],
          ),
        ),
      );
      if (action == null || !mounted) return;
      if (action == 'remove') {
        final reminders = await state.remindersOn(widget.day);
        for (final reminder in reminders.where((r) => r.taskId == widget.task.id)) {
          await state.deleteReminder(reminder.id);
        }
        if (!mounted) return;
        setState(() => _reminderAt = null);
        return;
      }
    }

    if (!mounted) return;
    final picked = await showTimePicker(
      context: context,
      initialTime: _parseTime(current) ?? const TimeOfDay(hour: 8, minute: 0),
    );
    if (picked == null || !mounted) return;

    final at = '${picked.hour.toString().padLeft(2, '0')}:'
        '${picked.minute.toString().padLeft(2, '0')}';
    // 先清掉旧的,避免同一条任务堆出多个提醒。
    final existing = await state.remindersOn(widget.day);
    for (final reminder in existing.where((r) => r.taskId == widget.task.id)) {
      await state.deleteReminder(reminder.id);
    }
    await state.addReminder(
      task: widget.task,
      day: widget.day,
      at: at,
      note: _controller.text.trim(),
    );
    if (!mounted) return;
    setState(() => _reminderAt = at);
    await _warnIfNotificationsOff(state);
  }

  /// 通知开关关着的时候说清楚,并给一个直接去开的入口。
  ///
  /// 排程本身是成功的,但系统不会弹——不说的话用户只会觉得"设了没有用",
  /// 然后反复设、反复没用。
  Future<void> _warnIfNotificationsOff(AppState state) async {
    final enabled = await state.notificationsEnabled();
    if (enabled != false || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      SnackBar(
        content: const Text('提醒已设好,但系统通知权限没开,到点不会弹'),
        duration: const Duration(seconds: 6),
        action: SnackBarAction(
          label: '去开启',
          onPressed: () => _openNotificationSettings(),
        ),
      ),
    );
  }

  static const _settingsChannel = MethodChannel('com.xi283.yiji/app');

  Future<void> _openNotificationSettings() async {
    try {
      await _settingsChannel.invokeMethod<void>('openNotificationSettings');
    } on PlatformException {
      // 打不开就只能靠用户自己去系统设置里找,不额外打扰。
    } on MissingPluginException {
      // 同上:没有这个原生实现(桌面/测试环境)。
    }
  }

  static TimeOfDay? _parseTime(String? at) {
    if (at == null) return null;
    final parts = at.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return TimeOfDay(hour: hour, minute: minute);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  /// 保存并退出。内容清空等于删掉这条——和新增弹层的约定一致。
  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);
    final state = AppScope.of(context);
    final navigator = Navigator.of(context);

    final text = _controller.text.trim();
    if (text.isEmpty) {
      await state.deleteTaskOn(widget.day, widget.task);
    } else {
      await state.updateTaskOn(
        widget.day,
        widget.task.copyWith(text: text, color: _color, done: _done),
      );
    }
    navigator.pop();
  }

  Future<void> _delete() async {
    final state = AppScope.of(context);
    final navigator = Navigator.of(context);
    await state.deleteTaskOn(widget.day, widget.task);
    navigator.pop();
  }

  /// 把这条挪到别的日子,不离开编辑页。
  Future<void> _changeDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: parseDayKey(widget.day),
      firstDate: parseDayKey(widget.day).subtract(const Duration(days: 365)),
      lastDate: parseDayKey(widget.day).add(const Duration(days: 365)),
    );
    if (picked == null || !mounted) return;
    final state = AppScope.of(context);
    await state.moveTaskOn(widget.day, widget.task, dayKey(picked));
    if (!mounted) return;
    // 挪走之后这一条已经不在原来那天了,编辑页没有继续存在的意义。
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          onPressed: () => Navigator.pop(context),
          icon: const Icon(Icons.close),
          tooltip: '不保存',
        ),
        title: Text(shortDateLabel(widget.day)),
        titleTextStyle: TextStyle(fontSize: 15, color: textSecondary),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: const Text('完成'),
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
              child: TextField(
                controller: _controller,
                autofocus: true,
                maxLines: null,
                expands: true,
                textAlignVertical: TextAlignVertical.top,
                keyboardType: TextInputType.multiline,
                style: TextStyle(fontSize: 19, height: 1.55, color: textPrimary),
                decoration: const InputDecoration(
                  hintText: '这条任务是什么',
                  filled: false,
                  border: InputBorder.none,
                ),
              ),
            ),
          ),
          // 颜色一排直接摊开,不用再点一层选择器。
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                for (final color in TaskColor.selectable)
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: GestureDetector(
                      onTap: () => setState(() => _color = color),
                      child: AnimatedContainer(
                        duration: AppTheme.fast,
                        curve: AppTheme.easeOut,
                        width: 30,
                        height: 30,
                        decoration: BoxDecoration(
                          color: AppTheme.cardFill(color, done: false, dark: dark),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: color == _color
                                ? AppTheme.accent
                                : Colors.transparent,
                            width: 2.5,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          // 底部动作条,对应原子笔记编辑页下面那排。
          Material(
            color: dark ? AppTheme.darkSurface : AppTheme.lightSurface,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _EditorAction(
                      icon: _done ? Icons.check_circle : Icons.radio_button_unchecked,
                      label: _done ? '已完成' : '标记完成',
                      color: _done ? AppTheme.accent : textSecondary,
                      onTap: () => setState(() => _done = !_done),
                    ),
                    _EditorAction(
                      icon: _reminderAt == null
                          ? Icons.notifications_none
                          : Icons.notifications_active,
                      label: _reminderAt == null ? '提醒' : _reminderAt!,
                      color: _reminderAt == null ? textSecondary : AppTheme.accent,
                      onTap: _setReminder,
                    ),
                    _EditorAction(
                      icon: Icons.event_outlined,
                      label: '改到别的日子',
                      color: textSecondary,
                      onTap: _changeDay,
                    ),
                    _EditorAction(
                      icon: Icons.delete_outline,
                      label: '删除',
                      color: const Color(0xFFE05252),
                      onTap: _delete,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _EditorAction extends StatelessWidget {
  const _EditorAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11.5, color: color)),
          ],
        ),
      ),
    );
  }
}
