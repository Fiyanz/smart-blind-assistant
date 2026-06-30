import 'dart:convert';
import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/logger.dart';
import '../models/ai_response.dart';
import '../models/capture_payload.dart';
import 'supabase_service.dart';

/// Service untuk komunikasi dengan OpenRouter API.
///
/// Mengirimkan gambar ke Vision Language Model (Gemini)
/// melalui OpenRouter dan mengembalikan deskripsi teks.
/// Juga mendukung mode obrolan (text-only, tanpa gambar).
class ApiService {
  static const String _tag = 'ApiService';

  /// API Key (bisa di-override dari settings)
  String _apiKey = AppConstants.openRouterApiKey;

  /// Model AI yang digunakan
  String _model = AppConstants.aiModel;

  /// Memori riwayat obrolan untuk mode Obrolan
  final List<Map<String, dynamic>> _chatHistory = [];
  bool _historyLoaded = false;

  /// Memori riwayat untuk mode Asisten (konteks visual multi-turn)
  /// Menyimpan 3 interaksi terakhir agar AI ingat percakapan sebelumnya.
  final List<Map<String, dynamic>> _assistantHistory = [];

  /// Inisialisasi API service (memuat riwayat chat dari lokal)
  Future<void> initialize() async {
    if (_historyLoaded) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final historyString = prefs.getString('chat_history');
      if (historyString != null) {
        final List<dynamic> decoded = jsonDecode(historyString);
        _chatHistory.clear();
        for (var item in decoded) {
          _chatHistory.add(Map<String, dynamic>.from(item));
        }
        AppLogger.info(
          _tag,
          'Riwayat chat dimuat: ${_chatHistory.length} pesan',
        );
      }
      _historyLoaded = true;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal memuat riwayat chat', e);
    }
  }

  /// Simpan riwayat chat ke lokal
  Future<void> _saveChatHistory() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('chat_history', jsonEncode(_chatHistory));
    } catch (e) {
      AppLogger.error(_tag, 'Gagal menyimpan riwayat chat', e);
    }
  }

  /// Update API key (dari settings)
  void setApiKey(String key) {
    _apiKey = key;
    AppLogger.info(_tag, 'API key diperbarui');
  }

  /// Update model
  void setModel(String model) {
    _model = model;
    AppLogger.info(_tag, 'Model diubah ke: $model');
  }

  // ─── Prompt Templates ──────────────────────────────────────

  static const String _sinarBasePersona =
      '''Kamu adalah Sinar, sahabat setia penyandang tunanetra. Kamu berbicara seperti teman dekat yang perhatian — hangat, santai, dan penuh empati. Gunakan bahasa Indonesia sehari-hari yang natural.

KEPRIBADIAN:
- Bicara seperti teman, bukan robot. Pakai nada santai tapi tetap jelas.
- Peduli keselamatan teman. Kalau ada bahaya, langsung kasih tahu dengan tenang.
- Sabar dan tidak pernah mengeluh.

ATURAN PENTING:
- Jawab SINGKAT (1-2 kalimat). Ini akan dibacakan lewat speaker, jadi jangan kepanjangan.
- Langsung jawab, jangan mulai dengan "Baik", "Oke", "Tentu", atau basa-basi lain.
- JANGAN pernah bilang "gambar buram", "gambar tidak jelas", "kualitas rendah", atau sejenisnya. Tetap jawab sebaik mungkin walaupun gambar kurang jelas.
- Hanya bilang tidak bisa menjawab kalau gambar benar-benar gelap/hitam total atau memang tidak ada yang terlihat sama sekali.
- JANGAN bilang "Saya melihat gambar" atau "Pada gambar ini" — langsung ceritakan apa yang ada.
- Pakai arah jam untuk posisi: "ada tangga di arah jam 2, sekitar 1 meter".

SKENARIO PEJALAN KAKI TUNANETRA (SELALU PERHATIKAN):
- Zebra cross & lampu lalu lintas — bilang kapan aman menyeberang.
- Trotoar rusak, lubang, genangan air, permukaan tidak rata.
- Tangga naik/turun — sebutkan kira-kira berapa anak tangga kalau kelihatan.
- Pintu — terbuka/tertutup, dorong/tarik, posisi gagang.
- Tanda/tulisan penting — nama toko, petunjuk arah, peringatan.
- Orang yang mungkin bisa dimintai bantuan (petugas, satpam, dll).
- Kendaraan yang mendekat dari arah manapun.
- Perubahan permukaan jalan (aspal → keramik → tanah → rumput).
- Batas trotoar, pembatas jalan, tiang, pot tanaman, dan rintangan setinggi kepala (dahan, kanopi).''';

  /// Mendapatkan system prompt berdasarkan mode.
  ///
  /// Prompt ditulis dengan gaya santai dan natural agar
  /// agent tidak terkesan kaku saat bicara via TTS.
  String _getSystemPrompt(String mode, {String? customPrompt}) {
    final String base = _sinarBasePersona;

    switch (mode) {
      case 'asisten':
        return '''$base

TUGAS UTAMA: Kamu adalah Sinar. Jawab pertanyaan atau bantu teman kamu berdasarkan gambar yang ada di depan.
- Kalau dia minta panduan jalan/navigasi, kasih arahan yang jelas dengan patokan sekitar.
- Kalau dia minta bacakan teks, bacakan intinya.
- Kalau dia cuma nanya bebas (misal "warna apa?", "siapa ini?"), jawab langsung.
- Kalau tidak ada pertanyaan spesifik, ceritakan saja secara singkat apa yang ada di depannya.
Selalu prioritaskan peringatan bahaya kalau ada!''';

      case 'autopilot':
        final autopilotBase = '''$base

TUGAS: Kamu lagi nemenin teman kamu jalan. Pantau keselamatan.

FORMAT JAWABAN (WAJIB DIIKUTI):
- Jika ada BAHAYA LANGSUNG (lubang, kendaraan mendekat, tangga mendadak, tiang, objek menghalangi jalan): mulai dengan "BAHAYA!" lalu jelaskan singkat dengan posisi arah jam.
- Jika ada sesuatu yang perlu diperhatikan tapi tidak mendesak: mulai dengan "Hati-hati," lalu jelaskan.
- Jika aman: jawab "Aman." atau "Jalan terus."

Contoh:
- "BAHAYA! Ada lubang besar di arah jam 12, sekitar 2 langkah."
- "Hati-hati, ada motor parkir di kiri."
- "Aman, jalan lurus aja."''';

        if (customPrompt != null && customPrompt.isNotEmpty) {
          return '''$autopilotBase

Teman kamu minta tolong cari "$customPrompt". Kalau kelihatan, kasih tahu posisinya. Contoh: "Ada di depan kamu", "Di sebelah kanan".''';
        }
        return autopilotBase;

      case 'obrolan':
        return '''$base

TUGAS: Ngobrol sama teman kamu. Jawab pertanyaannya singkat dan jelas, kayak ngobrol biasa.''';

      case 'custom':
        return '''$base

TUGAS: Pengguna (tunanetra) bertanya: "${customPrompt ?? 'Apa ini?'}" berdasarkan gambar di depan mereka.

ATURAN WAJIB (SANGAT KETAT):
1. JAWAB TEPAT PADA SASARAN. HANYA jawab apa yang ditanyakan.
2. JANGAN PERNAH menjelaskan hal-hal lain di luar pertanyaan (misal: jangan deskripsikan latar belakang atau objek lain jika tidak ditanya).
3. Langsung ke intinya tanpa basa-basi. Contoh: jika ditanya "warna apa?", jawab "Merah".
4. Gunakan orientasi arah jarum jam (misal: "di arah jam 12") untuk memberi tahu posisi jika relevan.
5. Jika hal yang ditanyakan tidak terlihat di gambar, bilang saja "Tidak terlihat" tanpa menebak-nebak.''';

      default:
        return '''$base

Ceritakan singkat apa yang ada di depan.''';
    }
  }

  // ─── Send Image to OpenRouter ──────────────────────────────

  /// Kirim gambar ke OpenRouter API dan dapatkan deskripsi AI.
  ///
  /// Gambar dikonversi ke base64 dan dikirim sebagai bagian dari
  /// multimodal message (image_url dengan data URI).
  Future<AiResponse> analyzeImage(CapturePayload payload) async {
    try {
      AppLogger.info(
        _tag,
        'Mengirim gambar ke OpenRouter (mode: ${payload.mode})...',
      );

      // Baca file gambar dan konversi ke base64
      final imageFile = File(payload.imagePath);
      if (!await imageFile.exists()) {
        return AiResponse.error('File gambar tidak ditemukan');
      }

      // Kompresi gambar secara native
      final compressedBytes = await FlutterImageCompress.compressWithFile(
        imageFile.absolute.path,
        minWidth: 800,
        minHeight: 800,
        quality: 70,
      );

      if (compressedBytes == null) {
        return AiResponse.error('Gagal mengompres gambar');
      }

      final base64Image = base64Encode(compressedBytes);

      // Buat user message content
      // Untuk mode custom: pertanyaan user di-embed sebagai instruksi langsung
      // Untuk mode lain: instruksi generik
      final String userText;
      if (payload.mode == 'custom' && payload.customPrompt?.isNotEmpty == true) {
        userText = 'PERTANYAAN PENGGUNA: "${payload.customPrompt}". Jawab HANYA pertanyaan ini dengan SPESIFIK dan SINGKAT sesuai panduan.';
      } else if (payload.customPrompt?.isNotEmpty == true) {
        userText = payload.customPrompt!;
      } else {
        userText = 'Analisis gambar ini.';
      }

      final userContent = <Map<String, dynamic>>[
        {
          'type': 'image_url',
          'image_url': {'url': 'data:image/jpeg;base64,$base64Image'},
        },
        {
          'type': 'text',
          'text': userText,
        },
      ];

      // Untuk mode navigasi, tambahkan info lokasi
      final String systemPromptCustom;
      if (payload.mode == 'navigasi') {
        systemPromptCustom = payload.locationInfo ?? '';
      } else {
        systemPromptCustom = payload.customPrompt ?? '';
      }

      // Tentukan max_tokens berdasarkan mode
      // Mode custom: jawaban pendek → 100 tokens cukup
      // Mode autopilot: peringatan singkat → 80 tokens
      // Mode lain: deskripsi → 150 tokens (turun dari 300)
      final int maxTokens;
      switch (payload.mode) {
        case 'custom':
          maxTokens = 100;
          break;
        case 'autopilot':
          maxTokens = 80;
          break;
        default:
          maxTokens = 150;
      }

      // Buat request body sesuai format OpenRouter/OpenAI
      // Sertakan riwayat asisten (conversation memory) agar AI ingat konteks sebelumnya
      String systemPrompt = _getSystemPrompt(
        payload.mode,
        customPrompt: payload.mode == 'navigasi'
            ? systemPromptCustom
            : payload.customPrompt,
      );

      if (payload.locationInfo != null && payload.locationInfo!.isNotEmpty) {
        systemPrompt += '\n\n[INFO LOKASI SAAT INI]\n${payload.locationInfo}\nGunakan informasi lokasi di atas HANYA JIKA relevan dengan pertanyaan atau situasi.';
      }

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
        // Tambahkan riwayat percakapan asisten (maks 3 interaksi = 6 pesan)
        // agar AI ingat gambar & pertanyaan sebelumnya
        ..._assistantHistory,
        {'role': 'user', 'content': userContent},
      ];

      final body = jsonEncode({
        'model': _model,
        'messages': messages,
        'max_tokens': maxTokens,
        'temperature': 0.3,
      });

      // Kirim HTTP POST request
      final response = await http
          .post(
            Uri.parse(AppConstants.openRouterBaseUrl),
            headers: _buildHeaders(),
            body: body,
          )
          .timeout(Duration(seconds: AppConstants.httpTimeoutSeconds));

      final aiResponse = _parseResponse(response);

      // Simpan ke riwayat asisten untuk conversation memory
      if (aiResponse.isSuccess) {
        _assistantHistory.add({'role': 'user', 'content': userText});
        _assistantHistory.add({
          'role': 'assistant',
          'content': aiResponse.description,
        });
        // Batasi maksimal 3 pasang interaksi (6 pesan)
        if (_assistantHistory.length > 6) {
          _assistantHistory.removeRange(0, _assistantHistory.length - 6);
        }
        AppLogger.info(_tag,
            'Riwayat asisten disimpan: ${_assistantHistory.length} pesan');

        // Simpan ke Supabase
        SupabaseService().saveAiHistory(
          mode: payload.mode,
          prompt: userText,
          response: aiResponse.description,
          model: _model,
        );
      }

      return aiResponse;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengirim ke API', e);
      return AiResponse.error('Gagal menghubungi server: $e');
    }
  }

  // ─── Send Chat (Text-only, tanpa gambar) ───────────────────

  /// Kirim pesan teks ke OpenRouter API tanpa gambar.
  ///
  /// Digunakan di mode obrolan dimana pengguna cukup
  /// bertanya lewat suara tanpa perlu capture kamera.
  Future<AiResponse> sendChat(String userMessage) async {
    if (!_historyLoaded) {
      await initialize();
    }

    try {
      AppLogger.info(_tag, 'Mengirim chat ke OpenRouter...');

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': _getSystemPrompt('obrolan')},
        ..._chatHistory,
        {'role': 'user', 'content': userMessage},
      ];

      final body = jsonEncode({
        'model': _model,
        'messages': messages,
        'max_tokens': 150,
        'temperature': 0.3,
      });

      final response = await http
          .post(
            Uri.parse(AppConstants.openRouterBaseUrl),
            headers: _buildHeaders(),
            body: body,
          )
          .timeout(Duration(seconds: AppConstants.httpTimeoutSeconds));

      final aiResponse = _parseResponse(response);

      // Jika berhasil, simpan ke riwayat
      if (aiResponse.isSuccess) {
        _chatHistory.add({'role': 'user', 'content': userMessage});
        _chatHistory.add({
          'role': 'assistant',
          'content': aiResponse.description,
        });

        // Batasi maksimal 10 pasang (20 pesan)
        if (_chatHistory.length > 20) {
          _chatHistory.removeRange(0, _chatHistory.length - 20);
        }
        _saveChatHistory();

        // Simpan ke Supabase
        SupabaseService().saveAiHistory(
          mode: 'obrolan',
          prompt: userMessage,
          response: aiResponse.description,
          model: _model,
        );
      }

      return aiResponse;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengirim chat ke API', e);
      return AiResponse.error('Gagal menghubungi server: $e');
    }
  }

  /// Bersihkan riwayat percakapan asisten.
  ///
  /// Dipanggil saat ganti mode agar konteks tidak tercampur.
  void clearAssistantHistory() {
    _assistantHistory.clear();
    AppLogger.info(_tag, 'Riwayat asisten dibersihkan');
  }

  /// Bersihkan riwayat obrolan.
  void clearChatHistory() {
    _chatHistory.clear();
    _saveChatHistory();
    AppLogger.info(_tag, 'Riwayat obrolan dibersihkan');
  }

  // ─── Helpers ───────────────────────────────────────────────

  /// Build HTTP headers untuk OpenRouter API.
  Map<String, String> _buildHeaders() {
    return {
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://sightassist.app',
      'X-Title': 'SightAssist',
    };
  }

  /// Parse HTTP response dari OpenRouter.
  AiResponse _parseResponse(http.Response response) {
    if (response.statusCode == 200) {
      final json = jsonDecode(response.body);
      final content =
          json['choices']?[0]?['message']?['content'] ?? 'Tidak ada respons';
      final model = json['model'] ?? _model;

      AppLogger.info(_tag, 'Respons diterima dari $model');
      return AiResponse.success(description: content, model: model);
    } else {
      final errorBody = response.body;
      AppLogger.error(_tag, 'API Error ${response.statusCode}: $errorBody');
      return AiResponse.error('Server error: ${response.statusCode}');
    }
  }
}
