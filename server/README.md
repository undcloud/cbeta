# 反馈服务器

## 部署说明

1. 安装依赖：
```bash
pip install -r requirements.txt
```

2. 运行服务器：
```bash
python app.py
```

服务器将在 0.0.0.0:5000 上运行。

## API 接口

### 提交反馈
- POST /api/feedback
- Body: {"content": "...", "contact": "...", "app_version": "...", "platform": "...", "os_version": "..."}

### 查看反馈
- GET /api/feedback

## 生产部署建议

使用 gunicorn 或 uwsgi 部署：
```bash
gunicorn -w 4 -b 0.0.0.0:5000 app:app
```

建议使用 nginx 反向代理并配置 HTTPS。
