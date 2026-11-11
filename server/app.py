"""CBETA 鏡像下載 + 反饋服務。

單一 Flask 進程同時提供：
  * POST/GET /api/feedback        反饋（原本功能，資料存 JSON）
  * HEAD/GET /cbeta/html_full.zip 全量鏡像 ZIP，支援 Range/斷點續傳
  * POST     /api/mirror/event    App 回報下載/匯入事件（SQLite 統計）
  * GET      /api/mirror/stats    聚合統計（人數、次數、版本）

帶寬與併發由進程內的全域令牌桶控制，因此 gunicorn 必須只開一個 worker
（用 gthread 多執行緒處理請求），見 deploy.sh。
"""

import json
import os
import re
import sqlite3
import threading
import time
import uuid
from datetime import datetime, timedelta, timezone
from email.utils import formatdate, parsedate_to_datetime

from flask import Flask, Response, jsonify, request, stream_with_context
from flask_cors import CORS

app = Flask(__name__)
app.config['MAX_CONTENT_LENGTH'] = 256 * 1024
CORS(app, expose_headers=[
    'Content-Length', 'Content-Range', 'Accept-Ranges',
    'ETag', 'Last-Modified', 'X-Mirror-Release',
])

# ===== 檔案路徑 =====
BASE_DIR = os.path.dirname(os.path.abspath(__file__))
FEEDBACK_FILE = os.path.join(BASE_DIR, 'feedback_data.json')
MIRROR_ZIP = os.environ.get('MIRROR_ZIP', '/home/cbeta/static/html_full.zip')
MIRROR_RELEASE = os.environ.get('MIRROR_RELEASE', '')
STATS_DB = os.environ.get('MIRROR_STATS_DB', os.path.join(BASE_DIR, 'mirror_stats.db'))
STATS_EVENTS = {'start', 'download_complete', 'import_complete', 'failed'}

# ===== 流量控制參數 =====
KB = 1024
RATE_BYTES_PER_SECOND = int(os.environ.get('MIRROR_RATE_KBPS', '300')) * KB
MAX_GLOBAL = int(os.environ.get('MIRROR_MAX_GLOBAL', '2'))
MAX_PER_IP = int(os.environ.get('MIRROR_MAX_PER_IP', '2'))
MAX_PER_DEVICE = int(os.environ.get('MIRROR_MAX_PER_DEVICE', '1'))
FRESH_LIMIT = int(os.environ.get('MIRROR_FRESH_LIMIT', '3'))
FRESH_WINDOW_SECONDS = int(os.environ.get('MIRROR_FRESH_WINDOW', '600'))
CHUNK_SIZE = 64 * KB


# ===== 反饋 =====
def load_feedback():
    if os.path.exists(FEEDBACK_FILE):
        with open(FEEDBACK_FILE, 'r', encoding='utf-8') as f:
            return json.load(f)
    return []


def save_feedback(data):
    with open(FEEDBACK_FILE, 'w', encoding='utf-8') as f:
        json.dump(data, f, ensure_ascii=False, indent=2)


@app.route('/api/feedback', methods=['POST'])
def receive_feedback():
    try:
        feedback = request.get_json(silent=True)
        if not feedback or 'content' not in feedback:
            return jsonify({'error': '缺少反馈内容'}), 400

        feedback_list = load_feedback()
        feedback_list.append({
            'id': len(feedback_list) + 1,
            'timestamp': datetime.now().isoformat(),
            'content': feedback.get('content', ''),
            'contact': feedback.get('contact', ''),
            'app_version': feedback.get('app_version', ''),
            'platform': feedback.get('platform', ''),
            'os_version': feedback.get('os_version', ''),
        })
        save_feedback(feedback_list)
        return jsonify({'success': True, 'message': '反馈已收到'}), 200
    except Exception as e:
        print(f'Error: {e}')
        return jsonify({'error': '服务器错误'}), 500


@app.route('/api/feedback', methods=['GET'])
def get_feedback():
    try:
        return jsonify(load_feedback()), 200
    except Exception as e:
        print(f'Error: {e}')
        return jsonify({'error': '服务器错误'}), 500


# ===== 統計 DB =====
_stats_lock = threading.Lock()


def _db_connect():
    conn = sqlite3.connect(STATS_DB, timeout=15)
    conn.execute('PRAGMA journal_mode=WAL')
    conn.execute('PRAGMA busy_timeout=15000')
    return conn


def init_stats_db():
    with _stats_lock:
        conn = _db_connect()
        try:
            conn.execute('''
                CREATE TABLE IF NOT EXISTS mirror_events (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    event TEXT NOT NULL,
                    device TEXT NOT NULL DEFAULT '',
                    session TEXT NOT NULL DEFAULT '',
                    ip TEXT NOT NULL DEFAULT '',
                    release TEXT NOT NULL DEFAULT '',
                    bytes INTEGER NOT NULL DEFAULT 0,
                    detail TEXT NOT NULL DEFAULT '',
                    created_at TEXT NOT NULL,
                    UNIQUE(session, event)
                )
            ''')
            conn.execute(
                'CREATE INDEX IF NOT EXISTS idx_mirror_event ON mirror_events(event)')
            conn.execute(
                'CREATE INDEX IF NOT EXISTS idx_mirror_device ON mirror_events(device)')
            conn.execute(
                'CREATE INDEX IF NOT EXISTS idx_mirror_created ON mirror_events(created_at)')
            conn.commit()
        finally:
            conn.close()


def utc_now_iso():
    return datetime.now(timezone.utc).isoformat(timespec='seconds')


def _client_ip():
    forwarded = request.headers.get('X-Forwarded-For', '')
    if forwarded:
        return forwarded.split(',')[0].strip()
    return request.headers.get('X-Real-IP', request.remote_addr or '')


@app.route('/api/mirror/event', methods=['POST'])
def mirror_event():
    payload = request.get_json(silent=True) or {}
    event = str(payload.get('event', '')).strip()
    if event not in STATS_EVENTS:
        return jsonify({'error': '未知事件'}), 400

    device = str(payload.get('device', '')).strip()[:64]
    session = str(payload.get('session', '')).strip()[:64] or uuid.uuid4().hex
    release = str(payload.get('release', '')).strip()[:32]
    detail = str(payload.get('detail', '')).strip()[:512]
    try:
        byte_count = int(payload.get('bytes', 0) or 0)
    except (TypeError, ValueError):
        byte_count = 0

    try:
        with _stats_lock:
            conn = _db_connect()
            try:
                conn.execute(
                    '''INSERT OR IGNORE INTO mirror_events
                       (event, device, session, ip, release, bytes, detail, created_at)
                       VALUES (?, ?, ?, ?, ?, ?, ?, ?)''',
                    (event, device, session, _client_ip(),
                     release, byte_count, detail, utc_now_iso()),
                )
                conn.commit()
            finally:
                conn.close()
    except sqlite3.Error as e:
        print(f'Stats DB error: {e}')
        return jsonify({'error': '统计写入失败'}), 500

    return jsonify({'success': True}), 200


def _scalar(conn, sql, params=()):
    row = conn.execute(sql, params).fetchone()
    return row[0] if row else 0


@app.route('/api/mirror/stats', methods=['GET'])
def mirror_stats():
    try:
        conn = _db_connect()
        try:
            total_downloads = _scalar(
                conn, "SELECT COUNT(*) FROM mirror_events WHERE event='download_complete'")
            total_imports = _scalar(
                conn, "SELECT COUNT(*) FROM mirror_events WHERE event='import_complete'")
            failures = _scalar(
                conn, "SELECT COUNT(*) FROM mirror_events WHERE event='failed'")
            unique_devices = _scalar(
                conn, "SELECT COUNT(DISTINCT device) FROM mirror_events WHERE device<>''")
            downloaders = _scalar(
                conn,
                "SELECT COUNT(DISTINCT device) FROM mirror_events "
                "WHERE event='download_complete' AND device<>''")
            importers = _scalar(
                conn,
                "SELECT COUNT(DISTINCT device) FROM mirror_events "
                "WHERE event='import_complete' AND device<>''")
            since = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat(
                timespec='seconds')
            recent_downloads = _scalar(
                conn,
                "SELECT COUNT(*) FROM mirror_events "
                "WHERE event='download_complete' AND created_at>=?", (since,))
            by_release = [
                {'release': row[0] or 'unknown', 'downloads': row[1],
                 'imports': row[2]}
                for row in conn.execute(
                    '''SELECT release,
                              SUM(event='download_complete'),
                              SUM(event='import_complete')
                       FROM mirror_events
                       GROUP BY release ORDER BY downloads DESC''')
            ]
        finally:
            conn.close()

        with _slots_lock:
            active = {
                'global': _active_total,
                'limit_global': MAX_GLOBAL,
                'limit_per_ip': MAX_PER_IP,
                'limit_per_device': MAX_PER_DEVICE,
            }

        return jsonify({
            'total_downloads': total_downloads,
            'total_imports': total_imports,
            'failures': failures,
            'unique_devices': unique_devices,
            'unique_downloaders': downloaders,
            'unique_importers': importers,
            'downloads_last_7_days': recent_downloads,
            'by_release': by_release,
            'active_streams': active,
            'rate_limit_kbps': RATE_BYTES_PER_SECOND // KB,
            'zip_available': os.path.isfile(MIRROR_ZIP),
            'release': MIRROR_RELEASE,
        })
    except Exception as e:
        print(f'Stats query error: {e}')
        return jsonify({'error': '统计查询失败'}), 500


# ===== 全域帶寬（令牌桶） =====
class TokenBucket:
    """所有下載共用一個桶；總速率固定，人越多每人越慢但不會低於公平分配。"""

    def __init__(self, rate_per_second, capacity):
        self.rate = float(rate_per_second)
        self.capacity = float(capacity)
        self.tokens = float(capacity)
        self.updated = time.monotonic()
        self.lock = threading.Lock()

    def consume(self, amount):
        while True:
            with self.lock:
                now = time.monotonic()
                self.tokens = min(
                    self.capacity, self.tokens + (now - self.updated) * self.rate)
                self.updated = now
                if self.tokens >= amount:
                    self.tokens -= amount
                    return
                wait = (amount - self.tokens) / self.rate
            time.sleep(min(wait, 0.5))


_limiter = TokenBucket(RATE_BYTES_PER_SECOND, RATE_BYTES_PER_SECOND)

# ===== 併發槽位 =====
_slots_lock = threading.Lock()
_active_total = 0
_active_per_ip = {}
_active_per_device = {}
_fresh_starts = {}


def _acquire_slot(ip, device):
    global _active_total
    with _slots_lock:
        if _active_total >= MAX_GLOBAL:
            return 'global'
        if _active_per_ip.get(ip, 0) >= MAX_PER_IP:
            return 'ip'
        if device and _active_per_device.get(device, 0) >= MAX_PER_DEVICE:
            return 'device'
        _active_total += 1
        _active_per_ip[ip] = _active_per_ip.get(ip, 0) + 1
        if device:
            _active_per_device[device] = _active_per_device.get(device, 0) + 1
        return None


def _release_slot(ip, device):
    global _active_total
    with _slots_lock:
        if _active_total > 0:
            _active_total -= 1
        current = _active_per_ip.get(ip, 0)
        if current <= 1:
            _active_per_ip.pop(ip, None)
        else:
            _active_per_ip[ip] = current - 1
        if device:
            current = _active_per_device.get(device, 0)
            if current <= 1:
                _active_per_device.pop(device, None)
            else:
                _active_per_device[device] = current - 1


def _allow_fresh_start(ip, device):
    """同一部裝置 10 分鐘內最多重新從頭開始 3 次；續傳不受限制。"""
    key = device or f'ip:{ip}'
    now = time.monotonic()
    with _slots_lock:
        entries = [t for t in _fresh_starts.get(key, []) if now - t < FRESH_WINDOW_SECONDS]
        if len(entries) >= FRESH_LIMIT:
            _fresh_starts[key] = entries
            return False
        entries.append(now)
        _fresh_starts[key] = entries
        return True


# ===== 鏡像 ZIP =====
def _zip_meta():
    stat = os.stat(MIRROR_ZIP)
    etag = f'"{stat.st_size}-{int(stat.st_mtime)}"'
    return stat, etag


_RANGE_RE = re.compile(r'^bytes=(\d*)-(\d*)$')


def _parse_range(header, size):
    """回傳 (start, end)（含尾端）、None（忽略 Range）或 'invalid'。"""
    if not header:
        return None
    match = _RANGE_RE.match(header.strip())
    if not match:
        return 'invalid'
    raw_start, raw_end = match.group(1), match.group(2)
    if not raw_start and not raw_end:
        return 'invalid'
    if not raw_start:
        suffix = int(raw_end)
        if suffix <= 0:
            return 'invalid'
        start = max(0, size - suffix)
        end = size - 1
    else:
        start = int(raw_start)
        end = int(raw_end) if raw_end else size - 1
        if start >= size or start > end:
            return 'invalid'
        end = min(end, size - 1)
    return start, end


def _not_modified(etag, last_modified, size):
    if_none_match = request.headers.get('If-None-Match')
    if if_none_match and if_none_match.strip() == etag:
        return True
    if_modified_since = request.headers.get('If-Modified-Since')
    if if_modified_since and not if_none_match:
        try:
            since = parsedate_to_datetime(if_modified_since)
            if since is not None and int(last_modified) <= int(since.timestamp()):
                return True
        except (TypeError, ValueError, OverflowError):
            pass
    return False


def _base_headers(stat, etag, accept_ranges=True):
    headers = {
        'ETag': etag,
        'Last-Modified': formatdate(stat.st_mtime, usegmt=True),
        'Cache-Control': 'public, max-age=86400',
        'Content-Type': 'application/zip',
        'Content-Disposition': 'attachment; filename="cbeta_html_full.zip"',
        'X-Mirror-Release': MIRROR_RELEASE,
    }
    if accept_ranges:
        headers['Accept-Ranges'] = 'bytes'
    return headers


def _stream_zip(path, start, length, on_done):
    def generate():
        sent = 0
        try:
            with open(path, 'rb') as handle:
                handle.seek(start)
                remaining = length
                while remaining > 0:
                    chunk = handle.read(min(CHUNK_SIZE, remaining))
                    if not chunk:
                        break
                    _limiter.consume(len(chunk))
                    yield chunk
                    sent += len(chunk)
                    remaining -= len(chunk)
        except (BrokenPipeError, ConnectionResetError):
            pass
        finally:
            on_done(sent == length)

    return generate()


def _serve_zip():
    if not os.path.isfile(MIRROR_ZIP):
        return jsonify({'error': '镜像文件尚未就绪'}), 404

    stat, etag = _zip_meta()
    size = stat.st_size
    headers = _base_headers(stat, etag)

    if _not_modified(etag, stat.st_mtime, size):
        headers.pop('Content-Type', None)
        headers.pop('Content-Disposition', None)
        return Response(status=304, headers=headers)

    if request.method == 'HEAD':
        headers['Content-Length'] = str(size)
        return Response(status=200, headers=headers)

    ip = _client_ip()
    device = request.headers.get('X-Fodian-Device', '').strip()[:64]

    range_header = request.headers.get('Range')
    if_range = request.headers.get('If-Range')
    if if_range and if_range.strip().strip('"') != etag.strip('"'):
        range_header = None

    parsed = _parse_range(range_header, size)
    if parsed == 'invalid':
        headers['Content-Range'] = f'bytes */{size}'
        return Response(status=416, headers=headers)

    if parsed is None:
        start, end = 0, size - 1
    else:
        start, end = parsed

    error_headers = {
        key: value for key, value in headers.items()
        if key not in ('Content-Type', 'Content-Disposition')
    }

    blocked = _acquire_slot(ip, device)
    if blocked:
        error_headers['Retry-After'] = '20'
        reason = {
            'global': '鏡像下載人數已滿，請稍後重試（會自動續傳）',
            'ip': '同一個網路的下載數已滿，請稍後重試',
            'device': '這部裝置已有下載進行中',
        }[blocked]
        return jsonify({'error': reason, 'reason': blocked}), 503, error_headers

    fresh_start = parsed is None or start == 0
    if fresh_start and not _allow_fresh_start(ip, device):
        _release_slot(ip, device)
        error_headers['Retry-After'] = str(FRESH_WINDOW_SECONDS)
        return jsonify({
            'error': '重新下載過於頻繁，請稍後再試；已中斷的下載會自動續傳',
        }), 429, error_headers

    length = end - start + 1
    status = 206 if parsed is not None else 200
    if parsed is not None:
        headers['Content-Range'] = f'bytes {start}-{end}/{size}'
    headers['Content-Length'] = str(length)

    released = threading.Event()

    def release(_completed):
        if released.is_set():
            return
        released.set()
        _release_slot(ip, device)

    return Response(
        stream_with_context(_stream_zip(MIRROR_ZIP, start, length, release)),
        status=status,
        headers=headers,
        direct_passthrough=True,
    )


@app.route('/cbeta/html_full.zip', methods=['GET', 'HEAD'])
def mirror_zip():
    return _serve_zip()


try:
    init_stats_db()
except Exception as error:  # 統計不可用時仍保留反饋與鏡像下載
    print(f'Stats DB init failed: {error}')

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True, threaded=True)
