import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../core/day.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'theme.dart';

/// 总结页:周报 / 月报两个页签。
///
/// 上半部分是**真实打卡统计**(不依赖网络,永远能看),
/// 下半部分是 AI 成稿(要配 key,失败也不影响上半部分)。
class ReportScreen extends StatefulWidget {
  const ReportScreen({super.key});

  @override
  State<ReportScreen> createState() => _ReportScreenState();
}

class _ReportScreenState extends State<ReportScreen> with SingleTickerProviderStateMixin {
  late final TabController _tabs = TabController(length: 2, vsync: this)
    ..addListener(() {
      if (!_tabs.indexIsChanging) setState(_reset);
    });

  /// 当前查看区间所属的锚点日期;切换周/月时用同一个锚点。
  String _anchor = todayKey();

  PeriodReport? _report;
  bool _loading = true;
  String? _loadError;

  /// AI 成稿的流式缓冲。
  String _draft = '';
  bool _generating = false;
  String? _aiError;
  StreamSubscription<String>? _subscription;

  bool get _isWeek => _tabs.index == 0;

  @override
  void initState() {
    super.initState();
    // 首帧之后再取数:这时 AppScope 一定已经可用。
    WidgetsBinding.instance.addPostFrameCallback((_) => _load());
  }

  @override
  void dispose() {
    _subscription?.cancel();
    _tabs.dispose();
    super.dispose();
  }

  void _reset() {
    _draft = '';
    _aiError = null;
    // 延到下一帧再取数:切页签会触发本方法,而那时 TabBar 还在构建,
    // 直接在里面 setState 会撞上"在错误的构建作用域里标脏组件"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  Future<void> _load() async {
    final state = AppScope.of(context);
    setState(() {
      _loading = true;
      _loadError = null;
    });
    try {
      final report = _isWeek
          ? await state.weekReport(_anchor)
          : await state.monthReport(_anchor);
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } on Exception catch (error) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _loadError = '取数据失败:$error';
      });
    }
  }

  /// 往前/往后翻一个区间。周 = 7 天,月 = 跨到上/下月同一天。
  void _shift(int delta) {
    setState(() {
      if (_isWeek) {
        _anchor = addDays(_anchor, 7 * delta);
      } else {
        final date = parseDayKey(_anchor);
        final target = DateTime(date.year, date.month + delta, 1);
        _anchor = dayKey(target);
      }
    });
    _reset();
  }

  String get _periodLabel {
    final state = AppScope.of(context);
    return _isWeek ? state.weekLabel(_anchor) : state.monthLabel(_anchor);
  }

  Future<void> _generate() async {
    final state = AppScope.of(context);
    await _subscription?.cancel();
    setState(() {
      _draft = '';
      _aiError = null;
      _generating = true;
    });

    final stream = _isWeek
        ? state.generateWeekReport(_anchor)
        : state.generateMonthReport(_anchor);

    _subscription = stream.listen(
      (chunk) {
        if (!mounted) return;
        setState(() => _draft += chunk);
      },
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _generating = false;
          _aiError = error is Exception ? error.toString() : '生成失败:$error';
        });
      },
      onDone: () {
        if (!mounted) return;
        setState(() => _generating = false);
      },
      cancelOnError: true,
    );
  }

  Future<void> _copyDraft() async {
    final text = _exportText();
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('已复制,粘到 Word 里就行')));
  }

  /// 直接把成稿分享出去(微信、备忘录等),省掉复制粘贴。
  Future<void> _shareDraft() async {
    final text = _exportText();
    if (text.isEmpty) return;
    await SharePlus.instance.share(
      ShareParams(text: text, subject: '$_periodLabel 总结'),
    );
  }

  /// 导出优先给 AI 成稿;没生成过就给纯统计版,保证任何时刻都能导出。
  String _exportText() {
    if (_draft.trim().isNotEmpty) return _draft;
    return _report == null ? '' : _plainFallback();
  }

  String _plainFallback() {
    final report = _report!;
    final buffer = StringBuffer()
      ..writeln('$_periodLabel 总结')
      ..writeln()
      ..writeln('计划 ${report.total} 条,完成 ${report.doneCount} 条,'
          '完成率 ${(report.completionRate * 100).round()}%。')
      ..writeln();
    final byDay = report.tasksByDay;
    final days = byDay.keys.toList()..sort();
    for (final day in days) {
      buffer.writeln('${shortDateLabel(day)} ${weekdayLabel(day)}');
      for (final task in byDay[day]!) {
        buffer.writeln('${task.done ? '✓' : '×'} ${task.text}');
      }
      buffer.writeln();
    }
    final undone = report.undoneTasks;
    if (undone.isNotEmpty) {
      buffer.writeln('未完成:');
      for (final task in undone) {
        buffer.writeln('- ${shortDateLabel(task.day)} ${task.text}');
      }
      buffer.writeln();
    }
    for (final journal in report.journals) {
      buffer
        ..writeln('【${shortDateLabel(journal.day)}】')
        ..writeln(journal.text)
        ..writeln();
    }
    return buffer.toString().trimRight();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final hasKey = state.aiConfig.isUsable;
    final report = _report;

    return Scaffold(
      appBar: AppBar(
        title: const Text('总结'),
        bottom: TabBar(
          controller: _tabs,
          labelColor: AppTheme.accent,
          unselectedLabelColor:
              dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
          indicatorColor: AppTheme.accent,
          tabs: const [Tab(text: '周报'), Tab(text: '月报')],
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => _shift(-1),
                  icon: const Icon(Icons.chevron_left),
                  tooltip: _isWeek ? '上一周' : '上个月',
                ),
                Expanded(
                  child: Text(
                    _periodLabel,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      color: dark
                          ? AppTheme.darkTextSecondary
                          : AppTheme.lightTextSecondary,
                    ),
                  ),
                ),
                IconButton(
                  onPressed: () => _shift(1),
                  icon: const Icon(Icons.chevron_right),
                  tooltip: _isWeek ? '下一周' : '下个月',
                ),
              ],
            ),
          ),
        Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : ListView(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 32),
                    children: [
                      if (_loadError != null)
                        _ErrorCard(message: _loadError!)
                      else if (report != null) ...[
                        _StatsCard(report: report),
                        const SizedBox(height: 12),
                        _CompletionList(report: report),
                        if (report.journals.isNotEmpty) ...[
                          const SizedBox(height: 12),
                          _JournalSummary(report: report),
                        ],
                      ],
                      const SizedBox(height: 12),
                      _AiSection(
                        hasKey: hasKey,
                        generating: _generating,
                        draft: _draft,
                        error: _aiError,
                        onGenerate: _generate,
                        onCopy: _copyDraft,
                        onShare: _shareDraft,
                        label: _isWeek ? '让 AI 写这周总结' : '让 AI 写这个月总结',
                      ),
                    ],
                  ),
          ),
        ],
      ),
    );
  }
}

/// 统计卡:计划/完成/完成率/有记录天数。
class _StatsCard extends StatelessWidget {
  const _StatsCard({required this.report});

  final PeriodReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 8),
        child: Row(
          children: [
            _Stat(value: '${report.total}', label: '计划'),
            _Stat(value: '${report.doneCount}', label: '完成'),
            _Stat(
              value: '${(report.completionRate * 100).round()}%',
              label: '完成率',
              highlight: true,
            ),
            _Stat(value: '${report.activeDayCount}', label: '有记录天数'),
          ],
        ),
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.value, required this.label, this.highlight = false});

  final String value;
  final String label;
  final bool highlight;

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.w600,
              color: highlight ? AppTheme.accent : AppTheme.lightTextPrimary,
            ),
          ),
          const SizedBox(height: 2),
          Text(label, style: const TextStyle(fontSize: 12, color: AppTheme.lightTextSecondary)),
        ],
      ),
    );
  }
}

/// 逐天列出完成与未完成。这是"这周到底干了什么"的答案。
class _CompletionList extends StatelessWidget {
  const _CompletionList({required this.report});

  final PeriodReport report;

  @override
  Widget build(BuildContext context) {
    final byDay = report.tasksByDay;
    final days = byDay.keys.toList()..sort();

    if (days.isEmpty) {
      return const Card(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Center(
            child: Text(
              '这个区间还没有待办记录',
              style: TextStyle(color: AppTheme.lightTextSecondary),
            ),
          ),
        ),
      );
    }

    return Card(
      child: Column(
        children: [
          for (var i = 0; i < days.length; i++) ...[
            if (i > 0) const Divider(height: 1),
            _DayGroup(day: days[i], tasks: byDay[days[i]]!),
          ],
        ],
      ),
    );
  }
}

class _DayGroup extends StatelessWidget {
  const _DayGroup({required this.day, required this.tasks});

  final String day;
  final List<Task> tasks;

  @override
  Widget build(BuildContext context) {
    final done = tasks.where((t) => t.done).length;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '${shortDateLabel(day)} ${weekdayLabel(day)}',
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Text(
                '$done/${tasks.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: done == tasks.length ? AppTheme.accent : AppTheme.lightTextSecondary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final task in tasks)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      task.done ? Icons.check : Icons.close,
                      size: 14,
                      color: task.done ? AppTheme.accent : AppTheme.lightTextSecondary,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      task.text,
                      // 报告里每条待办都带 key,测试才能精确断言"哪条被划掉了"。
                      // 之前这里判断写反过(没完成的被划掉),而当时没有测试守着。
                      key: Key('report-task-${task.id}'),
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: task.done
                            ? AppTheme.lightTextSecondary
                            : AppTheme.lightTextPrimary,
                        // 划掉的应该是**已完成**的。
                        // 之前这里判断写反了,导致报告里"没做的"全被划掉,看着像做完了。
                        decoration: task.done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 本周写过的想法/收获,折起来放,需要时再展开看。
class _JournalSummary extends StatelessWidget {
  const _JournalSummary({required this.report});

  final PeriodReport report;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ExpansionTile(
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(Icons.auto_stories_outlined, size: 20, color: AppTheme.accent),
        title: Text(
          '这期间的想法 / 收获(${report.journals.length} 天)',
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
        ),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        children: [
          for (final journal in report.journals)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${shortDateLabel(journal.day)} ${weekdayLabel(journal.day)}',
                    style: const TextStyle(fontSize: 12, color: AppTheme.lightTextSecondary),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    journal.text,
                    style: const TextStyle(fontSize: 14, height: 1.55),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// AI 成稿区:一个按钮、一段流式文字、一个复制出口。
class _AiSection extends StatelessWidget {
  const _AiSection({
    required this.hasKey,
    required this.generating,
    required this.draft,
    required this.error,
    required this.onGenerate,
    required this.onCopy,
    required this.onShare,
    required this.label,
  });

  final bool hasKey;
  final bool generating;
  final String draft;
  final String? error;
  final Future<void> Function() onGenerate;
  final Future<void> Function() onCopy;
  final Future<void> Function() onShare;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.auto_awesome, size: 18, color: AppTheme.accent),
                const SizedBox(width: 6),
                const Text(
                  'AI 成稿',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (draft.isNotEmpty && !generating) ...[
                  TextButton.icon(
                    onPressed: onShare,
                    icon: const Icon(Icons.ios_share, size: 16),
                    label: const Text('分享'),
                  ),
                  TextButton.icon(
                    onPressed: onCopy,
                    icon: const Icon(Icons.copy, size: 16),
                    label: const Text('复制'),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 8),
            if (!hasKey)
              const Text(
                '还没填 API key,去「我的」里填一个。',
                style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.lightTextSecondary),
              )
            else if (draft.isEmpty && !generating)
              const Text(
                '按「进度 / 不足 / 调整方向」的格式写成稿。',
                style: TextStyle(fontSize: 13, height: 1.5, color: AppTheme.lightTextSecondary),
              ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(
                error!,
                style: const TextStyle(fontSize: 13, height: 1.5, color: Color(0xFFE05252)),
              ),
            ],
            if (draft.isNotEmpty) ...[
              const SizedBox(height: 10),
              SelectableText(
                draft,
                style: const TextStyle(fontSize: 14.5, height: 1.7),
              ),
            ],
            const SizedBox(height: 12),
            Row(
              children: [
                FilledButton.icon(
                  onPressed: hasKey && !generating ? onGenerate : null,
                  icon: generating
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.auto_awesome, size: 18),
                  label: Text(
                    generating
                        ? '正在写…'
                        : draft.isEmpty
                            ? label
                            : '重新生成',
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

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Icon(Icons.error_outline, color: Color(0xFFE05252), size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(fontSize: 13, color: Color(0xFFE05252)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
