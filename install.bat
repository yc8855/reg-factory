@echo off
chcp 65001 >nul
setlocal enabledelayedexpansion
cd /d "%~dp0"

echo ============================================================
echo   reg-factory 一键安装 (Python 环境 + 依赖 + 浏览器内核)
echo ============================================================
echo.

REM ---- 1. 找 Python (>=3.10) ----
set PY=
where py >nul 2>nul && set PY=py -3
if "%PY%"=="" (
  where python >nul 2>nul && set PY=python
)
if "%PY%"=="" (
  echo [错误] 没找到 Python。请先到 https://www.python.org/downloads/ 安装 Python 3.10 以上,
  echo        安装时勾选 "Add Python to PATH",装完重新双击本脚本。
  pause
  exit /b 1
)
echo [1/5] 使用 Python: %PY%
%PY% --version

REM ---- 2. 建虚拟环境 ----
if exist ".venv\Scripts\python.exe" (
  echo [2/5] 虚拟环境已存在,跳过创建。
) else (
  echo [2/5] 创建虚拟环境 .venv ...
  %PY% -m venv .venv
  if errorlevel 1 ( echo [错误] 创建 venv 失败 & pause & exit /b 1 )
)

set VENV_PY=.venv\Scripts\python.exe

REM ---- 3. 装依赖 ----
echo [3/5] 安装依赖 (pip install -r requirements.txt) ...
"%VENV_PY%" -m pip install --upgrade pip >nul 2>nul
"%VENV_PY%" -m pip install -r requirements.txt
if errorlevel 1 ( echo [错误] 依赖安装失败,检查网络/pip 源 & pause & exit /b 1 )

REM ---- 4. 装 Playwright Chromium ----
echo [4/5] 安装 Playwright Chromium 内核 ...
"%VENV_PY%" -m playwright install chromium
if errorlevel 1 ( echo [警告] playwright 内核安装失败,可稍后手动跑: .venv\Scripts\playwright install chromium )

REM ---- 5. 准备 .env ----
if exist ".env" (
  echo [5/5] .env 已存在,保留你的配置。
) else (
  if exist ".env.example" (
    copy ".env.example" ".env" >nul
    echo [5/5] 已从模板生成 .env,稍后在面板"配置"页填写密钥。
  ) else (
    echo [5/5] 未找到 .env.example,跳过。
  )
)

echo.
echo ============================================================
echo   安装完成!
echo   - 启动客户端: 确保 BitBrowser 和 Clash Verge 已打开
echo   - 双击 start.bat 打开控制面板
echo ============================================================
pause
