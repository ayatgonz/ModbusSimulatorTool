@echo off
title Modbus TCP/IP Tester Application
echo ========================================================
echo   Starting Modbus TCP/IP Client & Server Tester...
echo ========================================================

cd /d "%~dp0"

powershell -ExecutionPolicy Bypass -File "%~dp0server.ps1"

pause
