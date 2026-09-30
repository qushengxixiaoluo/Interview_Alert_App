@echo off
chcp 65001 >nul
title 事件日历

echo ========================================
echo   事件日历 - 启动中...
echo ========================================
echo.

cd /d D:\PythonCode\Interview_Alert_App\interview_calendar

echo [1/2] 安装依赖...
E:\flutter\bin\flutter.bat pub get
if %errorlevel% neq 0 (
    echo.
    echo [!] 依赖安装失败，请检查 Flutter 安装
    pause
    exit /b 1
)

echo.
echo [2/2] 启动应用...
echo.
E:\flutter\bin\flutter.bat run -d windows

if %errorlevel% neq 0 (
    echo.
    echo [!] 启动失败，尝试其他方式...
    echo.
    echo 可用的设备:
    E:\flutter\bin\flutter.bat devices
    echo.
    echo 请手动选择设备运行:
    echo   E:\flutter\bin\flutter.bat run -d windows
    echo   E:\flutter\bin\flutter.bat run -d chrome
    echo   E:\flutter\bin\flutter.bat run -d android
    pause
)
