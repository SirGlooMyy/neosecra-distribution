import smtplib
import ssl
import os
import json
import logging
from datetime import datetime
from email.mime.text import MIMEText
from email.mime.multipart import MIMEMultipart
from http.server import HTTPServer, BaseHTTPRequestHandler

logging.basicConfig(level=logging.INFO, format='%(asctime)s [%(levelname)s] %(message)s')

SMTP_SERVER = os.environ.get('SMTP_SERVER', 'mail.vdmail.cloud')
SMTP_PORT = int(os.environ.get('SMTP_PORT', 587))
SMTP_USER = os.environ.get('SMTP_USER', 'info@neosecra.com')
SMTP_PASS = os.environ.get('SMTP_PASS', '')
NOTIFY_EMAIL = os.environ.get('NOTIFY_EMAIL', 'info@neosecra.com')

def send_demo_email(data: dict) -> bool:
    full_name = data.get('full_name', 'Bilinmiyor')
    email = data.get('email', 'Bilinmiyor')
    company = data.get('company', 'Bilinmiyor')
    phone = data.get('phone', 'Bilinmiyor')
    products = data.get('products', [])
    notes = data.get('notes', 'Belirtilmedi')
    time_str = datetime.now().strftime('%d.%m.%Y %H:%M:%S')

    products_html = ''.join([f'<li style="margin-bottom:4px; color:#2563eb; font-weight:600;">• {p}</li>' for p in products]) or '<li>Belirtilmedi</li>'

    subject = f"🚀 Yeni Canlı Demo & PoC Talebi: {company} ({full_name})"

    html_content = f"""
    <!DOCTYPE html>
    <html>
    <head>
      <meta charset="utf-8">
      <style>
        body {{ font-family: 'Segoe UI', Arial, sans-serif; background-color: #0b0f19; color: #e2e8f0; margin: 0; padding: 20px; }}
        .container {{ max-width: 600px; margin: 0 auto; background: #131d31; border: 1px solid #232e42; border-radius: 12px; overflow: hidden; }}
        .header {{ background: #1f6ea6; padding: 24px; text-align: center; }}
        .header h1 {{ color: #ffffff; margin: 0; font-size: 20px; font-weight: 700; }}
        .content {{ padding: 28px; }}
        .field {{ margin-bottom: 16px; }}
        .label {{ font-size: 12px; text-transform: uppercase; letter-spacing: 0.05em; color: #94a3b8; font-weight: 600; margin-bottom: 4px; }}
        .value {{ font-size: 15px; color: #ffffff; font-weight: 500; background: #0b0f19; padding: 10px 14px; border-radius: 6px; border: 1px solid #232e42; }}
        .footer {{ padding: 18px 28px; background: #0a0e17; border-top: 1px solid #232e42; font-size: 12px; color: #64748b; text-align: center; }}
      </style>
    </head>
    <body>
      <div class="container">
        <div class="header">
          <h1>NeoSecra — Yeni Canlı Demo & PoC Talebi</h1>
        </div>
        <div class="content">
          <div class="field">
            <div class="label">Ad Soyad</div>
            <div class="value">{full_name}</div>
          </div>
          <div class="field">
            <div class="label">Kurumsal E-Posta</div>
            <div class="value"><a href="mailto:{email}" style="color:#60a5fa; text-decoration:none;">{email}</a></div>
          </div>
          <div class="field">
            <div class="label">Kurum / Şirket Adı</div>
            <div class="value">{company}</div>
          </div>
          <div class="field">
            <div class="label">Telefon Numarası</div>
            <div class="value"><a href="tel:{phone}" style="color:#60a5fa; text-decoration:none;">{phone}</a></div>
          </div>
          <div class="field">
            <div class="label">İlgilenilen Ürünler</div>
            <div class="value" style="background:#0b0f19;">
              <ul style="list-style:none; padding-left:0; margin:0;">
                {products_html}
              </ul>
            </div>
          </div>
          <div class="field">
            <div class="label">Not / Özel Gereksinimler</div>
            <div class="value">{notes}</div>
          </div>
        </div>
        <div class="footer">
          Tarih: {time_str} • NeoSecra Enterprise Platform Webhook
        </div>
      </div>
    </body>
    </html>
    """

    msg = MIMEMultipart('alternative')
    msg['From'] = f"NeoSecra Demo Portal <{SMTP_USER}>"
    msg['To'] = NOTIFY_EMAIL
    msg['Subject'] = subject
    msg.attach(MIMEText(html_content, 'html', 'utf-8'))

    if not SMTP_PASS:
        raise RuntimeError('SMTP_PASS ortam degiskeni tanimli degil')

    context = ssl.create_default_context()
    with smtplib.SMTP(SMTP_SERVER, SMTP_PORT, timeout=10) as server:
        server.starttls(context=context)
        server.login(SMTP_USER, SMTP_PASS)
        server.sendmail(SMTP_USER, [NOTIFY_EMAIL], msg.as_string())
        logging.info(f"Successfully sent demo notification for {company} ({email})")
        return True

class RequestHandler(BaseHTTPRequestHandler):
    def do_OPTIONS(self):
        self.send_response(200)
        self.send_header('Access-Control-Allow-Origin', '*')
        self.send_header('Access-Control-Allow-Methods', 'POST, OPTIONS')
        self.send_header('Access-Control-Allow-Headers', 'Content-Type')
        self.end_headers()

    def do_POST(self):
        if self.path == '/api/demo-request' or self.path == '/demo-request':
            content_length = int(self.headers.get('Content-Length', 0))
            body = self.rfile.read(content_length).decode('utf-8')
            try:
                data = json.loads(body)
                send_demo_email(data)
                
                self.send_response(200)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                response = json.dumps({"status": "ok", "message": "Demo talebiniz başarıyla alındı. Uzman ekibimiz en kısa sürede sizinle iletişime geçecektir."})
                self.wfile.write(response.encode('utf-8'))
            except Exception as e:
                logging.error(f"Error handling demo request: {e}")
                self.send_response(500)
                self.send_header('Content-Type', 'application/json')
                self.send_header('Access-Control-Allow-Origin', '*')
                self.end_headers()
                response = json.dumps({"status": "error", "message": str(e)})
                self.wfile.write(response.encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8000), RequestHandler)
    logging.info("Demo mailer listening on port 8000...")
    server.serve_forever()
