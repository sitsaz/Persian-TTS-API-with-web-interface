#!/bin/bash

# Check if script is run with sudo
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo: sudo ./setup-tts.sh"
    exit 1
fi

# Default values
DEFAULT_IP="localhost"
DEFAULT_PORT="8000"

# Interactive prompts for IP/domain and port
echo "Enter the IP address or domain for the web interface (default: $DEFAULT_IP):"
read -p "> " WEB_IP
WEB_IP=${WEB_IP:-$DEFAULT_IP}

echo "Enter the port for the web interface (default: $DEFAULT_PORT):"
read -p "> " WEB_PORT
WEB_PORT=${WEB_PORT:-$DEFAULT_PORT}

# Validate port number
if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || [ "$WEB_PORT" -lt 1 ] || [ "$WEB_PORT" -gt 65535 ]; then
    echo "Error: Port must be a number between 1 and 65535."
    exit 1
fi

# Variables
TTS_DIR="$HOME/tts-api"
WEB_DIR="$HOME/tts-web"
VOICE_MODEL_DIR="$HOME/piper-voices"
CURRENT_USER=$(logname)

# Step 1: Install dependencies
echo "Installing dependencies..."
apt-get update
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get install -y docker.io
    systemctl enable docker
    systemctl start docker
fi
if ! command -v python3 &> /dev/null; then
    echo "Installing Python3..."
    apt-get install -y python3 python3-pip
fi

# Step 2: Set up TTS API
echo "Setting up Persian Piper TTS API..."
mkdir -p "$TTS_DIR" "$VOICE_MODEL_DIR"
cd "$TTS_DIR"

# Pull Piper TTS Docker image
docker pull rhasspy/piper:latest

# Download Persian voice model (example: fa_IR-parsa-medium)
if [ ! -f "$VOICE_MODEL_DIR/fa_IR-parsa-medium.onnx" ]; then
    echo "Downloading Persian voice model..."
    wget -P "$VOICE_MODEL_DIR" https://huggingface.co/rhasspy/piper-voices/resolve/main/fa/fa_IR/parsa/medium/fa_IR-parsa-medium.onnx
    wget -P "$VOICE_MODEL_DIR" https://huggingface.co/rhasspy/piper-voices/resolve/main/fa/fa_IR/parsa/medium/fa_IR-parsa-medium.onnx.json
fi

# Run TTS API container (detached)
docker run -d --name piper-tts \
    -p 5000:5000 \
    -v "$VOICE_MODEL_DIR:/voices" \
    rhasspy/piper:latest \
    --port 5000 \
    --model /voices/fa_IR-parsa-medium.onnx

# Step 3: Set up web interface
echo "Setting up web interface..."
mkdir -p "$WEB_DIR"
cd "$WEB_DIR"

# Create index.html with dynamic IP and port
cat << EOF > index.html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <title>Persian TTS Web Interface</title>
</head>
<body>
    <h1>Persian Text-to-Speech</h1>
    <textarea id="text" rows="4" cols="50">سلام، این یک آزمایش است.</textarea><br>
    <button onclick="synthesize()">Synthesize</button><br>
    <audio id="audio" controls></audio>

    <script>
        async function synthesize() {
            const text = document.getElementById("text").value;
            const response = await fetch("http://$WEB_IP:$WEB_PORT/synthesize", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({ text: text, voice: "fa_IR-parsa-medium" })
            });
            const blob = await response.blob();
            const audio = document.getElementById("audio");
            audio.src = URL.createObjectURL(blob);
            audio.play();
        }
    </script>
</body>
</html>
EOF

# Create simple Python server
cat << EOF > server.py
import http.server
import socketserver
import json
import requests

PORT = $WEB_PORT

class TTSHandler(http.server.SimpleHTTPRequestHandler):
    def do_POST(self):
        if self.path == '/synthesize':
            content_length = int(self.headers['Content-Length'])
            post_data = self.rfile.read(content_length)
            data = json.loads(post_data)
            text = data.get('text', '')
            voice = data.get('voice', 'fa_IR-parsa-medium')

            # Forward request to TTS API
            tts_response = requests.get(
                'http://localhost:5000/synthesize',
                params={'text': text, 'voice': voice},
                stream=True
            )

            # Send audio response
            self.send_response(200)
            self.send_header('Content-Type', 'audio/wav')
            self.end_headers()
            for chunk in tts_response.iter_content(chunk_size=8192):
                self.wfile.write(chunk)
        else:
            self.send_error(404)

Handler = TTSHandler
with socketserver.TCPServer(("", PORT), Handler) as httpd:
    print(f"Serving web interface at http://$WEB_IP:$WEB_PORT")
    httpd.serve_forever()
EOF

# Step 4: Set up auto-start services
echo "Configuring auto-start services..."

# TTS API service
cat << EOF > /etc/systemd/system/piper-tts.service
[Unit]
Description=Persian Piper TTS API
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker start piper-tts
ExecStop=/usr/bin/docker stop piper-tts
Restart=always
User=root

[Install]
WantedBy=multi-user.target
EOF

# Web interface service
cat << EOF > /etc/systemd/system/tts-web.service
[Unit]
Description=TTS Web Interface
After=network.target piper-tts.service

[Service]
ExecStart=/usr/bin/python3 $WEB_DIR/server.py
WorkingDirectory=$WEB_DIR
Restart=always
User=$CURRENT_USER

[Install]
WantedBy=multi-user.target
EOF

# Reload and enable services
systemctl daemon-reload
systemctl enable piper-tts.service
systemctl enable tts-web.service
systemctl start piper-tts.service
systemctl start tts-web.service

# Step 5: Test the setup
echo "Testing TTS API..."
sleep 5 # Wait for services to start
curl -o test.wav "http://localhost:5000/synthesize?text=سلام&voice=fa_IR-parsa-medium"
if [ $? -eq 0 ] && [ -s test.wav ]; then
    echo "Setup complete! Access the web interface at http://$WEB_IP:$WEB_PORT"
else
    echo "Error: TTS API test failed. Check Docker container and logs."
    exit 1
fi
