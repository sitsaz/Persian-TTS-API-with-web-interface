# Persian TTS API

A simple and open-source Text-to-Speech API with Persian (Farsi) language support, complete with a PHP web interface.

## Features

- Persian (Farsi) text-to-speech conversion
- RESTful API for easy integration
- Simple web interface for testing and demonstration
- Automatic audio file cleanup
- Easy one-script deployment

## Requirements

- Ubuntu server (18.04 LTS or newer)
- Sudo/root access
- Internet connection (to download Python packages and models)

## Quick Installation

```bash
# Clone the repository
git clone https://github.com/sitsaz/persian-tts-api.git
cd persian-tts-api

# Make the deployment script executable
chmod +x deploy-persian-tts.sh

# Run the deployment script with sudo
sudo ./deploy-persian-tts.sh
```

The script will prompt you for:
- Your server domain or IP address (for the web interface)
- Port for the TTS API server (default: 5000)

## Manual Installation

If you prefer to install the components manually, follow these steps:

### 1. Install System Dependencies

```bash
sudo apt update
sudo apt install -y python3-pip python3-dev python3-venv ffmpeg libsndfile1 git apache2 php libapache2-mod-php php-curl
```

### 2. Set Up TTS Server

```bash
mkdir -p ~/tts-server
cd ~/tts-server
python3 -m venv venv
source venv/bin/activate
pip install -U pip setuptools wheel
pip install TTS flask
```

### 3. Download Persian TTS Model

```bash
mkdir -p ~/tts-server/models
tts --download_path=~/tts-server/models --model_name="tts_models/fa/cv/tacotron2-DDC"
```

### 4. Create and Configure Files

Follow the detailed instructions in the provided deployment script to create:
- TTS server Python script
- Systemd service file
- PHP web interface files
- Apache configuration

## API Usage

### Generate Speech

**Endpoint:** `POST /api/tts`

**Request:**
```json
{
  "text": "متن فارسی برای تبدیل به گفتار"
}
```

**Response:**
```json
{
  "success": true,
  "filename": "6f7e2d4b-3f2d-4e5b-8a6c-9f7e2d4b3f2d.wav",
  "filepath": "audio_files/6f7e2d4b-3f2d-4e5b-8a6c-9f7e2d4b3f2d.wav"
}
```

### Get Audio File

**Endpoint:** `GET /api/audio/{filename}`

Returns the audio file as `audio/wav`.

## Web Interface

Access the web interface at: `http://your-server-domain/tts/`

The interface allows you to:
1. Enter Persian text in the text area
2. Click "Convert to Speech" to generate audio
3. Play or download the generated speech

## Configuration

The TTS server is configured via a systemd service at `/etc/systemd/system/persian-tts.service`.

To modify settings:
1. Edit the service file
2. Reload systemd: `sudo systemctl daemon-reload`
3. Restart the service: `sudo systemctl restart persian-tts`

## Troubleshooting

### TTS Server Issues

Check the TTS server logs:
```bash
sudo journalctl -u persian-tts
```

### Web Interface Issues

Check the Apache error logs:
```bash
sudo tail -f /var/log/apache2/tts_error.log
```

### Testing the API

Use the provided test script:
```bash
~/test-tts.sh
```

Or manually with curl:
```bash
curl -X POST http://localhost:5000/api/tts \
  -H "Content-Type: application/json" \
  -d '{"text": "سلام دنیا"}' \
  -v
```

## Customization

### Using Different TTS Models

You can replace the default model with other Persian models:

1. List available Persian models:
```bash
source ~/tts-server/venv/bin/activate
tts --list_models | grep -i persian
```

2. Download a different model:
```bash
tts --download_path=~/tts-server/models --model_name="tts_models/fa/THE_MODEL_NAME"
```

3. Edit the TTS server script to use the new model:
```bash
sudo nano ~/tts-server/tts_server.py
```

Update the model name and restart the service:
```bash
sudo systemctl restart persian-tts
```

## Security Considerations

For production use, consider:
- Enabling HTTPS
- Adding authentication
- Implementing rate limiting
- Setting up a proper firewall

## License

[MIT License](LICENSE)

## Acknowledgments

- [Mozilla TTS/Coqui TTS](https://github.com/coqui-ai/TTS) for the base TTS engine
- Contributors to the Persian language models
