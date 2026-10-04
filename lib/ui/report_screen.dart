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

  /// 思考过程的流式缓冲。和正文分开存:成稿里不该混进思考。
  String _reasoning = '';

  /// 用户自己补的要求(打完再生成/再发一次)。
  final _extra = TextEditingController();

  bool _generating = false;
  String? _aiError;
  StreamSubscription<ReportDelta>? _subscription;

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
    _extra.dispose();
    _tabs.dispose();
    super.dispose();
  }

  void _reset() {
    // 切页签/翻区间时把正在生成的那次停掉。
    // 不停的话,旧区间的流会继续往新区间的成稿区里写字:标题写着"这个月",
    // 正文却是上周的内容,而且按钮一直卡在"正在写…"。那是真金白银的一次
    // API 调用被展示到错误的区间上。
    _cancelGeneration();
    _draft = '';
    _reasoning = '';
    _aiError = null;
    // 延到下一帧再取数:切页签会触发本方法,而那时 TabBar 还在构建,
    // 直接在里面 setState 会撞上"在错误的构建作用域里标脏组件"。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _load();
    });
  }

  void _cancelGeneration() {
    _subscription?.cancel();
    _subscription = null;
    _generating = false;
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
    // 记下这次是为哪个区间生成的。分片回来时如果用户已经翻走了,
    // 就把它们丢掉,而不是打进别人的成稿区。
    final generation = '${_isWeek ? 'week' : 'month'}:$_anchor';
    setState(() {
      _draft = '';
      _reasoning = '';
      _aiError = null;
      _generating = true;
    });

    // 用户自己补的要求一起发过去。他打完字点"重新生成"就是这条路。
    final extra = _extra.text.trim();
    final stream = _isWeek
        ? state.generateWeekReport(_anchor, extra: extra)
        : state.generateMonthReport(_anchor, extra: extra);

    bool stillCurrent() => mounted && _generationKey == generation;

    _subscription = stream.listen(
      (delta) {
        if (!stillCurrent()) return;
        setState(() {
          // 思考和正文分开放:混在一起的话用户复制出来的成稿里会带着思考。
          if (delta.isReasoning) {
            _reasoning += delta.reasoning;
          } else {
            _draft += delta.text;
          }
        });
      },
      onError: (Object error) {
        if (!stillCurrent()) return;
        setState(() {
          _generating = false;
          _aiError = error is Exception ? error.toString() : '生成失败:$error';
        });
      },
      onDone: () {
        if (!stillCurrent()) return;
        setState(() => _generating = false);
      },
      cancelOnError: true,
    );
  }

  /// 当前页签 + 区间的标识,用来判断"这一次生成还算不算数"。
  String get _generationKey => '${_isWeek ? 'week' : 'month'}:$_anchor';

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
                        reasoning: _reasoning,
                        error: _aiError,
                        extraController: _extra,
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

/// 成稿区里的思考过程块。
///
/// 和聊天页同一套做法:**定高 + 区内滚动 + 生成完自动收起**。
/// 用户要求"总结功能要支持流式思考和输出"——以前这里把 reasoning 分片
/// 直接丢掉了,界面上只看得到正文在长,看不到它在想什么。
class _ReportReasoning extends StatefulWidget {
  const _ReportReasoning({required this.text, required this.live});

  final String text;
  final bool live;

  @override
  State<_ReportReasoning> createState() => _ReportReasoningState();
}

class _ReportReasoningState extends State<_ReportReasoning> {
  late bool _expanded = widget.live;
  bool _userToggled = false;
  final _inner = ScrollController();

  @override
  void didUpdateWidget(_ReportReasoning oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 生成完自己收起来;用户点开过就不收,别把他正在读的抽走。
    if (oldWidget.live && !widget.live && !_userToggled) {
      setState(() => _expanded = false);
    }
  }

  @override
  void dispose() {
    _inner.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final secondary = AppTheme.textSecondary(context);
    return Material(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => setState(() {
          _userToggled = true;
          _expanded = !_expanded;
        }),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (widget.live)
                    const SizedBox(
                      width: 12,
                      height: 12,
                      child: CircularProgressIndicator(strokeWidth: 1.8),
                    )
                  else
                    Icon(Icons.psychology_outlined, size: 15, color: secondary),
                  const SizedBox(width: 7),
                  Text(
                    widget.live ? '思考中' : '思考过程',
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w500,
                      color: secondary,
                    ),
                  ),
                  const Spacer(),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: AppTheme.fast,
                    child: Icon(
                      Icons.keyboard_arrow_down,
                      size: 18,
                      color: secondary,
                    ),
                  ),
                ],
              ),
              AnimatedSize(
                duration: AppTheme.fast,
                curve: AppTheme.easeOut,
                alignment: Alignment.topLeft,
                child: _expanded
                    ? Padding(
                        padding: const EdgeInsets.only(top: 7),
                        child: ConstrainedBox(
                          // 定高:内容在里面滚,不把成稿区挤没了。
                          constraints: const BoxConstraints(maxHeight: 170),
                          child: PrimaryScrollController.none(
                            child: Scrollbar(
                              controller: _inner,
                              thumbVisibility: !widget.live,
                              child: SingleChildScrollView(
                                controller: _inner,
                                reverse: true,
                                padding: const EdgeInsets.only(right: 6),
                                child: SizedBox(
                                  width: double.infinity,
                                  child: Text(
                                    widget.text,
                                    style: TextStyle(
                                      fontSize: 13,
                                      height: 1.6,
                                      color: secondary,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      )
                    : const SizedBox(width: double.infinity),
              ),
            ],
          ),
        ),
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
              color: highlight ? AppTheme.accent : AppTheme.textPrimary(context),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 12, color: AppTheme.textSecondary(context)),
          ),
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
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Center(
            child: Text(
              '这个区间还没有任务记录',
              style: TextStyle(color: AppTheme.textSecondary(context)),
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
                  color: done == tasks.length
                      ? AppTheme.accent
                      : AppTheme.textSecondary(context),
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
                      color: task.done
                          ? AppTheme.accent
                          : AppTheme.textSecondary(context),
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
                            ? AppTheme.textSecondary(context)
                            : AppTheme.textPrimary(context),
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
                    style: TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary(context),
                    ),
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
    required this.reasoning,
    required this.error,
    required this.extraController,
    required this.onGenerate,
    required this.onCopy,
    required this.onShare,
    required this.label,
  });

  final bool hasKey;
  final bool generating;
  final String draft;

  /// 模型的思考过程。单独一块显示,不混进成稿。
  final String reasoning;

  final String? error;

  /// 用户自己补的要求。打完点生成就一起发过去。
  final TextEditingController extraController;

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
            // 思考过程。和聊天页同一套:定高、区内滚动、生成完自己收起来。
            // 用户要求"总结功能要支持流式思考"——以前这里根本不显示它。
            if (reasoning.isNotEmpty) ...[
              const SizedBox(height: 8),
              _ReportReasoning(text: reasoning, live: generating),
            ],
            const SizedBox(height: 8),
            if (!hasKey)
              Text(
                '还没填 API key,去「我的」里填一个。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppTheme.textSecondary(context),
                ),
              )
            else if (draft.isEmpty && !generating)
              Text(
                '按「进度 / 不足 / 调整方向」的格式写成稿。',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.5,
                  color: AppTheme.textSecondary(context),
                ),
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
            // 自己补一句要求再生成。
            //
            // 用户的原话:"还要能让用户能自行打字调整需求再发呀,
            // 而不是现在这种只能选择总结"。所以这里是个真的输入框,
            // 内容会跟着下一次生成一起发给模型。
            TextField(
              controller: extraController,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13.5),
              decoration: InputDecoration(
                isDense: true,
                hintText: '想让它怎么写?比如:短一点,重点说英语那部分',
                prefixIcon: const Icon(Icons.edit_note, size: 18),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
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
