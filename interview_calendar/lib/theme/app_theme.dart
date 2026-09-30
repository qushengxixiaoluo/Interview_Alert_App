import 'package:flutter/material.dart';

/// 界面风格：经典卡通 / Low-poly 黑描边。运行时可切换，选择会被记住。
enum AppStyle { classic, lowpoly }

/// 双风格主题。
///
/// 约定：
/// - 所有会随风格变化的值一律用 **getter**（页面里直接引用 `AppTheme.outline`
///   这类取值即可同时适配两种风格），因此这些取值**不能**出现在 const 上下文里。
/// - 经典风格下 `outline` 返回全透明：页面里统一的描边在经典模式自动"隐身"，
///   视觉上回到原来的无描边样式。
/// - 阴影走 `hardShadow`：lowpoly 是纯黑硬阴影，经典是原来的柔和蓝影。
class AppTheme {
  AppTheme._();

  // ===== 风格状态（运行时可切） =====
  static AppStyle _style = AppStyle.classic;
  static AppStyle get style => _style;
  static bool get isLowpoly => _style == AppStyle.lowpoly;

  /// 根组件监听它，切换风格时整体重建，所有取值随新风格刷新
  static final ValueNotifier<AppStyle> styleListenable = ValueNotifier(AppStyle.classic);

  /// 启动时用本地存储的值恢复（main 里调用）
  static void initStyle(AppStyle s) {
    _style = s;
    styleListenable.value = s;
  }

  /// 切换风格（调用方负责把选择存进本地存储）
  static void switchStyle(AppStyle s) {
    _style = s;
    styleListenable.value = s;
  }

  // ===== 不随风格变的颜色 =====
  static const Color primary = Color(0xFF4A90D9); // 天蓝
  static const Color primaryLight = Color(0xFFB3D4FC); // 浅蓝
  static const Color accent = Color(0xFFFF8C42); // 橙色（强调）
  static const Color cardBg = Color(0xFFFFFFFF); // 白色卡片
  static const Color textPrimary = Color(0xFF1A1A2E); // 深色文字
  static const Color textSecondary = Color(0xFF6B7280); // 灰色文字
  static const Color badge = Color(0xFFEF4444); // 红点
  static const Color success = Color(0xFF22C55E); // 绿色（确认）
  static const Color warning = Color(0xFFF59E0B); // 黄色（待确认）

  // ===== 随风格变化的取值 =====

  /// 背景：经典=冷灰蓝（原版），lowpoly=米白纸感
  static Color get background =>
      isLowpoly ? const Color(0xFFF3EFE6) : const Color(0xFFEEF2F7);

  /// 卡片所在的浅色面：经典=浅灰蓝（原版），lowpoly=纸面白
  static Color get surface =>
      isLowpoly ? const Color(0xFFFBF8F1) : const Color(0xFFF5F7FA);

  /// 今天高亮描边：经典=蓝（原版），lowpoly=黑
  static Color get todayBorder => isLowpoly ? const Color(0xFF141414) : primary;

  /// 全局描边：lowpoly=黑；经典=全透明（统一描边自动隐身，视觉=原版无描边）。
  /// 宽度恒为 2，保证两种风格下布局一致、切换不跳动。
  static Color get outline => isLowpoly ? const Color(0xFF141414) : const Color(0x00000000);
  static const double outlineWidth = 2;

  /// 输入框描边：经典=浅蓝细线（原版），lowpoly=黑粗线
  static Color get inputBorder =>
      isLowpoly ? outline : primaryLight.withValues(alpha: 0.5);
  static double get inputBorderWidth => isLowpoly ? 2 : 1;

  /// 描边按钮（OutlinedButton）的边框：lowpoly=黑；经典=主题蓝（原版多数是蓝色系，
  /// 透明会让按钮在经典模式下变成"无边框"，所以这里给个可见色）
  static Color get buttonOutline => isLowpoly ? outline : primary;

  // 圆角：lowpoly 小一号贴棱角感，经典用原版值
  static double get radiusSmall => isLowpoly ? 6 : 8;
  static double get radiusMedium => isLowpoly ? 10 : 14;
  static double get radiusLarge => isLowpoly ? 14 : 20;
  static double get radiusXL => isLowpoly ? 18 : 28;

  /// 统一阴影：lowpoly=纯黑硬阴影（零模糊实心偏移）；经典=原版的柔和蓝影
  static List<BoxShadow> get hardShadow => isLowpoly
      ? const [
          BoxShadow(color: Color(0xFF141414), offset: Offset(3, 3), blurRadius: 0),
        ]
      : const [
          BoxShadow(
            color: Color(0x144A90D9),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ];

  /// 标准卡片装饰：白底 + 当前风格描边 + 当前风格阴影
  static BoxDecoration get cardDecoration => BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(radiusMedium),
        border: Border.all(color: outline, width: outlineWidth),
        boxShadow: hardShadow,
      );

  static ThemeData get cartoonTheme {
    return ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(
        seedColor: primary,
        brightness: Brightness.light,
        primary: primary,
        secondary: accent,
        surface: surface,
        outline: outline,
      ),
      scaffoldBackgroundColor: background,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        centerTitle: true,
        titleTextStyle: TextStyle(
          fontSize: 22,
          fontWeight: FontWeight.w700,
          color: textPrimary,
        ),
        iconTheme: IconThemeData(color: textPrimary),
      ),
      cardTheme: CardThemeData(
        color: cardBg,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          side: BorderSide(color: outline, width: outlineWidth),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
          // 经典模式 outline 透明 = 原版无描边
          side: BorderSide(color: outline, width: outlineWidth),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(radiusMedium),
          ),
          textStyle: const TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: Colors.white,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: inputBorder, width: inputBorderWidth),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: BorderSide(color: inputBorder, width: inputBorderWidth),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(radiusMedium),
          borderSide: const BorderSide(color: primary, width: 2.5),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      // 只有 lowpoly 换弹窗外观；经典回落到 Material 默认（和原版一致）
      dialogTheme: isLowpoly
          ? DialogThemeData(
              backgroundColor: cardBg,
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusMedium),
                side: BorderSide(color: outline, width: outlineWidth),
              ),
            )
          : null,
      // 勾选框黑描边方块（lowpoly）；经典回落默认
      checkboxTheme: isLowpoly
          ? CheckboxThemeData(
              side: BorderSide(color: outline, width: 2),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(3)),
            )
          : null,
      // 提示条黑描边（lowpoly）；经典回落默认
      snackBarTheme: isLowpoly
          ? SnackBarThemeData(
              elevation: 0,
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(radiusMedium),
                side: BorderSide(color: outline, width: outlineWidth),
              ),
            )
          : null,
      dividerTheme: isLowpoly
          ? const DividerThemeData(color: Color(0xFF141414), thickness: 1.5, space: 1)
          : null,
    );
  }
}
