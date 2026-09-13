@echo off
title JARVIS
powershell -NoProfile -STA -ExecutionPolicy Bypass -File "%~dp0Jarvis.ps1"
if errorlevel 1 (
  echo.
  echo JARVIS exited with an error. Closing in 10 seconds...
  timeout /t 10 >nul
)
