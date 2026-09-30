@echo off
chcp 65001 >nul
echo ========================================
echo   事件日历 - Flutter 项目初始化
echo ========================================
echo.

REM 检查 Flutter 是否可用
where flutter >nul 2>&1
if %errorlevel% neq 0 (
    echo [!] flutter 命令未找到，请先安装 Flutter SDK
    echo     下载地址: https://docs.flutter.dev/get-started/install/windows
    echo.
    echo 或者手动运行: E:\flutter\bin\flutter.bat
    pause
    exit /b 1
)

echo [1/3] 初始化 Flutter 平台文件...
flutter create . --org com.interview.calendar --project-name interview_calendar
if %errorlevel% neq 0 (
    echo [!] flutter create 失败
    pause
    exit /b 1
)

echo.
echo [2/3] 安装依赖...
flutter pub get
if %errorlevel% neq 0 (
    echo [!] flutter pub get 失败
    pause
    exit /b 1
)

echo.
echo [3/3] 完成！
echo.
echo ========================================
echo   启动方式:
echo   - 电脑: flutter run -d windows
echo   - 手机: flutter run (需连接手机并开启USB调试)
echo   - 浏览器: flutter run -d chrome
echo ========================================
pause
