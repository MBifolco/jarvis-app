// lib/services/whisper_service.dart
import 'dart:convert';
import 'dart:typed_data';

import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

class WhisperService {
  final String apiKey;
  WhisperService(this.apiKey);

  /// Sends the full WAV bytes to OpenAI Whisper and returns the transcript.
  Future<String> transcribe(Uint8List wavBytes) async {
    final uri = Uri.parse('https://api.openai.com/v1/audio/transcriptions');
    final req = http.MultipartRequest('POST', uri)
      ..headers['Authorization'] = 'Bearer $apiKey'
      ..fields['model'] = 'whisper-1'
      ..files.add(http.MultipartFile.fromBytes(
        'file',
        wavBytes,
        filename: 'audio.wav',
        contentType: MediaType('audio', 'wav'),
      ));

    final streamed = await req.send();
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode != 200) {
      throw Exception('Whisper failed: $body');
    }
    return jsonDecode(body)['text'] as String;
  }
}
