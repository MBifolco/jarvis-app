# CLAUDE.md - Jarvis Voice Assistant System

This file provides guidance to Claude Code (claude.ai/code) when working across the Jarvis voice assistant system, which consists of two interconnected components in a unified repository structure.

## System Overview
The Jarvis voice assistant is a distributed system with two main components:
1. **jarvis-device**: ESP32-based firmware for the physical voice assistant device
2. **jarvis-app**: Flutter mobile application that interfaces with the device

## Repository Structure

This is a unified repository containing both components. Each component has its own CLAUDE.md file with specific build instructions and architecture details.

### jarvis-device (ESP32 Firmware)
**Location**: `./jarvis-device/`
**Purpose**: ESP32-based voice assistant device firmware

**Key Features**:
- Wake word detection using ESP-SR
- Audio recording with VAD (Voice Activity Detection)
- Bluetooth Low Energy communication for data transmission
- Audio playback capabilities
- Real-time audio processing pipeline

**Architecture**:
- Dual AFE (Audio Front End) instances for wake vs hold modes
- I2S audio capture from microphone (GPIO8, GPIO10, GPIO9)
- I2S audio output to speaker (GPIO6, GPIO5, GPIO7)
- BLE peripheral that streams compressed audio to mobile app
- 16kHz sample rate, 30-second max recording sessions

**Build System**: ESP-IDF with CMake (see `./jarvis-device/CLAUDE.md` for detailed commands)

### jarvis-app (Flutter Mobile App)
**Location**: `./jarvis-app/`
**Purpose**: Flutter mobile application that connects to jarvis-device

**Key Features**:
- BLE client that connects to jarvis-device
- Scans for devices with "Jarvis" in the name
- Receives compressed audio data via BLE characteristics
- Integrates with OpenAI APIs for voice processing
- Provides user interface for device interaction

**Key Services**:
- `bt_connection_service.dart`: Bluetooth connection management
- `audio_stream_service.dart`: Audio data handling from device
- `whisper_service.dart`: Speech-to-text processing
- `realtime_service.dart`: Real-time audio processing
- `chat_service.dart`: Chat/conversation management
- `audio_player_service.dart`: Audio playback

**Build System**: Flutter (see `./jarvis-app/CLAUDE.md` for detailed commands)

## Cross-Repository Communication Protocol

### BLE Communication Flow
1. **jarvis-device** acts as BLE peripheral advertising as "Jarvis"
2. **jarvis-app** scans for and connects to Jarvis devices
3. Device streams compressed audio data to app via BLE characteristics
4. App sends configuration commands back to device
5. Device provides real-time status updates (recording state, battery, etc.)

### Data Flow
```
[Microphone] → [jarvis-device] → [BLE] → [jarvis-app] → [OpenAI APIs] → [Response] → [jarvis-app] → [BLE] → [jarvis-device] → [Speaker]
```

## Development Guidelines

### Working Across Both Repositories
When making changes that affect both systems:

1. **Always consider the communication protocol**: Changes to BLE characteristics, data formats, or timing in one repo require corresponding changes in the other
2. **Audio format compatibility**: Ensure audio compression/decompression, sample rates, and formats match between device firmware and mobile app
3. **Configuration synchronization**: Device configuration changes must be reflected in the mobile app's config service
4. **Status reporting**: Device status changes should be communicated to and handled by the mobile app

### Common Integration Points
- **BLE service UUIDs and characteristics**: Defined in both repositories
- **Audio compression format**: Must match between firmware encoding and app decoding
- **Device configuration structure**: Shared between `config.c` (firmware) and `device_config.dart` (app)
- **Status/state reporting**: Battery, recording state, connection state
- **Error handling**: Timeout handling, connection failures, audio processing errors

### Testing Cross-Repository Changes
1. Test BLE communication with both scanning and connection
2. Verify audio data transmission quality and timing
3. Test configuration commands from app to device
4. Validate status reporting from device to app
5. Test error conditions and recovery scenarios

## Key Constants and Compatibility

### Audio Configuration (Must Match)
- **Sample Rate**: 16kHz (defined in both repositories)
- **Recording Limit**: 30 seconds max
- **Minimum Recording**: 1 second (16000 samples)

### BLE Configuration
- **Device Name Filter**: "Jarvis" (app scans for devices containing this string)
- **Connection Timeout**: 5 seconds
- **Keep-alive**: 20 seconds (device-side timeout)

## Dependencies

### jarvis-device (ESP-IDF)
- `espressif__esp-sr`: Speech recognition and VAD
- `espressif__esp-dsp`: Digital signal processing
- `espressif__esp_audio_codec`: Audio encoding/decoding

### jarvis-app (Flutter)
- `flutter_blue_plus`: Bluetooth Low Energy communication
- `permission_handler`: Android/iOS permissions
- `flutter_dotenv`: Environment configuration (OpenAI API keys)

## Development Tips

### When Working on Audio Features
- Changes to audio processing in firmware may require corresponding changes in app audio handling
- Test audio quality and latency across the BLE connection
- Monitor memory usage on ESP32 side for audio buffers

### When Working on BLE Communication
- Use BLE debugging tools to verify characteristic updates
- Test connection stability and reconnection scenarios
- Verify data integrity across BLE transmission

### When Working on Configuration
- Ensure configuration structures match between C structs and Dart models
- Test configuration persistence on both device and app sides
- Validate configuration limits and error handling

## Project-Specific Instructions

### Component Context Awareness
When Claude is working in one component, it should:
1. Be aware of the counterpart component's existence and purpose
2. Consider cross-component impacts of changes
3. Suggest testing procedures that involve both systems
4. Reference component-specific CLAUDE.md files for detailed build/architecture information

### Making Cross-Component Changes
When changes affect both components:
1. Start with the device firmware changes (more constrained environment)
2. Update the mobile app to accommodate firmware changes
3. Test the complete system integration
4. Update documentation in both component directories as needed

This shared context ensures Claude can work effectively across both parts of the Jarvis system while maintaining compatibility and understanding the full system architecture.