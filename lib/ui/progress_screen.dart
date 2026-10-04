import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../core/day.dart';
import '../data/data_range.dart';
import '../data/goals.dart';
import '../data/palette.dart';
import '../state/app_state.dart';
import 'prompt_dialog.dart';
import 'theme.dart';

/// 进度页:进度推进条 + AI 智能同步。
///
/// 同步的分工是刻意这样切的:
/// - AI 负责**读懂**("码字2k""码了2千字"是同一件事),这是只有模型能做好的部分;
/// - 用户负责**确认**,因为进度条是他用来判断自己有没有在推进的依据,
///   被 AI 猜错的数字污染比多看一眼更糟;
/// - 手动增删改始终可用,AI 只是省事,不是唯一入口。
class ProgressScreen extends StatelessWidget {
  const ProgressScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final goals = state.activeGoals;
    final archived = state.goals.where((g) => !g.active).toList();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 8, 8, 8),
          child: Row(
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '进度',
                    style: TextStyle(
                      fontSize: 24,
                      fontWeight: FontWeight.w700,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    goals.isEmpty ? '还没有设定目标' : '${goals.length} 个在推进',
                    style: TextStyle(fontSize: 13, color: textSecondary),
                  ),
                ],
              ),
              const Spacer(),
              // 开始新周期时用:重置进度 / 重设任务。
              PopupMenuButton<String>(
                icon: Icon(Icons.more_vert, color: textPrimary),
                tooltip: '重置',
                onSelected: (value) => _reset(context, value),
                itemBuilder: (context) => const [
                  PopupMenuItem(
                    value: 'progress',
                    child: Text('重置进度(保留任务)'),
                  ),
                  PopupMenuItem(
                    value: 'tasks',
                    child: Text('重设任务(保留进度记录)'),
                  ),
                ],
              ),
              IconButton(
                onPressed: () => _createGoal(context),
                icon: Icon(Icons.add_circle_outline, color: textPrimary),
                tooltip: '新建目标',
              ),
              _SyncButton(
                pending: state.pendingSyncCount,
                busy: state.matching,
                onTap: () => _sync(context),
              ),
            ],
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppTheme.pagePadding,
              0,
              AppTheme.pagePadding,
              120,
            ),
            children: [
              if (goals.isEmpty)
                _EmptyHint(onCreate: () => _createGoal(context))
              else
                for (final goal in goals)
                  _GoalCard(
                    goal: goal,
                    dark: dark,
                    onAdd: () => _addManual(context, goal),
                    onHistory: () => _showHistory(context, goal),
                    onEdit: () => _editGoal(context, goal),
                    onArchive: () => state.archiveGoal(goal),
                    onDelete: () => state.deleteGoal(goal),
                  ),
              if (archived.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  '已归档',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                    color: textSecondary,
                  ),
                ),
                const SizedBox(height: 8),
                for (final goal in archived)
                  _ArchivedRow(
                    goal: goal,
                    dark: dark,
                    onRestore: () => state.archiveGoal(goal),
                  ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  /// 选一段日期,让 AI 读这段时间的已完成待办。
  ///
  /// 以前写死"本周":攒两三周没整理的人一次只能整理一周,剩下的永远读不到。
  /// 用户明确要求过"需增加进度用户选取范围(比如用户自选读取整理多久日期之类的信息)"。
  Future<void> _sync(BuildContext context) async {
    final state = AppScope.of(context);
    if (!state.aiConfig.isUsable) {
      _toast(context, '还没填 API key,去「我的」里填一下');
      return;
    }

    final range = await showModalBottomSheet<DataRange>(
      context: context,
      useSafeArea: true,
      builder: (_) => const _SyncRangeSheet(),
    );
    if (range == null || !context.mounted) return;

    // 用**带流式输出**的对话框等结果,而不是一个转圈。
    //
    // 用户明确要求过"ai 的流式输出 ui(而不是现在的转圈等待)"。进度同步
    // 要读一批待办、再等模型吐一段 JSON,几秒到十几秒;转圈只说明"在忙",
    // 看不出它在干什么,也分不清是卡住了还是真的在跑。
    //
    // 让**对话框自己发请求**:先 pop 请求的写法在快客户端下会变成
    // "请求已完成 → 对话框还没画出来就要关掉",测试里连一帧都抓不到。
    final count = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _SyncProgressDialog(range: range),
    );
    if (!context.mounted || count == null) return;
    if (count == 0) {
      _toast(context, '${range.label}里没有能对上目标的数字');
      return;
    }
    await _reviewSuggestions(context);
  }

  /// 展示 AI 的建议,逐条可勾选,确认后才落库。
  ///
  /// 两类建议一起给:匹配到已有推进条的(加进度),和**建议新建目标的**
  /// (做完的事里有一些还没有被追踪)。后者是用户最需要的那一步——
  /// 他往往是先做事、后想起来要追踪,让他自己去建等于把活推回给他。
  Future<void> _reviewSuggestions(BuildContext context) async {
    final state = AppScope.of(context);
    final accepted = await showModalBottomSheet<_ReviewResult>(
      context: context,
      isScrollControlled: true,
      // 让弹层自己避开状态栏/刘海:有的 ROM 上不加这个,顶部会被遮住。
      useSafeArea: true,
      builder: (_) => _SuggestionSheet(
        suggestions: state.suggestions,
        newGoals: state.newGoalSuggestions,
      ),
    );
    if (accepted == null) {
      // 只是关掉面板,不要把结果删掉。
      // 这份建议是一次付费 API 调用的产物,误触遮罩/下拉一下就没了的话,
      // 只能再花钱重跑一遍。留着,下次点同步时被新结果覆盖即可。
      return;
    }

    // 先建目标再记进度:新建的那些要把这次已完成的量一并记进去。
    final created = await state.confirmNewGoals(accepted.newGoals);
    final applied = await state.confirmSuggestions(accepted.matches);
    // 用户看过并确认过这一批了,角标就该掉——**包括他一条都没勾的那些**:
    // 「取快递」这类匹配不上推进条的事,处理结果就是"没有结果"。
    // 只算勾选的,角标会永远挂着(用户报的就是这个)。
    await state.markReviewedSuggestionsSynced();
    if (!context.mounted) return;
    final parts = [
      if (applied > 0) '推进了 $applied 项',
      if (created > 0) '新建了 $created 个目标',
    ];
    _toast(context, parts.isEmpty ? '没有改动' : parts.join(','));
  }

  Future<void> _addManual(BuildContext context, Goal goal) async {
    final state = AppScope.of(context);
    final result = await showModalBottomSheet<(double, String)>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ManualProgressSheet(goal: goal),
    );
    if (result == null) return;
    await state.addProgress(goal, result.$1, result.$2);
  }

  /// 重置进度 / 重设任务。
///
/// 两个都是破坏性操作,所以都先说清"会删什么、会留什么",再让用户确认。
/// 只写"确定吗"是不够的——他不知道代价是什么,只能赌。
Future<void> _reset(BuildContext context, String what) async {
  final state = AppScope.of(context);
  final progress = what == 'progress';
  final ok = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(progress ? '重置进度?' : '重设任务?'),
      content: Text(
        progress
            ? '所有推进条的当前值会归零,推进记录被清空。\n'
                '**待办和完成标记都留着**——只是重新开始算推进。'
            : '所有待办会被删掉(包括完成标记和提醒)。\n'
                '**进度记录保留**——那是已经发生的推进历史,不会跟着消失。',
        style: const TextStyle(fontSize: 13.5, height: 1.6),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(progress ? '重置进度' : '重设任务'),
        ),
      ],
    ),
  );
  if (ok != true) return;
  if (progress) {
    await state.resetProgress();
  } else {
    await state.resetTasks();
  }
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(
      content: Text(progress ? '进度已归零,任务还在' : '任务已清空,进度记录保留'),
    ),
  );
}

Future<void> _createGoal(BuildContext context) async {
    final state = AppScope.of(context);
    final draft = await showModalBottomSheet<GoalDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => const _GoalEditorSheet(),
    );
    if (draft == null) return;
    await state.createGoal(
      title: draft.title,
      unit: draft.unit,
      target: draft.target,
      period: draft.period,
      direction: draft.direction,
      color: draft.color,
    );
  }

  Future<void> _editGoal(BuildContext context, Goal goal) async {
    final state = AppScope.of(context);
    final draft = await showModalBottomSheet<GoalDraft>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _GoalEditorSheet(goal: goal),
    );
    if (draft == null) return;
    await state.updateGoal(
      goal.copyWith(
        title: draft.title,
        unit: draft.unit,
        target: draft.target,
        period: draft.period,
        direction: draft.direction,
        color: draft.color,
        // 用户把"目标值"清空时,draft.target 是 null——那意味着他真的想让它
        // 变回一条纯推进条,而不是"这次不改目标值"。
        clear: {if (draft.target == null) GoalField.target},
      ),
    );
  }

  Future<void> _showHistory(BuildContext context, Goal goal) async {
    final state = AppScope.of(context);
    final entries = await state.progressHistory(goal);
    if (!context.mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _HistorySheet(goal: goal, entries: entries),
    );
  }

  static void _toast(BuildContext context, String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }
}

/// 进度条同步按钮。带未同步条数的角标——没有角标时他根本不会想起来点。
/// 选同步范围:让 AI 读多久的已完成待办。
///
/// 以前写死"本周"。攒了两三周没整理的人一次只能整理一周,剩下那些永远读不到,
/// 而且待同步角标会一直挂着——他明明有内容可同步,却被告知"没有能对上的数字"。
/// 用户明确要求过"需增加进度用户选取范围(比如用户自选读取整理多久日期之类的信息)"。
class _SyncRangeSheet extends StatelessWidget {
  const _SyncRangeSheet();

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    final options = <(String, DataRange)>[
      // 「今天」放第一位:用户明确要过"要能自选,且增加'今天'"。
      ('今天', DataRange.between(todayKey(), todayKey())),
      ('本周', DataRange.between(mondayOf(todayKey()), sundayOf(todayKey()))),
      ('近 7 天', DataRange.lastDays(7)),
      ('近 14 天', DataRange.lastDays(14)),
      ('近 30 天', DataRange.lastDays(30)),
      ('近 90 天', DataRange.lastDays(90)),
    ];

    return SafeArea(
      child: SingleChildScrollView(
        // 档位 + 标题在小屏上会超出弹层的最大高度(实测溢出 67px),
        // 包一层滚动比调高度稳:字号或档位以后变了也不会再撞。
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '让 AI 读多久的记录?',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                '只读这段时间里还没整理过的已完成待办。',
                style: TextStyle(fontSize: 12.5, height: 1.5, color: textSecondary),
              ),
              const SizedBox(height: 8),
              // 自选任意起止日期。固定档位总有覆盖不到的情况
              // ("8 月 1 日到 8 月 20 日"这种),用户明确要求能自己选。
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                leading: Icon(Icons.date_range, size: 20, color: AppTheme.accent),
                title: Text(
                  '自选起止日期',
                  style: TextStyle(fontSize: 15, color: textPrimary),
                ),
                subtitle: Text(
                  '在日历上点两个日期',
                  style: TextStyle(fontSize: 12, color: textSecondary),
                ),
                onTap: () async {
                  final picked = await showDateRangePicker(
                    context: context,
                    firstDate: DateTime(2020),
                    lastDate: DateTime(2100),
                    helpText: '选择要读的日期范围',
                    saveText: '就用这段',
                    initialDateRange: DateTimeRange(
                      start: DateTime.parse(todayKey()),
                      end: DateTime.parse(todayKey()),
                    ),
                  );
                  if (picked == null || !context.mounted) return;
                  Navigator.pop(
                    context,
                    DataRange.between(
                      dayKey(picked.start),
                      dayKey(picked.end),
                    ),
                  );
                },
              ),
              const Divider(height: 8),
              for (final (label, range) in options)
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title:
                      Text(label, style: TextStyle(fontSize: 15, color: textPrimary)),
                  subtitle: Text(
                    '${shortDateLabel(range.startDay)} - ${shortDateLabel(range.endDay)}',
                    style: TextStyle(fontSize: 12, color: textSecondary),
                  ),
                  onTap: () => Navigator.pop(context, range),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 同步中的流式对话框。
///
/// 展示模型**已经吐出来的原文**,而不是一个转圈。它读的是编号化的 JSON,
/// 肉眼看当然不好看,但"能看到它在往外吐东西"本身就是用户要的信息:
/// 证明它在跑、没有卡死。用户明确要求过"用流式输出而不是转圈等待"。
///
/// 请求由它自己发起、结束后自己 pop:交给外面的先 pop 后请求,快客户端下
/// 会变成"刚开就要关",一帧都留不住。
///
/// 用等宽小字、低对比色,让它像一段日志而不是正文——它不是给用户读的内容。
class _SyncProgressDialog extends StatefulWidget {
  const _SyncProgressDialog({required this.range});

  final DataRange range;

  @override
  State<_SyncProgressDialog> createState() => _SyncProgressDialogState();
}

class _SyncProgressDialogState extends State<_SyncProgressDialog> {
  @override
  void initState() {
    super.initState();
    // 排在下一帧之后再发:让对话框先画出来,用户才看得到"正在读"。
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    final state = AppScope.of(context);
    final navigator = Navigator.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final count = await state.requestProgressSuggestions(range: widget.range);
      if (!mounted) return;
      navigator.pop(count);
    } on Exception catch (error) {
      if (!mounted) return;
      navigator.pop(0);
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return AlertDialog(
      title: Row(
        children: [
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 10),
          Text('正在读你的记录', style: TextStyle(fontSize: 16, color: textPrimary)),
        ],
      ),
      content: SizedBox(
        // 给定宽高:内容在长,但对话框**不许跟着变大**,否则每来一个字
        // 整个框就抖一下(就是聊天页当初那个毛病)。
        width: 300,
        height: 132,
        child: AnimatedBuilder(
          animation: state.streamTick,
          builder: (context, _) => SingleChildScrollView(
            reverse: true,
            child: Text(
              state.syncProgress.isEmpty ? '正在等第一条结果…' : state.syncProgress,
              style: TextStyle(
                fontSize: 11.5,
                height: 1.45,
                color: textSecondary,
                fontFamily: 'monospace',
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SyncButton extends StatelessWidget {
  const _SyncButton({required this.pending, required this.busy, required this.onTap});

  final int pending;
  final bool busy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        IconButton(
          onPressed: busy ? null : onTap,
          icon: busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          tooltip: '让 AI 同步进度',
        ),
        if (pending > 0 && !busy)
          Positioned(
            right: 4,
            top: 4,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: const Color(0xFFE05252),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Text(
                '$pending',
                style: const TextStyle(
                  fontSize: 10,
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 一个目标卡片:进度条 + 还差多少 + 手动加进度入口。
class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.dark,
    required this.onAdd,
    required this.onHistory,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
  });

  final Goal goal;
  final bool dark;
  final VoidCallback onAdd;
  final VoidCallback onHistory;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final fill = AppTheme.cardFill(goal.color, done: false, dark: dark);

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onHistory,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        goal.title,
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                    ),
                    if (goal.reached)
                      const Padding(
                        padding: EdgeInsets.only(right: 2),
                        child: Icon(Icons.check_circle, size: 18, color: AppTheme.accent),
                      ),
                    IconButton(
                      onPressed: onAdd,
                      icon: Icon(Icons.add, size: 20, color: textSecondary),
                      tooltip: '手动加进度',
                      visualDensity: VisualDensity.compact,
                    ),
                    _MoreMenu(
                      color: textSecondary,
                      onEdit: onEdit,
                      onArchive: onArchive,
                      onDelete: onDelete,
                      archived: !goal.active,
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                // 有目标值才谈得上"完成多少";没有目标值时就只报已推进的量。
                if (goal.hasTarget)
                  Row(
                    children: [
                      Text(
                        goal.progressLabel,
                        style: TextStyle(fontSize: 13, color: textSecondary),
                      ),
                      const Spacer(),
                      Text(
                        '${(goal.ratio * 100).round()}%',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: goal.reached ? AppTheme.accent : textSecondary,
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    goal.progressLabel,
                    style: TextStyle(fontSize: 13, color: textSecondary),
                  ),
                const SizedBox(height: 8),
                _ProgressBar(goal: goal, color: fill),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Text(
                      goal.period.label,
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                    const Spacer(),
                    Text(
                      // 没有目标值时不写"还差多少"——没有终点就没有"还差"。
                      !goal.hasTarget
                          ? '未设目标值'
                          : (goal.reached
                              ? '已完成'
                              : '还差 ${Goal.formatAmount(goal.remaining)} ${goal.unit}'),
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 进度条。
///
/// 220ms 宽度过渡:这是"推进了多少"的主要视觉反馈,
/// 从旧值滑到新值比直接跳过去更能让人感到"确实往前走了"。
/// 用 ease-out 而不是线性——结束要收得住。
class _ProgressBar extends StatelessWidget {
  const _ProgressBar({required this.goal, required this.color});

  final Goal goal;
  final Color color;

  /// 没有目标值时的推进条填充比例。
  ///
  /// 累计量越多、条越长,但**永远不填满**:没有终点就没有"到顶"这回事。
  /// 用对数增长,这样几十和几千的差距在视觉上都能看出来,
  /// 而不是第一周就把条填满、后面再也看不出变化。
  static const _noTargetMaxFill = 0.85;

  double get _fill {
    if (goal.hasTarget) return goal.ratio;
    if (goal.current <= 0) return 0;
    // log(1+current) / (log(1+current)+1):从 0 单调增到 1,前段涨得快、后段放缓。
    final scaled = log(goal.current + 1) / (log(goal.current + 1) + 1);
    return (scaled * _noTargetMaxFill).clamp(0.0, _noTargetMaxFill);
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final track = dark ? const Color(0xFF2A2D33) : const Color(0xFFEDEEF1);
    final fill = _fill;

    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return Stack(
          children: [
            Container(
              height: 9,
              decoration: BoxDecoration(
                color: track,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
            AnimatedContainer(
              duration: AppTheme.medium,
              curve: AppTheme.easeOut,
              height: 9,
              width: (width * fill).clamp(0.0, width),
              decoration: BoxDecoration(
                color: goal.reached ? AppTheme.accent : color,
                borderRadius: BorderRadius.circular(5),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _MoreMenu extends StatelessWidget {
  const _MoreMenu({
    required this.color,
    required this.onEdit,
    required this.onArchive,
    required this.onDelete,
    required this.archived,
  });

  final Color color;
  final VoidCallback onEdit;
  final VoidCallback onArchive;
  final VoidCallback onDelete;
  final bool archived;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<String>(
      icon: Icon(Icons.more_vert, size: 20, color: color),
      tooltip: '更多',
      onSelected: (value) => switch (value) {
        'edit' => onEdit(),
        'archive' => onArchive(),
        'delete' => onDelete(),
        _ => null,
      },
      itemBuilder: (context) => [
        const PopupMenuItem(value: 'edit', child: Text('编辑目标')),
        PopupMenuItem(value: 'archive', child: Text(archived ? '取消归档' : '归档')),
        const PopupMenuItem(value: 'delete', child: Text('删除目标与记录')),
      ],
    );
  }
}

class _ArchivedRow extends StatelessWidget {
  const _ArchivedRow({required this.goal, required this.dark, required this.onRestore});

  final Goal goal;
  final bool dark;
  final VoidCallback onRestore;

  @override
  Widget build(BuildContext context) {
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Expanded(
            child: Text(
              goal.title,
              style: TextStyle(fontSize: 14, color: textSecondary),
            ),
          ),
          TextButton(onPressed: onRestore, child: const Text('恢复')),
        ],
      ),
    );
  }
}

class _EmptyHint extends StatelessWidget {
  const _EmptyHint({required this.onCreate});

  final VoidCallback onCreate;

  @override
  Widget build(BuildContext context) {
    final textSecondary = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 44),
      child: Column(
        children: [
          Icon(Icons.trending_up, size: 46, color: textSecondary.withValues(alpha: 0.5)),
          const SizedBox(height: 14),
          Text(
            '还没有进度推进条',
            style: TextStyle(fontSize: 15, color: textSecondary),
          ),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onCreate,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建一个目标'),
            style: FilledButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
          ),
        ],
      ),
    );
  }
}

/// 用户在确认面板上勾出来的结果。
class _ReviewResult {
  const _ReviewResult({required this.matches, required this.newGoals});

  final List<ProgressSuggestion> matches;
  final List<NewGoalSuggestion> newGoals;
}

/// AI 建议的确认面板:逐条可勾选,理由可见。
///
/// 把"为什么算这么多"显示出来是刻意的:他要能一眼判断 AI 有没有理解错,
/// 而不是盲点确认。
///
/// 分两组:上面是"算进已有推进条",下面是"这些事还没有被追踪,要不要建目标"。
/// 后者单独一块并说明白会新建什么,因为它的后果比加一条进度大。
class _SuggestionSheet extends StatefulWidget {
  const _SuggestionSheet({
    required this.suggestions,
    this.newGoals = const [],
  });

  final List<ProgressSuggestion> suggestions;
  final List<NewGoalSuggestion> newGoals;

  @override
  State<_SuggestionSheet> createState() => _SuggestionSheetState();
}

class _SuggestionSheetState extends State<_SuggestionSheet> {
  late final Set<int> _accepted = {
    for (var i = 0; i < widget.suggestions.length; i++) i,
  };

  /// 建议新建的目标默认**全选**:这正是用户想要的"帮我补上",
  /// 而且它比"改一条已有进度"的后果更可见(会多出一张卡片),容易发现。
  late final Set<int> _acceptedNew = {
    for (var i = 0; i < widget.newGoals.length; i++) i,
  };

  int get _total => _accepted.length + _acceptedNew.length;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    // 用 DraggableScrollableSheet 而不是"SafeArea + Column(min) + Flexible"。
    //
    // 后者有个必然的坑:Column 取最小高度,里面的 ListView 只受 maxHeight 约束,
    // 于是条目一多,整个弹层就长到超过屏幕——标题被顶到状态栏底下(用户截图里
    // "AI 读到的推"被时间和信号遮住就是这么来的),底部的确认按钮也被推出去。
    // 给定高度 + 内部滚动,标题和按钮就永远在看得见的位置。
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'AI 读到的推进',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '确认后才计入,算错的取消勾选。',
                    style: TextStyle(
                      fontSize: 12.5,
                      height: 1.5,
                      color: textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: ListView(
                controller: scrollController,
                padding: const EdgeInsets.symmetric(horizontal: 16),
                children: [
                  for (var i = 0; i < widget.suggestions.length; i++)
                    _SuggestionRow(
                      suggestion: widget.suggestions[i],
                      selected: _accepted.contains(i),
                      dark: dark,
                      onToggle: () => setState(() {
                        if (!_accepted.remove(i)) _accepted.add(i);
                      }),
                    ),
                  // 还没有被追踪的那些。放在下面并单独起一个标题:
                  // 它的后果是"多出一张卡片",和上面那组不是一回事。
                  if (widget.newGoals.isNotEmpty) ...[
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Icon(Icons.add_circle_outline, size: 16, color: textSecondary),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            '这些事还没在追踪,要不要补上?',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '勾选的会新建一条推进条,并把这次完成的数量一起记进去。',
                      style: TextStyle(fontSize: 12.5, height: 1.5, color: textSecondary),
                    ),
                    const SizedBox(height: 8),
                    for (var i = 0; i < widget.newGoals.length; i++)
                      _NewGoalRow(
                        suggestion: widget.newGoals[i],
                        selected: _acceptedNew.contains(i),
                        dark: dark,
                        onToggle: () => setState(() {
                          if (!_acceptedNew.remove(i)) _acceptedNew.add(i);
                        }),
                      ),
                  ],
                ],
              ),
            ),
            // 按钮固定在底部:滚多少内容都不用去找它。
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text('都不算'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: _total == 0
                          ? null
                          : () => Navigator.pop(
                                context,
                                _ReviewResult(
                                  matches: [
                                    for (var i = 0;
                                        i < widget.suggestions.length;
                                        i++)
                                      if (_accepted.contains(i))
                                        widget.suggestions[i],
                                  ],
                                  newGoals: [
                                    for (var i = 0;
                                        i < widget.newGoals.length;
                                        i++)
                                      if (_acceptedNew.contains(i))
                                        widget.newGoals[i],
                                  ],
                                ),
                              ),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: Text('确认这 $_total 项'),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SuggestionRow extends StatelessWidget {
  const _SuggestionRow({
    required this.suggestion,
    required this.selected,
    required this.dark,
    required this.onToggle,
  });

  final ProgressSuggestion suggestion;
  final bool selected;
  final bool dark;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 20,
                  color: selected ? AppTheme.accent : textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${suggestion.goalTitle}  ${suggestion.amountLabel}',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '来自待办:${suggestion.taskText}',
                        style: TextStyle(fontSize: 12.5, color: textSecondary),
                      ),
                      if (suggestion.reason.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          suggestion.reason,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: textSecondary.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 一条"建议新建目标"的勾选项。
///
/// 与进度建议分开画:它左边是个加号而不是对勾,颜色也不同,
/// 让人一眼看出"这一条会新建东西,而不是记一笔账"。
class _NewGoalRow extends StatelessWidget {
  const _NewGoalRow({
    required this.suggestion,
    required this.selected,
    required this.dark,
    required this.onToggle,
  });

  final NewGoalSuggestion suggestion;
  final bool selected;
  final bool dark;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onToggle,
          child: Padding(
            padding: const EdgeInsets.all(13),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  selected ? Icons.check_box : Icons.check_box_outline_blank,
                  size: 20,
                  color: selected ? AppTheme.accent : textSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '新建「${suggestion.title}」',
                        style: TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        suggestion.label,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: AppTheme.accent,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        '来自待办:${suggestion.taskText}',
                        style: TextStyle(fontSize: 12.5, color: textSecondary),
                      ),
                      if (suggestion.reason.isNotEmpty) ...[
                        const SizedBox(height: 3),
                        Text(
                          suggestion.reason,
                          style: TextStyle(
                            fontSize: 12,
                            height: 1.4,
                            color: textSecondary.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 手动加进度的面板。
class _ManualProgressSheet extends StatefulWidget {
  const _ManualProgressSheet({required this.goal});

  final Goal goal;

  @override
  State<_ManualProgressSheet> createState() => _ManualProgressSheetState();
}

class _ManualProgressSheetState extends State<_ManualProgressSheet> {
  final _amount = TextEditingController();
  final _note = TextEditingController();

  @override
  void dispose() {
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Padding(
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
            '推进「${widget.goal.title}」',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 3),
          Text(
            '当前 ${widget.goal.progressLabel}',
            style: TextStyle(fontSize: 12.5, color: textSecondary),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: 16),
            decoration: InputDecoration(
              labelText: '加多少(${widget.goal.unit})',
              hintText: '2000',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _note,
            style: const TextStyle(fontSize: 15),
            decoration: const InputDecoration(
              labelText: '备注(可留空)',
              hintText: '下午码字',
            ),
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  final amount = double.tryParse(_amount.text.trim());
                  if (amount == null || amount <= 0) return;
                  Navigator.pop(context, (amount, _note.text.trim()));
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: const Text('加上去'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 进度明细:能看到每一次推进是哪来的,也能删掉算错的那条。
class _HistorySheet extends StatefulWidget {
  const _HistorySheet({required this.goal, required this.entries});

  final Goal goal;
  final List<ProgressEntry> entries;

  @override
  State<_HistorySheet> createState() => _HistorySheetState();
}

class _HistorySheetState extends State<_HistorySheet> {
  late List<ProgressEntry> _entries = List.of(widget.entries);

  /// 表头用的目标。
  ///
  /// 不能一直用 `widget.goal`:改完一条推进量之后,进度值已经变了,
  /// 而传进来的那个 Goal 是打开弹层那一刻的快照——表头会一直写着旧数字。
  /// 所以每次刷新都从当前状态里按 id 重新取一份。
  Goal get goal {
    final current = AppScope.of(context).goals.where((g) => g.id == widget.goal.id);
    return current.isEmpty ? widget.goal : current.first;
  }

  /// 重新读一遍明细,顺便让表头跟上。
  Future<void> _refresh() async {
    final state = AppScope.of(context);
    final refreshed = await state.progressHistory(goal);
    if (!mounted) return;
    setState(() => _entries = refreshed);
  }

  /// 改一条已经记下的推进。
  ///
  /// AI 判断错了(把不相干的事算进来,或者数字读错)时,用户要能当场改对,
  /// 而不是只能删掉重来——手动修正正是"让 AI 自己判断"这个方案成立的前提。
  Future<void> _editEntry(ProgressEntry entry) async {
    final state = AppScope.of(context);
    final value = await showAmountDialog(
      context,
      initial: Goal.formatAmount(entry.amount),
      unit: goal.unit,
    );
    if (value == null || value <= 0) return;

    await state.updateProgressEntry(entry.id, amount: value);
    await _refresh();
  }

  Future<void> _deleteEntry(ProgressEntry entry) async {
    final state = AppScope.of(context);
    await state.deleteProgressEntry(entry.id);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final entries = _entries;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              goal.title,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              '${goal.progressLabel} · 共 ${entries.length} 条记录',
              style: TextStyle(fontSize: 12.5, color: textSecondary),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: entries.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.symmetric(vertical: 28),
                      child: Center(
                        child: Text(
                          '还没有推进记录',
                          style: TextStyle(fontSize: 14, color: textSecondary),
                        ),
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: entries.length,
                      itemBuilder: (context, index) {
                        final entry = entries[index];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          // 点一下就改数字:AI 看错了要能当场纠正。
                          onTap: () => _editEntry(entry),
                          title: Text(
                            '+${Goal.formatAmount(entry.amount)} ${goal.unit}',
                            style: TextStyle(
                              fontSize: 14.5,
                              fontWeight: FontWeight.w600,
                              color: textPrimary,
                            ),
                          ),
                          subtitle: Text(
                            [
                              shortDate(entry.day),
                              if (entry.note.isNotEmpty) entry.note,
                              if (entry.fromAi) 'AI 识别',
                            ].join(' · '),
                            style: TextStyle(fontSize: 12.5, color: textSecondary),
                          ),
                          trailing: IconButton(
                            icon: Icon(Icons.delete_outline, size: 20, color: textSecondary),
                            tooltip: '删掉这条',
                            onPressed: () => _deleteEntry(entry),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String shortDate(String day) {
    final parts = day.split('-');
    return '${int.parse(parts[1])}月${int.parse(parts[2])}日';
  }
}

/// 目标编辑器直接复用 `goals.dart` 里的 [GoalDraft]:
/// 那里同一份结构还用于 AI 拆字段,两处各写一份必然漂开。

/// 新建/编辑目标的表单。
class _GoalEditorSheet extends StatefulWidget {
  const _GoalEditorSheet({this.goal});

  final Goal? goal;

  @override
  State<_GoalEditorSheet> createState() => _GoalEditorSheetState();
}

class _GoalEditorSheetState extends State<_GoalEditorSheet> {
  late final _title = TextEditingController(text: widget.goal?.title ?? '');
  late final _unit = TextEditingController(text: widget.goal?.unit ?? '');
  late final _target = TextEditingController(
    text: widget.goal?.hasTarget == true
        ? Goal.formatAmount(widget.goal!.target!)
        : '',
  );

  /// 自然语言描述。填完由 AI 拆成下面那些字段。
  final _describe = TextEditingController();
  bool _parsing = false;
  String? _aiError;

  late GoalPeriod _period = widget.goal?.period ?? GoalPeriod.weekly;
  late GoalDirection _direction = widget.goal?.direction ?? GoalDirection.increase;
  late TaskColor _color = widget.goal?.color ?? TaskColor.blue;

  @override
  void dispose() {
    _title.dispose();
    _unit.dispose();
    _target.dispose();
    _describe.dispose();
    super.dispose();
  }

  /// 让 AI 把一句话拆成结构化字段。
  ///
  /// 拆完的结果**只用来预填表单**,不直接建目标:AI 理解错了用户还能当场改。
  Future<void> _parseWithAi() async {
    final text = _describe.text.trim();
    if (text.isEmpty || _parsing) return;

    final state = AppScope.of(context);
    if (!state.aiConfig.isUsable) {
      setState(() => _aiError = '还没填 API key');
      return;
    }

    setState(() {
      _parsing = true;
      _aiError = null;
    });
    try {
      final draft = await state.parseGoal(text);
      if (!mounted) return;
      if (draft == null) {
        setState(() => _aiError = '没看懂,可以直接在下面填');
        return;
      }
      setState(() {
        _title.text = draft.title;
        _target.text = draft.target == null ? '' : Goal.formatAmount(draft.target!);
        _unit.text = draft.unit;
        _period = draft.period;
        _direction = draft.direction;
        _color = draft.color;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() => _aiError = error.toString());
    } finally {
      if (mounted) setState(() => _parsing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final isEdit = widget.goal != null;

    // 用 DraggableScrollableSheet 而不是裸的 SingleChildScrollView:
    // 后者会让内容一路顶到屏幕最上方(字段一多、键盘再一挤就积攒到顶部),
    // 这个弹层字段不少,必须给它一个固定的、可拖动的容器。
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.of(context).viewInsets.bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.78,
        minChildSize: 0.45,
        maxChildSize: 0.94,
        builder: (context, scrollController) => Column(
          children: [
            // 抓手:让"这是可以往下拖的"看得见。
            Container(
              margin: const EdgeInsets.only(top: 10, bottom: 4),
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: textSecondary.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            Expanded(
              child: SingleChildScrollView(
                controller: scrollController,
                padding: const EdgeInsets.fromLTRB(18, 10, 18, 18),
                child: _form(context, isEdit, textPrimary, textSecondary, dark),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _form(
    BuildContext context,
    bool isEdit,
    Color textPrimary,
    Color textSecondary,
    bool dark,
  ) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
          Text(
            isEdit ? '编辑目标' : '新建目标',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w600,
              color: textPrimary,
            ),
          ),
          const SizedBox(height: 12),
          // 用自然语言描述,AI 帮你填下面的字段。
          // 这是主要的建法:不用先想清楚"单位填什么",说人话就行。
          if (!isEdit) ...[
            TextField(
              controller: _describe,
              autofocus: true,
              style: const TextStyle(fontSize: 15.5),
              onSubmitted: (_) => _parseWithAi(),
              decoration: InputDecoration(
                hintText: '说一句就行,比如「每周跑3次」',
                suffixIcon: IconButton(
                  onPressed: _parsing ? null : _parseWithAi,
                  tooltip: '让 AI 帮我填',
                  icon: _parsing
                      ? const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 20),
                ),
              ),
            ),
            if (_aiError != null)
              Padding(
                padding: const EdgeInsets.only(top: 6, left: 4),
                child: Text(
                  _aiError!,
                  style: const TextStyle(fontSize: 12, color: Color(0xFFE05252)),
                ),
              ),
            const SizedBox(height: 18),
            Row(
              children: [
                Expanded(child: Divider(color: textSecondary.withValues(alpha: 0.3))),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(
                    '也可以直接填',
                    style: TextStyle(fontSize: 12, color: textSecondary),
                  ),
                ),
                Expanded(child: Divider(color: textSecondary.withValues(alpha: 0.3))),
              ],
            ),
            const SizedBox(height: 14),
          ],
          TextField(
            controller: _title,
            autofocus: isEdit,
            style: const TextStyle(fontSize: 16),
            decoration: const InputDecoration(
              labelText: '推进什么',
              hintText: '随便什么都行:跑步、读书、背单词、早睡……',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _target,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  style: const TextStyle(fontSize: 16),
                  decoration: const InputDecoration(
                    labelText: '目标值',
                    hintText: '想推进到多少',
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _unit,
                  style: const TextStyle(fontSize: 16),
                  decoration: const InputDecoration(
                    labelText: '单位(可留空)',
                    hintText: '次',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text('周期', style: TextStyle(fontSize: 12.5, color: textSecondary)),
          const SizedBox(height: 6),
          SegmentedButton<GoalPeriod>(
            segments: [
              for (final period in GoalPeriod.values)
                ButtonSegment(value: period, label: Text(period.label)),
            ],
            selected: {_period},
            onSelectionChanged: (set) => setState(() => _period = set.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 14),
          Text('方向', style: TextStyle(fontSize: 12.5, color: textSecondary)),
          const SizedBox(height: 6),
          SegmentedButton<GoalDirection>(
            segments: [
              for (final direction in GoalDirection.values)
                ButtonSegment(value: direction, label: Text(direction.label)),
            ],
            selected: {_direction},
            onSelectionChanged: (set) => setState(() => _direction = set.first),
            showSelectedIcon: false,
          ),
          const SizedBox(height: 14),
          Text('颜色', style: TextStyle(fontSize: 12.5, color: textSecondary)),
          const SizedBox(height: 8),
          Row(
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
                          color: color == _color ? AppTheme.accent : Colors.transparent,
                          width: 2.5,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  // 只有"推进什么"是必填的。目标值留空完全合法——
                  // 很多事情一开始根本不知道该推进到多少,那时它只是一条推进记录。
                  if (_title.text.trim().isEmpty) return;
                  final target = double.tryParse(_target.text.trim());
                  Navigator.pop(
                    context,
                    GoalDraft(
                      title: _title.text.trim(),
                      // 单位也可以留空。
                      unit: _unit.text.trim(),
                      // 目标值为空或非法时传 null,建出来的就是一条纯推进条。
                      target: (target != null && target > 0) ? target : null,
                      period: _period,
                      direction: _direction,
                      color: _color,
                    ),
                  );
                },
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 12),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
                child: Text(isEdit ? '保存' : '建好'),
              ),
            ],
          ),
        ],
    );
  }
}
