#!/bin/bash

# Ensure the script is run with sudo for installing dependencies and managing services
if [ -z "$SUDO_USER" ]; then
    echo "Please run this script with sudo."
    exit 1
fi

# Get the home directory of the original user
USER_HOME=$(eval echo ~$SUDO_USER)

# Prompt for the server's IP address or domain name
echo "Enter the server's IP address or domain name (default: localhost):"
read HOST
if [ -z "$HOST" ]; then
    HOST="localhost"
fi

# Prompt for the web interface port
echo "Enter the port for the web interface (default: 8000):"
read WEB_PORT
if [ -z "$WEB_PORT" ]; then
    WEB_PORT=8000
fi

# Validate the port number
if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || [ "$WEB_PORT" -lt 1 ] || [ "$WEB_PORT" -gt 65535 ]; then
    echo "Invalid port number. Please enter a number between 1 and 65535."
    exit 1
fi

# Install dependencies
echo "Checking and installing dependencies..."
if ! command -v docker &> /dev/null; then
    echo "Installing Docker..."
    apt-get update
    apt-get install -y docker.io
fi

if ! command -v curl &> /dev/null; then
    echo "Installing curl..."
    apt-get install -y curl
fi

if ! command -v python3 &> /dev/null; then
    echo "Installing Python3..."
    apt-get install -y python3
fi

# Add user to docker group (optional, for non-root Docker usage)
if ! id -nG "$SUDO_USER" | grep -qw docker; then
    echo "Adding $SUDO_USER to docker group..."
    usermod -aG docker "$SUDO_USER"
fi

# Set up the TTS API
echo "Pulling the TTS API Docker image..."
docker pull ghcr.io/arunk140/serve-piper-tts:latest

echo "Creating models directory at $USER_HOME/models..."
mkdir -p "$USER_HOME/models"

echo "Downloading Persian voice model..."
curl -o "$USER_HOME/models/persian.onnx" "https://github.com/gyroing/Persian-Piper-TTS-WebAssembly/blob/main/persian_pipert_1.onnx?raw=true"

# Remove any existing container to avoid conflicts
echo "Removing any existing TTS container..."
docker rm -f persian-piper-tts || true

# Start the TTS API container (runs on port 8080)
echo "Starting TTS API server..."
docker run -d --name persian-piper-tts -p 8080:8080 -v "$USER_HOME/models:/app/models" ghcr.io/arunk140/serve-piper-tts:latest

# Set up the web interface
echo "Creating web interface directory at $USER_HOME/web_interface..."
mkdir -p "$USER_HOME/web_interface"

# Generate index.html with the user-provided host
echo "Generating index.html with host: $HOST..."
cat <<EOF > "$USER_HOME/web_interface/index.html"
<html>
<body>
<input id="text" type="text" placeholder="Enter text">
<button onclick="generateSpeech()">Generate Speech</button>
<audio id="audio" controls></audio>
<script>
function generateSpeech() {
    var text = document.getElementById("text").value;
    fetch('http://$HOST:8080/api/tts?text=' + encodeURI(text))
        .then(response => response.arrayBuffer())
        .then(buffer => {
            var audioBlob = new Blob([buffer], {type: 'audio/wav'});
            var audioUrl = URL.createObjectURL(audioBlob);
            document.getElementById("audio").src = audioUrl;
            document.getElementById("audio").play();
        });
}
</script>
</body>
</html>
EOF

# Start the Python HTTP server with the user-provided port
echo "Starting web interface on port $WEB_PORT..."
nohup python3 -m http.server --directory "$USER_HOME/web_interface" "$WEB_PORT" > /dev/null 2>&1 &

# Set up auto-start services
echo "Setting up TTS API auto-start service..."
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

echo "Setting up web interface auto-start service..."
cat <<EOF > /etc/systemd/system/persian-piper-web.service
[Unit]
Description=Persian Piper TTS Web Interface
After=network.target

[Service]
User=$SUDO_USER
ExecStart=/usr/bin/python3 -m http.server --directory $USER_HOME/web_interface $WEB_PORT
WorkingDirectory=$USER_HOME/web_interface
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Enable services
echo "Enabling services to start on reboot..."
systemctl daemon-reload
systemctl enable persian-piper-tts.service
systemctl enable persian-piper-web.service

# Inform the user
echo "Setup complete!"
echo "Access the web interface at: http://$HOST:$WEB_PORT"
echo "The TTS API and web interface will auto-start on reboot."
