import 'package:flutter/material.dart';

import '../core/day.dart';
import '../data/models.dart';
import '../state/app_state.dart';
import 'ai_avatar.dart';
import 'task_card.dart';
import 'task_sheets.dart';
import 'theme.dart';

/// 待办列表的排序方式。
///
/// 对照原子笔记的排序菜单:那里有"按提醒时间/按创建时间/自定义拖拽"。
/// 这个 app 暂时没有提醒,所以只保留真实可用的两种,并补一个他真实会需要的
/// 「未完成优先」——而不是照抄一个这里没有对应功能的菜单项。
enum TaskSort {
  custom('自定义顺序'),
  newest('新加的在前'),
  undoneFirst('没做完的在前');

  const TaskSort(this.label);

  final String label;

  TaskSort get next => TaskSort.values[(index + 1) % TaskSort.values.length];
}

/// 今天页:打开就是今天的待办,和他在原子笔记里的用法一致。
///
/// 日期可以左右翻,所以同一页也承担"回看历史某天"的职责。
class TodayScreen extends StatefulWidget {
  const TodayScreen({super.key});

  @override
  State<TodayScreen> createState() => _TodayScreenState();
}

class _TodayScreenState extends State<TodayScreen> {
  TaskSort _sort = TaskSort.custom;

  /// 排序模式:长按任意一条进来,右侧出现拖拽把手。
  ///
  /// 只在自定义排序下有意义——按别的字段排的时候拖拽的结果会被重新排掉。
  bool _reordering = false;

  /// 拖拽结束后把新顺序落库。
  ///
  /// 传进来的是**某一段**的顺序,所以要拼回当天完整顺序:
  /// 未完成段在前、已完成段在后,与界面展示一致。
  /// 下标换算由 ReorderableListView 的 onReorderItem 负责,这里拿到的就是最终位置。
  Future<void> _reorder(List<Task> section, int oldIndex, int newIndex) async {
    final state = AppScope.of(context);
    final reordered = [...section];
    reordered.insert(newIndex, reordered.removeAt(oldIndex));

    final all = _sorted(state.dayTasks);
    final unfinished = all.where((t) => !t.done).map((t) => t.id).toList();
    final finished = all.where((t) => t.done).map((t) => t.id).toList();
    final movedIds = reordered.map((t) => t.id).toList();
    final movedIsFinished = section.isNotEmpty && section.first.done;

    await state.reorderTasks([
      if (movedIsFinished) ...unfinished,
      ...movedIds,
      if (!movedIsFinished) ...finished,
    ]);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final id = AppScope.of(context).justAddedId;
    if (id == null) return;
    // 入场动画放完就清掉标记,否则任何一次重建都会让它再滑一次。
    Future.delayed(const Duration(milliseconds: 320), () {
      if (mounted) AppScope.of(context).clearJustAdded();
    });
  }

  List<Task> _sorted(List<Task> tasks) {
    final list = [...tasks];
    switch (_sort) {
      case TaskSort.custom:
        break;
      case TaskSort.newest:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      case TaskSort.undoneFirst:
        list.sort((a, b) {
          if (a.done == b.done) return a.sortOrder.compareTo(b.sortOrder);
          return a.done ? 1 : -1;
        });
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final tasks = state.dayTasks;
    final doneCount = tasks.where((t) => t.done).length;
    final selecting = state.selecting;
    // 先按用户选的排序排好,再拆成两段:未完成的在上,已完成的在下。
    // 分界本身是有信息量的——一眼就能看出"今天还剩几件"。
    final ordered = _sorted(tasks);
    final unfinished = ordered.where((t) => !t.done).toList();
    final finished = ordered.where((t) => t.done).toList();
    // 排序模式:两段各自可拖拽。分界夹在中间,所以分开渲染两个列表。
    final reorderable = _reordering && _sort == TaskSort.custom;

    return Column(
      children: [
        _Header(
          day: state.currentDay,
          total: tasks.length,
          doneCount: doneCount,
          sort: _sort,
          selectedCount: state.selected.length,
          selecting: selecting,
          reordering: reorderable,
          onShift: state.shiftDay,
          onToday: state.goToToday,
          onCycleSort: () => setState(() => _sort = _sort.next),
          onToggleReorder: () => setState(() {
            // 进入排序模式时自动切到"自定义":别的排序方式会把拖出来的
            // 顺序立刻重排掉,那样拖了等于没拖。
            if (!_reordering) _sort = TaskSort.custom;
            _reordering = !_reordering;
            if (_reordering) state.clearSelection();
          }),
          onCancelSelect: () {
            setState(() => _reordering = false);
            state.clearSelection();
          },
          onOpenDay: () => showDayEditor(context, state.currentDay),
        ),
        Expanded(
          child: Stack(
            children: [
              if (state.loading && tasks.isEmpty)
                const Center(child: CircularProgressIndicator())
              else
                ListView(
                  // 底部留出浮动按钮的高度,最后一条才不会被盖住。
                  padding: EdgeInsets.fromLTRB(
                    AppTheme.pagePadding,
                    4,
                    AppTheme.pagePadding,
                    selecting ? 96 : 152,
                  ),
                  children: [
                    if (tasks.isEmpty)
                      const _EmptyHint()
                    else ...[
                      _TaskSection(
                        tasks: unfinished,
                        day: state.currentDay,
                        dark: dark,
                        selecting: selecting,
                        selectedIds: state.selected,
                        justAddedId: state.justAddedId,
                        reorderable: reorderable,
                        sortIsCustom: _sort == TaskSort.custom,
                        onReorder: _reorder,
                      ),
                      // 已完成与未完成之间的分界。原子笔记里这条线很明显,
                      // 它就是"今天还剩什么"的视觉答案,所以带上剩余条数。
                      if (finished.isNotEmpty) ...[
                        _DoneDivider(count: finished.length),
                        _TaskSection(
                          tasks: finished,
                          day: state.currentDay,
                          dark: dark,
                          selecting: selecting,
                          selectedIds: state.selected,
                          justAddedId: state.justAddedId,
                          reorderable: reorderable,
                          sortIsCustom: _sort == TaskSort.custom,
                          onReorder: _reorder,
                        ),
                      ],
                    ],
                    const SizedBox(height: 8),
                    _JournalCard(day: state.currentDay, journal: state.dayJournal),
                  ],
                ),
              if (selecting)
                Positioned(
                  left: 0,
                  right: 0,
                  bottom: 0,
                  child: _SelectionBar(
                    reordering: reorderable,
                    onToggleReorder: () =>
                        setState(() => _reordering = !_reordering),
                    onColor: () async {
                      final color = await showColorPicker(context);
                      if (color != null) await state.setSelectedColor(color);
                    },
                    onDelete: state.deleteSelected,
                    onToggleAll: () {
                      final all =
                          state.dayTasks.every((t) => state.selected.contains(t.id));
                      for (final task in state.dayTasks) {
                        final has = state.selected.contains(task.id);
                        if (all == has) state.toggleSelection(task.id);
                      }
                    },
                  ),
                ),
              if (!selecting)
                Positioned(
                  right: AppTheme.pagePadding,
                  bottom: 20,
                  child: FloatingActionButton(
                    onPressed: () => showAddTaskSheet(context),
                    tooltip: '加任务',
                    child: const Icon(Icons.add),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 一段待办列表(未完成段或已完成段)。
///
/// 抽出来是因为两段要分别渲染,而且都支持拖拽:分界线夹在中间,
/// 所以不能用一个大列表,只能两个 ReorderableListView。
/// 待办列表里的一段(未完成 / 已完成)。分两段是因为中间要插那条分界线,
/// 所以不能用一个大列表,只能两个 ReorderableListView。
class _TaskSection extends StatelessWidget {
  const _TaskSection({
    required this.tasks,
    required this.day,
    required this.dark,
    required this.selecting,
    required this.selectedIds,
    required this.justAddedId,
    required this.reorderable,
    required this.onReorder,
    this.sortIsCustom = true,
  });

  final List<Task> tasks;
  final String day;
  final bool dark;
  final bool selecting;
  final Set<int> selectedIds;
  final int? justAddedId;
  final bool reorderable;
  final bool sortIsCustom;
  final void Function(List<Task>, int, int) onReorder;

  @override
  Widget build(BuildContext context) {
    // 两个 ReorderableListView 同时挂在树上,key 必须各自唯一。
    return ReorderableListView.builder(
      key: PageStorageKey('section-${tasks.isEmpty ? 'empty' : tasks.first.done}'),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      buildDefaultDragHandles: false,
      itemCount: tasks.length,
      onReorderItem: (oldIndex, newIndex) => onReorder(tasks, oldIndex, newIndex),
      itemBuilder: (context, index) {
        final task = tasks[index];
        return _TaskRow(
          key: ValueKey('task-${task.id}'),
          task: task,
          day: day,
          index: index,
          dark: dark,
          selecting: selecting,
          selected: selectedIds.contains(task.id),
          justAdded: justAddedId == task.id,
          reorderable: reorderable,
          sortIsCustom: sortIsCustom,
        );
      },
    );
  }
}

/// 一条待办。
///
/// 交互分工:
/// - 点文字 → 进编辑页
/// - 点右边圆圈 → 打钩(一天几十次的动作,不给它加绕路)
/// - **左滑 → 标记完成**(这也是几十次的动作,不该比打钩更难)
/// - **右滑 → 删除**(破坏性的那个放后面,而且带撤回)
/// - **长按 → 直接拖着排序**(不用先进"排序模式")
/// - 多选模式下的勾选框 → 批量操作
class _TaskRow extends StatelessWidget {
  const _TaskRow({
    super.key,
    required this.task,
    required this.day,
    required this.index,
    required this.dark,
    required this.selecting,
    required this.selected,
    this.justAdded = false,
    this.reorderable = false,
    this.sortIsCustom = true,
  });

  final Task task;
  final String day;
  final int index;
  final bool dark;
  final bool selecting;
  final bool selected;
  final bool justAdded;
  final bool reorderable;

  /// 当前排序方式是不是"自定义"。不是的话长按不能用来拖动(会被重排掉)。
  final bool sortIsCustom;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);

    final card = Dismissible(
      key: ValueKey('dismiss-${task.id}'),
      // 左滑完成、右滑删除。direction 用 horizontal 才两个方向都收手势。
      direction: selecting || reorderable
          ? DismissDirection.none
          : DismissDirection.horizontal,
      background: const _SwipeBackground(done: true),
      secondaryBackground: const _SwipeBackground(done: false),
      // 两个动作都必须在 dismiss 动画**之前**落库并刷新列表。
      // 放在 onDismissed 里是异步的,会出现"已经通知重建、列表里却还有这条"
      // 的窗口,Flutter 会直接抛 "A dismissed Dismissible widget is still
      // part of the tree"(debug 下整屏红)。
      confirmDismiss: (direction) async {
        if (direction == DismissDirection.startToEnd) {
          // 右滑删除,给一次撤回的机会:左滑是完成,右滑一步就是不可逆的删除,
          // 太容易误触了。
          return await _confirmDelete(context, state);
        }
        await state.toggleTaskOn(day, task);
        // 这一条的状态已经变了,列表刷新后它会被挪到"已完成"那一段,
        // 所以这里返回 false 让 Dismissible 自己收回去,不走 dismiss 流程。
        return false;
      },
      child: _DragToReorder(
        // 只在排序模式下让长按变成拖动:平时长按是"进入多选"(既有行为,
        // 用户已经习惯),两个长按只能留一个。排序模式下整张卡片按住就能拖,
        // 不用去够右边那个小把手。
        enabled: !selecting && reorderable,
        index: index,
        child: TaskCard(
          task: task,
          dark: dark,
          selected: selected,
          selecting: selecting,
          justAdded: justAdded,
          reordering: reorderable,
          onToggleSelect: () => state.toggleSelection(task.id),
          onTap: selecting
              ? () => state.toggleSelection(task.id)
              : () => showTaskEditor(context, task: task, day: day),
          onToggleDone: selecting ? null : () => state.toggleTaskOn(day, task),
          // 长按进多选。排序模式下长按被拖动接管(见上面的 _DragToReorder),
          // 所以那时不接这个回调,免得两个手势抢。
          onLongPress: selecting
              ? () => state.toggleSelection(task.id)
              : (reorderable ? null : () => state.toggleSelection(task.id)),
          dragHandle: reorderable
              ? ReorderableDragStartListener(
                  index: index,
                  child: Icon(
                    Icons.drag_handle,
                    size: 22,
                    color: dark
                        ? AppTheme.darkTextSecondary
                        : AppTheme.lightTextSecondary,
                  ),
                )
              : null,
        ),
      ),
    );

    return card;
  }

  /// 右滑删除前的确认。
  Future<bool> _confirmDelete(BuildContext context, AppState state) async {
    final messenger = ScaffoldMessenger.of(context);
    await state.deleteTaskOn(day, task);
    messenger.showSnackBar(
      SnackBar(
        content: Text('已删除「${task.text}」'),
        action: SnackBarAction(
          label: '撤回',
          onPressed: () => state.restoreTask(task),
        ),
      ),
    );
    return false;
  }
}

/// 长按就把这条拖起来排序。
///
/// 只在**排序模式打开时**启用(见 `_reordering`)。平时长按留给"进入多选":
/// 两者都是长按,只能有一个生效,而多选是已有行为、用户已经习惯。
/// 排序模式下整张卡片按住就能拖,不用去够右边那个把手。
class _DragToReorder extends StatelessWidget {
  const _DragToReorder({
    required this.enabled,
    required this.index,
    required this.child,
  });

  final bool enabled;
  final int index;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (!enabled) return child;
    return ReorderableDelayedDragStartListener(
      index: index,
      child: child,
    );
  }
}

/// 已完成与未完成之间的分界。
class _DoneDivider extends StatelessWidget {
  const _DoneDivider({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final textSecondary = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    final lineColor = Theme.of(context).brightness == Brightness.dark
        ? const Color(0xFF2A2D33)
        : const Color(0xFFE3E5EA);

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: AppTheme.cardGap),
      child: Row(
        children: [
          Text(
            '已完成 $count',
            style: TextStyle(fontSize: 12.5, color: textSecondary),
          ),
          const SizedBox(width: 10),
          Expanded(child: Container(height: 1, color: lineColor)),
        ],
      ),
    );
  }
}

/// 滑动时露出的背景。
///
/// [done] 为真表示这是**左滑**(标为完成)露出来的那一侧;为假是右滑(删除)。
/// 两边的图标和颜色必须一眼能分开,否则用户分不清这一滑会做什么。
class _SwipeBackground extends StatelessWidget {
  const _SwipeBackground({required this.done});

  final bool done;

  @override
  Widget build(BuildContext context) {
    return Container(
      // 左滑露出的在右边,右滑露出的在左边。
      alignment: done ? Alignment.centerRight : Alignment.centerLeft,
      padding: EdgeInsets.only(
        right: done ? 22 : 0,
        left: done ? 0 : 22,
        bottom: AppTheme.cardGap,
      ),
      child: Icon(
        done ? Icons.check_circle_outline : Icons.delete_outline,
        color: done ? AppTheme.accent : const Color(0xFFE05252),
      ),
    );
  }
}

/// 头部:大号标题 + 计数副标题 + 搜索/排序图标。
///
/// 布局照着原子笔记:左边"待办 / N条待办",右边搜索与排序。
/// 这里把排序做成直接可点的循环按钮(那边是弹出菜单),因为只有三种模式,
/// 少一层交互更省事;菜单里那几项在这个 app 里没有对应功能。
class _Header extends StatelessWidget {
  const _Header({
    required this.day,
    required this.total,
    required this.doneCount,
    required this.sort,
    required this.selectedCount,
    required this.selecting,
    required this.reordering,
    required this.onShift,
    required this.onToday,
    required this.onCycleSort,
    required this.onToggleReorder,
    required this.onCancelSelect,
    required this.onOpenDay,
  });

  final String day;
  final int total;
  final int doneCount;
  final TaskSort sort;
  final int selectedCount;
  final bool selecting;
  final bool reordering;
  final void Function(int) onShift;
  final VoidCallback onToday;
  final VoidCallback onCycleSort;
  final VoidCallback onToggleReorder;
  final VoidCallback onCancelSelect;
  final VoidCallback onOpenDay;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final isToday = day == todayKey();

    if (selecting) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
        child: Row(
          children: [
            IconButton(
              onPressed: onCancelSelect,
              icon: Icon(Icons.close, color: textPrimary),
              tooltip: '取消',
            ),
            Expanded(
              // 选中数量每点一下都变,文字直接跳会显得很生硬;
              // 180ms 的交叉淡入让数字变化看起来是"滑过去"的。
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                switchInCurve: AppTheme.easeOut,
                switchOutCurve: AppTheme.easeOut,
                transitionBuilder: (child, animation) => FadeTransition(
                  opacity: animation,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0, 0.25),
                      end: Offset.zero,
                    ).animate(animation),
                    child: child,
                  ),
                ),
                child: Text(
                  reordering ? '拖动右侧把手排序' : '已选择 $selectedCount 项',
                  key: ValueKey('$reordering-$selectedCount'),
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: reordering ? 15 : 17,
                    fontWeight: FontWeight.w600,
                    color: textPrimary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 48),
          ],
        ),
      );
    }

    return Padding(
      // 顶部至少留 8:万一某个 ROM 少报了状态栏高度,SafeArea 让不出足够空间时
      // 标题也不至于贴到屏幕最上沿。
      padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 8, 8, 10),
      child: Row(
        children: [
          GestureDetector(
            onTap: isToday ? null : onToday,
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      relativeDayLabel(day),
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w700,
                        height: 1.15,
                        color: textPrimary,
                      ),
                    ),
                    if (!isToday) ...[
                      const SizedBox(width: 6),
                      Icon(Icons.undo, size: 15, color: textSecondary),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  total == 0 ? '暂无任务' : '$total 条任务 · 完成 $doneCount',
                  style: TextStyle(fontSize: 13, color: textSecondary),
                ),
              ],
            ),
          ),
          const Spacer(),
          IconButton(
            onPressed: onOpenDay,
            icon: Icon(Icons.search, color: textPrimary),
            tooltip: '看这一天',
          ),
          IconButton(
            onPressed: onCycleSort,
            icon: Icon(Icons.sort, color: textPrimary),
            tooltip: '排序:${sort.label}',
          ),
          // 排序模式:进去之后长按卡片就能拖动排序。
          // 独立一个按钮而不是塞进排序循环里:"换排序方式"和"我要手动挪位置"
          // 是两件事,混在一起用户找不到后者。
          IconButton(
            onPressed: onToggleReorder,
            icon: Icon(
              reordering ? Icons.check : Icons.drag_indicator,
              color: reordering ? AppTheme.accent : textPrimary,
            ),
            tooltip: reordering ? '完成排序' : '调整顺序',
          ),
        ],
      ),
    );
  }
}

/// 底部多选操作栏,还原原子笔记的"颜色 / 提醒 / 删除 / 更多"。
///
/// 少一项「提醒」是刻意的:这个 app 没有通知能力,摆一个点不动的按钮
/// 比不摆更糟。
class _SelectionBar extends StatelessWidget {
  const _SelectionBar({
    required this.reordering,
    required this.onToggleReorder,
    required this.onColor,
    required this.onDelete,
    required this.onToggleAll,
  });

  final bool reordering;
  final VoidCallback onToggleReorder;
  final VoidCallback onColor;
  final VoidCallback onDelete;
  final VoidCallback onToggleAll;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return Material(
      color: surface,
      elevation: 8,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // 排序按钮一直在:它既是"进入排序"也是"排好了"。
              _BarAction(
                icon: reordering ? Icons.check : Icons.swap_vert,
                label: reordering ? '排好了' : '排序',
                color: reordering ? AppTheme.accent : textSecondary,
                onTap: onToggleReorder,
              ),
              _BarAction(
                icon: Icons.palette_outlined,
                label: '颜色',
                color: textSecondary,
                onTap: onColor,
              ),
              _BarAction(
                icon: Icons.delete_outline,
                label: '删除',
                color: const Color(0xFFE05252),
                onTap: onDelete,
              ),
              _BarAction(
                icon: Icons.done_all,
                label: '全选',
                color: textSecondary,
                onTap: onToggleAll,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BarAction extends StatelessWidget {
  const _BarAction({
    required this.icon,
    required this.label,
    required this.color,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 22, color: color),
            const SizedBox(height: 3),
            Text(label, style: TextStyle(fontSize: 11.5, color: color)),
          ],
        ),
      ),
    );
  }
}

/// 空状态:不是一句"暂无数据",而是把下一步动作直接摆出来。
///
/// 图标用和开屏、桌面图标同一套的品牌标记,而不是随手一个 Material 图标——
/// 空状态是用户最容易看到"这个 app 长什么样"的地方。
class _EmptyHint extends StatelessWidget {
  const _EmptyHint();

  @override
  Widget build(BuildContext context) {
    final textSecondary = Theme.of(context).brightness == Brightness.dark
        ? AppTheme.darkTextSecondary
        : AppTheme.lightTextSecondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 48),
      child: Column(
        children: [
          const BrandMark(size: 56, radius: 16),
          const SizedBox(height: 18),
          Text('今天还没有任务', style: TextStyle(fontSize: 15, color: textSecondary)),
          const SizedBox(height: 6),
          Text(
            '点右下角加一条',
            style: TextStyle(fontSize: 13, color: textSecondary.withValues(alpha: 0.8)),
          ),
        ],
      ),
    );
  }
}

/// 每天的想法/收获。用卡片展示,点开才进编辑器——避免长期占着屏幕。
class _JournalCard extends StatelessWidget {
  const _JournalCard({required this.day, required this.journal});

  final String day;
  final Journal? journal;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final hasContent = journal != null && !journal!.isEmpty;

    return Material(
      color: surface,
      borderRadius: BorderRadius.circular(AppTheme.cardRadius),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showJournalEditor(context, day, journal?.text ?? ''),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Icon(Icons.edit_note, size: 19, color: AppTheme.accent),
                  const SizedBox(width: 7),
                  Text(
                    '今天的想法 / 收获',
                    style: TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                      color: textPrimary,
                    ),
                  ),
                  const Spacer(),
                  Icon(Icons.chevron_right, size: 19, color: textSecondary),
                ],
              ),
              const SizedBox(height: 9),
              Text(
                hasContent ? journal!.text : '写两句今天的想法',
                maxLines: hasContent ? 6 : 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14.5,
                  height: 1.6,
                  color: hasContent ? textPrimary : textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
