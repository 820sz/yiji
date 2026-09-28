import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:yiji/data/database.dart';
import 'package:yiji/data/goals.dart';
import 'package:yiji/data/palette.dart';
import 'package:yiji/data/record_store.dart';
import 'package:yiji/data/report_service.dart';
import 'package:yiji/data/sqlite_record_store.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// 数据层测试跑在桌面版 SQLite 上(内存库),不依赖模拟器。
///
/// 用真实 SQL 引擎而不是假对象:这里要验证的正是 SQL 本身
/// (日期范围、排序、唯一约束、事务),换成假对象就等于什么都没测。
void main() {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Database db;
  late RecordStore store;
  late ReportService reports;

  setUp(() async {
    db = await databaseFactory.openDatabase(inMemoryDatabasePath);
    // 直接调生产侧的建表函数,而不是在这里抄一份建表语句:
    // 抄的那份一旦漏了新增的列(比如 color),测试会以一种和真实运行无关的方式失败。
    await AppDatabase.createSchema(db);
    store = SqliteRecordStore(db);
    reports = ReportService(store);
  });

  tearDown(() => db.close());

  group('待办的增删改查', () {
    test('追加后按加入顺序返回', () async {
      await store.addTask('2026-09-14', '早上 码字1h半');
      await store.addTask('2026-09-14', '下午下课 健身');
      await store.addTask('2026-09-14', '晚上回寝 洗澡+洗衣服');

      final tasks = await store.tasksOfDay('2026-09-14');
      expect(tasks.map((t) => t.text), [
        '早上 码字1h半',
        '下午下课 健身',
        '晚上回寝 洗澡+洗衣服',
      ]);
    });

    test('只返回指定那一天', () async {
      await store.addTask('2026-09-14', '今天的事');
      await store.addTask('2026-09-15', '明天的事');

      expect((await store.tasksOfDay('2026-09-14')).single.text, '今天的事');
    });

    test('空白内容被拒绝', () async {
      expect(() => store.addTask('2026-09-14', '   '), throwsArgumentError);
    });

    test('内容两端的空白会被去掉', () async {
      await store.addTask('2026-09-14', '  读书  ');
      expect((await store.tasksOfDay('2026-09-14')).single.text, '读书');
    });

    test('勾选记录完成时刻,取消勾选清掉它', () async {
      final id = await store.addTask('2026-09-14', '健身');
      await store.setTaskDone(id, true);

      var task = (await store.tasksOfDay('2026-09-14')).single;
      expect(task.done, isTrue);
      expect(task.completedAt, isNotNull);

      await store.setTaskDone(id, false);
      task = (await store.tasksOfDay('2026-09-14')).single;
      expect(task.done, isFalse);
      expect(task.completedAt, isNull);
    });

    test('改内容', () async {
      final id = await store.addTask('2026-09-14', '旧内容');
      await store.updateTaskText(id, '新内容');
      expect((await store.tasksOfDay('2026-09-14')).single.text, '新内容');
    });

    test('删除', () async {
      final id = await store.addTask('2026-09-14', '要删的');
      await store.deleteTask(id);
      expect(await store.tasksOfDay('2026-09-14'), isEmpty);
    });
  });

  group('粘贴导入', () {
    test('多行一次加完,行首标记被剥掉', () async {
      final added = await store.addTasks('2026-09-14', [
        '- 早上 码字1h半',
        '1. 上午 码完字 读《人物》',
        '☑ 下午下课 健身',
        '   ',
        '晚上回寝 洗澡 + 洗衣服',
      ]);

      expect(added, 4);
      final tasks = await store.tasksOfDay('2026-09-14');
      expect(tasks.map((t) => t.text), [
        '早上 码字1h半',
        '上午 码完字 读《人物》',
        '下午下课 健身',
        '晚上回寝 洗澡 + 洗衣服',
      ]);
    });

    test('整段都是空行时不写入任何东西', () async {
      expect(await store.addTasks('2026-09-14', ['', '  ', '\n']), 0);
      expect(await store.tasksOfDay('2026-09-14'), isEmpty);
    });

    test('追加到已有待办之后,不覆盖原来的排序', () async {
      await store.addTask('2026-09-14', '已有的');
      await store.addTasks('2026-09-14', ['- 新来的']);

      final tasks = await store.tasksOfDay('2026-09-14');
      expect(tasks.map((t) => t.text), ['已有的', '新来的']);
    });
  });

  group('顺延未完成', () {
    test('只搬没完成的,并且搬到目标日末尾', () async {
      final doneId = await store.addTask('2026-09-14', '做完了的');
      await store.addTask('2026-09-14', '没做的A');
      await store.addTask('2026-09-14', '没做的B');
      await store.setTaskDone(doneId, true);
      await store.addTask('2026-09-15', '明天已有一条');

      final moved = await store.moveUndoneTasks('2026-09-14', '2026-09-15');
      expect(moved, 2);

      expect((await store.tasksOfDay('2026-09-14')).map((t) => t.text), ['做完了的']);
      expect((await store.tasksOfDay('2026-09-15')).map((t) => t.text), [
        '明天已有一条',
        '没做的A',
        '没做的B',
      ]);
    });

    test('没有未完成时不动任何数据', () async {
      final id = await store.addTask('2026-09-14', '都做完了');
      await store.setTaskDone(id, true);
      expect(await store.moveUndoneTasks('2026-09-14', '2026-09-15'), 0);
    });
  });

  group('日记', () {
    test('没写过返回 null', () async {
      expect(await store.journalOfDay('2026-09-14'), isNull);
    });

    test('同一天写两次是覆盖,不是新增', () async {
      await store.saveJournal('2026-09-14', '第一版');
      await store.saveJournal('2026-09-14', '改过的');

      expect((await store.journalOfDay('2026-09-14'))!.text, '改过的');
      expect(await store.journalsBetween('2026-09-01', '2026-09-30'), hasLength(1));
    });

    test('写成空白等于删除', () async {
      await store.saveJournal('2026-09-14', '待会儿删掉');
      await store.saveJournal('2026-09-14', '   ');
      expect(await store.journalOfDay('2026-09-14'), isNull);
    });

    test('区间查询按日期升序,且过滤掉空内容', () async {
      await store.saveJournal('2026-09-16', '十六号');
      await store.saveJournal('2026-09-14', '十四号');
      await store.saveJournal('2026-10-01', '十月的不该出现');

      final journals = await store.journalsBetween('2026-09-01', '2026-09-30');
      expect(journals.map((j) => j.day), ['2026-09-14', '2026-09-16']);
    });
  });

  group('聊天记录', () {
    test('先落库的排在前面', () async {
      await store.addMessage('user', '第一条');
      await store.addMessage('assistant', '第二条');

      final messages = await store.recentMessages();
      expect(messages.map((m) => m.content), ['第一条', '第二条']);
      expect(messages.first.isUser, isTrue);
      expect(messages.last.isUser, isFalse);
    });

    test('只保留最近 N 条,但仍是升序', () async {
      for (var i = 1; i <= 5; i++) {
        await store.addMessage('user', '第$i条');
      }
      final messages = await store.recentMessages(limit: 3);
      expect(messages.map((m) => m.content), ['第3条', '第4条', '第5条']);
    });

    test('清空只删对话', () async {
      await store.addTask('2026-09-14', '保留的待办');
      await store.addMessage('user', '删掉的对话');

      await store.clearMessages();

      expect(await store.recentMessages(), isEmpty);
      expect(await store.tasksOfDay('2026-09-14'), hasLength(1));
    });
  });

  group('周报统计', () {
    setUp(() async {
      // 2026-09-14 是周一,这一周是 14 至 20 日。
      await store.addTask('2026-09-13', '上周日的,不该算进来');
      await store.addTask('2026-09-14', '周一完成的事');
      final id = await store.addTask('2026-09-16', '周三完成的事');
      await store.setTaskDone(id, true);
      await store.addTask('2026-09-20', '周日没做完的事');
      await store.addTask('2026-09-21', '下周一,不该算进来');
    });

    test('区间是周一到周日,边界外的都排除', () async {
      final report = await reports.weekOf('2026-09-17');

      expect(report.startDay, '2026-09-14');
      expect(report.endDay, '2026-09-20');
      expect(report.total, 3);
      expect(report.tasks.map((t) => t.text), [
        '周一完成的事',
        '周三完成的事',
        '周日没做完的事',
      ]);
    });

    test('完成数、完成率、有记录天数', () async {
      final report = await reports.weekOf('2026-09-14');

      expect(report.doneCount, 1);
      expect(report.undoneTasks.map((t) => t.text), ['周一完成的事', '周日没做完的事']);
      expect(report.completionRate, closeTo(1 / 3, 1e-9));
      expect(report.activeDayCount, 3);
    });

    test('一条记录都没有时完成率是 0,不是 NaN', () async {
      final report = await reports.weekOf('2027-01-04');
      expect(report.total, 0);
      expect(report.completionRate, 0);
    });

    test('按天分组保持日期升序', () async {
      final report = await reports.weekOf('2026-09-14');
      expect(report.tasksByDay.keys.toList(), ['2026-09-14', '2026-09-16', '2026-09-20']);
    });
  });

  group('月报统计', () {
    test('覆盖整月,包括月末最后一天', () async {
      await store.addTask('2026-09-01', '月初');
      await store.addTask('2026-09-30', '月末');
      await store.addTask('2026-10-01', '十月,不该算进来');

      final report = await reports.monthOf('2026-09-15');
      expect(report.startDay, '2026-09-01');
      expect(report.endDay, '2026-09-30');
      expect(report.tasks.map((t) => t.text), ['月初', '月末']);
    });
  });

  group('给 AI 的上下文', () {
    test('包含统计、完成项、未完成项和当天想法', () async {
      final id = await store.addTask('2026-09-14', '健身');
      await store.setTaskDone(id, true);
      await store.addTask('2026-09-15', '读《人物》');
      await store.saveJournal('2026-09-14', '今天读完了 12 页');

      final report = await reports.weekOf('2026-09-14');
      final context = reports.aiContext(report, periodLabel: '9月14日 - 9月20日 周总结');

      expect(context, contains('计划 2 条,完成 1 条'));
      expect(context, contains('完成率 50%'));
      expect(context, contains('9月14日 健身'));
      expect(context, contains('9月15日 读《人物》'));
      expect(context, contains('今天读完了 12 页'));
    });

    test('没有未完成项时不出现那一段', () async {
      final report = await reports.weekOf('2027-01-04');
      final context = reports.aiContext(report, periodLabel: '空周');
      expect(context, isNot(contains('## 没完成的')));
      expect(context, contains('(无)'));
    });
  });

  group('纯文本报告', () {
    test('逐天列出时用勾叉标记完成状态', () async {
      final id = await store.addTask('2026-09-14', '完成的事');
      await store.setTaskDone(id, true);
      await store.addTask('2026-09-14', '没做的事');

      final report = await reports.weekOf('2026-09-14');
      final text = reports.plainReport(report, periodLabel: '测试周总结');

      expect(text, contains('测试周总结'));
      expect(text, contains('✓ 完成的事'));
      expect(text, contains('× 没做的事'));
      expect(text, contains('未完成:'));
    });
  });

  /// 粘贴解析是从原子笔记搬数据的关键路径,单独把各种写法覆盖一遍。
  group('粘贴文本的解析', () {
    test('普通多行原样拆开', () {
      expect(parseTaskLines('早上 码字\n中午 吃饭\n晚上 健身'), [
        '早上 码字',
        '中午 吃饭',
        '晚上 健身',
      ]);
    });

    test('剥掉各种行首标记', () {
      expect(
        parseTaskLines('- 破折号\n* 星号\n• 圆点\n1. 阿拉伯序号\n2、顿号序号\n'
            '一、中文序号\n[ ] 方框\n[x] 已勾方框\n☑ 勾选符号\n☐ 空方框\n✓ 对勾'),
        [
          '破折号',
          '星号',
          '圆点',
          '阿拉伯序号',
          '顿号序号',
          '中文序号',
          '方框',
          '已勾方框',
          '勾选符号',
          '空方框',
          '对勾',
        ],
      );
    });

    test('标记叠加也能剥干净', () {
      expect(parseTaskLines('- [ ] 两层标记'), ['两层标记']);
    });

    test('空行和只有空格的行被丢掉', () {
      expect(parseTaskLines('第一条\n\n   \n第二条\n'), ['第一条', '第二条']);
    });

    test('Windows 换行也能拆', () {
      expect(parseTaskLines('第一条\r\n第二条\r\n'), ['第一条', '第二条']);
    });

    test('正文里的符号不会被误剥', () {
      // 书名号、连字符、小数点都在正文中间或末尾,不该动。
      expect(parseTaskLines('读《人物》\n码字 2.5 小时\n读书-笔记'), [
        '读《人物》',
        '码字 2.5 小时',
        '读书-笔记',
      ]);
    });

    test('纯标记行会变成空行而被丢掉', () {
      expect(parseTaskLines('-\n1.\n☑'), isEmpty);
    });
  });

  group('目标与进度推进条', () {
    test('新建的目标当前值为 0', () async {
      await store.addGoal(
        title: '小说推进',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );

      final goals = await store.goals();
      expect(goals, hasLength(1));
      expect(goals.single.title, '小说推进');
      expect(goals.single.current, 0);
      expect(goals.single.target, 10000);
    });

    test('当前值等于所有进度条目之和', () async {
      final id = await store.addGoal(
        title: '小说推进',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      await store.addProgress(goalId: id, amount: 2000, day: '2026-09-14', note: '');
      await store.addProgress(goalId: id, amount: 1500, day: '2026-09-15', note: '');

      final goal = (await store.goals()).single;
      expect(goal.current, 3500);
      expect(goal.ratio, closeTo(0.35, 1e-9));
      expect(goal.remaining, 6500);
      expect(goal.reached, isFalse);
    });

    test('两个目标各自累计,互不影响', () async {
      final a = await store.addGoal(
        title: '小说',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      final b = await store.addGoal(
        title: '跑步',
        unit: '公里',
        target: 20,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.green,
      );
      await store.addProgress(goalId: a, amount: 2000, day: '2026-09-14', note: '');
      await store.addProgress(goalId: b, amount: 5, day: '2026-09-14', note: '');

      final goals = await store.goals();
      expect(goals.firstWhere((g) => g.id == a).current, 2000);
      expect(goals.firstWhere((g) => g.id == b).current, 5);
    });

    test('达标后 ratio 封顶在 1,超出部分不溢出', () async {
      final id = await store.addGoal(
        title: '跑步',
        unit: '公里',
        target: 10,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.green,
      );
      await store.addProgress(goalId: id, amount: 25, day: '2026-09-14', note: '');

      final goal = (await store.goals()).single;
      expect(goal.ratio, 1.0);
      expect(goal.reached, isTrue);
      expect(goal.remaining, 0);
    });

    test('删掉目标会连进度条目一起删,不留孤儿行', () async {
      final id = await store.addGoal(
        title: '小说',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      await store.addProgress(goalId: id, amount: 2000, day: '2026-09-14', note: '');

      await store.deleteGoal(id);

      expect(await store.goals(), isEmpty);
      expect(await store.progressEntriesOfGoal(id), isEmpty);
    });

    test('归档不影响历史条目', () async {
      final id = await store.addGoal(
        title: '小说',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      await store.addProgress(goalId: id, amount: 2000, day: '2026-09-14', note: '');
      await store.setGoalActive(id, false);

      final goal = (await store.goals()).single;
      expect(goal.active, isFalse);
      expect(goal.current, 2000);
    });

    test('能改目标和单条进度', () async {
      final id = await store.addGoal(
        title: '小说',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      final entryId =
          await store.addProgress(goalId: id, amount: 2000, day: '2026-09-14', note: '');

      await store.updateProgress(entryId, amount: 3000, note: '改过');
      expect((await store.goals()).single.current, 3000);

      await store.updateGoal(
        (await store.goals()).single.copyWith(target: 5000, title: '小说(改)'),
      );
      final updated = (await store.goals()).single;
      expect(updated.target, 5000);
      expect(updated.title, '小说(改)');
    });

    test('删掉一条进度,当前值跟着退回去', () async {
      final id = await store.addGoal(
        title: '小说',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      final entryId =
          await store.addProgress(goalId: id, amount: 2000, day: '2026-09-14', note: '');
      await store.deleteProgress(entryId);

      expect((await store.goals()).single.current, 0);
    });
  });

  group('未同步的已完成待办', () {
    test('只挑出已完成、且还没计入过进度的', () async {
      final goalId = await store.addGoal(
        title: '小说推进',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      final doneId = await store.addTask('2026-09-14', '上午 码字2k');
      await store.setTaskDone(doneId, true);
      await store.addTask('2026-09-14', '下午 健身');

      var pending = await store.unprocessedDoneTasks('2026-09-14', '2026-09-20');
      expect(pending.map((t) => t.text), ['上午 码字2k']);

      // 计入之后就不该再出现在待同步列表里。
      await store.addProgress(
        goalId: goalId,
        amount: 2000,
        day: '2026-09-14',
        note: '上午 码字2k',
        taskId: doneId,
        source: 'ai',
      );

      pending = await store.unprocessedDoneTasks('2026-09-14', '2026-09-20');
      expect(pending, isEmpty);
    });

    test('区间外的已完成待办不算进来', () async {
      final id = await store.addTask('2026-09-01', '上个月的事');
      await store.setTaskDone(id, true);

      final pending = await store.unprocessedDoneTasks('2026-09-14', '2026-09-20');
      expect(pending, isEmpty);
    });

    test('手动加的进度(没挂待办)不会把待办标成已同步', () async {
      final goalId = await store.addGoal(
        title: '小说推进',
        unit: '字',
        target: 10000,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      final taskId = await store.addTask('2026-09-14', '上午 码字2k');
      await store.setTaskDone(taskId, true);
      await store.addProgress(goalId: goalId, amount: 500, day: '2026-09-14', note: '手动');

      final pending = await store.unprocessedDoneTasks('2026-09-14', '2026-09-20');
      expect(pending.map((t) => t.id), [taskId]);
    });
  });

  group('日历用的每日计数', () {
    test('按天汇总总数与完成数', () async {
      final a = await store.addTask('2026-09-14', '甲');
      await store.addTask('2026-09-14', '乙');
      await store.setTaskDone(a, true);
      await store.addTask('2026-09-16', '丙');

      final counts = await store.taskCountsByDay('2026-09-01', '2026-09-30');
      expect(counts['2026-09-14']!.total, 2);
      expect(counts['2026-09-14']!.done, 1);
      expect(counts['2026-09-14']!.allDone, isFalse);
      expect(counts['2026-09-16']!.total, 1);
      expect(counts['2026-09-16']!.done, 0);
      expect(counts.containsKey('2026-09-15'), isFalse);
    });

    test('全部完成时 allDone 为真', () async {
      final id = await store.addTask('2026-09-14', '唯一一件事');
      await store.setTaskDone(id, true);

      final counts = await store.taskCountsByDay('2026-09-14', '2026-09-14');
      expect(counts['2026-09-14']!.allDone, isTrue);
    });
  });

  group('待办配色', () {
    test('默认是蓝色,可以改', () async {
      final id = await store.addTask('2026-09-14', '随便一条');
      expect((await store.tasksOfDay('2026-09-14')).single.color, TaskColor.blue);

      await store.updateTaskColor(id, TaskColor.pink);
      expect((await store.tasksOfDay('2026-09-14')).single.color, TaskColor.pink);
    });

    test('批量改配色只影响选中的那些', () async {
      final a = await store.addTask('2026-09-14', '甲');
      await store.addTask('2026-09-14', '乙');

      await store.updateTasksColor([a], TaskColor.green);

      final tasks = await store.tasksOfDay('2026-09-14');
      expect(tasks.firstWhere((t) => t.text == '甲').color, TaskColor.green);
      expect(tasks.firstWhere((t) => t.text == '乙').color, TaskColor.blue);
    });

    test('批量删除只删选中的', () async {
      final a = await store.addTask('2026-09-14', '甲');
      await store.addTask('2026-09-14', '乙');

      await store.deleteTasks([a]);

      expect((await store.tasksOfDay('2026-09-14')).map((t) => t.text), ['乙']);
    });
  });

  group('把待办挪到另一天', () {
    test('改日期后从原来那天消失', () async {
      final id = await store.addTask('2026-09-14', '挪走的事');
      await store.updateTaskDay(id, '2026-09-20');

      expect(await store.tasksOfDay('2026-09-14'), isEmpty);
      expect((await store.tasksOfDay('2026-09-20')).single.text, '挪走的事');
    });
  });

  group('聊天记录带思考过程', () {
    test('思考内容会被存下来', () async {
      await store.addMessage('assistant', '回答', reasoning: '先看数据再回答');

      final message = (await store.recentMessages()).single;
      expect(message.content, '回答');
      expect(message.reasoning, '先看数据再回答');
      expect(message.hasReasoning, isTrue);
    });

    test('没传思考内容时为空串,不算有思考', () async {
      await store.addMessage('user', '在吗');
      expect((await store.recentMessages()).single.hasReasoning, isFalse);
    });
  });

  group('v1 升级到 v2 不丢数据', () {
    /// 按 v1 的表结构建库并塞一条数据,然后用**生产侧的 open()** 打开它,
    /// 走真实的 onUpgrade 路径。
    ///
    /// 这是数据安全的关键路径:数据库是唯一事实源、没有云端副本,
    /// 一次升级写坏就没得恢复,所以它必须被真的跑一遍——
    /// 而不是在这里重抄一遍迁移语句(那只能证明抄得对)。
    test('旧的待办、日记、聊天都还在,新表和默认值也对', () async {
      final dir = await Directory.systemTemp.createTemp('yiji_migrate');
      final path = p.join(dir.path, 'yiji.db');
      addTearDown(() => dir.delete(recursive: true));

      // 第一步:按 v1 的结构建库,写成文件。
      final old = await databaseFactory.openDatabase(path);
      // v1 的 tasks 没有 color,messages 没有 reasoning。
      await old.execute('''
        CREATE TABLE tasks (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          day TEXT NOT NULL, text TEXT NOT NULL,
          done INTEGER NOT NULL DEFAULT 0, completed_at INTEGER,
          sort_order INTEGER NOT NULL DEFAULT 0, created_at INTEGER NOT NULL
        )
      ''');
      await old.execute('''
        CREATE TABLE journals (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          day TEXT NOT NULL UNIQUE, text TEXT NOT NULL, updated_at INTEGER NOT NULL
        )
      ''');
      await old.execute('''
        CREATE TABLE messages (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          role TEXT NOT NULL, content TEXT NOT NULL, created_at INTEGER NOT NULL
        )
      ''');
      await old.insert('tasks', {
        'day': '2026-09-14',
        'text': '旧版本记的待办',
        'done': 1,
        'sort_order': 1,
        'created_at': DateTime(2026, 9, 14).millisecondsSinceEpoch,
      });
      await old.insert('journals', {
        'day': '2026-09-14',
        'text': '旧版本写的想法',
        'updated_at': DateTime(2026, 9, 14).millisecondsSinceEpoch,
      });
      await old.insert('messages', {
        'role': 'assistant',
        'content': '旧版本的回复',
        'created_at': DateTime(2026, 9, 14).millisecondsSinceEpoch,
      });
      await old.setVersion(1);
      await old.close();

      // 第二步:用生产的打开方式升级。
      final upgraded = await AppDatabase.open(path: path);
      addTearDown(upgraded.close);
      final migrated = SqliteRecordStore(upgraded.db);

      final tasks = await migrated.tasksOfDay('2026-09-14');
      expect(tasks.single.text, '旧版本记的待办');
      expect(tasks.single.done, isTrue);
      // 新加的列有默认值,不会让老数据变成 NULL。
      expect(tasks.single.color, TaskColor.blue);

      expect((await migrated.journalOfDay('2026-09-14'))!.text, '旧版本写的想法');
      final message = (await migrated.recentMessages()).single;
      expect(message.content, '旧版本的回复');
      expect(message.reasoning, '');

      // 新表可用。
      await migrated.addGoal(
        title: '升级后新建的目标',
        unit: '字',
        target: 100,
        period: GoalPeriod.weekly,
        direction: GoalDirection.increase,
        color: TaskColor.blue,
      );
      expect((await migrated.goals()).single.title, '升级后新建的目标');
    });

    test('同一个库被打开两次不会重复加列', () async {
      final dir = await Directory.systemTemp.createTemp('yiji_migrate_twice');
      final path = p.join(dir.path, 'yiji.db');
      addTearDown(() => dir.delete(recursive: true));

      final first = await AppDatabase.open(path: path);
      await first.close();
      // 第二次打开时 version 已经是 2,不该再跑一遍 ALTER。
      final second = await AppDatabase.open(path: path);
      final store2 = SqliteRecordStore(second.db);
      await store2.addTask('2026-09-14', '能写就行');
      expect((await store2.tasksOfDay('2026-09-14')).single.text, '能写就行');
      await second.close();
    });
  });
}
