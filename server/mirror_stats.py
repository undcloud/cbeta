"""查看鏡像下載統計。

用法：
    ./venv/bin/python mirror_stats.py          # 人類可讀摘要
    ./venv/bin/python mirror_stats.py --json   # JSON 輸出
"""

import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone

DB_PATH = os.environ.get(
    'MIRROR_STATS_DB',
    os.path.join(os.path.dirname(os.path.abspath(__file__)), 'mirror_stats.db'),
)


def connect():
    if not os.path.exists(DB_PATH):
        raise SystemExit(f'统计数据库不存在：{DB_PATH}（服务尚未收到任何事件）')
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn


def collect(conn):
    def scalar(sql, params=()):
        row = conn.execute(sql, params).fetchone()
        return row[0] if row else 0

    since = (datetime.now(timezone.utc) - timedelta(days=7)).isoformat(timespec='seconds')
    data = {
        'total_downloads': scalar(
            "SELECT COUNT(*) FROM mirror_events WHERE event='download_complete'"),
        'total_imports': scalar(
            "SELECT COUNT(*) FROM mirror_events WHERE event='import_complete'"),
        'failures': scalar(
            "SELECT COUNT(*) FROM mirror_events WHERE event='failed'"),
        'unique_devices': scalar(
            "SELECT COUNT(DISTINCT device) FROM mirror_events WHERE device<>''"),
        'unique_downloaders': scalar(
            "SELECT COUNT(DISTINCT device) FROM mirror_events "
            "WHERE event='download_complete' AND device<>''"),
        'unique_importers': scalar(
            "SELECT COUNT(DISTINCT device) FROM mirror_events "
            "WHERE event='import_complete' AND device<>''"),
        'downloads_last_7_days': scalar(
            "SELECT COUNT(*) FROM mirror_events "
            "WHERE event='download_complete' AND created_at>=?", (since,)),
    }
    data['by_release'] = [
        {'release': row['release'] or 'unknown',
         'downloads': row['downloads'], 'imports': row['imports']}
        for row in conn.execute(
            '''SELECT release,
                      SUM(event='download_complete') AS downloads,
                      SUM(event='import_complete') AS imports
               FROM mirror_events
               GROUP BY release ORDER BY downloads DESC''')
    ]
    data['recent_failures'] = [
        {'time': row['created_at'], 'device': row['device'],
         'release': row['release'], 'detail': row['detail']}
        for row in conn.execute(
            "SELECT created_at, device, release, detail FROM mirror_events "
            "WHERE event='failed' ORDER BY id DESC LIMIT 10")
    ]
    return data


def print_summary(data):
    print('鏡像下載統計')
    print(f"  完成下載次數： {data['total_downloads']}（近 7 天 {data['downloads_last_7_days']}）")
    print(f"  完成匯入次數： {data['total_imports']}")
    print(f"  失敗事件：     {data['failures']}")
    print(f"  不重複裝置：   {data['unique_devices']}")
    print(f"  下載過的裝置： {data['unique_downloaders']}")
    print(f"  匯入過的裝置： {data['unique_importers']}")
    if data['by_release']:
        print('  依版本：')
        for row in data['by_release']:
            print(f"    {row['release']}: 下載 {row['downloads']} / 匯入 {row['imports']}")
    if data['recent_failures']:
        print('  最近失败：')
        for row in data['recent_failures']:
            detail = row['detail'] or '-'
            print(f"    {row['time']} {row['device'] or '-'} {detail}")


def main():
    conn = connect()
    try:
        data = collect(conn)
    finally:
        conn.close()
    if '--json' in sys.argv:
        print(json.dumps(data, ensure_ascii=False, indent=2))
    else:
        print_summary(data)


if __name__ == '__main__':
    main()
