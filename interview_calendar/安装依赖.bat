@echo off
chcp 65001 >nul
title 安装依赖

cd /d D:\PythonCode\Interview_Alert_App\interview_calendar

echo 安装 Flutter 依赖...
E:\flutter\bin\flutter.bat pub get

echo.
echo 完成！
pause
