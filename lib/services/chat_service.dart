// lib/services/chat_service.dart
import 'dart:convert';
import 'package:http/http.dart' as http;

class ChatService {
  final String apiKey;
  ChatService(this.apiKey);

  /// Sends [prompt] to ChatGPT and returns the assistant’s reply.
  Future<String> chat(String prompt) async {
    final uri = Uri.parse('https://api.openai.com/v1/chat/completions');
    final res = await http.post(
      uri,
      headers: {
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $apiKey',
      },
      body: jsonEncode({
        'model': 'gpt-3.5-turbo',
        'messages': [
          {'role': 'user', 'content': prompt}
        ],
      }),
    );
    if (res.statusCode != 200) {
      throw Exception('ChatGPT failed: ${res.body}');
    }
    final j = jsonDecode(res.body);
    return j['choices'][0]['message']['content'] as String;
  }
}
