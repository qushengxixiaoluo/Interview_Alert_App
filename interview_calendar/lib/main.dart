import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'theme/app_theme.dart';
import 'screens/home_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 恢复上次选的界面风格（经典卡通 / Lowpoly 描边）
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('app_style');
    AppTheme.initStyle(
      AppStyle.values.firstWhere(
        (s) => s.name == saved,
        orElse: () => AppStyle.classic,
      ),
    );
  } catch (_) {
    // 存储不可用就用默认风格，不影响启动
  }

  runApp(const InterviewCalendarApp());
}

class InterviewCalendarApp extends StatelessWidget {
  const InterviewCalendarApp({super.key});

  @override
  Widget build(BuildContext context) {
    // 监听风格切换：换风格时整树重建，所有 AppTheme.* 动态取值随新风格刷新
    return ValueListenableBuilder<AppStyle>(
      valueListenable: AppTheme.styleListenable,
      builder: (context, style, _) {
        return MaterialApp(
          title: '事件日历',
          debugShowCheckedModeBanner: false,
          theme: AppTheme.cartoonTheme,
          // 固定中文界面：不加这一段，日期/时间选择器会是英文（OK/Cancel、January…）
          locale: const Locale('zh', 'CN'),
          supportedLocales: const [Locale('zh', 'CN')],
          localizationsDelegates: const [
            GlobalMaterialLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
          ],
          home: const HomeScreen(),
        );
      },
    );
  }
}
