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
  static const _version = 6;

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
        color TEXT NOT NULL DEFAULT 'blue',
        outcome TEXT NOT NULL DEFAULT '',
        synced_at INTEGER
      )
    ''');
    // 按天查列表、按区间查周报,都走这个索引。
    await db.execute('CREATE INDEX idx_tasks_day ON tasks(day)');

    await db.execute('''
      CREATE TABLE journals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        day TEXT NOT NULL UNIQUE,
        text TEXT NOT NULL,
        photos TEXT NOT NULL DEFAULT '',
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

  /// 只建会话表。
  ///
  /// v3 迁移里用得上:那时候 messages 表已经存在(v1/v2 就有),
  /// 只需要补上 conversations 与 messages.conversation_id。
  ///
  /// 建的是**v3 当时的样子**(没有 avatar 列):升级是一步一步走的,
  /// v4 那一步会自己 ALTER 补列。这里如果把 avatar 一起建出来,
  /// 从 v2 升上来的库就会在 v4 那步撞 "duplicate column name: avatar"。
  static Future<void> createConversationTableV3(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL
      )
    ''');
  }

  /// 建会话表(当前版本的样子)。新建库时用这个。
  static Future<void> createConversationTable(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE conversations (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL DEFAULT '',
        avatar TEXT NOT NULL DEFAULT '',
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
      await createConversationTableV3(db);
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
    if (from < 4) {
      // v4:任务的完成质量。原来只有"做完/没做完"两种状态,但"做了、可是没做好"
      // 是很常见的一种结果,而且正是周报"不足"那一栏最该看到的东西。
      // 空串表示用户没评价过(老数据全是空串,读起来就是"没标过")。
      await db.execute("ALTER TABLE tasks ADD COLUMN outcome TEXT NOT NULL DEFAULT ''");
      // v4:每条会话有自己的头像。以前头像挂在全局设置上,换个对话还是同一张脸。
      await db.execute("ALTER TABLE conversations ADD COLUMN avatar TEXT NOT NULL DEFAULT ''");
    }
    if (from < 5) {
      // v5:记下"这条做完的事已经被 AI 读过并处理过了"。
      //
      // 进度页右上角那个待同步角标,以前是"本周做完的事里没有进度记录的条数"。
      // 这个定义有个必然的漏洞:像「取快递」这种永远不会匹配上任何推进条的事,
      // 会永远留在计数里——用户整理完、确认完,角标还是挂着,怎么都清不掉。
      // 现在改成"还没被处理过的条数",处理过就打上时间戳。
      await db.execute('ALTER TABLE tasks ADD COLUMN synced_at INTEGER');
    }
    if (from < 6) {
      // v6:「今日想法」可以配照片。
      //
      // 存的是文件名(换行分隔),不是 base64:照片进了库会让每条日记
      // 膨胀几百 KB,回看和查库都会变慢。文件走聊天图片那套存储。
      // 老日记的 photos 是空串,读出来就是"没配图"。
      await db.execute("ALTER TABLE journals ADD COLUMN photos TEXT NOT NULL DEFAULT ''");
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
