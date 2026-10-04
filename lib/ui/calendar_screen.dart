import 'package:flutter/material.dart';

import '../core/day.dart';
import '../data/record_store.dart';
import '../state/app_state.dart';
import 'task_sheets.dart';
import 'theme.dart';

/// 日历页:月视图 + 点某天就地编辑。
///
/// 每格上的信息按"一眼能看出这天的状态"来排:
/// 有未完成 → 蓝点;全部完成 → 打钩;没有安排 → 只显示日期数字(不打扰)。
/// 未来的日期可以提前安排,这是他明确要的能力。
class CalendarScreen extends StatefulWidget {
  const CalendarScreen({super.key});

  @override
  State<CalendarScreen> createState() => _CalendarScreenState();
}

class _CalendarScreenState extends State<CalendarScreen> {
  /// 换月动画的方向:+1 表示新月份从右边进来(往后翻),-1 从左边。
  ///
  /// 方向得由**用户按了哪个箭头**决定,不能从月份大小推——跨年时会推错
  /// (12 月按"下个月",月份值反而变小)。
  double _slideFrom = 1;

  void _shift(int months) {
    setState(() => _slideFrom = months >= 0 ? 1 : -1);
    AppScope.of(context).shiftCalendarMonth(months);
  }

  @override
  void initState() {
    super.initState();
    // 首帧之后再取数:这时 AppScope 一定可用。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) AppScope.of(context).loadCalendarMonth(todayKey());
    });
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    final anchor = state.calendarMonth;
    final cells = monthGrid(anchor);
    final today = todayKey();

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 8, 8, 8),
          child: Row(
            children: [
              Text(
                monthTitle(anchor),
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w700,
                  color: textPrimary,
                ),
              ),
              const Spacer(),
              IconButton(
                onPressed: () => _shift(-1),
                icon: Icon(Icons.chevron_left, color: textPrimary),
                tooltip: '上个月',
              ),
              IconButton(
                onPressed: () => _shift(1),
                icon: Icon(Icons.chevron_right, color: textPrimary),
                tooltip: '下个月',
              ),
              TextButton(
                onPressed: () {
                  state.loadCalendarMonth(today);
                  state.goToToday();
                },
                child: const Text('今天'),
              ),
            ],
          ),
        ),
        // 星期表头。
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              for (final label in weekHeaderLabels)
                Expanded(
                  child: Center(
                    child: Text(
                      label,
                      style: TextStyle(fontSize: 12.5, color: textSecondary),
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Expanded(
          // 换月时整块网格横向滑出/滑入,方向跟着用户按的箭头走。
          //
          // 用户原话:"日历月份切换之间没有动画过渡"。原来是一帧换掉,
          // 数字变了他也未必注意到。
          //
          // 用 AnimatedSwitcher + key 而不是自己管动画:月份是个值,
          // 值变了就换——这正是 AnimatedSwitcher 的模型,不用手写控制器。
          child: AnimatedSwitcher(
            duration: AppTheme.medium,
            switchInCurve: AppTheme.easeOut,
            switchOutCurve: AppTheme.easeOut,
            transitionBuilder: (child, animation) {
              // 从哪边进来取决于这次是往前还是往后翻,所以读 _slideFrom。
              final offset = Tween<Offset>(
                begin: Offset(_slideFrom, 0),
                end: Offset.zero,
              ).animate(animation);
              return ClipRect(
                child: SlideTransition(
                  position: offset,
                  child: FadeTransition(opacity: animation, child: child),
                ),
              );
            },
            layoutBuilder: (current, previous) => Stack(
              alignment: Alignment.topCenter,
              children: [...previous, ?current],
            ),
            child: SingleChildScrollView(
              // key 带上月份:换了月份就是"另一个孩子",AnimatedSwitcher 才会动。
              key: ValueKey('month-${monthTitle(anchor)}'),
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 100),
              child: Column(
                children: [
                  for (var row = 0; row < cells.length ~/ 7; row++)
                    Row(
                      children: [
                        for (var col = 0; col < 7; col++)
                          Expanded(
                            child: _DayCell(
                              day: cells[row * 7 + col],
                              isToday: cells[row * 7 + col] == today,
                              count: state.monthCounts[cells[row * 7 + col]],
                              hasJournal: state.monthJournals
                                  .containsKey(cells[row * 7 + col]),
                              dark: dark,
                              onTap: (day) => showDayEditor(context, day),
                            ),
                          ),
                      ],
                    ),
                  // 这一月记过的想法汇总在下面。
                  //
                  // 用户要求"日历里无法看到记录过的'今日感想'"。做在格子下面
                  // 而不是塞进格子里:格子里只剩 62 像素,放不下正文,
                  // 而感想是要读的,不是要一个"有"的标记。
                  if (state.monthJournals.isNotEmpty) ...[
                    const SizedBox(height: 14),
                    _MonthJournalList(
                      journals: state.monthJournals,
                      dark: dark,
                      onTapDay: (day) => showDayEditor(context, day),
                      onDeleteDay: (day) => state.deleteJournal(day),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 一个日期格。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isToday,
    required this.count,
    required this.dark,
    required this.onTap,
    this.hasJournal = false,
  });

  /// null 表示这一格是月初/月末的占位。
  final String? day;
  final bool isToday;
  final DayCount? count;
  final bool dark;
  final ValueChanged<String> onTap;

  /// 这天有没有记过"今日想法"。
  final bool hasJournal;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    if (day == null) {
      return const SizedBox(height: 62);
    }
    final date = parseDayKey(day!);
    final total = count?.total ?? 0;
    final done = count?.done ?? 0;
    final future = isFutureDay(day!);

    return InkWell(
      onTap: () => onTap(day!),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 62,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // 日期那圈用一个 Stack:今天的高亮圈、以及"记过想法"的小角标
            // 都挂在它上面。
            //
            // 角标**不能加到 Column 里**当第三个孩子——62 的高度已经被
            // 日期圈(30)+ 间距(2)+ 完成标记(18)= 50 加上居中留白占满了,
            // 再加一个就溢出(实测报 "overflowed by 1.00 pixels")。
            // 角标本来就是叠加信息,压在圈上正合适。
            SizedBox(
              width: 34,
              height: 30,
              child: Stack(
                clipBehavior: Clip.none,
                alignment: Alignment.center,
                children: [
                  Container(
                    width: 30,
                    height: 30,
                    alignment: Alignment.center,
                    decoration: isToday
                        ? const BoxDecoration(
                            color: AppTheme.accent,
                            shape: BoxShape.circle,
                          )
                        : null,
                    child: Text(
                      '${date.day}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                        color: isToday
                            ? Colors.white
                            : (future
                                ? textSecondary.withValues(alpha: 0.65)
                                : textPrimary),
                      ),
                    ),
                  ),
                  if (hasJournal)
                    Positioned(
                      right: -1,
                      top: -1,
                      child: Icon(
                        Icons.edit_note,
                        size: 13,
                        color: isToday ? Colors.white : AppTheme.accent,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 2),
            // 完成度标记:一眼看出这天有没有安排、做完没有。
            SizedBox(
              height: 18,
              child: CalendarDayDot(total: total, done: done),
            ),
          ],
        ),
      ),
    );
  }
}

/// 日期下方那个状态标记。
///
/// 三档完成度一眼可辨:
/// - 全做完 → 勾
/// - 完成一半以上 → 半勾
/// - 不到一半 → 叉
///
/// 没安排的日子不显示任何标记——日历上不该到处都是符号。
/// 单独做成组件是为了让这件事有一个可被测试定位的落点。
class CalendarDayDot extends StatelessWidget {
  const CalendarDayDot({super.key, required this.total, required this.done});

  final int total;
  final int done;

  /// 完成率。没有任何安排时返回 0。
  double get ratio => total == 0 ? 0 : done / total;

  /// 这一天的完成度档次。测试直接断言这个,不去比对图标。
  DayProgress get progress {
    if (total == 0) return DayProgress.none;
    if (done >= total) return DayProgress.all;
    if (ratio >= 0.5) return DayProgress.half;
    return DayProgress.few;
  }

  @override
  Widget build(BuildContext context) {
    return switch (progress) {
      DayProgress.none => const SizedBox.shrink(),
      // 尺寸从 12 提到 17。
      //
      // 用户原话:"'✓'这种标记太小了"。12 在 1080p 上只有几毫米,
      // 嵌在日期下面基本看不清是勾还是点——而它承载的是"这天做完了没有"
      // 这个核心信息,不该省这点地方。
      DayProgress.all => const Icon(
          Icons.check,
          size: 17,
          color: AppTheme.accent,
        ),
      // 半勾:空心勾套一个实心下半部,视觉上就是"勾了一半"。
      DayProgress.half => const Icon(
          Icons.check_circle_outline,
          size: 17,
          color: AppTheme.doneText,
        ),
      DayProgress.few => Icon(
          Icons.close,
          size: 17,
          color: AppTheme.doneText.withValues(alpha: 0.75),
        ),
    };
  }
}

/// 这一月记过的"今日想法",按日期列在日历下面。
///
/// 用户原话:"日历里,无法看到记录过的'今日感想'"。只给格子点个小点不够
/// ——想法是要读的,不是要知道"有没有"。所以这里把正文列出来,点一条
/// 能进那天的编辑页。
class _MonthJournalList extends StatelessWidget {
  const _MonthJournalList({
    required this.journals,
    required this.dark,
    required this.onTapDay,
    required this.onDeleteDay,
  });

  /// 键是 `YYYY-MM-DD`,值是那天的想法正文。
  final Map<String, String> journals;
  final bool dark;
  final ValueChanged<String> onTapDay;

  /// 删掉某天的想法。
  final Future<void> Function(String day) onDeleteDay;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary =
        dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    // 按日期倒序:最近写的在最上面。
    final days = journals.keys.toList()..sort((a, b) => b.compareTo(a));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.edit_note, size: 16, color: textSecondary),
            const SizedBox(width: 6),
            Text(
              '这月记的想法(${days.length} 天)',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textSecondary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        for (final day in days)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: InkWell(
              onTap: () => onTapDay(day),
              // 长按删除。用户问"日历里记录的想法为什么没法删除?"——
              // 之前确实一条路都没有,写错了只能去改文字、改不掉整条。
              onLongPress: () => _confirmDelete(context, day),
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: dark ? AppTheme.darkSurface : AppTheme.lightSurface,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          shortDateLabel(day),
                          style: TextStyle(fontSize: 11.5, color: textSecondary),
                        ),
                        const Spacer(),
                        // 显式的删除按钮:长按不是所有人都知道。
                        InkWell(
                          onTap: () => _confirmDelete(context, day),
                          customBorder: const CircleBorder(),
                          child: Padding(
                            padding: const EdgeInsets.all(4),
                            child: Icon(
                              Icons.delete_outline,
                              size: 17,
                              color: textSecondary,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 1),
                    Text(
                      journals[day]!,
                      // 正文截几行了事:这里是一份"这个月都想了什么"的索引,
                      // 要能一眼扫过;想看全文点进去。
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13.5, height: 1.5, color: textPrimary),
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// 删除前确认一次。日记删了找不回来,不该一下点掉。
  Future<void> _confirmDelete(BuildContext context, String day) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删掉这天的想法?'),
        content: Text(
          '${shortDateLabel(day)}记的想法会被清掉,删了找不回来。',
          style: const TextStyle(fontSize: 13.5, height: 1.5),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await onDeleteDay(day);
  }
}

/// 一天的完成度档次。
enum DayProgress { none, all, half, few }
