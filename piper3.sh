#!/bin/bash

# This script sets up the Persian Piper TTS API and web interface.
# It prompts for the server's IP or domain and ports, installs dependencies,
# downloads the Persian voice model from GitHub, sets up auto-start services,
# and tests the API.

# Ensure the script is run with sudo (required for installing packages and managing services)
if [ "$EUID" -ne 0 ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Get the current user (original user who invoked sudo)
CURRENT_USER=$(logname)

# Set default values
DEFAULT_HOST="localhost"
DEFAULT_API_PORT=8080
DEFAULT_WEB_PORT=8000

# Prompt for the server's IP address or domain name
echo "Enter the server's IP address or domain name (default: $DEFAULT_HOST):"
read HOST
if [ -z "$HOST" ]; then
    HOST=$DEFAULT_HOST
fi

# Prompt for the API port
echo "Enter the port for the API (default: $DEFAULT_API_PORT):"
read API_PORT
if [ -z "$API_PORT" ]; then
    API_PORT=$DEFAULT_API_PORT
fi

# Prompt for the web interface port
echo "Enter the port for the web interface (default: $DEFAULT_WEB_PORT):"
read WEB_PORT
if [ -z "$WEB_PORT" ]; then
    WEB_PORT=$DEFAULT_WEB_PORT
fi

# Function to validate port numbers
validate_port() {
    if ! [[ "$1" =~ ^[0-9]+$ ]] || [ "$1" -lt 1 ] || [ "$1" -gt 65535 ]; then
        echo "Invalid port number: $1. Must be a number between 1 and 65535."
        exit 1
    fi
}

# Validate the entered ports
validate_port "$API_PORT"
validate_port "$WEB_PORT"

# Automate dependency installation
echo "Checking and installing dependencies..."
apt-get update
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get install -y docker.io
    systemctl start docker
    systemctl enable docker
fi
if ! command -v python3 &> /dev/null; then
    echo "Installing Python3..."
    apt-get install -y python3
fi

# Define model variables
MODEL_NAME="persian_pipert_1"
MODEL_URL="https://github.com/gyroing/Persian-Piper-TTS-WebAssembly/raw/main/${MODEL_NAME}.onnx"
CONFIG_URL="https://github.com/gyroing/Persian-Piper-TTS-WebAssembly/raw/main/${MODEL_NAME}.onnx.json"
MODEL_DIR="$HOME/models"
WEB_DIR="$HOME/web_interface"

# Create necessary directories
mkdir -p "$MODEL_DIR" "$WEB_DIR"

# Download Persian voice model and configuration files from GitHub
echo "Downloading Persian voice model and configuration..."
curl -s -o "$MODEL_DIR/${MODEL_NAME}.onnx" "$MODEL_URL"
curl -s -o "$MODEL_DIR/${MODEL_NAME}.onnx.json" "$CONFIG_URL"

# Verify that the downloads were successful
if [ ! -s "$MODEL_DIR/${MODEL_NAME}.onnx" ] || [ ! -s "$MODEL_DIR/${MODEL_NAME}.onnx.json" ]; then
    echo "Error: Failed to download Persian voice model or configuration file."
    exit 1
fi
echo "Persian voice model and configuration downloaded successfully."

# Pull the Docker image for the TTS API
echo "Pulling the serve-piper-tts Docker image..."
docker pull ghcr.io/arunk140/serve-piper-tts:latest

# Remove any existing container with the same name
echo "Removing any existing container..."
docker rm -f persian-piper-tts 2>/dev/null

# Start the API server in a Docker container with --restart=no (systemd will handle restarts)
# Customize the Docker run command here if needed, e.g., change port mapping or volume mounts
docker run -d --name persian-piper-tts --restart=no -p "$API_PORT:8080" -v "$MODEL_DIR:/app/models" ghcr.io/arunk140/serve-piper-tts:latest

# Generate the web interface HTML
# The web interface HTML is generated below. Modify it if needed.
echo "Generating web interface..."
cat <<EOF > "$WEB_DIR/index.html"
<html>
<body>
<input id="text" type="text" placeholder="Enter Persian text">
<button onclick="generateSpeech()">Generate Speech</button>
<audio id="audio" controls></audio>
<script>
function generateSpeech() {
    var text = document.getElementById("text").value;
    fetch('http://$HOST:$API_PORT/api/tts?text=' + encodeURI(text) + '&voice=$MODEL_NAME')
        .then(response => {
            if (!response.ok) throw new Error('Network response was not ok');
            return response.arrayBuffer();
        })
        .then(buffer => {
            var audioBlob = new Blob([buffer], {type: 'audio/wav'});
            var audioUrl = URL.createObjectURL(audioBlob);
            document.getElementById("audio").src = audioUrl;
            document.getElementById("audio").play();
        })
        .catch(error => console.error('Error:', error));
}
</script>
</body>
</html>
EOF

# Create systemd service for TTS API
cat <<EOF > /etc/systemd/system/persian-piper-tts.service
[Unit]
Description=Persian Piper TTS API
After=docker.service
Requires=docker.service

[Service]
ExecStart=/usr/bin/docker start persian-piper-tts
ExecStop=/usr/bin/docker stop persian-piper-tts
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Create systemd service for web interface
cat <<EOF > /etc/systemd/system/persian-piper-web.service
[Unit]
Description=Persian Piper Web Interface
After=network.target persian-piper-tts.service

[Service]
User=$CURRENT_USER
ExecStart=/usr/bin/python3 -m http.server --directory $WEB_DIR $WEB_PORT
WorkingDirectory=$WEB_DIR
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Reload systemd and enable services for auto-start on reboot
systemctl daemon-reload
systemctl enable persian-piper-tts.service
systemctl enable persian-piper-web.service

# Start the services
systemctl start persian-piper-tts.service
systemctl start persian-piper-web.service

# Wait for the API to start
echo "Waiting for API to start..."
sleep 10

# Test the API with Persian text
PERSIAN_TEXT="سلام"
echo "Testing Persian TTS with text: '$PERSIAN_TEXT'"
STATUS_CODE=$(curl -s -o test.wav -w "%{http_code}" "http://localhost:$API_PORT/api/tts?text=${PERSIAN_TEXT}&voice=${MODEL_NAME}")
if [ "$STATUS_CODE" -eq 200 ] && [ -s test.wav ]; then
    echo "Persian TTS test successful."
    rm test.wav
else
    echo "Persian TTS test failed. HTTP Status code: $STATUS_CODE"
    exit 1
fi

# Inform the user
echo "Deployment complete. Access the web interface at http://$HOST:$WEB_PORT"
echo "The web interface files are in $WEB_DIR. You can edit index.html to customize the interface."
echo "The TTS API is configured in the Docker container. To change settings, modify the docker run command in this script."
