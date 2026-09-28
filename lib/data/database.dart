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
  static const _version = 2;

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

  /// 建全部表。`synchronized` 之外的地方(测试、迁移)也用它,
  /// 避免有人手抄一份建表语句——抄的那份一定会跟这里漂开。
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

    await db.execute('''
      CREATE TABLE messages (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        role TEXT NOT NULL,
        content TEXT NOT NULL,
        reasoning TEXT NOT NULL DEFAULT '',
        created_at INTEGER NOT NULL
      )
    ''');

    await createGoalTables(db);
  }

  /// 建目标与进度相关的表。
  static Future<void> createGoalTables(DatabaseExecutor db) async {
    await db.execute('''
      CREATE TABLE goals (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        title TEXT NOT NULL,
        unit TEXT NOT NULL,
        target REAL NOT NULL,
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

  /// 版本升级。每一步只做"从上一版到这一版"的增量改动。
  static Future<void> _upgrade(Database db, int from, int to) async {
    if (from < 2) {
      // v2:待办加配色;聊天加思考过程;新增目标与进度表。
      await db.execute("ALTER TABLE tasks ADD COLUMN color TEXT NOT NULL DEFAULT 'blue'");
      await db.execute("ALTER TABLE messages ADD COLUMN reasoning TEXT NOT NULL DEFAULT ''");
      await createGoalTables(db);
    }
  }

  /// 删除全部记录。只给"清空数据"这类用户显式操作使用。
  Future<void> wipe() async {
    await db.delete('tasks');
    await db.delete('journals');
    await db.delete('messages');
    await db.delete('progress_entries');
    await db.delete('goals');
  }

  Future<void> close() => db.close();
}
