import 'package:flutter/material.dart';

import '../core/day.dart';
import '../state/app_state.dart';
import '../ui/theme.dart';

/// 状态曲线:每天的完成率折线。
///
/// 用户的原话:"软件根据用户近期的每日任务完成率,绘制一个曲线:纵轴是完成率
/// (0% 25% 50% 75% 100%),横轴是日期(支持用户自选范围,默认近七天)。
/// 比如我每天在任务里布置了10项任务,完成了5项,那么曲线随着一天的结束
/// 自动绘制50%的点线"。
///
/// 两条设计上的取舍:
/// - **没安排任务的那天不画点,把线断开**。画成 0% 的话,"那天我没安排"
///   和"那天我全没做"看起来一样,曲线会骗人。
/// - 纵轴固定 0..100%,不随数据缩放。缩放的话"完成率从 80% 掉到 60%"
///   会被画成断崖,而它其实只是正常波动。
class StatusCurve extends StatefulWidget {
  const StatusCurve({super.key, required this.dark});

  final bool dark;

  @override
  State<StatusCurve> createState() => _StatusCurveState();
}

class _StatusCurveState extends State<StatusCurve> {
  /// 自选范围。默认近七天。
  int _days = 7;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _reload());
  }

  void _reload() {
    if (!mounted) return;
    _load(context, _days);
  }

  void _load(BuildContext context, int days) {
    final today = todayKey();
    AppScope.of(context).loadRangeCounts(addDays(today, -(days - 1)), today);
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final textSecondary = widget.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;

    final today = todayKey();
    // 从左到右是老 → 新。
    final days = [for (var i = _days - 1; i >= 0; i--) addDays(today, -i)];
    final points = [
      for (final day in days)
        (
          day: day,
          // 没安排任务时给 null:曲线上断一截,不假装是 0%。
          rate: (state.rangeCounts[day]?.total ?? 0) == 0
              ? null
              : state.rangeCounts[day]!.done / state.rangeCounts[day]!.total,
        ),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.show_chart, size: 16, color: textSecondary),
            const SizedBox(width: 6),
            Text(
              '状态曲线',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: textSecondary,
              ),
            ),
            const Spacer(),
            // 范围自选。默认近七天。
            PopupMenuButton<int>(
              initialValue: _days,
              tooltip: '选择范围',
              onSelected: (value) {
                setState(() => _days = value);
                _load(context, value);
              },
              itemBuilder: (context) => const [
                PopupMenuItem(value: 7, child: Text('近 7 天')),
                PopupMenuItem(value: 14, child: Text('近 14 天')),
                PopupMenuItem(value: 30, child: Text('近 30 天')),
              ],
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '近 $_days 天',
                    style: TextStyle(fontSize: 12.5, color: AppTheme.accent),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 18),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          padding: const EdgeInsets.fromLTRB(8, 10, 12, 6),
          decoration: BoxDecoration(
            color: widget.dark ? AppTheme.darkSurface : AppTheme.lightSurface,
            borderRadius: BorderRadius.circular(12),
          ),
          child: SizedBox(
            height: 132,
            child: CustomPaint(
              painter: _CurvePainter(
                points: points,
                accent: AppTheme.accent,
                grid:
                    (widget.dark
                            ? AppTheme.darkTextSecondary
                            : AppTheme.lightTextSecondary)
                        .withValues(alpha: 0.35),
                label: textSecondary,
                dark: widget.dark,
              ),
              size: Size.infinite,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          '纵轴是当天完成率。没安排任务的那天线会断开——那不是 0%,是没记。',
          style: TextStyle(fontSize: 11.5, height: 1.5, color: textSecondary),
        ),
      ],
    );
  }
}

/// 画折线本身。
class _CurvePainter extends CustomPainter {
  _CurvePainter({
    required this.points,
    required this.accent,
    required this.grid,
    required this.label,
    required this.dark,
  });

  final List<({String day, double? rate})> points;
  final Color accent;
  final Color grid;
  final Color label;
  final bool dark;

  /// 左侧留给纵轴刻度的宽度。
  static const _leftPad = 34.0;
  static const _rightPad = 6.0;
  static const _topPad = 8.0;
  static const _bottomPad = 20.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty) return;

    final plotWidth = size.width - _leftPad - _rightPad;
    final plotHeight = size.height - _topPad - _bottomPad;
    if (plotWidth <= 0 || plotHeight <= 0) return;

    double yFor(double rate) => _topPad + plotHeight * (1 - rate);
    // 只有一天时把它放在中间,不然会贴着左边缘。
    double xFor(int index) => points.length == 1
        ? _leftPad + plotWidth / 2
        : _leftPad + plotWidth * index / (points.length - 1);

    // 网格与纵轴刻度:0 25 50 75 100。
    final gridPaint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final rate in const [0.0, 0.25, 0.5, 0.75, 1.0]) {
      final y = yFor(rate);
      canvas.drawLine(
        Offset(_leftPad, y),
        Offset(size.width - _rightPad, y),
        gridPaint,
      );
      _text(
        canvas,
        '${(rate * 100).round()}%',
        Offset(0, y - 6),
        label,
        10,
        width: _leftPad - 6,
        align: TextAlign.right,
      );
    }

    // 折线。遇到 null 断开——"没安排"不该画成 0%。
    final linePaint = Paint()
      ..color = accent
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    var started = false;
    final path = Path();
    for (var i = 0; i < points.length; i++) {
      final rate = points[i].rate;
      if (rate == null) {
        started = false;
        continue;
      }
      final offset = Offset(xFor(i), yFor(rate));
      if (!started) {
        path.moveTo(offset.dx, offset.dy);
        started = true;
      } else {
        path.lineTo(offset.dx, offset.dy);
      }
    }
    canvas.drawPath(path, linePaint);

    // 点和填充:点让"一天一个值"看得见。
    final dotPaint = Paint()..color = accent;
    final fillPaint = Paint()..color = accent.withValues(alpha: 0.12);
    for (var i = 0; i < points.length; i++) {
      final rate = points[i].rate;
      if (rate == null) continue;
      final offset = Offset(xFor(i), yFor(rate));
      canvas.drawCircle(offset, 3, dotPaint);
      // 从 0 拉一条淡淡的竖线到点上:一眼看出那天的量级。
      canvas.drawRect(
        Rect.fromLTRB(offset.dx - 1, offset.dy, offset.dx + 1, yFor(0)),
        fillPaint,
      );
    }

    // 横轴日期:只标头、中、尾三个,全标会糊成一片。
    final marks = points.length <= 3
        ? [for (var i = 0; i < points.length; i++) i]
        : [0, points.length ~/ 2, points.length - 1];
    for (final index in marks) {
      final day = points[index].day;
      final parts = day.split('-');
      final shortLabel = '${int.parse(parts[1])}/${int.parse(parts[2])}';
      _text(
        canvas,
        shortLabel,
        Offset(xFor(index) - 18, size.height - _bottomPad + 4),
        label,
        10,
        width: 36,
        align: TextAlign.center,
      );
    }
  }

  void _text(
    Canvas canvas,
    String text,
    Offset offset,
    Color color,
    double size, {
    required double width,
    required TextAlign align,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: color, fontSize: size),
      ),
      textDirection: TextDirection.ltr,
      textAlign: align,
    )..layout(maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(_CurvePainter old) =>
      old.points != points || old.accent != accent || old.dark != dark;
}
