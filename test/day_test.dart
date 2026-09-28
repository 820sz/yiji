import 'package:flutter_test/flutter_test.dart';
import 'package:yiji/core/day.dart';

void main() {
  group('dayKey / parseDayKey', () {
    test('按本地时区补零', () {
      expect(dayKey(DateTime(2026, 9, 14)), '2026-09-14');
      expect(dayKey(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('与 parseDayKey 互为逆运算', () {
      for (final key in ['2026-01-01', '2024-02-29', '2026-12-31']) {
        expect(dayKey(parseDayKey(key)), key);
      }
    });

    test('不存在的日期被归一化,而不是抛异常', () {
      // 2026 不是闰年,输入 2 月 29 会落到 3 月 1 日。
      // 记下这个语义:宁可日期偏移,也不要让记录界面崩掉。
      expect(dayKey(parseDayKey('2026-02-29')), '2026-03-01');
    });
  });

  group('周的计算', () {
    test('周一至周日都归到同一个周一', () {
      // 2026-09-14 是周一。
      expect(mondayOf('2026-09-14'), '2026-09-14');
      expect(mondayOf('2026-09-20'), '2026-09-14');
    });

    test('周日是本周最后一天(不是下周第一天)', () {
      expect(sundayOf('2026-09-14'), '2026-09-20');
      expect(sundayOf('2026-09-20'), '2026-09-20');
    });

    test('跨月的周仍然连续', () {
      // 2026-09-28 是周一,那周跨到 10 月。
      expect(mondayOf('2026-10-01'), '2026-09-28');
      expect(sundayOf('2026-10-01'), '2026-10-04');
    });
  });

  group('月的计算', () {
    test('首末日正确', () {
      expect(firstDayOfMonth('2026-09-14'), '2026-09-01');
      expect(lastDayOfMonth('2026-09-14'), '2026-09-30');
    });

    test('闰年二月是 29 天', () {
      expect(lastDayOfMonth('2024-02-10'), '2024-02-29');
      expect(daysInMonth('2024-02-10'), 29);
      expect(lastDayOfMonth('2026-02-10'), '2026-02-28');
      expect(daysInMonth('2026-02-10'), 28);
    });

    test('十二月不会溢出到下一年', () {
      expect(lastDayOfMonth('2026-12-05'), '2026-12-31');
    });
  });

  group('相对标签', () {
    final now = DateTime(2026, 9, 14);

    test('今天/昨天/明天', () {
      expect(relativeDayLabel('2026-09-14', now), '今天');
      expect(relativeDayLabel('2026-09-13', now), '昨天');
      expect(relativeDayLabel('2026-09-15', now), '明天');
    });

    test('其他日期给完整日期加星期', () {
      expect(relativeDayLabel('2026-09-10', now), '9月10日 周四');
    });

    test('跨月时昨天也认得出来', () {
      expect(relativeDayLabel('2026-08-31', DateTime(2026, 9, 1)), '昨天');
    });
  });

  group('addDays', () {
    test('跨月、跨年都对', () {
      expect(addDays('2026-08-31', 1), '2026-09-01');
      expect(addDays('2026-12-31', 1), '2027-01-01');
      expect(addDays('2027-01-01', -1), '2026-12-31');
    });
  });
}
