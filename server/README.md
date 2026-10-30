# 反饋服務器部署（Python 3.11）

腳本位置：`/home/cbeta/server/app.py`
監聽端口：`5000`（與 App 端 `feedback_url` 一致）

## 0. 一键部署（推薦）

本目錄提供 `deploy.sh`，自動完成建 venv、裝依賴、生成 systemd 服務並自檢：

```bash
cd /home/cbeta/server

# 完整部署（含 systemd 開機自啟，需 sudo）
sudo bash deploy.sh

# 僅前台啟動測試（不裝 systemd，Ctrl+C 停止）
bash deploy.sh --run-only
```

可調變數（改腳本頂部或用環境變數覆蓋）：`APP_DIR`、`PORT`、`WORKERS`、`PYTHON_BIN`、`RUN_USER`。
例如換端口：`PORT=8080 sudo bash deploy.sh`。

以下 1～5 為手動分步說明，腳本已包含這些步驟；若想逐步理解或自訂，可參考。

## 1. 建立虛擬環境並安裝依賴

```bash
cd /home/cbeta/server
python3.11 -m venv venv
./venv/bin/pip install --upgrade pip
./venv/bin/pip install -r requirements.txt
```

> 一定用 `python3.11 -m venv` 與 `./venv/bin/...`，避免機器上有多個 Python 版本時裝錯地方。

## 2. 快速驗證（前台運行）

```bash
cd /home/cbeta/server
./venv/bin/python -m gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

另開一個終端測試：

```bash
curl -X POST http://127.0.0.1:5000/api/feedback \
  -H "Content-Type: application/json" \
  -d '{"content":"測試反饋","contact":"undcloud"}'
```

正常返回：`{"message":"反饋已收到","success":true}`

## 3. 生產運行（systemd，開機自啟 + 崩潰重啟）

新建 `/etc/systemd/system/cbeta-feedback.service`：

```ini
[Unit]
Description=CBETA Feedback Server
After=network.target

[Service]
Type=notify
User=cbeta
WorkingDirectory=/home/cbeta/server
ExecStart=/home/cbeta/server/venv/bin/python -m gunicorn -w 4 -b 0.0.0.0:5000 app:app
ExecReload=/bin/kill -s HUP $MAINPID
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
```

啟用：

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cbeta-feedback
sudo systemctl status cbeta-feedback
```

查看日誌：

```bash
journalctl -u cbeta-feedback -f
```

## 4. 防火牆

確保 5000 端口可訪問：

```bash
sudo ufw allow 5000/tcp
# 或雲服務器安全組放行 5000
```

## 5. 反饋數據

存儲在 `/home/cbeta/server/feedback_data.json`。也可通過 API 查看：

```bash
curl http://127.0.0.1:5000/api/feedback
```

## 上線檢查清單

- [ ] App 端 `feedback_url` 指向 `http://59.110.91.183:5000/api/feedback`
- [ ] 服務器防火牆/安全組放行 5000
- [ ] systemd 服務運行中，重啟後自啟
- [ ] `feedback_data.json` 所在目錄对用户 `cbeta` 可寫

## 可選：HTTPS + nginx

若要 HTTPS，用 nginx 反代到 5000，並把 App 端 `feedback_url` 改為 `https://你的域名/api/feedback`。注意：HTTP 明文下反饋內容（聯繫方式）在網絡上可被竊聽，正式上線建議上 HTTPS。
