from flask import Flask, request, send_file
import yt_dlp
import os
import uuid

app = Flask(__name__)

# === НАСТРОЙКА ПРОКСИ ===
# Можно указать прокси здесь (например, 'socks5://127.0.0.1:1080' или 'http://user:pass@host:port')
# Если не нужен прокси — оставь пустую строку
PROXY = os.environ.get('YTDLP_PROXY', '')  # Можно задать через переменную окружения YTDLP_PROXY

@app.route('/download', methods=['GET'])
def download():
    url = request.args.get('url')
    if not url:
        return "No URL", 400
    outtmpl = f"/tmp/{uuid.uuid4()}.%(ext)s"
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
            response = send_file(filename, as_attachment=True)
            # Удаляем файл после отправки
            @response.call_on_close
            def cleanup():
                try:
                    os.remove(filename)
                except Exception:
                    pass
            return response
    except Exception as e:
        return f"Ошибка: {str(e)}", 500

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=5000) 
