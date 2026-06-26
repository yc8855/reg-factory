@echo off
chcp 65001 >nul
cd /d "%~dp0"

if not exist ".venv\Scripts\python.exe" (
  echo [错误] 还没安装。请先双击 install.bat 完成安装。
  pause
  exit /b 1
)

echo 启动 reg-factory 控制面板 ...
echo 面板地址: http://127.0.0.1:8799  (浏览器会自动打开)
echo 关闭本窗口即停止服务。
echo.

REM 延迟 2 秒后打开浏览器(等服务起来)
start "" /b cmd /c "timeout /t 2 >nul & start http://127.0.0.1:8799"

.venv\Scripts\python.exe -m uvicorn webui.server:app --host 127.0.0.1 --port 8799
pause
