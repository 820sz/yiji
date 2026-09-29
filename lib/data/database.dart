import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// 本地 SQLite 库的建库与升级。
///
/// 数据库是唯一事实源,没有云端副本,所以每次升级都必须保留既有数据:
/// 只允许加表、加列,不重建表。
class AppDatabase {
  AppDatabase._(this.db);

  final Database db;

  static const _fileName = 'yiji.db';

  /// v2:待办配色、聊天思考过程、目标与进度推进条。
  /// v3:聊天按会话隔离。
  ///
  /// v2 及以前所有消息混在一条历史里,新开的对话也能"看到"以前聊过的内容,
  /// 表现出来就是 AI 无中生有地提起你从没在这个对话里说过的事。
  /// v3 给消息加上会话归属,并把 `goals.target` 改成可空(推进条可以不预设目标值)。
  static const _version = 3;

  /// 打开(必要时创建或升级)数据库。
  ///
  /// [path] 只在测试里传,生产走 sqflite 默认的应用私有目录。
  static Future<AppDatabase> open({String? path}) async {
    final dbPath = path ?? p.join(await getDatabasesPath(), _fileName);
    final db = await openDatabase(
      dbPath,
      version: _version,
      onCreate: _createSchema,
      onUpgrade: _upgrade,
    );
    return AppDatabase._(db);
  }

  static Future<void> _createSchema(Database db, int version) async {
    await createSchema(db);
  }

  /// 建全部表。测试与迁移也用它,避免有人手抄一份建表语句——
  /// 抄的那份一定会跟这里漂开。
  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE tasks (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day TEXT NOT NULL,
        text TEXT NOT NULL,
        done INTEGER NOT NULL DEFAULT 0,
        completed_at INTEGER,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL,
        color TEXT NOT NULL DEFAULT 'blue'
      )
    ''');
    // 按天查列表、按区间查周报,都走这个索引。
    await db.execute('CREATE INDEX idx_tasks_day ON tasks(day)');

    await db.execute('''
      CREATE TABLE journals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day TEXT NOT NULL UNIQUE,
        text TEXT NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');

    await createChatTables(db);
    await createGoalTables(db);
    await createReminderTable(db);
  }

  /// 建聊天相关的表。
  static Future<void> createChatTables(DatabaseExecutor db) async {
    await createConversationTable(db);
    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        conversation_id INTEGER NOT NULL,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        reasoning TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_messages_conversation ON messages(conversation_id)',
    );
  }

  /// 只建会话表。v3 迁移里用得上:那时候 messages 表已经存在(v1/v2 就有),
  /// 只需要补上 conversations 与 messages.conversation_id。
  static Future<void> createConversationTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// 建目标与进度相关的表。
  ///
  /// `target` 允许为 NULL:很多事情一开始根本不知道该推进到多少
  /// (「读这本书」要读几页是读着读着才知道的),那时它只是一条推进记录,
  /// 而不是一个有待完成比例的进度条。
  static Future<void> createGoalTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE goals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        unit TEXT NOT NULL DEFAULT '',
        target REAL,
        period TEXT NOT NULL,
        direction TEXT NOT NULL DEFAULT 'increase',
        color TEXT NOT NULL DEFAULT 'blue',
        active INTEGER NOT NULL DEFAULT 1,
        start_day TEXT,
        end_day TEXT,
        created_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE progress_entries (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        goal_id INTEGER NOT NULL,
        amount REAL NOT NULL,
        day TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        task_id INTEGER,
        source TEXT NOT NULL DEFAULT 'manual',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_progress_goal ON progress_entries(goal_id)');
    await db.execute('CREATE INDEX idx_progress_day ON progress_entries(day)');
  }

  /// 建提醒表(日历里给某条任务设的定时提醒)。
  static Future<void> createReminderTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE reminders (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        task_id INTEGER NOT NULL,
        day TEXT NOT NULL,
        at TEXT NOT NULL,
        note TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');
    await db.execute('CREATE INDEX idx_reminders_day ON reminders(day)');
  }

  /// 版本升级。每一步只做"从上一版到这一版"的增量改动。
  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      // v2:任务加配色;聊天加思考过程;新增目标与进度表。
      await db.execute("ALTER TABLE tasks ADD COLUMN color TEXT NOT NULL DEFAULT 'blue'");
      await db.execute("ALTER TABLE messages ADD COLUMN reasoning TEXT NOT NULL DEFAULT ''");
      await createGoalTables(db);
    }
    if (from < 3) {
      // v3:聊天加会话维度;目标值改成可空;新增提醒表。
      //
      // 老数据不能丢:把所有历史消息归进一个"以前的对话"会话,
      // 而不是删掉或者留着一条混在一起的历史。
      //
      // 注意 messages 表在 v1/v2 就存在了,所以这里只建 conversations、
      // 给 messages 补一列,不能整个重建(会撞 "table messages already exists")。
      await createConversationTable(db);
      await db.execute(
        'ALTER TABLE messages ADD COLUMN conversation_id INTEGER NOT NULL DEFAULT 0',
      );
      await db.execute(
        'CREATE INDEX idx_messages_conversation ON messages(conversation_id)',
      );

      await db.execute('''
        INSERT INTO conversations (title, created_at, updated_at)
        VALUES ('以前的对话', ?, ?)
      ''', [
        DateTime.now().millisecondsSinceEpoch,
        DateTime.now().millisecondsSinceEpoch,
      ]);
      final conversationId =
          Sqflite.firstIntValue(await db.rawQuery('SELECT MAX(id) FROM conversations')) ?? 1;
      // 旧消息的 conversation_id 都是默认值 0,归到刚建的那个会话里。
      await db.execute(
        'UPDATE messages SET conversation_id = ? WHERE conversation_id = 0',
        [conversationId],
      );

      // target 从 NOT NULL 改成可空:SQLite 不支持改列约束,只能重建这张表。
      await db.execute('ALTER TABLE goals RENAME TO goals_old');
      await db.execute('''
        CREATE TABLE goals (
          id INTEGER PRIMARY KEY AUTOINCREMENT,
          title TEXT NOT NULL,
          unit TEXT NOT NULL DEFAULT '',
          target REAL,
          period TEXT NOT NULL,
          direction TEXT NOT NULL DEFAULT 'increase',
          color TEXT NOT NULL DEFAULT 'blue',
          active INTEGER NOT NULL DEFAULT 1,
          start_day TEXT,
          end_day TEXT,
          created_at INTEGER NOT NULL
        )
      ''');
      await db.execute('''
        INSERT INTO goals (id, title, unit, target, period, direction, color, active, start_day, end_day, created_at)
        SELECT id, title, unit, target, period, direction, color, active, start_day, end_day, created_at
        FROM goals_old
      ''');
      await db.execute('DROP TABLE goals_old');

      await createReminderTable(db);
    }
  }

  /// 删除全部记录。只给"清空数据"这类用户显式操作使用。
  Future<void> wipe() async {
    await db.delete('tasks');
    await db.delete('journals');
    await db.delete('messages');
    await db.delete('conversations');
    await db.delete('progress_entries');
    await db.delete('goals');
    await db.delete('reminders');
  }

  Future<void> close() => db.close();
}
