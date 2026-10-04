import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../state/app_state.dart';
import 'theme.dart';

/// 退出前的告别弹窗。
///
/// 用户的原话:"增加软件退出动画——退出时一个支持自定义的弹窗语录,
/// 目前默认为「今天辛苦啦~」"。
///
/// 这里刻意**不做拦截式的"你确定要退出吗"**:那是打扰。它是一个道别——
/// 出来停一下,然后自己走。用户想留下就点「再待会儿」。
///
/// 返回 true 表示确实该退出了。
Future<bool> showFarewell(BuildContext context) async {
  final state = AppScope.of(context);
  final dark = Theme.of(context).brightness == Brightness.dark;
  final text = state.farewellText;

  final result = await showGeneralDialog<bool>(
    context: context,
    // 点空白处 = "再待会儿",不是退出。误触不该把应用关掉。
    barrierDismissible: true,
    barrierLabel: '再待会儿',
    barrierColor: Colors.black.withValues(alpha: 0.45),
    transitionDuration: AppTheme.medium,
    pageBuilder: (context, animation, secondary) =>
        FarewellCard(text: text, dark: dark),
    transitionBuilder: (context, animation, secondary, child) {
      final curved = CurvedAnimation(
        parent: animation,
        curve: AppTheme.easeOut,
      );
      return FadeTransition(
        opacity: curved,
        child: ScaleTransition(
          // 轻微缩放:"弹"出来而不是硬切。
          scale: Tween<double>(begin: 0.92, end: 1).animate(curved),
          child: child,
        ),
      );
    },
  );
  return result ?? false;
}

/// 真正要显示的告别卡片。
///
/// 单独一个 widget 是为了让 [showFarewell] 的过渡能包住它。
class FarewellCard extends StatelessWidget {
  const FarewellCard({super.key, required this.text, required this.dark});

  final String text;
  final bool dark;

  @override
  Widget build(BuildContext context) {
    final surface = dark ? AppTheme.darkSurface : AppTheme.lightSurface;
    final textPrimary = dark
        ? AppTheme.darkTextPrimary
        : AppTheme.lightTextPrimary;

    return Center(
      child: Material(
        color: surface,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(28, 26, 28, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(
                Icons.nightlight_round,
                size: 30,
                color: AppTheme.accent,
              ),
              const SizedBox(height: 14),
              Text(
                text,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                  height: 1.5,
                  color: textPrimary,
                ),
              ),
              const SizedBox(height: 18),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('再待会儿'),
                  ),
                  const SizedBox(width: 8),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('退出'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 直接退出应用。
///
/// `SystemNavigator.pop()` 在 Android 上是"回到桌面"——这正是用户点退出
/// 时期待的结果。它不会杀进程,系统自己会回收。
Future<void> exitApp() async {
  await SystemNavigator.pop();
}
