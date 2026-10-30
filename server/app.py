from flask import Flask, request, jsonify
from flask_cors import CORS
import json
import os
from datetime import datetime

app = Flask(__name__)
CORS(app)

FEEDBACK_FILE = 'feedback_data.json'

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
        feedback = request.get_json()
        
        if not feedback or 'content' not in feedback:
            return jsonify({'error': '缺少反馈内容'}), 400
        
        feedback_list = load_feedback()
        
        feedback_entry = {
            'id': len(feedback_list) + 1,
            'timestamp': datetime.now().isoformat(),
            'content': feedback.get('content', ''),
            'contact': feedback.get('contact', ''),
            'app_version': feedback.get('app_version', ''),
            'platform': feedback.get('platform', ''),
            'os_version': feedback.get('os_version', ''),
        }
        
        feedback_list.append(feedback_entry)
        save_feedback(feedback_list)
        
        return jsonify({'success': True, 'message': '反馈已收到'}), 200
    
    except Exception as e:
        print(f'Error: {e}')
        return jsonify({'error': '服务器错误'}), 500

@app.route('/api/feedback', methods=['GET'])
def get_feedback():
    try:
        feedback_list = load_feedback()
        return jsonify(feedback_list), 200
    except Exception as e:
        print(f'Error: {e}')
        return jsonify({'error': '服务器错误'}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000, debug=True)
