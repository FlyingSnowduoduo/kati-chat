@echo off
chcp 65001 >nul
title 发布 卡提聊天助手 到 GitHub
echo.
echo   ================================================
echo        卡提聊天助手 · 一键发布到 GitHub
echo   ================================================
echo.
echo   需要一个 GitHub 令牌（Classic Token，勾选 repo 权限）
echo   创建地址: https://github.com/settings/tokens
echo   注意: 本机可能打不开 github.com 网页，可用手机或代理创建
echo.
echo   接下来会提示粘贴令牌，输入内容不会显示在屏幕上。
echo.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0发布到GitHub.ps1" -PromptToken -RepoName kati-chat
echo.
echo   按任意键关闭窗口...
pause >nul