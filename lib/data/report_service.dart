import '../core/day.dart';
import 'models.dart';
import 'record_store.dart';

/// 把打卡记录聚合成周报/月报,并渲染成给 AI 的上下文。
///
/// 这一层不碰数据库:它接受 [RecordStore],按日期区间取数后做纯计算。
/// 报告不落库(见 PLAN.md 决策记录),所以任何一次生成都能重算。
class ReportService {
  ReportService(this._store);

  final RecordStore _store;

  /// 周报:`[day]` 所在周的周一至周日。
  Future<PeriodReport> weekOf(String day) {
    return _build(mondayOf(day), sundayOf(day));
  }

  /// 月报:`[day]` 所在月的 1 号到月末。
  Future<PeriodReport> monthOf(String day) {
    return _build(firstDayOfMonth(day), lastDayOfMonth(day));
  }

  Future<PeriodReport> _build(String start, String end) async {
    final tasks = await _store.tasksBetween(start, end);
    final journals = await _store.journalsBetween(start, end);
    return PeriodReport(
      startDay: start,
      endDay: end,
      tasks: tasks,
      journals: journals,
    );
  }

  /// 渲染成给 AI 的提示词素材。
  ///
  /// 刻意用 xi283 自己周总结里的栏目名(进度/不足/调整方向),
  /// 让模型输出直接贴合他已有的写作结构,而不是套一个通用模板。
  String aiContext(PeriodReport report, {required String periodLabel}) {
    final buffer = StringBuffer()
      ..writeln('# $periodLabel 打卡数据')
      ..writeln()
      ..writeln('统计:计划 ${report.total} 条,完成 ${report.doneCount} 条,'
          '完成率 ${(report.completionRate * 100).round()}%,'
          '有记录的天数 ${report.activeDayCount} 天。')
      ..writeln();

    final done = report.doneTasks;
    if (done.isEmpty) {
      buffer.writeln('## 本周完成\n(无)');
    } else {
      buffer.writeln('## 本周完成');
      for (final task in done) {
        buffer.writeln('- ${shortDateLabel(task.day)} ${task.text}');
      }
    }
    buffer.writeln();

    // 用户自己标过"没做好"的那些。这是"不足"那一栏里最实在的素材:
    // 它不是"没完成",而是"做了但结果不好",两者在总结里该分开写。
    final fellShort = done.where((t) => t.fellShort).toList();
    if (fellShort.isNotEmpty) {
      buffer.writeln('## 做了但用户自己标了"没做好"');
      for (final task in fellShort) {
        buffer.writeln('- ${shortDateLabel(task.day)} ${task.text}');
      }
      buffer.writeln('(这些是他主动标的判断,写"不足"时优先用这些,不要另编原因)');
      buffer.writeln();
    }

    final undone = report.undoneTasks;
    if (undone.isNotEmpty) {
      buffer.writeln('## 没完成的');
      for (final task in undone) {
        buffer.writeln('- ${shortDateLabel(task.day)} ${task.text}');
      }
      buffer.writeln();
    }

    if (report.journals.isNotEmpty) {
      buffer.writeln('## 每天的想法/收获');
      for (final journal in report.journals) {
        buffer
          ..writeln('### ${shortDateLabel(journal.day)} ${weekdayLabel(journal.day)}')
          ..writeln(journal.text)
          ..writeln();
      }
    }

    return buffer.toString().trimRight();
  }

  /// 渲染成可读、可直接粘贴进 Word 的纯文本报告。
  ///
  /// 与 [aiContext] 的区别:这份是给用户看的成稿,不含"给模型看的指示",
  /// 所以统计和条目都换成自然语言的写法。
  String plainReport(PeriodReport report, {required String periodLabel}) {
    final buffer = StringBuffer()
      ..writeln(periodLabel)
      ..writeln()
      ..writeln('完成情况:计划 ${report.total} 条,完成 ${report.doneCount} 条,'
          '完成率 ${(report.completionRate * 100).round()}%。')
      ..writeln();

    final byDay = report.tasksByDay;
    final days = byDay.keys.toList()..sort();
    for (final day in days) {
      final tasks = byDay[day]!;
      buffer.writeln('${shortDateLabel(day)} ${weekdayLabel(day)}');
      for (final task in tasks) {
        // 三种结果分开标:做完的 ✓、没做 ×、做了但自己觉得没做好的 △。
        // 最后那种在纯文本报告里也要能一眼看见,不然标了等于白标。
        final mark = task.done ? (task.fellShort ? '△' : '✓') : '×';
        buffer.writeln('$mark ${task.text}');
      }
      buffer.writeln();
    }

    final fellShort = report.tasks.where((t) => t.fellShort).toList();
    if (fellShort.isNotEmpty) {
      buffer.writeln('做了但没做好的(△):');
      for (final task in fellShort) {
        buffer.writeln('- ${shortDateLabel(task.day)} ${task.text}');
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

    if (report.journals.isNotEmpty) {
      buffer.writeln('想法与收获:');
      for (final journal in report.journals) {
        buffer
          ..writeln('【${shortDateLabel(journal.day)}】')
          ..writeln(journal.text)
          ..writeln();
      }
    }

    return buffer.toString().trimRight();
  }
}
