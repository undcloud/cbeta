#!/usr/bin/env bash
#
# CBETA 鏡像下載 + 反饋服務器一键部署脚本
# 用法：
#   sudo bash deploy.sh              # 完整部署（含 systemd 开机自启）
#   bash deploy.sh --run-only        # 只前台启动，不装 systemd
#
set -euo pipefail

# ===== 可配置变量（按需修改）=====
APP_DIR="${APP_DIR:-/home/cbeta/server}"
PORT="${PORT:-5000}"
# 必须只有 1 个 worker：带宽令牌桶与并发计数都在进程内存中
WORKERS="${WORKERS:-1}"
THREADS="${THREADS:-8}"
PYTHON_BIN="${PYTHON_BIN:-python3.11}"
MIRROR_ZIP="${MIRROR_ZIP:-/home/cbeta/static/html_full.zip}"
# 5 Mbps 总带宽，镜像只占用约一半（300 KB/s），其余留给反馈与其他应用
MIRROR_RATE_KBPS="${MIRROR_RATE_KBPS:-300}"
MIRROR_RELEASE="${MIRROR_RELEASE:-}"
SERVICE_NAME="cbeta-feedback"
# 运行用户：非 root 时用当前用户；systemd 用这个用户跑
RUN_USER="${RUN_USER:-$(whoami)}"
GUNICORN_ARGS=(-w "${WORKERS}" --worker-class gthread --threads "${THREADS}"
  --timeout 7200 --graceful-timeout 30 --keep-alive 75
  -b "0.0.0.0:${PORT}")

RUN_ONLY=false
[[ "${1:-}" == "--run-only" ]] && RUN_ONLY=true

echo "==> 检查 Python: ${PYTHON_BIN}"
if ! command -v "${PYTHON_BIN}" >/dev/null 2>&1; then
  echo "错误：找不到 ${PYTHON_BIN}，请先安装（Debian/Ubuntu: apt install ${PYTHON_BIN} ${PYTHON_BIN}-venv）"
  exit 1
fi

cd "${APP_DIR}"
echo "==> 工作目录：$(pwd)"

if [[ ! -f "${MIRROR_ZIP}" ]]; then
  echo "⚠️  镜像文件不存在：${MIRROR_ZIP}"
  echo "   请先上传 html_full.zip 到该路径；服务仍会启动，但镜像接口返回 404。"
fi

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
  export MIRROR_ZIP MIRROR_RATE_KBPS MIRROR_RELEASE
  exec "${VENV_PY}" -m gunicorn "${GUNICORN_ARGS[@]}" app:app
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
Description=CBETA Mirror + Feedback Server
After=network.target

[Service]
Type=notify
User=${RUN_USER}
WorkingDirectory=${APP_DIR}
Environment=MIRROR_ZIP=${MIRROR_ZIP}
Environment=MIRROR_RATE_KBPS=${MIRROR_RATE_KBPS}
Environment=MIRROR_RELEASE=${MIRROR_RELEASE}
LimitNOFILE=65535
ExecStart=${VENV_PY} -m gunicorn ${GUNICORN_ARGS[*]} app:app
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
  echo "✅ 反馈接口正常"
else
  echo "⚠️  反馈自测失败，请检查日志： journalctl -u ${SERVICE_NAME} -n 50"
  exit 1
fi

echo "==> 自测 HEAD /cbeta/html_full.zip"
if curl -fsSI "http://127.0.0.1:${PORT}/cbeta/html_full.zip" | grep -qi 'Accept-Ranges: bytes'; then
  echo "✅ 镜像接口正常（支持 Range）"
else
  echo "⚠️  镜像接口不可用；若文件尚未上传属正常，上传后重启服务即可"
fi

echo "✅ 部署完成，服务已在 0.0.0.0:${PORT} 运行"
echo "   镜像文件： ${MIRROR_ZIP}"
echo "   带宽上限： ${MIRROR_RATE_KBPS} KB/s（全局共享）"
echo "   查看日志： journalctl -u ${SERVICE_NAME} -f"
echo "   反馈数据： ${APP_DIR}/feedback_data.json"
echo "   统计数据库： ${APP_DIR}/mirror_stats.db"
