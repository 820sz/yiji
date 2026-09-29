import 'package:flutter/material.dart';

import '../data/models.dart';
import '../data/palette.dart';
import 'theme.dart';

/// 一条待办卡片,视觉与交互对齐 vivo 原子笔记。
///
/// 三种状态对应三种视觉:
/// - 未完成:实心淡彩底 + 深色粗体字 + 空心圆
/// - 已完成:灰底 + 灰色字 + 删除线 + 实心勾
/// - 选中(多选模式):左侧勾选框 + 轻微缩进
///
/// 交互分工([onToggleDone] 与 [onTap] 分开)是刻意的:
/// 点文字进编辑,点右边圆圈打钩。打钩是一天几十次的动作,
/// 如果它也要绕进编辑页,这个 app 每天都要多花几秒钟。
///
/// 打钩只做 140ms 的状态过渡,不做入场表演;入场动画只给刚加进来的那一条。
class TaskCard extends StatelessWidget {
  const TaskCard({
    super.key,
    required this.task,
    required this.onTap,
    this.onToggleDone,
    this.onLongPress,
    this.selected = false,
    this.selecting = false,
    this.onToggleSelect,
    this.dark = false,
    this.justAdded = false,
    this.reordering = false,
    this.dragHandle,
  });

  final Task task;

  /// 点文字:进编辑。
  final VoidCallback onTap;

  /// 点右边那个圈:打钩 / 取消。为 null 时整张卡片都走 [onTap]。
  final VoidCallback? onToggleDone;

  /// 长按:进入多选与排序。
  final VoidCallback? onLongPress;

  final bool selected;

  /// 是否处于多选模式(决定左边显示圆圈还是勾选框)。
  final bool selecting;

  final VoidCallback? onToggleSelect;
  final bool dark;

  /// 刚被加进来的那条:给一次轻柔的滑入,让用户看到它落在哪。
  final bool justAdded;

  /// 排序模式:卡片右侧让出把手的位置,并隐藏打钩圈(那一侧要留给拖拽)。
  final bool reordering;

  /// 排序把手(由 ReorderableListView 注入)。
  final Widget? dragHandle;

  @override
  Widget build(BuildContext context) {
    final fill = AppTheme.cardFill(task.color, done: task.done, dark: dark);
    final foreground = AppTheme.cardForeground(task.color, done: task.done, dark: dark);

    final card = Padding(
      padding: const EdgeInsets.only(bottom: AppTheme.cardGap),
      child: Material(
        color: fill,
        borderRadius: BorderRadius.circular(AppTheme.cardRadius),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: selecting ? onToggleSelect : onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 多选模式下的勾选框只在需要时占位,平时用打钩圆圈。
                AnimatedSize(
                  duration: AppTheme.fast,
                  curve: AppTheme.easeOut,
                  alignment: Alignment.centerLeft,
                  child: selecting
                      ? Padding(
                          padding: const EdgeInsets.only(right: 12, top: 1),
                          child: Icon(
                            selected ? Icons.check_box : Icons.check_box_outline_blank,
                            size: 22,
                            color:
                                selected ? AppTheme.accent : foreground.withValues(alpha: 0.5),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),
                Expanded(
                  child: Text(
                    task.text,
                    style: TextStyle(
                      fontSize: 16,
                      height: 1.45,
                      fontWeight: task.done ? FontWeight.w400 : FontWeight.w500,
                      color: foreground,
                      decoration: task.done ? TextDecoration.lineThrough : null,
                      decorationColor: foreground,
                      decorationThickness: 1.6,
                    ),
                  ),
                ),
                if (!selecting && !reordering)
                  Padding(
                    padding: const EdgeInsets.only(left: 10, top: 1),
                    child: _DoneMark(
                      done: task.done,
                      foreground: foreground,
                      dark: dark,
                      // 打钩与文字分开命中:点圈只打钩,点文字进编辑。
                      onTap: onToggleDone,
                    ),
                  ),
                if (reordering && dragHandle != null)
                  Padding(padding: const EdgeInsets.only(left: 6), child: dragHandle),
              ],
            ),
          ),
        ),
      ),
    );

    if (!justAdded) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 240),
      curve: AppTheme.easeOut,
      builder: (context, value, child) => Opacity(
        opacity: value,
        // 位移放在卡片**内部**,卡片本身的布局位置立刻就是最终位置。
        // 这样入场时不会推动下面的内容,列表看起来是"稳住"的。
        child: Transform.translate(offset: Offset(0, -10 * (1 - value)), child: child),
      ),
      child: card,
    );
  }
}

/// 右侧的完成标记。
///
/// 勾出现时用 140ms 的缩放 + 淡入:这是一天几十次的反馈层级,
/// 所以只做"让状态变化看得见",不做表演。
///
/// [onTap] 只包住这个圆圈,不包整张卡片:点圈是打钩,点文字是编辑,
/// 两个动作的命中区必须分开,否则用户想改字却把它打上了钩。
class _DoneMark extends StatelessWidget {
  const _DoneMark({
    required this.done,
    required this.foreground,
    required this.dark,
    this.onTap,
  });

  final bool done;
  final Color foreground;
  final bool dark;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    // 打钩的动效分两层:圆圈先被"填满",勾再从中心弹出来。
    // 只用图标切换会显得很突然——用户点了一下,东西直接换了,
    // 没有"我正在把它标记成完成"这个过程的反馈。
    final mark = SizedBox(
      width: 22,
      height: 22,
      child: AnimatedSwitcher(
        duration: AppTheme.fast,
        switchInCurve: AppTheme.easeOut,
        switchOutCurve: AppTheme.easeOut,
        transitionBuilder: (child, animation) => ScaleTransition(
          // 从 0.9 而不是 0 开始:没有东西是从"无"里出现的。
          scale: Tween<double>(begin: 0.9, end: 1).animate(animation),
          child: FadeTransition(opacity: animation, child: child),
        ),
        child: done
            // 已完成:实心圆 + 白勾。缩放从 0.7 起,做出"盖上去"的感觉。
            ? TweenAnimationBuilder<double>(
                key: const ValueKey('done'),
                tween: Tween(begin: 0.7, end: 1),
                duration: AppTheme.fast,
                curve: AppTheme.easeOut,
                builder: (context, value, child) =>
                    Transform.scale(scale: value, child: child),
                child: Container(
                  decoration: BoxDecoration(
                    color: foreground,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.check,
                    size: 15,
                    color: AppTheme.cardFillForContrast(dark),
                  ),
                ),
              )
            : Icon(
                Icons.radio_button_unchecked,
                key: const ValueKey('undone'),
                size: 22,
                color: foreground.withValues(alpha: 0.45),
              ),
      ),
    );

    if (onTap == null) return mark;
    return Semantics(
      button: true,
      label: done ? '标记为未完成' : '标记为已完成',
      child: InkResponse(
        onTap: onTap,
        radius: 22,
        child: Padding(
          // 圆圈本身只有 22px,撑到 44 才好点。
          padding: const EdgeInsets.all(6),
          child: mark,
        ),
      ),
    );
  }
}

/// 配色选择弹层,还原原子笔记那个"更换颜色"面板。
///
/// 返回选中的颜色;用户点取消返回 null。
Future<TaskColor?> showColorPicker(
  BuildContext context, {
  TaskColor? current,
}) {
  return showModalBottomSheet<TaskColor>(
    context: context,
    builder: (context) {
      final dark = Theme.of(context).brightness == Brightness.dark;
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '更换颜色',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 18,
                runSpacing: 14,
                alignment: WrapAlignment.center,
                children: [
                  for (final color in TaskColor.selectable)
                    _ColorDot(
                      color: color,
                      selected: color == (current ?? TaskColor.blue),
                      dark: dark,
                      onTap: () => Navigator.pop(context, color),
                    ),
                ],
              ),
              const SizedBox(height: 22),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => Navigator.pop(context),
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: const Text('取消'),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}

class _ColorDot extends StatelessWidget {
  const _ColorDot({
    required this.color,
    required this.selected,
    required this.dark,
    required this.onTap,
  });

  final TaskColor color;
  final bool selected;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fill = AppTheme.cardFill(color, done: false, dark: dark);
    return Semantics(
      button: true,
      label: color.label,
      selected: selected,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: AppTheme.fast,
          curve: AppTheme.easeOut,
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: fill,
            shape: BoxShape.circle,
            border: selected
                ? Border.all(color: AppTheme.accent, width: 2.5)
                : Border.all(color: Colors.transparent, width: 2.5),
          ),
          child: selected
              ? Icon(
                  Icons.check,
                  size: 20,
                  color: dark ? AppTheme.darkCardText : color.onFill,
                )
              : null,
        ),
      ),
    );
  }
}
