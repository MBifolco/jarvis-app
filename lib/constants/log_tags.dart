// Log tags for consistent logging across the app
class LogTags {
  // Connection & Discovery
  static const String bleScan = '[BLE-SCAN]';
  static const String bleConn = '[BLE-CONN]';
  static const String bleDisc = '[BLE-DISC]';
  static const String bleMtu = '[BLE-MTU]';
  
  // Audio Flow
  static const String audioRx = '[AUDIO-RX]';
  static const String audioTx = '[AUDIO-TX]';
  static const String audioPlay = '[AUDIO-PLAY]';
  static const String audioBuff = '[AUDIO-BUFF]';
  
  // AI Services
  static const String whisper = '[WHISPER]';
  static const String realtime = '[REALTIME]';
  static const String chat = '[CHAT]';
  
  // Config
  static const String config = '[CONFIG]';
  static const String configBle = '[CONFIG-BLE]';
  
  // App Flow
  static const String appInit = '[APP-INIT]';
  static const String appUi = '[APP-UI]';
  static const String appState = '[APP-STATE]';
  
  // Device (for future device logs)
  static const String device = '[DEVICE]';
  static const String deviceWake = '[DEVICE-WAKE]';
  static const String deviceVad = '[DEVICE-VAD]';
}