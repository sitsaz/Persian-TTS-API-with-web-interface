#!/bin/bash

# Persian TTS API with PHP Interface - Deployment Script for WSL
# This script automates the installation of a Persian TTS API server and web interface on WSL

# Exit on error
set -e

# Text colors
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

# Print colored messages
info() {
    echo -e "${GREEN}[INFO] $1${NC}"
}

warn() {
    echo -e "${YELLOW}[WARNING] $1${NC}"
}

error() {
    echo -e "${RED}[ERROR] $1${NC}" >&2
    exit 1
}

# Check if running as root or with sudo
if [ "$EUID" -ne 0 ]; then
    error "Please run this script with sudo or as root"
fi

# WSL-specific check
if ! grep -q Microsoft /proc/version && ! grep -q microsoft /proc/version; then
    warn "This doesn't appear to be a WSL environment. Some features may not work as expected."
fi

# Get the current non-root user (different approach for WSL)
if [ -n "$SUDO_USER" ]; then
    CURRENT_USER="$SUDO_USER"
else
    # On WSL, sometimes logname doesn't work properly
    CURRENT_USER=$(who am i | awk '{print $1}')
    # Fallback if the above doesn't work
    if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
        CURRENT_USER=$(grep -v "root\|daemon\|bin\|sys\|sync" /etc/passwd | grep "/home" | head -1 | cut -d: -f1)
    fi
    if [ -z "$CURRENT_USER" ] || [ "$CURRENT_USER" = "root" ]; then
        error "Cannot determine non-root user. Please run with sudo instead of as root directly"
    fi
fi

CURRENT_USER_HOME=$(eval echo ~$CURRENT_USER)
info "Running script for user: $CURRENT_USER (home: $CURRENT_USER_HOME)"

# Ask for server domain/IP
read -p "Enter your server domain or IP address (default: localhost): " SERVER_DOMAIN
SERVER_DOMAIN=${SERVER_DOMAIN:-localhost}

# Ask for TTS port
read -p "Enter port for TTS API server (default: 5000): " TTS_PORT
TTS_PORT=${TTS_PORT:-5000}

# Base directories
TTS_SERVER_DIR="$CURRENT_USER_HOME/tts-server"
WEB_DIR="/var/www/html/tts"

info "Installing system dependencies..."
apt update
# Added language-pack-fa for Farsi language support
apt install -y python3-pip python3-dev python3-venv ffmpeg libsndfile1 git apache2 php libapache2-mod-php php-curl language-pack-fa

# Ensure proper locale configuration for Farsi
info "Configuring locale for Farsi support..."
locale-gen fa_IR.UTF-8
update-locale LANG=fa_IR.UTF-8 LC_ALL=fa_IR.UTF-8

info "Setting up TTS server directory..."
mkdir -p "$TTS_SERVER_DIR"
cd "$TTS_SERVER_DIR"
python3 -m venv venv
chown -R "$CURRENT_USER:$CURRENT_USER" "$TTS_SERVER_DIR"

# Activate virtual environment and install requirements
info "Installing TTS and dependencies..."
sudo -u "$CURRENT_USER" bash << EOF
source "$TTS_SERVER_DIR/venv/bin/activate"
pip install --upgrade pip setuptools wheel
# Disable hash checking to avoid errors with package updates
pip install --no-cache-dir TTS flask
EOF

# Download model directly in the script
info "Downloading Persian TTS model..."
sudo -u "$CURRENT_USER" bash << EOF
source "$TTS_SERVER_DIR/venv/bin/activate"
mkdir -p "$TTS_SERVER_DIR/models"
python3 -c "
from TTS.utils.manage import ModelManager
model_name = 'tts_models/fa/cv/tacotron2-DDC'
ModelManager().download_model(model_name)
"
EOF

info "Creating TTS server script..."
cat > "$TTS_SERVER_DIR/tts_server.py" << 'PYTHON_SCRIPT'
from flask import Flask, request, send_file, jsonify
from TTS.api import TTS
import os
import uuid
import time
import sys
import locale

# Set locale to fa_IR.UTF-8 for Persian support
try:
    locale.setlocale(locale.LC_ALL, 'fa_IR.UTF-8')
except locale.Error:
    print("Warning: fa_IR.UTF-8 locale not available. Persian text may not render correctly.")

app = Flask(__name__)

# Initialize TTS with Persian model
try:
    tts = TTS(model_name="tts_models/fa/cv/tacotron2-DDC", progress_bar=False)
    print("Successfully loaded Persian TTS model")
except Exception as e:
    print(f"Error loading TTS model: {e}", file=sys.stderr)
    sys.exit(1)

AUDIO_DIR = "audio_files"
os.makedirs(AUDIO_DIR, exist_ok=True)

@app.route('/api/tts', methods=['POST'])
def generate_speech():
    try:
        # Get text from request
        data = request.json
        if not data or 'text' not in data:
            return jsonify({"error": "No text provided"}), 400
            
        text = data['text']
        
        # Generate a unique filename
        filename = f"{uuid.uuid4()}.wav"
        filepath = os.path.join(AUDIO_DIR, filename)
        
        # Generate audio
        tts.tts_to_file(text=text, file_path=filepath)
        
        # Return the audio file
        return jsonify({
            "success": True, 
            "filename": filename,
            "filepath": filepath
        })
        
    except Exception as e:
        print(f"Error generating speech: {e}", file=sys.stderr)
        return jsonify({"error": str(e)}), 500

@app.route('/api/audio/<filename>', methods=['GET'])
def get_audio(filename):
    filepath = os.path.join(AUDIO_DIR, filename)
    if os.path.exists(filepath):
        return send_file(filepath, mimetype="audio/wav")
    else:
        return jsonify({"error": "File not found"}), 404

# Cleanup old files periodically
@app.before_request
def cleanup_old_files():
    now = time.time()
    for filename in os.listdir(AUDIO_DIR):
        filepath = os.path.join(AUDIO_DIR, filename)
        # Remove files older than 1 hour
        if os.path.isfile(filepath) and os.stat(filepath).st_mtime < now - 3600:
            os.unlink(filepath)

if __name__ == '__main__':
    # Add improved error handling for port binding issues (common in WSL)
    try:
        app.run(host='0.0.0.0', port=PORT_PLACEHOLDER)
    except OSError as e:
        if "Address already in use" in str(e):
            print(f"Error: Port {PORT_PLACEHOLDER} is already in use. Please choose a different port.")
            sys.exit(1)
        else:
            raise
PYTHON_SCRIPT

# Replace the port placeholder
sed -i "s/PORT_PLACEHOLDER/$TTS_PORT/g" "$TTS_SERVER_DIR/tts_server.py"

info "Creating systemd service for TTS API..."
# Check if systemd is available (WSL1 doesn't have systemd)
if pidof systemd >/dev/null; then
    cat > /etc/systemd/system/persian-tts.service << EOF
[Unit]
Description=Persian TTS API Service
After=network.target

[Service]
User=$CURRENT_USER
WorkingDirectory=$TTS_SERVER_DIR
ExecStart=$TTS_SERVER_DIR/venv/bin/python $TTS_SERVER_DIR/tts_server.py
Restart=on-failure
Environment=PYTHONUNBUFFERED=1
Environment=LANG=fa_IR.UTF-8
Environment=LC_ALL=fa_IR.UTF-8

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable persian-tts
    systemctl start persian-tts
else
    # Create a startup script for WSL environments without systemd
    warn "Systemd not detected (common in WSL1). Creating startup script instead."
    cat > "$CURRENT_USER_HOME/start-persian-tts.sh" << EOF
#!/bin/bash
source "$TTS_SERVER_DIR/venv/bin/activate"
cd "$TTS_SERVER_DIR"
export LANG=fa_IR.UTF-8
export LC_ALL=fa_IR.UTF-8
python tts_server.py
EOF
    chmod +x "$CURRENT_USER_HOME/start-persian-tts.sh"
    chown "$CURRENT_USER:$CURRENT_USER" "$CURRENT_USER_HOME/start-persian-tts.sh"
    
    info "To start the TTS server manually, run: $CURRENT_USER_HOME/start-persian-tts.sh"
    info "To run it in the background: nohup $CURRENT_USER_HOME/start-persian-tts.sh > $CURRENT_USER_HOME/tts-server.log 2>&1 &"
fi

info "Setting up web interface..."
mkdir -p "$WEB_DIR"

# Create the PHP interface files
info "Creating PHP interface files..."
cat > "$WEB_DIR/index.php" << 'PHP_INTERFACE'
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Persian Text-to-Speech</title>
    <style>
        body {
            font-family: Tahoma, Arial, sans-serif;
            max-width: 800px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }
        h1 {
            color: #333;
            text-align: center;
        }
        textarea {
            width: 100%;
            height: 150px;
            padding: 10px;
            margin-bottom: 20px;
            border: 1px solid #ddd;
            border-radius: 4px;
            font-size: 16px;
        }
        button {
            display: block;
            width: 100%;
            padding: 10px;
            background-color: #4CAF50;
            color: white;
            border: none;
            border-radius: 4px;
            cursor: pointer;
            font-size: 16px;
        }
        button:hover {
            background-color: #45a049;
        }
        #audioContainer {
            margin-top: 20px;
            text-align: center;
            display: none;
        }
        .loader {
            border: 4px solid #f3f3f3;
            border-top: 4px solid #3498db;
            border-radius: 50%;
            width: 30px;
            height: 30px;
            animation: spin 2s linear infinite;
            margin: 20px auto;
            display: none;
        }
        @keyframes spin {
            0% { transform: rotate(0deg); }
            100% { transform: rotate(360deg); }
        }
    </style>
</head>
<body>
    <h1>متن به گفتار فارسی</h1>
    
    <textarea id="textInput" placeholder="متن فارسی خود را اینجا وارد کنید..."></textarea>
    
    <button id="convertBtn" onclick="convertToSpeech()">تبدیل به گفتار</button>
    
    <div class="loader" id="loader"></div>
    
    <div id="audioContainer">
        <audio id="audioPlayer" controls></audio>
        <p>شما می‌توانید فایل صوتی را پخش کرده یا دانلود کنید.</p>
    </div>

    <script>
        function convertToSpeech() {
            const text = document.getElementById('textInput').value.trim();
            
            if (!text) {
                alert('لطفاً یک متن وارد کنید.');
                return;
            }
            
            // Show loader
            document.getElementById('loader').style.display = 'block';
            document.getElementById('audioContainer').style.display = 'none';
            
            // Send request to PHP handler
            fetch('tts_handler.php', {
                method: 'POST',
                headers: {
                    'Content-Type': 'application/json',
                },
                body: JSON.stringify({ text: text })
            })
            .then(response => response.json())
            .then(data => {
                if (data.success) {
                    // Hide loader
                    document.getElementById('loader').style.display = 'none';
                    
                    // Show audio player
                    document.getElementById('audioContainer').style.display = 'block';
                    
                    // Set audio source
                    const audioPlayer = document.getElementById('audioPlayer');
                    audioPlayer.src = data.audio_url;
                    audioPlayer.load();
                } else {
                    alert('خطا: ' + data.error);
                    document.getElementById('loader').style.display = 'none';
                }
            })
            .catch(error => {
                alert('خطا در ارتباط با سرور: ' + error);
                document.getElementById('loader').style.display = 'none';
            });
        }
    </script>
</body>
</html>
PHP_INTERFACE

cat > "$WEB_DIR/tts_handler.php" << PHP_HANDLER
<?php
header('Content-Type: application/json');

// Function to sanitize input
function sanitize_text(\$text) {
    return htmlspecialchars(trim(\$text));
}

try {
    // Get input from JSON request
    \$json = file_get_contents('php://input');
    \$data = json_decode(\$json, true);
    
    if (!isset(\$data['text']) || empty(\$data['text'])) {
        echo json_encode(['success' => false, 'error' => 'No text provided']);
        exit;
    }
    
    \$text = sanitize_text(\$data['text']);
    
    // Create cURL request to TTS API
    \$curl = curl_init('http://localhost:$TTS_PORT/api/tts');
    curl_setopt(\$curl, CURLOPT_POST, true);
    curl_setopt(\$curl, CURLOPT_POSTFIELDS, json_encode(['text' => \$text]));
    curl_setopt(\$curl, CURLOPT_HTTPHEADER, ['Content-Type: application/json']);
    curl_setopt(\$curl, CURLOPT_RETURNTRANSFER, true);
    
    // Execute request
    \$response = curl_exec(\$curl);
    
    if (\$response === false) {
        echo json_encode(['success' => false, 'error' => 'Error connecting to TTS server: ' . curl_error(\$curl)]);
        exit;
    }
    
    \$http_code = curl_getinfo(\$curl, CURLINFO_HTTP_CODE);
    curl_close(\$curl);
    
    if (\$http_code !== 200) {
        echo json_encode(['success' => false, 'error' => 'TTS server returned error: ' . \$http_code]);
        exit;
    }
    
    // Process response
    \$result = json_decode(\$response, true);
    
    if (isset(\$result['success']) && \$result['success']) {
        // Return audio URL
        echo json_encode([
            'success' => true,
            'audio_url' => 'http://$SERVER_DOMAIN:$TTS_PORT/api/audio/' . \$result['filename']
        ]);
    } else {
        echo json_encode(['success' => false, 'error' => \$result['error'] ?? 'Unknown error']);
    }
    
} catch (Exception \$e) {
    echo json_encode(['success' => false, 'error' => 'Server error: ' . \$e->getMessage()]);
}
?>
PHP_HANDLER

# For WSL, Apache configuration may need adjustments
info "Setting up Apache configuration..."
cat > /etc/apache2/sites-available/tts.conf << EOF
<VirtualHost *:80>
    ServerName $SERVER_DOMAIN
    DocumentRoot $WEB_DIR
    
    <Directory $WEB_DIR>
        Options Indexes FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
    
    ErrorLog \${APACHE_LOG_DIR}/tts_error.log
    CustomLog \${APACHE_LOG_DIR}/tts_access.log combined
</VirtualHost>
EOF

# Set proper permissions
chown -R www-data:www-data "$WEB_DIR"
chmod -R 755 "$WEB_DIR"

# Enable the site in Apache
a2ensite tts.conf

# For WSL, check if Apache can be started
info "Configuring and starting Apache..."
if ! service apache2 status >/dev/null 2>&1; then
    warn "Apache may not start automatically in WSL. You might need to start it manually."
    service apache2 start || warn "Failed to start Apache. Try running 'sudo service apache2 start' manually."
else
    service apache2 restart || warn "Failed to restart Apache. Try running 'sudo service apache2 restart' manually."
fi

# WSL-specific network advice
info "WSL-specific network notes:"
info "1. In WSL, you may need to access services using the Windows host IP instead of localhost"
info "2. You may need to configure Windows Defender Firewall to allow traffic on ports 80 and $TTS_PORT"

# Skip UFW for WSL as it's not typically used there
if command -v ufw &> /dev/null; then
    info "Configuring firewall..."
    ufw allow 80/tcp
    ufw allow $TTS_PORT/tcp
    info "Firewall rules added for ports 80 and $TTS_PORT"
else
    info "UFW firewall not detected. This is normal for WSL."
    info "Please ensure Windows Firewall allows connections to ports 80 and $TTS_PORT if needed."
fi

info "Creating test script..."
cat > "$CURRENT_USER_HOME/test-tts.sh" << EOF
#!/bin/bash
echo "Testing Persian TTS API..."
curl -X POST http://localhost:$TTS_PORT/api/tts \\
  -H "Content-Type: application/json" \\
  -d '{"text": "سلام دنیا"}' \\
  -v
EOF
chmod +x "$CURRENT_USER_HOME/test-tts.sh"
chown "$CURRENT_USER:$CURRENT_USER" "$CURRENT_USER_HOME/test-tts.sh"

# Installation complete
echo
echo "=====================================================
${GREEN}Persian TTS API and Web Interface Installation Complete!${NC}

TTS API Server: http://$SERVER_DOMAIN:$TTS_PORT/api/tts
Web Interface: http://$SERVER_DOMAIN/tts/

Test the API with: $CURRENT_USER_HOME/test-tts.sh

WSL-SPECIFIC NOTES:
1. If using WSL1, use the start script to run the server:
   $CURRENT_USER_HOME/start-persian-tts.sh

2. Access the web interface using your Windows IP address:
   http://<windows-ip>/tts/

3. For port connectivity issues, ensure Windows Firewall 
   allows connections to these ports.

If you encounter any issues:
1. Check logs in $CURRENT_USER_HOME/tts-server.log (if using start script)
2. Check Apache logs: tail -f /var/log/apache2/tts_error.log
=====================================================
"
