import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../data/reminder.dart';

/// 把提醒排进系统通知。
///
/// 用系统的定时通知而不是应用内提醒:提醒的意义就在于"app 没开着也能响",
/// 应用内的提示做不到这件事。
///
/// 每次变化都整体重排(先全撤再排),而不是增量增删:
/// 提醒数量很小(一周内几条),整体重排不会有对不上的残留。
class ReminderNotifier {
  ReminderNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  final FlutterLocalNotificationsPlugin _plugin;
  bool _ready = false;

  static const _channelId = 'yiji_reminders';
  static const _channelName = '任务提醒';
  static const _channelDescription = '到点提醒你要做的事';

  /// 通知 id 的取法:用提醒自身的 id。
  ///
  /// 这样同一条提醒重排时会覆盖自己,不会越堆越多。
  int _notificationId(Reminder reminder) => reminder.id;

  /// 初始化插件。**任何失败都不抛**:没有通知权限、平台没实现、
  /// 甚至在没有平台的测试环境里跑,都只让提醒功能静默不可用,其余功能照常。
  Future<void> init() async {
    if (_ready) return;
    try {
      tz_data.initializeTimeZones();
      await _plugin.initialize(
        settings: const InitializationSettings(
          android: AndroidInitializationSettings('@mipmap/ic_launcher'),
        ),
      );
      // Android 13+ 需要用户显式同意才能发通知。
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
      _ready = true;
    } catch (_) {
      // 故意接住所有异常:这里出错的原因很多(没有平台实现、权限被拒、
      // 时区数据缺失),但每一种的处置都一样——关掉提醒,别影响别的功能。
      _ready = false;
    }
  }

  /// 按给定的提醒列表重排通知。
  ///
  /// [taskTextOf] 把 task id 映射到任务内容,用于通知正文兜底。
  Future<void> sync(
    List<Reminder> reminders, {
    required Map<int, String> taskTextOf,
  }) async {
    await init();
    if (!_ready) return;

    try {
      await _plugin.cancelAll();
      final now = DateTime.now();
      for (final reminder in reminders) {
        // 已经过去的时间点排不了,系统会立刻弹一条,很烦人。
        if (!reminder.when.isAfter(now)) continue;
        await _plugin.zonedSchedule(
          id: _notificationId(reminder),
          title: '该做这件事了',
          body: reminder.note.isNotEmpty
              ? reminder.note
              : (taskTextOf[reminder.taskId] ?? '打开忆记看看'),
          scheduledDate: tz.TZDateTime.from(reminder.when, tz.local),
          notificationDetails: const NotificationDetails(
            android: AndroidNotificationDetails(
              _channelId,
              _channelName,
              channelDescription: _channelDescription,
              importance: Importance.high,
              priority: Priority.high,
            ),
          ),
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        );
      }
    } catch (_) {
      // 排程失败(权限、系统限制、没有平台实现)不该影响用户正在做的事。
    }
  }

  Future<void> cancelAll() async {
    await init();
    if (!_ready) return;
    try {
      await _plugin.cancelAll();
    } catch (_) {
      // 取消失败没有可补救的动作。
    }
  }

  /// 系统有没有允许本应用发通知。
  ///
  /// 用户设了提醒却什么都没收到时,原因几乎总是这个开关被关了(Android 13
  /// 起要显式授权,而且授权后还能在系统设置里关掉)。界面要能问出这个状态,
  /// 把话说清楚,而不是让提醒悄悄不响——那是这个功能最难受的坏法。
  /// 查不出来时返回 null(桌面/测试环境没有这个实现)。
  Future<bool?> notificationsEnabled() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      if (android == null) return null;
      return await android.areNotificationsEnabled();
    } catch (_) {
      return null;
    }
  }
}
