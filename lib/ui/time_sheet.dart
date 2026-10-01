import 'package:flutter/material.dart';

import 'theme.dart';

/// 选一个时刻(HH:mm),自建而不是用系统的时间选择器。
///
/// 为什么自己写:系统的 Material 时间选择器在 24 小时制下会把 0–23 全部画在
/// 同一个钟面圈上,数字互相挤在一起、指针压着数字(用户截图里就是这个),
/// 想点 8 点很容易点到 20 点。而这是个"设个提醒"的日常动作,不该需要瞄准。
///
/// 这里改成两列滚动:左列小时(00–23)、右列分钟(00/05/…/55,可再精确到个位)。
/// 滚动列表天然不会点错,也不会因为屏幕矮而挤成一团。
Future<String?> showTimePickerSheet(
  BuildContext context, {
  required String initial,
}) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    // 高度是固定的,拖拽没有意义,关掉免得误触关掉已选的值。
    enableDrag: false,
    builder: (_) => _TimeSheet(initial: initial),
  );
}

/// 把 `HH:mm` 拆成小时和分钟;解析不出来时用 [fallback]。
({int hour, int minute}) parseHhMm(String? at, {int fallbackHour = 8}) {
  if (at == null) return (hour: fallbackHour, minute: 0);
  final parts = at.split(':');
  if (parts.length != 2) return (hour: fallbackHour, minute: 0);
  final hour = int.tryParse(parts[0]);
  final minute = int.tryParse(parts[1]);
  if (hour == null || minute == null) return (hour: fallbackHour, minute: 0);
  return (hour: hour.clamp(0, 23), minute: minute.clamp(0, 59));
}

String formatHhMm(int hour, int minute) =>
    '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

class _TimeSheet extends StatefulWidget {
  const _TimeSheet({required this.initial});

  final String initial;

  @override
  State<_TimeSheet> createState() => _TimeSheetState();
}

class _TimeSheetState extends State<_TimeSheet> {
  late int _hour;
  late int _minute;

  static const _itemExtent = 44.0;
  static const _listHeight = _itemExtent * 5;

  @override
  void initState() {
    super.initState();
    final parsed = parseHhMm(widget.initial);
    _hour = parsed.hour;
    _minute = parsed.minute;
  }

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '提醒时间',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              '到点会发系统通知',
              style: TextStyle(fontSize: 12.5, color: textSecondary),
            ),
            const SizedBox(height: 14),
            // 中间那行是被选中的值,上下各留两条,做出"滚轮"的感觉。
            SizedBox(
              height: _listHeight,
              child: Stack(
                children: [
                  // 选中行的高亮,先画在底层。
                  Positioned(
                    left: 0,
                    right: 0,
                    top: _itemExtent * 2,
                    height: _itemExtent,
                    child: Container(
                      decoration: BoxDecoration(
                        color: AppTheme.accent.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        child: _Wheel(
                          count: 24,
                          selected: _hour,
                          itemExtent: _itemExtent,
                          semanticLabel: '小时',
                          format: (i) => i.toString().padLeft(2, '0'),
                          onChanged: (value) => setState(() => _hour = value),
                          textColor: textPrimary,
                          fadedColor: textSecondary,
                        ),
                      ),
                      Text(
                        ':',
                        style: TextStyle(
                          fontSize: 26,
                          fontWeight: FontWeight.w600,
                          color: textPrimary,
                        ),
                      ),
                      Expanded(
                        child: _Wheel(
                          count: 60,
                          selected: _minute,
                          itemExtent: _itemExtent,
                          semanticLabel: '分钟',
                          format: (i) => i.toString().padLeft(2, '0'),
                          onChanged: (value) => setState(() => _minute = value),
                          textColor: textPrimary,
                          fadedColor: textSecondary,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: const Text('取消'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  flex: 2,
                  child: FilledButton(
                    onPressed: () =>
                        Navigator.pop(context, formatHhMm(_hour, _minute)),
                    style: FilledButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    child: const Text('确定'),
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

/// 一个可滚动的数字轮。滚到哪就选到哪,不需要瞄准。
class _Wheel extends StatefulWidget {
  const _Wheel({
    required this.count,
    required this.selected,
    required this.itemExtent,
    required this.format,
    required this.onChanged,
    required this.textColor,
    required this.fadedColor,
    required this.semanticLabel,
  });

  final int count;
  final int selected;
  final double itemExtent;
  final String Function(int) format;
  final ValueChanged<int> onChanged;
  final Color textColor;
  final Color fadedColor;
  final String semanticLabel;

  @override
  State<_Wheel> createState() => _WheelState();
}

class _WheelState extends State<_Wheel> {
  late final ScrollController _controller = ScrollController(
    // 选中项要落在中间那条。列表本身有上下各两格的 padding,所以偏移是
    // "选中项前面有几格" 减去那两格,不能直接乘。
    initialScrollOffset: _initialOffset(),
  );

  double _initialOffset() => _initialOffsetFor(widget.selected);

  /// 让第 [index] 项落在中间那条高亮上所需的滚动偏移。
  double _initialOffsetFor(int index) {
    // 高亮行在容器里是第 2 格(top = itemExtent * 2),所以把第 index 项
    // 滚到"容器顶部往下 2 格"的位置即可。
    final raw = (index - 2) * widget.itemExtent;
    return raw > 0 ? raw : 0;
  }

  @override
  void didUpdateWidget(_Wheel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 外部改了选中值(比如重新打开时换了初值)就把轮子也滚过去。
    if (oldWidget.selected == widget.selected || !_controller.hasClients) return;
    _controller.animateTo(
      _initialOffset(),
      duration: AppTheme.fast,
      curve: AppTheme.easeOut,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollEndNotification>(
      onNotification: (notification) {
        // 停下来时吸附到最近的一格。
        final index = (_controller.offset / widget.itemExtent).round() + 2;
        final clamped = index.clamp(0, widget.count - 1);
        if (clamped != widget.selected) {
          // 先让选中值变,再滚到吸附位置:两者顺序反了会在滚动回调里读到旧值。
          widget.onChanged(clamped);
          _controller.animateTo(
            _initialOffsetFor(clamped),
            duration: AppTheme.fast,
            curve: AppTheme.easeOut,
          );
        }
        return false;
      },
      child: ListView.builder(
        controller: _controller,
        itemExtent: widget.itemExtent,
        // 不做额外 padding:偏移量按"选中项前面有几格"算,靠 clamp 保证两端不越界,
        // 加 padding 反而会让边界的吸附算错一格。
        itemCount: widget.count,
        itemBuilder: (context, index) {
          final distance = (index - widget.selected).abs();
          return Center(
            child: Text(
              widget.format(index),
              style: TextStyle(
                fontSize: distance == 0 ? 26 : 20,
                fontWeight: distance == 0 ? FontWeight.w600 : FontWeight.w400,
                // 离选中项越远越淡,一眼能看出哪条是当前值。
                color: distance == 0
                    ? widget.textColor
                    : widget.fadedColor.withValues(
                        alpha: distance == 1 ? 0.55 : 0.3,
                      ),
              ),
            ),
          );
        },
      ),
    );
  }
}
