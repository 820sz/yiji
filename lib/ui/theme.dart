import 'package:flutter/material.dart';

import '../data/palette.dart';

/// 设计 token 与主题。
///
/// 视觉基准是 vivo 原子笔记的待办页:浅色底、大号粗体标题 + 灰色计数副标题、
/// 搜索/排序图标、实心淡彩卡片(未完成)与灰底删除线卡片(已完成)。
///
/// 动效配比按 animate 的判据:待办打钩是"几十次/天"的层级,所以只做**近乎无感**
/// 的反馈(勾选图标 140ms 缩放淡入、进度条 220ms 宽度过渡),不做入场动画;
/// 弹层属于"偶尔出现",才给标准时长(200–260ms)。
class AppTheme {
  // ---------- 颜色 ----------

  /// 页面底色。浅色沿用原子笔记的近白,深色用近黑。
  static const lightBackground = Color(0xFFF7F8FA);
  static const lightSurface = Color(0xFFFFFFFF);
  static const darkBackground = Color(0xFF111214);
  static const darkSurface = Color(0xFF1C1E22);

  static const accent = Color(0xFF4C8DFF);
  static const lightTextPrimary = Color(0xFF1C1C1E);
  static const lightTextSecondary = Color(0xFF8A8F98);
  static const darkTextPrimary = Color(0xFFE8EAED);
  static const darkTextSecondary = Color(0xFF9AA0A6);

  /// 已完成卡片的灰底(原子笔记里已完成项明显退到背景后面)。
  static const lightDoneFill = Color(0xFFEDEEF1);
  static const darkDoneFill = Color(0xFF232529);
  static const doneText = Color(0xFF9EA3AC);

  /// 深色模式下卡片上的字色。
  static const darkCardText = Color(0xFFE4E6EA);

  // ---------- 动效 ----------

  /// 勾选、颜色变化这类即时反馈。
  static const Duration fast = Duration(milliseconds: 140);

  /// 进度条推进、卡片尺寸变化。
  static const Duration medium = Duration(milliseconds: 220);

  /// 弹层、页面切换。UI 一律不超过 300ms。
  static const Duration sheet = Duration(milliseconds: 260);

  /// 标准 ease-out;进入与退出都用它,不用 ease-in。
  static const Curve easeOut = Cubic(0.23, 1, 0.32, 1);

  /// 屏幕内位移用 ease-in-out。
  static const Curve easeInOut = Cubic(0.77, 0, 0.175, 1);

  // ---------- 几何 ----------

  /// 卡片圆角。原子笔记的卡片接近 16。
  static const cardRadius = 16.0;
  static const cardGap = 10.0;
  static const pagePadding = 16.0;

  static ThemeData build({required bool dark}) {
    final base = dark ? ThemeData.dark(useMaterial3: true) : ThemeData.light(useMaterial3: true);
    final background = dark ? darkBackground : lightBackground;
    final surface = dark ? darkSurface : lightSurface;
    final textPrimary = dark ? darkTextPrimary : lightTextPrimary;
    final textSecondary = dark ? darkTextSecondary : lightTextSecondary;

    return base.copyWith(
      scaffoldBackgroundColor: background,
      colorScheme: base.colorScheme.copyWith(
        primary: accent,
        surface: surface,
        onSurface: textPrimary,
        brightness: dark ? Brightness.dark : Brightness.light,
      ),
      appBarTheme: AppBarTheme(
        backgroundColor: background,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: textPrimary,
          fontSize: 20,
          fontWeight: FontWeight.w600,
        ),
      ),
      cardTheme: CardThemeData(
        color: surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(cardRadius)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: dark ? const Color(0xFF26282D) : const Color(0xFFF0F1F4),
        hintStyle: TextStyle(color: textSecondary),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(12),
          borderSide: BorderSide.none,
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      ),
      dividerTheme: DividerThemeData(
        color: dark ? const Color(0xFF2A2D33) : const Color(0xFFE8E9ED),
        space: 1,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: surface,
        surfaceTintColor: Colors.transparent,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: const Color(0xFF2E3136),
        contentTextStyle: const TextStyle(color: Colors.white, fontSize: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      textTheme: base.textTheme.apply(bodyColor: textPrimary, displayColor: textPrimary),
    );
  }

  /// 卡片底色。已完成一律退成灰底,这是原子笔记最明显的一条视觉规则。
  static Color cardFill(TaskColor color, {required bool done, required bool dark}) {
    if (done) return dark ? darkDoneFill : lightDoneFill;
    return dark ? darkenForDark(color.fill) : color.fill;
  }

  /// 卡片文字色。
  static Color cardForeground(TaskColor color, {required bool done, required bool dark}) {
    if (done) return doneText;
    return dark ? darkCardText : color.onFill;
  }

  /// 深色模式下把淡彩压暗,保持色相但不再刺眼。
  ///
  /// 用 HSL 降亮度而不是简单乘系数:乘系数会让浅黄这类高亮度色压不下去,
  /// 深色模式下仍然是一片亮块。
  static Color darkenForDark(Color color) {
    final hsl = HSLColor.fromColor(color);
    return hsl
        .withLightness((hsl.lightness * 0.30).clamp(0.10, 0.24))
        .withSaturation((hsl.saturation * 0.75).clamp(0.0, 1.0))
        .toColor();
  }
}
