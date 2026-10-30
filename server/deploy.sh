#!/usr/bin/env bash
#
# CBETA 反饋服務器一键部署脚本
# 用法：
#   sudo bash deploy.sh              # 完整部署（含 systemd 开机自启）
#   bash deploy.sh --run-only        # 只前台启动，不装 systemd
#
set -euo pipefail

# ===== 可配置变量（按需修改）=====
APP_DIR="${APP_DIR:-/home/cbeta/server}"
PORT="${PORT:-5000}"
WORKERS="${WORKERS:-4}"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
SERVICE_NAME="cbeta-feedback"
# 运行用户：非 root 时用当前用户；systemd 用这个用户跑
RUN_USER="${RUN_USER:-$(whoami)}"

RUN_ONLY=false
[[ "${1:-}" == "--run-only" ]] && RUN_ONLY=true

echo "==> 检查 Python: ${PYTHON_BIN}"
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "错误：找不到 ${PYTHON_BIN}，请先安装（Debian/Ubuntu: apt install ${PYTHON_BIN} ${PYTHON_BIN}-venv）"
  exit 1
fi

cd "${APP_DIR}"
echo "==> 工作目录：$(pwd)"

# ===== 1. 虛擬環境 =====
if [[ ! -d venv ]]; then
  echo "==> 創建虛擬環境 venv"
  "${PYTHON_BIN}" -m venv venv
else
  echo "==> venv 已存在，跳過創建"
fi

VENV_PY="${APP_DIR}/venv/bin/python"

# ===== 2. 安装依赖 =====
echo "==> 安装 Python 依赖"
"${VENV_PY}" -m pip install --upgrade pip
"${VENV_PY}" -m pip install -r requirements.txt

# ===== 3. 前台快速验证模式 =====
if [[ "${RUN_ONLY}" == true ]]; then
  echo "==> 前台启动 gunicorn（Ctrl+C 停止），端口 ${PORT}"
  exec "${VENV_PY}" -m gunicorn -w "${WORKERS}" -b "0.0.0.0:${PORT}" app:app
fi

# ===== 4. systemd 服务（需 root）=====
if [[ $EUID -ne 0 ]]; then
  echo "错误：安装 systemd 服务需要 root，请用 'sudo bash deploy.sh'"
  echo "      或先手动前台测试：bash deploy.sh --run-only"
  exit 1
fi

echo "==> 生成 systemd 服务：${SERVICE_NAME}"
cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=CBETA Feedback Server
After=network.target

[Service]
Type=notify
User=${RUN_USER}
WorkingDirectory=${APP_DIR}
ExecStart=${VENV_PY} -m gunicorn -w ${WORKERS} -b 0.0.0.0:${PORT} app:app
ExecReload=/bin/kill -s HUP \$MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

echo "==> 重载 systemd 并启动服务"
systemctl daemon-reload
systemctl enable --now "${SERVICE_NAME}"

sleep 2
systemctl --no-pager --lines=0 status "${SERVICE_NAME}" || true

# ===== 5. 自测 =====
echo "==> 自测 POST /api/feedback"
if curl -fsS -X POST "http://127.0.0.1:${PORT}/api/feedback" \
    -H "Content-Type: application/json" \
    -d '{"content":"部署自测","contact":"deploy-check"}' >/dev/null; then
  echo "✅ 部署成功，服务已在 0.0.0.0:${PORT} 运行"
  echo "   查看日志： journalctl -u ${SERVICE_NAME} -f"
  echo "   反饋數據： ${APP_DIR}/feedback_data.json"
else
  echo "⚠️  自测失败，请检查日志： journalctl -u ${SERVICE_NAME} -n 50"
  exit 1
fi
