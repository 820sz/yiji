import 'dart:async';

import 'package:flutter/material.dart';

import '../state/app_state.dart';
import 'ai_avatar.dart';
import 'theme.dart';

/// 开屏:一行文案渐显,然后让位给主界面。
///
/// 节奏是这样定的:
/// - 图标立刻就在(它已经在原生启动图里出现过),**不做入场动画**,避免"闪两下";
/// - 文案延迟 180ms 起淡入,让人先看清图标再看清话;
/// - 文案淡入用 700ms —— 这是全应用唯一允许超过 300ms 的动效,
///   因为它是"读一句话"而不是"操作界面",快了反而像闪屏广告;
/// - 停一拍后整体淡出 260ms,和弹层同档,收得干净。
///
/// 全程约 1.6s。[enabled] 为假时直接给子界面,用于界面测试——
/// 测试要验的是页面本身,不该被一层持续 1.6 秒的遮罩挡住点击。
class SplashGate extends StatefulWidget {
  const SplashGate({super.key, required this.child, this.enabled = true});

  final Widget child;
  final bool enabled;

  @override
  State<SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<SplashGate> {
  static const _beforeFadeIn = Duration(milliseconds: 180);
  static const _fadeIn = Duration(milliseconds: 700);
  static const _holdAfterText = Duration(milliseconds: 480);
  static const _fadeOut = Duration(milliseconds: 260);

  final List<Timer> _timers = [];
  bool _textVisible = false;
  bool _fadingOut = false;
  bool _finished = false;

  @override
  void initState() {
    super.initState();
    if (!widget.enabled) {
      _finished = true;
      return;
    }
    _timers.addAll([
      Timer(_beforeFadeIn, () {
        if (mounted) setState(() => _textVisible = true);
      }),
      Timer(_beforeFadeIn + _fadeIn + _holdAfterText, () {
        if (mounted) setState(() => _fadingOut = true);
      }),
      Timer(_beforeFadeIn + _fadeIn + _holdAfterText + _fadeOut, () {
        if (mounted) setState(() => _finished = true);
      }),
    ]);
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final dark = state.darkMode;
    final background = dark ? AppTheme.darkBackground : AppTheme.lightBackground;
    final textPrimary = dark ? AppTheme.darkTextPrimary : AppTheme.lightTextPrimary;

    return Stack(
      children: [
        widget.child,
        if (!_finished)
          AnimatedOpacity(
            opacity: _fadingOut ? 0 : 1,
            duration: _fadeOut,
            curve: AppTheme.easeOut,
            child: IgnorePointer(
              // 淡出过程中不该再吃掉点击,否则用户会觉得"点不动"。
              ignoring: _fadingOut,
              child: ColoredBox(
                color: background,
                child: Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // 图标用和桌面图标同一个符号:圆角方块 + 打钩。
                      const BrandMark(size: 78, radius: 22),
                      const SizedBox(height: 26),
                      AnimatedOpacity(
                        opacity: _textVisible ? 1 : 0,
                        duration: _fadeIn,
                        curve: AppTheme.easeOut,
                        child: Text(
                          state.splashText,
                          style: TextStyle(
                            fontSize: 17,
                            letterSpacing: 4,
                            fontWeight: FontWeight.w500,
                            color: textPrimary.withValues(alpha: 0.85),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// 开屏图标。深色方块配暖黄钩子,和 launcher 图标一致。
/// 开屏图标由 [BrandMark] 提供,和桌面图标、空状态共用同一套形状。
