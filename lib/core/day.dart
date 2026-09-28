/// 本地日期工具。
///
/// 全项目只在这里做 `DateTime` 与 `YYYY-MM-DD` 的互转,其他地方一律传字符串日期,
/// 避免"某处用了 UTC、某处用了本地时间"导致的跨天错位。
library;

/// 把 [date] 按本地时区格式化成 `YYYY-MM-DD`。
String dayKey(DateTime date) {
  final local = date.toLocal();
  final month = local.month.toString().padLeft(2, '0');
  final day = local.day.toString().padLeft(2, '0');
  return '${local.year}-$month-$day';
}

/// 把 `YYYY-MM-DD` 解析成本地时区当天零点。
DateTime parseDayKey(String key) {
  final parts = key.split('-');
  return DateTime(
    int.parse(parts[0]),
    int.parse(parts[1]),
    int.parse(parts[2]),
  );
}

/// 今天的 `YYYY-MM-DD`。
String todayKey([DateTime? now]) => dayKey(now ?? DateTime.now());

/// 日期加天数,跨月跨年由 `DateTime` 自己处理。
String addDays(String key, int days) => dayKey(parseDayKey(key).add(Duration(days: days)));

/// [key] 所在周的周一。周报以周一为一周开始。
String mondayOf(String key) {
  final date = parseDayKey(key);
  // DateTime.weekday: 周一 = 1 … 周日 = 7。
  return addDays(key, 1 - date.weekday);
}

/// [key] 所在周的周日(含)。
String sundayOf(String key) => addDays(mondayOf(key), 6);

/// [key] 所在月的第一天。
String firstDayOfMonth(String key) {
  final date = parseDayKey(key);
  return dayKey(DateTime(date.year, date.month, 1));
}

/// [key] 所在月的最后一天(含)。下月 1 号往前退一天,自动处理闰年和月长。
String lastDayOfMonth(String key) {
  final date = parseDayKey(key);
  return dayKey(DateTime(date.year, date.month + 1, 1).subtract(const Duration(days: 1)));
}

/// 该月的天数。
int daysInMonth(String key) => parseDayKey(lastDayOfMonth(key)).day;

/// 中文星期,用于界面和报告标题。
String weekdayLabel(String key) {
  const names = ['一', '二', '三', '四', '五', '六', '日'];
  return '周${names[parseDayKey(key).weekday - 1]}';
}

/// `9月14日` 这类短标签。
String shortDateLabel(String key) {
  final date = parseDayKey(key);
  return '${date.month}月${date.day}日';
}

/// 界面上的完整日期标题,如 `9月14日 周一`。
String fullDateLabel(String key) => '${shortDateLabel(key)} ${weekdayLabel(key)}';

/// 月视图的星期表头。周一开始,与 [mondayOf] 保持一致。
const weekHeaderLabels = ['一', '二', '三', '四', '五', '六', '日'];

/// 某月 1 号之前要留的空格数。
///
/// 表头从周一开始,所以周一要留 0 格、周日留 6 格。
int leadingBlanksOfMonth(String monthAnchor) {
  final first = firstDayOfMonth(monthAnchor);
  return parseDayKey(first).weekday - 1;
}

/// 月视图的完整格子序列:前导空格用 null 占位,后面接该月每一天。
///
/// 返回的格子数一定是 7 的整数倍,方便直接按 7 个一行铺。
List<String?> monthGrid(String monthAnchor) {
  final leading = leadingBlanksOfMonth(monthAnchor);
  final days = daysInMonth(monthAnchor);
  final cells = <String?>[
    ...List<String?>.filled(leading, null),
    for (var i = 0; i < days; i++) addDays(firstDayOfMonth(monthAnchor), i),
  ];
  // 末尾补齐到最后一行,让每行都是 7 个,避免最后一行错位。
  while (cells.length % 7 != 0) {
    cells.add(null);
  }
  return cells;
}

/// `2026年9月` 这种月份标题。
String monthTitle(String monthAnchor) {
  final date = parseDayKey(monthAnchor);
  return '${date.year}年${date.month}月';
}

/// 是否落在未来(用于日历上区分"还没到的日子")。
bool isFutureDay(String key, [DateTime? now]) => key.compareTo(todayKey(now)) > 0;


/// 相对今天的口语化描述,用于"今天/昨天"这类快捷标题。
String relativeDayLabel(String key, [DateTime? now]) {
  final today = todayKey(now);
  if (key == today) return '今天';
  if (key == addDays(today, -1)) return '昨天';
  if (key == addDays(today, 1)) return '明天';
  return fullDateLabel(key);
}
