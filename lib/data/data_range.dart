import '../core/day.dart';

/// 聊天时要附带的"近期数据"范围。
///
/// 之前写死"本周":他想聊这一周时够用,想聊一整个月就落空了。
/// 现在做成可选,并且把选中的范围一直显示在输入框上方——
/// 附带了什么数据是会影响回答的,不能让它变成一个看不见的状态。
class DataRange {
  const DataRange({required this.startDay, required this.endDay, required this.label});

  /// 起止日,两端都含,`YYYY-MM-DD`。
  final String startDay;
  final String endDay;

  /// 界面上显示的短标签,如"近 7 天""8月1日 - 8月31日"。
  final String label;

  /// 最近 [days] 天(含今天)。
  factory DataRange.lastDays(int days, {String? today}) {
    final end = today ?? todayKey();
    return DataRange(
      startDay: addDays(end, -(days - 1)),
      endDay: end,
      label: '近 $days 天',
    );
  }

  /// 指定区间。
  factory DataRange.between(String start, String end) {
    return DataRange(
      startDay: start,
      endDay: end,
      label: '${shortDateLabel(start)} - ${shortDateLabel(end)}',
    );
  }

  /// 覆盖的天数(含首尾)。
  int get dayCount => parseDayKey(endDay).difference(parseDayKey(startDay)).inDays + 1;
}
