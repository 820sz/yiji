import 'package:flutter/material.dart';

import '../data/goals.dart';
import '../data/palette.dart';
import '../state/app_state.dart';
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

  /// 让 AI 读本周已完成的待办,给出建议后交给用户确认。
  Future<void> _sync(BuildContext context) async {
    final state = AppScope.of(context);
    if (!state.aiConfig.isUsable) {
      _toast(context, '还没填 API key,去「我的」里填一下');
      return;
    }
    if (state.activeGoals.isEmpty) {
      _toast(context, '先建一个目标');
      return;
    }
    try {
      final count = await state.requestProgressSuggestions();
      if (!context.mounted) return;
      if (count == 0) {
        _toast(context, '本周完成的待办里没有能对上目标的数字');
        return;
      }
      await _reviewSuggestions(context);
    } on Exception catch (error) {
      if (!context.mounted) return;
      _toast(context, error.toString());
    }
  }

  /// 展示 AI 的建议,逐条可勾选,确认后才落库。
  Future<void> _reviewSuggestions(BuildContext context) async {
    final state = AppScope.of(context);
    final accepted = await showModalBottomSheet<List<ProgressSuggestion>>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _SuggestionSheet(suggestions: state.suggestions),
    );
    if (accepted == null) {
      state.dismissSuggestions();
      return;
    }
    final applied = await state.confirmSuggestions(accepted);
    if (!context.mounted) return;
    _toast(context, '推进了 $applied 项');
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

  Future<void> _createGoal(BuildContext context) async {
    final state = AppScope.of(context);
    final draft = await showModalBottomSheet<_GoalDraft>(
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
    final draft = await showModalBottomSheet<_GoalDraft>(
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
                ),
                const SizedBox(height: 8),
                _ProgressBar(ratio: goal.ratio, color: fill, reached: goal.reached),
                const SizedBox(height: 7),
                Row(
                  children: [
                    Text(
                      goal.period.label,
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                    const Spacer(),
                    Text(
                      goal.reached
                          ? '已完成'
                          : '还差 ${Goal.formatAmount(goal.remaining)} ${goal.unit}',
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
  const _ProgressBar({required this.ratio, required this.color, required this.reached});

  final double ratio;
  final Color color;
  final bool reached;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final track = dark ? const Color(0xFF2A2D33) : const Color(0xFFEDEEF1);

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
              width: (width * ratio).clamp(0.0, width),
              decoration: BoxDecoration(
                color: reached ? AppTheme.accent : color,
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

/// AI 建议的确认面板:逐条可勾选,理由可见。
///
/// 把"为什么算这么多"显示出来是刻意的:他要能一眼判断 AI 有没有理解错,
/// 而不是盲点确认。
class _SuggestionSheet extends StatefulWidget {
  const _SuggestionSheet({required this.suggestions});

  final List<ProgressSuggestion> suggestions;

  @override
  State<_SuggestionSheet> createState() => _SuggestionSheetState();
}

class _SuggestionSheetState extends State<_SuggestionSheet> {
  late final Set<int> _accepted = {
    for (var i = 0; i < widget.suggestions.length; i++) i,
  };

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
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
              style: TextStyle(fontSize: 12.5, height: 1.5, color: textSecondary),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                shrinkWrap: true,
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
                ],
              ),
            ),
            const SizedBox(height: 12),
            Row(
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
                    onPressed: _accepted.isEmpty
                        ? null
                        : () => Navigator.pop(
                              context,
                              [
                                for (var i = 0; i < widget.suggestions.length; i++)
                                  if (_accepted.contains(i)) widget.suggestions[i],
                              ],
                            ),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: Text('计入这 ${_accepted.length} 条'),
                  ),
                ),
              ],
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
class _HistorySheet extends StatelessWidget {
  const _HistorySheet({required this.goal, required this.entries});

  final Goal goal;
  final List<ProgressEntry> entries;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

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
                            onPressed: () async {
                              await state.deleteProgressEntry(entry.id);
                              if (context.mounted) Navigator.pop(context);
                            },
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

/// 目标编辑器用的草稿值。
class _GoalDraft {
  const _GoalDraft({
    required this.title,
    required this.unit,
    required this.target,
    required this.period,
    required this.direction,
    required this.color,
  });

  final String title;
  final String unit;
  final double target;
  final GoalPeriod period;
  final GoalDirection direction;
  final TaskColor color;
}

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
    text: widget.goal == null ? '' : Goal.formatAmount(widget.goal!.target),
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
        _target.text = Goal.formatAmount(draft.target);
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
                  final target = double.tryParse(_target.text.trim());
                  if (_title.text.trim().isEmpty || target == null || target <= 0) {
                    return;
                  }
                  Navigator.pop(
                    context,
                    _GoalDraft(
                      title: _title.text.trim(),
                      unit: _unit.text.trim().isEmpty ? '次' : _unit.text.trim(),
                      target: target,
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
      ),
    );
  }
}
