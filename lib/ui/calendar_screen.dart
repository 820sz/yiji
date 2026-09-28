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
                onPressed: () => state.shiftCalendarMonth(-1),
                icon: Icon(Icons.chevron_left, color: textPrimary),
                tooltip: '上个月',
              ),
              IconButton(
                onPressed: () => state.shiftCalendarMonth(1),
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
          child: SingleChildScrollView(
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
                            dark: dark,
                            onTap: (day) => showDayEditor(context, day),
                          ),
                        ),
                    ],
                  ),
              ],
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
  });

  /// null 表示这一格是月初/月末的占位。
  final String? day;
  final bool isToday;
  final DayCount? count;
  final bool dark;
  final ValueChanged<String> onTap;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    if (day == null) {
      return const SizedBox(height: 56);
    }
    final date = parseDayKey(day!);
    final total = count?.total ?? 0;
    final done = count?.done ?? 0;
    final future = isFutureDay(day!);

    return InkWell(
      onTap: () => onTap(day!),
      borderRadius: BorderRadius.circular(12),
      child: SizedBox(
        height: 56,
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Container(
              width: 30,
              height: 30,
              alignment: Alignment.center,
              decoration: isToday
                  ? const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle)
                  : null,
              child: Text(
                '${date.day}',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: isToday ? FontWeight.w700 : FontWeight.w500,
                  color: isToday
                      ? Colors.white
                      : (future ? textSecondary.withValues(alpha: 0.65) : textPrimary),
                ),
              ),
            ),
            const SizedBox(height: 3),
            // 状态点:一眼看出这天有没有安排、做完没有。
            SizedBox(
              height: 8,
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
/// 单独做成组件是为了让"这天有没有安排"这件事有一个可被测试定位的落点,
/// 而不是埋在日期格子的嵌套结构里。
class CalendarDayDot extends StatelessWidget {
  const CalendarDayDot({super.key, required this.total, required this.done});

  final int total;
  final int done;

  @override
  Widget build(BuildContext context) {
    if (total == 0) return const SizedBox.shrink();
    if (total == done) {
      return Icon(Icons.check, size: 11, color: AppTheme.doneText.withValues(alpha: 0.8));
    }
    return Container(
      width: 5,
      height: 5,
      decoration: const BoxDecoration(color: AppTheme.accent, shape: BoxShape.circle),
    );
  }
}
