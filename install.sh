#!/usr/bin/env bash
# reg-factory 一键安装 (mac/linux)
set -e
cd "$(dirname "$0")"

echo "============================================================"
echo "  reg-factory 一键安装 (Python 环境 + 依赖 + 浏览器内核)"
echo "============================================================"

PY=python3
command -v python3 >/dev/null 2>&1 || PY=python
command -v "$PY" >/dev/null 2>&1 || { echo "[错误] 没找到 Python。请先安装 Python 3.10+"; exit 1; }
echo "[1/5] 使用 Python: $($PY --version)"

if [ -x ".venv/bin/python" ]; then
  echo "[2/5] 虚拟环境已存在,跳过创建。"
else
  echo "[2/5] 创建虚拟环境 .venv ..."
  "$PY" -m venv .venv
fi
VENV_PY=".venv/bin/python"

echo "[3/5] 安装依赖 ..."
"$VENV_PY" -m pip install --upgrade pip >/dev/null
"$VENV_PY" -m pip install -r requirements.txt

echo "[4/5] 安装 Playwright Chromium 内核 ..."
"$VENV_PY" -m playwright install chromium || echo "[警告] 内核安装失败,可稍后手动跑: .venv/bin/playwright install chromium"

if [ -f ".env" ]; then
  echo "[5/5] .env 已存在,保留你的配置。"
elif [ -f ".env.example" ]; then
  cp .env.example .env
  echo "[5/5] 已从模板生成 .env,稍后在面板"配置"页填写密钥。"
fi

echo ""
echo "============================================================"
echo "  安装完成! 确保 BitBrowser 和 Clash Verge 已打开,"
echo "  然后运行: ./start.sh  打开控制面板"
echo "============================================================"
