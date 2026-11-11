# CBETA 鏡像下載 + 反饋服務器

一個 Flask 進程同時提供鏡像下載與反饋收集，避免為低频的反饋接口單獨維持一套服務。

- 腳本位置：`/home/cbeta/server`
- 端口：`5000`（與 App 端 `feedback_url`、鏡像地址一致）
- 鏡像文件：`/home/cbeta/static/html_full.zip`（不進 Git）
- 統計數據庫：`/home/cbeta/server/mirror_stats.db`（不進 Git）

## 0. 一鍵部署（推薦）

```bash
cd /home/cbeta/server

# 完整部署（含 systemd 開機自啟，需 sudo）
sudo bash deploy.sh

# 僅前台啟動測試（Ctrl+C 停止）
bash deploy.sh --run-only
```

可調變數（改腳本頂部或用環境變數覆蓋）：

| 變數 | 默認 | 說明 |
| --- | --- | --- |
| `APP_DIR` | `/home/cbeta/server` | 服務目錄 |
| `PORT` | `5000` | 監聽端口 |
| `MIRROR_ZIP` | `/home/cbeta/static/html_full.zip` | 鏡像 ZIP 路徑 |
| `MIRROR_RATE_KBPS` | `300` | 全局下載帶寬上限（KB/s） |
| `MIRROR_RELEASE` | 空 | 鏡像版本號，如 `2026.R2`，會寫入響應頭 |
| `THREADS` | `8` | gunicorn gthread 線程數 |
| `PYTHON_BIN` | `python3.11` | Python 解譯器 |
| `RUN_USER` | 當前用戶 | systemd 運行用戶 |

示例：`MIRROR_RATE_KBPS=250 PORT=8080 sudo bash deploy.sh`

> **必須只有 1 個 worker**：帶寬令牌桶與併發計數都在進程內存中，多 worker 會各自計數。
> 請求併發由 gthread 線程解決，見 `deploy.sh` 的 `-w 1 --worker-class gthread`。

## 1. 上傳鏡像文件

```bash
sudo mkdir -p /home/cbeta/static
# 從本地上傳，或先放到臨時目錄再移動
sudo mv html_full.zip /home/cbeta/static/html_full.zip
sudo chown cbeta:cbeta /home/cbeta/static/html_full.zip   # RUN_USER 需可讀
```

ZIP 約 500 MB，包含全部作品的嵌套 work ZIP。**不要提交到 Git**，`.gitignore` 已排除 `server/*.zip`。

上傳後重啟：

```bash
sudo systemctl restart cbeta-feedback
```

## 2. 接口

### 反饋

```bash
curl -X POST http://127.0.0.1:5000/api/feedback \
  -H "Content-Type: application/json" \
  -d '{"content":"測試反饋","contact":"undcloud"}'
```

返回：`{"message":"反饋已收到","success":true}`

### 鏡像 ZIP

```bash
# HEAD：查看大小、ETag、是否支持 Range
curl -I http://127.0.0.1:5000/cbeta/html_full.zip

# 前 1 MB
curl -r 0-1048575 -o /tmp/part.bin http://127.0.0.1:5000/cbeta/html_full.zip

# 續傳
curl -C - -o /tmp/html_full.zip http://127.0.0.1:5000/cbeta/html_full.zip
```

支持：`HEAD`、`Content-Length`、`Accept-Ranges: bytes`、`Range`/`206`、
`If-Range`、`ETag`、`Last-Modified`、`If-None-Match`/`304`。

App 下載時會帶兩個頭：

| 頭 | 用途 |
| --- | --- |
| `X-Fodian-Device` | 隨機裝置 UUID，用於每人 1 路下載與公平統計（同一 WiFi 共用公網 IP 時仍可區分） |
| `X-Fodian-Session` | 單次下載會話，用於事件去重 |

### 下載事件（App 回報）

```bash
curl -X POST http://127.0.0.1:5000/api/mirror/event \
  -H "Content-Type: application/json" \
  -d '{"event":"download_complete","device":"abc123","session":"s1",
       "release":"2026.R2","bytes":528030605}'
```

事件：`start`、`download_complete`、`import_complete`、`failed`。
`(session, event)` 唯一，重複上報會忽略；統計按 `device` 去重。

### 統計

```bash
curl http://127.0.0.1:5000/api/mirror/stats
cd /home/cbeta/server && ./venv/bin/python mirror_stats.py
```

輸出下載/匯入次數、去重裝置數、近 7 天下載、依版本分佈、最近失敗。

## 3. 帶寬與併發

默認按 5 Mbps 總帶寬設計：

- 全局上限 `300 KB/s`（約 2.4 Mbps），其餘留給反饋與其他應用；
- 全局最多 `2` 路同時下載；
- 同一 IP 最多 `2` 路（同一 WiFi 多人共用公網 IP 時仍有全局上限兜底）；
- 同一裝置最多 `1` 路；
- 每部裝置 10 分鐘內最多重新從頭開始 `3` 次；帶 `Range` 的續傳不受限。

兩路同時下載時每人約 `150 KB/s`，仍高於 CBETA 按部下載的常見速度；
下載 504 MB 約需 56 分鐘。可用環境變數調整：

```bash
MIRROR_RATE_KBPS=300 MIRROR_MAX_GLOBAL=2 MIRROR_MAX_PER_IP=2 \
MIRROR_MAX_PER_DEVICE=1 MIRROR_FRESH_LIMIT=3 MIRROR_FRESH_WINDOW=600
```

返回 `503`/`429` 時會帶 `Retry-After`，App 會自動退避並續傳。

## 4. systemd 與防火牆

`deploy.sh` 會生成 `/etc/systemd/system/cbeta-feedback.service`：

```bash
sudo systemctl status cbeta-feedback
journalctl -u cbeta-feedback -f
```

放行端口：

```bash
sudo ufw allow 5000/tcp
# 或雲服務器安全組放行 5000
```

## 5. 上線檢查清單

- [ ] `/home/cbeta/static/html_full.zip` 已上傳且運行用戶可讀
- [ ] `systemctl status cbeta-feedback` 正常，重啟後自啟
- [ ] `curl -I .../cbeta/html_full.zip` 返回 `Accept-Ranges: bytes`
- [ ] App 端 `config/mirror_server.json` 的 `base_url` 指向 `http://<ECS_IP>:5000`
- [ ] App 端 `config/feedback_server.json` 的 `feedback_url` 保持不變
- [ ] 統計庫目錄對運行用戶可寫（`mirror_stats.db`）

## 可選：HTTPS + nginx

若前面加 nginx 反代到 5000，需注意：

- `proxy_buffering off;`，否則帶寬限制與續傳會被 nginx 緩衝干擾；
- `proxy_request_buffering off;`；
- 保留 `X-Fodian-Device`、`X-Fodian-Session`、`Range` 頭；
- App 端 `base_url` 改為 `https://你的域名`。

明文 HTTP 下載 ZIP 本身不含敏感信息，但反饋內容（聯繫方式）可被竊聽，正式上線建議 HTTPS。
