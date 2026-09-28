import 'package:flutter/material.dart';

/// 待办卡片配色。
///
/// 取自 vivo 原子笔记:未完成 = 实心淡彩底 + 深色字,已完成 = 灰底 + 灰删除线。
/// 之所以把候选做成一小组固定色而不是任意取色,是为了让配色始终成体系——
/// 用户按"每类事一个颜色"来分,而不是每天随手挑一个。
enum TaskColor {
  yellow('柠檬黄', 0xFFFBE8A6, 0xFF1C1C1E),
  green('薄荷绿', 0xFFC9E7D0, 0xFF1C1C1E),
  blue('晴空蓝', 0xFFBFDFF5, 0xFF1C1C1E),
  orange('蜜桃橙', 0xFFFAD9A9, 0xFF1C1C1E),
  pink('樱花粉', 0xFFF9CDD1, 0xFF1C1C1E),
  purple('薰衣草', 0xFFD8D2F0, 0xFF1C1C1E),
  graphite('石墨黑', 0xFF2E2E30, 0xFFEDEDED);

  const TaskColor(this.label, this._fill, this._onFill);

  /// 选择器里显示的名字。
  final String label;

  final int _fill;
  final int _onFill;

  /// 卡片底色。
  Color get fill => Color(_fill);

  /// 卡片上文字的颜色。深色底要配浅色字。
  Color get onFill => Color(_onFill);

  /// 用于持久化的稳定键名。**不要用 `index`**:枚举顺序一变,历史数据就错位。
  String get key => name;

  static TaskColor fromKey(String? key) {
    for (final color in TaskColor.values) {
      if (color.name == key) return color;
    }
    return TaskColor.blue;
  }

  /// 选择器里的候选顺序。
  static const selectable = [
    TaskColor.yellow,
    TaskColor.green,
    TaskColor.blue,
    TaskColor.orange,
    TaskColor.pink,
    TaskColor.purple,
    TaskColor.graphite,
  ];
}
