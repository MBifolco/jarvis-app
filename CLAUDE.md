# CLAUDE.md - Jarvis Mobile Application

This file provides guidance to Claude Code when working on the Jarvis mobile application, a Flutter-based companion app for the Jarvis voice assistant hardware device.

## Project Overview

The jarvis-app is a Flutter mobile application that serves as the control interface and processing hub for the Jarvis voice assistant device. It connects to the ESP32-based hardware via Bluetooth Low Energy (BLE) and provides voice processing capabilities through OpenAI APIs.

## Architecture

### Core Components

1. **BLE Communication Layer**
   - Scans for and connects to Jarvis devices
   - Manages bidirectional data transfer
   - Handles audio streaming and configuration

2. **Audio Processing Pipeline**
   - Receives compressed audio from device
   - Processes audio for speech recognition
   - Handles audio playback responses

3. **AI Integration**
   - OpenAI Whisper for speech-to-text
   - OpenAI Realtime API for conversational AI
   - Chat completion for text-based interactions

### Key Services

#### `bt_connection_service.dart`
- Manages BLE device connection lifecycle
- Handles MTU negotiation for optimal data transfer (typically 500 bytes)
- Coordinates service discovery and initialization
- Monitors connection stability

#### `audio_stream_service.dart`
- Receives compressed ADPCM audio data from device via BLE
- Decompresses ADPCM to PCM for processing
- Sends uncompressed PCM audio to device for playback
- Implements sync pattern protocol (0xAA 0x55) for reliable streaming

#### `whisper_service.dart`
- Converts speech to text using OpenAI Whisper API
- Processes audio chunks for transcription
- Manages API authentication and requests

#### `realtime_service.dart`
- Implements OpenAI Realtime API integration
- Handles WebSocket communication
- Manages real-time audio conversation flow
- Buffers TTS audio and sends 48KB chunks (1 second) to device
- Implements 400ms inter-chunk delay for reliable transmission

#### `chat_service.dart`
- Text-based chat functionality
- OpenAI ChatGPT integration
- Conversation history management

#### `config_service.dart`
- Device configuration management
- Synchronizes settings with hardware
- Persists user preferences

#### `audio_player_service.dart`
- Audio playback functionality
- Handles response audio from AI
- Manages audio output routing

## Build and Development

### Prerequisites
- Flutter SDK 3.2.3 or higher
- Android Studio / Xcode for platform-specific builds
- OpenAI API key (stored in `.env` file)

### Environment Setup
Create a `.env` file in the root directory:
```
OPENAI_API_KEY=your_api_key_here
```

### Build Commands
```bash
# Get dependencies
flutter pub get

# Run in debug mode
flutter run

# Build release APK
flutter build apk --release

# Build iOS app
flutter build ios --release

# Run tests
flutter test
```

### Development Server
```bash
# Run with hot reload
flutter run -d <device_id>

# List available devices
flutter devices
```

## Key Dependencies

- **flutter_blue_plus**: BLE communication
- **permission_handler**: Runtime permissions
- **flutter_dotenv**: Environment configuration
- **openai_realtime_dart**: OpenAI Realtime API
- **audioplayers/just_audio**: Audio playback
- **wav**: WAV file processing
- **http/web_socket_channel**: Network communication

## BLE Protocol

### Device Discovery
- Scans for devices with "Jarvis" in the name
- Connection timeout: 5 seconds
- Auto-reconnect on disconnect

### Service Structure
The app expects specific BLE services and characteristics from the device:
- Audio data characteristic (notifications)
- Configuration characteristic (read/write)
- Status characteristic (notifications)

### Data Format
- Audio from device: ADPCM compressed, 16kHz
- Audio to device: Uncompressed PCM, 24kHz, 16-bit mono
- Configuration: TLV (Tag-Length-Value) encoded
- Status: Binary status flags

## Audio Specifications

### Input (from device)
- Sample Rate: 16kHz
- Format: ADPCM compressed (256-byte blocks)
- Max Duration: 30 seconds
- Min Duration: 1 second

### Output (to device)
- Format: Raw PCM (no WAV header)
- Sample Rate: 24kHz (matching OpenAI TTS)
- Bit Depth: 16-bit signed
- Channels: Mono
- Chunk Size: 48KB (1 second of audio)
- Protocol: Sync pattern (0xAA 0x55) + 4-byte length + PCM data

## State Management

The app uses a service-based architecture with:
- Singleton services for global state
- Stream-based reactive updates
- Async/await for all I/O operations

## UI Structure

### Main Screens
1. **Device List**: Scan and select Jarvis devices
2. **Device Screen**: Main interaction interface
3. **Test Audio Screen**: Audio testing utilities

### Navigation
- Material Design navigation
- Bottom navigation for main features
- Modal dialogs for settings

## Error Handling

### BLE Errors
- Connection failures: Retry with exponential backoff
- Data corruption: CRC validation
- Timeout handling: 30-second max for operations

### API Errors
- Network failures: Offline queue
- Rate limiting: Backoff strategy
- Authentication: Token refresh

## Testing

### Unit Tests
```bash
flutter test
```

### Integration Tests
- BLE mock for device communication
- API mocks for OpenAI services
- Audio file fixtures in `assets/`

## Security Considerations

1. **API Keys**: Never commit `.env` file
2. **BLE Security**: Implement pairing/bonding
3. **Audio Privacy**: Local processing where possible
4. **Data Storage**: Encrypt sensitive data

## Performance Optimization

1. **Audio Buffering**: Optimize chunk size for BLE MTU
2. **Memory Management**: Release audio buffers after use
3. **Battery Usage**: Implement connection idle timeout
4. **Network Usage**: Batch API requests when possible

## Debugging

### Enable Debug Logging
```dart
// In main.dart
Logger.root.level = Level.ALL;
```

### BLE Debugging
- Use nRF Connect app for BLE inspection
- Monitor characteristic notifications
- Verify MTU negotiation

### Audio Debugging
- Test with `assets/test.mp3`
- Monitor audio buffer sizes
- Check sample rate conversions

## Common Issues

1. **BLE Connection Drops**
   - Check device proximity
   - Verify battery levels
   - Review connection parameters

2. **Audio Quality**
   - Verify compression settings
   - Check sample rate matching
   - Monitor packet loss

3. **API Failures**
   - Validate API key in `.env`
   - Check network connectivity
   - Review rate limits

## Platform-Specific Notes

### Android
- Minimum SDK: 21
- Bluetooth permissions required
- Location permission for BLE scanning

### iOS
- Minimum iOS: 12.0
- Bluetooth usage description required
- Background modes for BLE

## Development Workflow

1. **Feature Development**
   - Create feature branch
   - Implement service layer first
   - Add UI components
   - Write tests
   - Test with actual device

2. **Bug Fixes**
   - Reproduce with device
   - Add failing test
   - Implement fix
   - Verify on multiple devices

3. **Release Process**
   - Update version in `pubspec.yaml`
   - Run full test suite
   - Build release binaries
   - Test on real devices
   - Tag release

## Critical Implementation Details

### Audio Streaming Architecture

#### Sync Pattern Protocol
The app implements a sync pattern protocol for reliable audio streaming to the device:
```dart
// Header structure: [0xAA, 0x55, length(4 bytes)] + PCM data
final header = ByteData(6);
header.setUint8(0, 0xAA);  // Sync byte 1
header.setUint8(1, 0x55);  // Sync byte 2
header.setUint32(2, pcmData.length, Endian.little);
```

This sync pattern is CRITICAL - the device state machine looks for 0xAA 0x55 to detect packet boundaries and recover from any BLE packet corruption.

#### Chunk Size and Timing
- Audio is sent in 48KB chunks (exactly 1 second at 24kHz)
- 400ms delay between chunks prevents BLE congestion
- Chunks are sent synchronously to maintain order

#### BLE MTU Optimization
- App negotiates maximum MTU (typically 500 bytes)
- Each 48KB chunk is split into ~100 BLE packets
- Write without response for maximum throughput

### Known Issues and Solutions

1. **Audio Corruption**: Always use sync pattern - device will resync on next 0xAA 0x55
2. **Playback Skips**: Ensure 400ms inter-chunk delay is maintained
3. **Buffer Overflow**: Never send chunks larger than 48KB
4. **State Issues**: Device expects sync pattern at start of each audio transmission

## Integration with jarvis-device

When making changes that affect device communication:
1. Review device firmware BLE implementation
2. Ensure protocol compatibility (especially sync pattern)
3. Test with actual hardware
4. Update both repos if protocol changes
5. Document any breaking changes

### Protocol Changes Checklist
- [ ] Sync pattern (0xAA 0x55) maintained?
- [ ] Chunk size still 48KB?
- [ ] Sample rate matches (24kHz for playback)?
- [ ] Header format unchanged (6 bytes total)?
- [ ] Inter-chunk timing preserved (400ms)?

This mobile app is the user-facing component of the Jarvis system and must maintain reliable communication with the hardware device while providing a smooth user experience.