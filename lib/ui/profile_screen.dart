import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';

import '../ai/ai_client.dart';
import '../ai/settings_store.dart';
import '../core/day.dart';
import '../state/app_state.dart';
import '../update/app_updater.dart';
import 'ai_avatar.dart';
import 'identity_card.dart';
import 'prompt_dialog.dart';
import 'report_screen.dart';
import 'settings_screen.dart';
import 'theme.dart';

/// 「我的」页:AI 助手的设置入口 + app 级偏好。
///
/// 头像与思考强度放在这里是因为它们属于"我把它当成谁",
/// 而模型/key 属于"它接的是哪个服务",所以后者再点一层进去。
class ProfileScreen extends StatelessWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;
    final provider = AiProvider.from(
      model: state.aiConfig.model,
      baseUrl: state.aiConfig.baseUrl,
    );

    return ListView(
      // 有 key 才能在测试里精确指定要滚动的是本页(多个页签同时在组件树上)。
      key: const Key('profile-list'),
      padding: const EdgeInsets.fromLTRB(AppTheme.pagePadding, 8, AppTheme.pagePadding, 120),
      children: [
        // 先看到"我",而不是 AI 的模型名——这是「我的」页。
        const IdentityCard(),
        _SectionTitle('AI 助手'),
        // AI 的身份缩成一行,不再占着整页顶部。
        Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Row(
            children: [
              AiAvatar(
                provider: provider,
                bytes: state.avatarBytes,
                dark: dark,
                size: 34,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      state.aiConfig.isUsable ? provider.label : '还没配 API key',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      state.aiConfig.isUsable ? state.aiConfig.model : '配一个 key 就能聊',
                      style: TextStyle(fontSize: 12, color: textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        _Tile(
          icon: Icons.vpn_key_outlined,
          title: 'API key 与模型',
          subtitle: state.aiConfig.isUsable ? '已配置' : '未配置',
          dark: dark,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SettingsScreen()),
          ),
        ),
        _Tile(
          icon: Icons.psychology_outlined,
          title: '思考强度',
          subtitle: state.aiConfig.thinking.label,
          dark: dark,
          onTap: () => _pickThinking(context),
        ),
        _Tile(
          icon: Icons.image_outlined,
          title: 'AI 头像',
          subtitle: state.avatarBytes == null ? '跟随模型' : '已自定义',
          dark: dark,
          onTap: () => _pickAvatar(context),
        ),
        const SizedBox(height: 18),
        _SectionTitle('记录'),
        _Tile(
          icon: Icons.insights_outlined,
          title: '周报 / 月报',
          subtitle: '统计与成稿',
          dark: dark,
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const ReportScreen()),
          ),
        ),
        _Tile(
          icon: Icons.ios_share,
          title: '导出数据',
          subtitle: '复制最近两周的文本',
          dark: dark,
          onTap: () => _exportData(context),
        ),
        const SizedBox(height: 18),
        _SectionTitle('外观'),
        SwitchListTile(
          value: state.darkMode,
          onChanged: state.saveDarkMode,
          title: Text(
            '深色模式',
            style: TextStyle(fontSize: 15, color: textPrimary),
          ),
          activeThumbColor: AppTheme.accent,
          contentPadding: EdgeInsets.zero,
        ),
        _Tile(
          icon: Icons.auto_awesome_outlined,
          title: '开屏文案',
          subtitle: state.splashText,
          dark: dark,
          onTap: () => _editSplashText(context),
        ),
        const SizedBox(height: 18),
        _SectionTitle('关于'),
        _Tile(
          icon: Icons.system_update_alt,
          title: '检查更新',
          subtitle: state.availableUpdate != null
              ? '有新版本 ${state.availableUpdate!.versionName}'
              : (state.versionName.isEmpty ? '从 GitHub 下载新版本' : '当前 ${state.versionName}'),
          dark: dark,
          onTap: () => _checkUpdate(context),
        ),
        _Tile(
          icon: Icons.info_outline,
          title: '忆记',
          subtitle: state.versionName.isEmpty ? '0.5.0' : state.versionName,
          dark: dark,
          // 版本号不该是被点的东西,但也没必要单独占一行小字。
          onTap: () {},
        ),
      ],
    );
  }

  /// 手动查一次更新;有新版就问要不要装。
  Future<void> _checkUpdate(BuildContext context) async {
    final state = AppScope.of(context);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final info = await state.checkForUpdate();
      if (!context.mounted) return;
      if (info == null) {
        messenger.showSnackBar(const SnackBar(content: Text('已经是最新版')));
        return;
      }
      await _showUpdateSheet(context, info);
    } on Exception catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.toString())));
    }
  }

  /// 有新版本时问用户装不装。
  Future<void> _showUpdateSheet(BuildContext context, UpdateInfo info) async {
    final state = AppScope.of(context);
    final confirmed = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '有新版本 ${info.versionName}',
                style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
              ),
              if (info.sizeBytes > 0) ...[
                const SizedBox(height: 4),
                Text(
                  '${(info.sizeBytes / 1024 / 1024).toStringAsFixed(1)} MB',
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: AppTheme.lightTextSecondary,
                  ),
                ),
              ],
              if (info.notes.isNotEmpty) ...[
                const SizedBox(height: 12),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: SingleChildScrollView(
                    child: Text(
                      info.notes,
                      style: const TextStyle(fontSize: 14, height: 1.6),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 18),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton(
                      onPressed: () => Navigator.pop(context, false),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text('以后再说'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    flex: 2,
                    child: FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      style: FilledButton.styleFrom(
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      child: const Text('下载并安装'),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
    if (confirmed != true || !context.mounted) return;

    // 下载期间留一个**关不掉**的进度弹窗。之前是点了按钮什么都不显示,
    // 用户只能对着没反应的界面等,失败了也不知道是卡住还是断了。
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _UpdateProgressDialog(state: state, info: info),
    );
  }

  /// 改开屏那句话。
  ///
  /// 留空就回到默认文案——开屏上出现空白比出现一句别人的话更怪。
  Future<void> _editSplashText(BuildContext context) async {
    final state = AppScope.of(context);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => TextPromptDialog(
        title: '开屏文案',
        initialValue: state.splashText,
        hintText: SettingsStore.defaultSplashText,
        maxLength: 20,
      ),
    );
    if (result != null) await state.saveSplashText(result);
  }

  /// 选思考强度。跟聊天页那个临时选择是同一组档位,这里是全局默认值。
  Future<void> _pickThinking(BuildContext context) async {
    final state = AppScope.of(context);
    final picked = await showModalBottomSheet<ThinkingLevel>(
      context: context,
      builder: (context) => _ThinkingSheet(current: state.aiConfig.thinking),
    );
    if (picked == null) return;
    await state.saveAiConfig(state.aiConfig.copyWith(thinking: picked));
  }

  /// 换头像:选图 → 交给系统裁剪成方形 → 存本地。
  Future<void> _pickAvatar(BuildContext context) async {
    final state = AppScope.of(context);
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选一张'),
              onTap: () => Navigator.pop(context, 'pick'),
            ),
            if (state.avatarBytes != null)
              ListTile(
                leading: const Icon(Icons.restart_alt),
                title: const Text('恢复成内置图标'),
                onTap: () => Navigator.pop(context, 'reset'),
              ),
          ],
        ),
      ),
    );

    if (choice == 'reset') {
      await state.saveAvatar(null);
      return;
    }
    if (choice != 'pick') return;

    try {
      final file = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        // 头像展示尺寸很小,先让系统压到 512,省内存也省存储。
        maxWidth: 512,
        maxHeight: 512,
        imageQuality: 88,
      );
      if (file == null) return;
      final bytes = await file.readAsBytes();
      await state.saveAvatar(bytes);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('头像换好了')));
      }
    } on Exception catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('选图失败:$error')));
    }
  }

  /// 把这一周的数据复制成文本,方便发给别的 AI(或交给代理程序)。
  Future<void> _exportData(BuildContext context) async {
    final state = AppScope.of(context);
    final buffer = StringBuffer();

    for (final weeksAgo in [0, 1]) {
      final anchor = addDays(todayKey(), -7 * weeksAgo);
      buffer
        ..writeln('===== ${state.weekLabel(anchor)} =====')
        ..writeln(await state.plainWeekReport(anchor))
        ..writeln();
    }

    final goals = state.activeGoals;
    if (goals.isNotEmpty) {
      buffer.writeln('===== 进度推进条 =====');
      for (final goal in goals) {
        buffer.writeln(
          '${goal.title}:${goal.progressLabel}'
          '(${(goal.ratio * 100).round()}%,${goal.period.label})',
        );
      }
    }

    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('最近两周的数据已复制')));
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 6, 4, 8),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 12.5,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.6,
          color: dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary,
        ),
      ),
    );
  }
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.dark,
    required this.onTap,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool dark;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return ListTile(
      onTap: onTap,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(icon, size: 21, color: textSecondary),
      title: Text(title, style: TextStyle(fontSize: 15, color: textPrimary)),
      subtitle: Text(subtitle, style: TextStyle(fontSize: 12.5, color: textSecondary)),
      trailing: Icon(Icons.chevron_right, size: 19, color: textSecondary),
    );
  }
}

/// 下载并安装的进度弹窗。
///
/// 全部状态都从 [AppState] 读,自己不持有进度——下载是 state 在跑,
/// 弹窗只是个显示器,关掉再打开也能接上。
class _UpdateProgressDialog extends StatefulWidget {
  const _UpdateProgressDialog({required this.state, required this.info});

  final AppState state;
  final UpdateInfo info;

  @override
  State<_UpdateProgressDialog> createState() => _UpdateProgressDialogState();
}

class _UpdateProgressDialogState extends State<_UpdateProgressDialog> {
  String? _error;
  var _started = false;

  @override
  void initState() {
    super.initState();
    // 不能在 initState 里直接碰 InheritedWidget,但这里拿的是外部传进来的
    // state 对象,所以可以立刻起下载。
    _run();
  }

  Future<void> _run() async {
    if (_started) return;
    _started = true;
    setState(() => _error = null);
    try {
      await widget.state.installUpdate();
      // 成功后系统安装界面已经弹出来了,这个弹窗没用了。
      if (mounted) Navigator.of(context).pop();
    } on Exception catch (error) {
      if (!mounted) return;
      // 失败**不关**弹窗:关掉之后用户就只看到界面没反应,
      // 这正是上次"等半天又报错"的观感来源。
      setState(() => _error = error.toString());
    }
  }

  static String _mb(int bytes) => (bytes / 1024 / 1024).toStringAsFixed(1);

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return AlertDialog(
      title: Text(
        _error == null ? '正在下载' : '下载失败',
        style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w600),
      ),
      content: AnimatedBuilder(
        animation: widget.state,
        builder: (context, _) {
          final received = widget.state.updateReceived;
          final total = widget.state.updateTotal;
          final progress = widget.state.updateProgress;

          if (_error != null) {
            return Text(
              _error!,
              style: TextStyle(fontSize: 13.5, height: 1.6, color: textSecondary),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  value: progress > 0 ? progress : null,
                  minHeight: 6,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                total > 0
                    ? '${_mb(received)} MB / ${_mb(total)} MB  ·  ${(progress * 100).round()}%'
                    : '${_mb(received)} MB',
                style: TextStyle(fontSize: 13, color: textPrimary),
              ),
              const SizedBox(height: 4),
              Text(
                '下载中断会自动重试,请保持网络畅通。',
                style: TextStyle(fontSize: 12, color: textSecondary),
              ),
            ],
          );
        },
      ),
      actions: [
        if (_error != null) ...[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
          FilledButton(
            onPressed: () {
              _started = false;
              _run();
            },
            child: const Text('重试'),
          ),
        ],
      ],
    );
  }
}

/// 思考强度选择面板。
class _ThinkingSheet extends StatelessWidget {
  const _ThinkingSheet({required this.current});

  final ThinkingLevel current;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;
    final textSecondary = dark ? AppTheme.darkTextSecondary : AppTheme.lightTextSecondary;

    return SafeArea(
      // 四个档位加说明文字在矮屏上会超出,所以外层可滚动——
      // 弹层不该因为屏幕矮就把最后一项切掉。
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(18, 18, 18, 12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '思考强度',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w600,
                color: textPrimary,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '强度越高,它想得越久、也越贵。日常闲聊用「轻」就够。',
              style: TextStyle(fontSize: 12.5, height: 1.5, color: textSecondary),
            ),
            const SizedBox(height: 10),
            for (final level in ThinkingLevel.values)
              ListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                onTap: () => Navigator.pop(context, level),
                leading: Icon(
                  level == current
                      ? Icons.radio_button_checked
                      : Icons.radio_button_off,
                  size: 20,
                  color: level == current ? AppTheme.accent : textSecondary,
                ),
                title: Text(
                  level.label,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                    color: textPrimary,
                  ),
                ),
                subtitle: Text(
                  level.hint,
                  style: TextStyle(fontSize: 12, color: textSecondary),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
