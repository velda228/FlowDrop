from flask import Flask, request, send_file, jsonify
import yt_dlp
import os
import uuid
import threading
import time

app = Flask(__name__)

# === НАСТРОЙКА ПРОКСИ ===
# Можно указать прокси здесь (например, 'socks5://127.0.0.1:1080' или 'http://user:pass@host:port')
# Если не нужен прокси — оставь пустую строку
PROXY = os.environ.get('YTDLP_PROXY', '')  # Можно задать через переменную окружения YTDLP_PROXY

# Хранилище задач: task_id -> {'status': 'pending'|'downloading'|'ready'|'error', 'file': path, 'error': str}
tasks = {}

DOWNLOAD_DIR = '/tmp/ytviewer_downloads'
os.makedirs(DOWNLOAD_DIR, exist_ok=True)

# Фоновая функция скачивания
def download_worker(task_id, url):
    tasks[task_id]['status'] = 'downloading'
    outtmpl = os.path.join(DOWNLOAD_DIR, f"{task_id}.%(ext)s")
    ydl_opts = {
        'outtmpl': outtmpl,
        'format': 'bestvideo+bestaudio/best',
        'merge_output_format': 'mp4',
        'quiet': True,
    }
    if PROXY:
        ydl_opts['proxy'] = PROXY
    try:
        with yt_dlp.YoutubeDL(ydl_opts) as ydl:
            info = ydl.extract_info(url, download=True)
            filename = ydl.prepare_filename(info)
            if not filename.endswith('.mp4'):
                filename = filename.rsplit('.', 1)[0] + '.mp4'
            tasks[task_id]['file'] = filename
            tasks[task_id]['status'] = 'ready'
    except Exception as e:
        tasks[task_id]['status'] = 'error'
        tasks[task_id]['error'] = str(e)

@app.route('/start_download', methods=['POST'])
def start_download():
    data = request.get_json()
    url = data.get('url')
    if not url:
        return jsonify({'error': 'No URL'}), 400
    task_id = str(uuid.uuid4())
    tasks[task_id] = {'status': 'pending', 'file': None, 'error': None}
    threading.Thread(target=download_worker, args=(task_id, url), daemon=True).start()
    return jsonify({'task_id': task_id})

@app.route('/status/<task_id>', methods=['GET'])
def status(task_id):
    task = tasks.get(task_id)
    if not task:
        return jsonify({'error': 'Task not found'}), 404
    return jsonify({'status': task['status'], 'error': task['error']})

@app.route('/get_file/<task_id>', methods=['GET'])
def get_file(task_id):
    task = tasks.get(task_id)
    if not task or task['status'] != 'ready' or not task['file']:
        return jsonify({'error': 'File not ready'}), 404
    try:
        response = send_file(task['file'], as_attachment=True)
        @response.call_on_close
        def cleanup():
            try:
                os.remove(task['file'])
            except Exception:
                pass
            tasks.pop(task_id, None)
        return response
    except Exception as e:
        return jsonify({'error': str(e)}), 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000) 
