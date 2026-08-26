import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../core/constants/app_constants.dart';
import '../core/utils/logger.dart';
import '../models/ai_response.dart';
import '../models/capture_payload.dart';
import 'ai_tools.dart';
import 'supabase_service.dart';

/// Service untuk komunikasi dengan OpenRouter API.
///
/// Mengirimkan gambar dan teks ke Vision Language Model (Gemini via OpenRouter)
/// dan mengembalikan deskripsi teks. Mendukung function calling tools
/// untuk aksi nyata di perangkat.
class ApiService {
  static const String _tag = 'ApiService';

  /// API Key (bisa di-override dari settings)
  String _apiKey = AppConstants.openRouterApiKey;

  /// Model AI yang digunakan
  String _model = AppConstants.aiModel;

  /// Referensi ke AI tools service
  AiToolsService? _toolsService;

  /// Memori riwayat obrolan untuk mode Obrolan
  final List<Map<String, dynamic>> _chatHistory = [];
  bool _historyLoaded = false;

  /// Memori riwayat untuk mode Asisten (konteks visual multi-turn)
  /// Menyimpan 3 interaksi terakhir agar AI ingat percakapan sebelumnya.
  final List<Map<String, dynamic>> _assistantHistory = [];

  /// Maksimal iterasi tool calling loop (keamanan)
  static const int _maxToolCallIterations = 3;

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

  /// Set referensi ke AI tools service
  void setToolsService(AiToolsService toolsService) {
    _toolsService = toolsService;
    AppLogger.info(_tag, 'Tools service terpasang');
  }

  // ─── Prompt Templates ──────────────────────────────────────

  static const String _sinarBasePersona =
      '''Kamu adalah Sinar, sahabat dan asisten pribadi tunanetra. Kamu berbicara seperti sahabat dekat yang setia, perhatian, hangat, dan observan. Gunakan bahasa Indonesia sehari-hari yang santai, luwes, dan menyenangkan.

PERAN & KEPRIBADIAN:
- Kamu adalah mata dan teman bicara bagi temanmu. Kamu hadir untuk menemani, membantu melihat dunia, dan menjaga keselamatannya.
- Bersikaplah ramah dan ekspresif seperti sahabat sejati, bukan mesin kaku atau robot pemindai.
- Pandai mengamati detail lingkungan (cahaya, suasana, cuaca, kerapian, warna, suasana hati).
- Tanggap, solutif, dan tidak pernah berbelit-belit.

CARA MENJAWAB PERTANYAAN (PERSONAL & TEPAT SASARAN):
- JAWAB LANGSUNG apa yang ditanyakan temanmu dengan nada bersahabat.
- Contoh pertanyaan sehari-hari:
  * "Pagi ini cerah ya?" / "Di luar terang gak?":
    -> Amati pencahayaan di gambar dan kondisi sekitar. Jawab hangat: "Iya, pagi ini cerah banget! Cahaya matahari kelihatan terang masuk ke ruangan, suasananya segar."
  * "Menurut kamu di depan ada apa?" / "Ada penghalang gak?":
    -> Amati jalur jalan. Jawab secara personal dan jelas: "Di depanmu jalur jalan aman kok. Cuma ada meja kecil di sebelah kanan arah jam 2, jadi kamu bisa jalan lurus tanpa khawatir."
  * "Apakah kondisi berantakan?":
    -> Jawab jujur dan ramah: "Iya, kelihatannya agak berantakan nih. Ada baju dan beberapa barang di kasur sama lantai." atau "Ruanganmu rapi dan bersih kok."
  * "Baju yang aku pegang warna apa?":
    -> Jawab spesifik: "Baju yang kamu pegang warnanya biru dongker polos."
  * "Buka GPS dong" / "Cek lokasi":
    -> Panggil tool open_gps / get_current_location lalu jawab: "Oke, aku bantu buka pengaturan GPS di HP kamu ya."
- DILARANG KERAS mengabsen atau membacakan daftar barang yang tidak ditanyakan (misal jangan sebut "ada kasur, bantal, laptop, meja" jika temanmu hanya bertanya apakah cerah atau apakah berantakan).

ATURAN FORMAT & KESELAMATAN:
- Jawab SINGKAT dan NATURAL (1-3 kalimat) agar nyaman didengar lewat suara TTS.
- JANGAN pernah menggunakan frasa kaku seperti "Pada gambar ini", "Saya melihat gambar", atau "Gambar buram". Langsung ceritakan apa yang kamu lihat.
- Gunakan orientasi arah jam ("arah jam 12", "arah jam 3") dan perkiraan jarak langkah/meter untuk posisi benda.
- PRIORITAS BAHAYA: Jika ada bahaya langsung di jalur jalan (lubang, tangga curam, kendaraan melintas, dahan rendah setinggi kepala), beri tahu dengan segera dan jelas.

TOOLS YANG TERSEDIA:
Kamu punya akses ke tools function calling:
- open_gps: untuk membuka pengaturan lokasi/GPS di HP pengguna
- get_current_time: untuk waktu/hari/tanggal WIB
- get_current_location: untuk posisi GPS dan alamat jalan pengguna
- get_nearby_places: untuk mencari tempat terdekat (masjid, ATM, minimarket, dll) dari OpenStreetMap
- get_weather: untuk info suhu dan kondisi cuaca
- set_tts_speed: untuk mengubah kecepatan suara bicara
- scan_obstacles: untuk memindai rintangan di depan
- read_text_from_image: untuk membaca tulisan dari kamera
- identify_money: untuk identifikasi uang
- switch_mode: untuk mengganti mode asisten

ALUR BERPIKIR RE-ACT (REASON + ACT):
1. Pikirkan apa yang dibutuhkan pengguna sebelum mengeksekusi.
2. Jika butuh data nyata (waktu, lokasi, tempat sekitar, cuaca, kontrol GPS), panggil tool yang relevan.
3. Kamu bisa memanggil beberapa tool berurutan jika pertanyaannya membutuhkan lebih dari satu data.
4. Rangkum seluruh hasil observasi dari tool menjadi satu jawaban akhir yang utuh dan mengalir.

PENANGANAN FALLBACK & ERROR (NATURAL):
- Jika suatu tool gagal atau mengembalikan pesan error (misal GPS mati atau data tidak ditemukan), JANGAN sebutkan kode teknis atau format JSON ke pengguna.
- Tanggapi dengan tenang, ramah, dan solutif. Contoh: "Sepertinya sinyal GPS belum dapat posisi yang pas nih. Coba nyalakan lokasi di HP ya." atau "Aku belum menemukan tempat itu di sekitar sini."''';

  /// Mendapatkan system prompt berdasarkan mode.
  String _getSystemPrompt(String mode, {String? customPrompt}) {
    final String base = _sinarBasePersona;

    switch (mode) {
      case 'asisten':
        if (customPrompt != null && customPrompt.isNotEmpty) {
          return '''$base

PERTANYAAN PENGGUNA: "$customPrompt"

TUGAS UTAMA: Jawab LANGSUNG dan HANYA pertanyaan pengguna di atas.
- Fokus 100% pada apa yang ditanyakan.
- JANGAN mengabsen atau mendeskripsikan barang-barang lain di sekitar jika tidak relevan dengan pertanyaan.
- Jika pengguna bertanya kondisi ruangan (misal: "apakah berantakan?"): Jawab tegas apakah berantakan atau rapi beserta alasan singkat.
- Jika ditanya penghalang: Jawab apakah ada penghalang di jalur jalan.
- Jawab singkat dalam 1-3 kalimat natural.''';
        }

        return '''$base

TUGAS UTAMA: Pengguna ingin tahu situasi di depannya.
- Ceritakan secara singkat objek utama dan situasi di depan (termasuk warna dan tulisan penting jika ada).
- Jika ada penghalang di jalur jalan, utamakan keselamatan dengan memberi tahu posisi arah jam dan jaraknya.
- Jawab dalam 1-3 kalimat singkat.''';

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

TUGAS: Ngobrol santai sama teman kamu. Kamu teman ngobrol terbaik!
- Jawab singkat tapi hangat, kayak ngobrol sama teman dekat.
- Boleh bercanda ringan, kasih semangat, atau cerita pendek kalau diminta.
- Bisa jawab pertanyaan pengetahuan umum (sejarah, sains, budaya, resep, dll).
- Kalau ditanya jam/waktu/hari/tanggal, panggil tool get_current_time.
- Kalau ditanya lokasi atau tempat terdekat, panggil tool yang sesuai.
- Kalau teman curhat, dengarkan dengan empati dan kasih respons yang menenangkan.
- Kalau kamu tidak tahu jawabannya, jujur bilang tidak tahu — jangan mengarang.
- Ingat percakapan sebelumnya dan sambungkan pembicaraan secara natural.''';

      case 'penghalang':
        final questionPrefix = (customPrompt != null && customPrompt.isNotEmpty)
            ? 'PERTANYAAN PENGGUNA: "$customPrompt"\n\n'
            : '';
        return '''$base

${questionPrefix}TUGAS UTAMA: JAWAB PERTANYAAN TENTANG PENGHALANG & KESELAMATAN JALUR JALAN.
- Jawab LANGSUNG apakah ada rintangan yang menghalangi jalan pengguna.
- Jika ada rintangan di jalur jalan (orang, kendaraan, tiang, pot, lubang, genangan, tangga, kabel, dahan rendah):
  Sebutkan objek, posisi arah jam, dan estimasi jarak langkah/meter. Berikan instruksi hindar yang jelas jika perlu.
- Jika jalur aman/bersih: Jawab "Aman, tidak ada penghalang di depanmu. Jalur terbuka."
- JANGAN menyebutkan barang-barang sekeliling yang tidak menghalangi jalur jalan jika tidak ditanyakan.''';

      case 'custom':
        return '''$base

PERTANYAAN PENGGUNA: "${customPrompt ?? 'Apa ini?'}"

ATURAN MUTLAK (SANGAT KETAT):
1. JAWAB HANYA DAN TEPAT PADA SASARAN PERTANYAAN: "${customPrompt ?? ''}".
2. DILARANG KERAS mengabsen atau menyebutkan daftar barang di sekitar yang tidak ditanyakan (misal jangan sebut kasur, bantal, laptop, meja jika pengguna bertanya "apakah berantakan?").
3. Berikan jawaban langsung, to-the-point, dan informatif (1-3 kalimat).
   - Contoh: Jika ditanya "apakah kondisi berantakan?": Jawab "Iya, kondisinya cukup berantakan, ada barang dan baju berserakan di kasur dan lantai." atau "Tidak, kondisi ruangan rapi."
   - Contoh: Jika ditanya "apakah ada orang?": Jawab "Ada satu orang di arah jam 12 sekitar 2 meter." atau "Tidak ada orang."
4. KHUSUS pertanyaan terkait tulisan/teks: bacakan LENGKAP semua kata yang terlihat.
5. KHUSUS pertanyaan terkait warna: sebutkan warna spesifik.
6. KHUSUS pertanyaan terkait waktu/jam/hari/tanggal: panggil tool get_current_time.
7. Jika hal yang ditanyakan tidak terlihat di gambar, bilang "Tidak terlihat di depanmu."''';

      default:
        return '''$base

Ceritakan singkat apa yang ada di depan secara ringkas.''';
    }
  }

  // ─── Headers & Helpers ─────────────────────────────────────

  /// Build HTTP headers untuk OpenRouter API.
  Map<String, String> _buildHeaders() {
    return {
      'Authorization': 'Bearer $_apiKey',
      'Content-Type': 'application/json',
      'HTTP-Referer': 'https://sightassist.app',
      'X-Title': 'SightAssist',
    };
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
      final String userText;
      if (payload.mode == 'custom' && payload.customPrompt?.isNotEmpty == true) {
        userText =
            'PERTANYAAN PENGGUNA: "${payload.customPrompt}". Jawab HANYA pertanyaan ini dengan SPESIFIK dan SINGKAT sesuai panduan.';
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

      // Build system prompt
      final String systemPromptCustom;
      if (payload.mode == 'navigasi') {
        systemPromptCustom = payload.locationInfo ?? '';
      } else {
        systemPromptCustom = payload.customPrompt ?? '';
      }

      String systemPrompt = _getSystemPrompt(
        payload.mode,
        customPrompt: payload.mode == 'navigasi'
            ? systemPromptCustom
            : payload.customPrompt,
      );

      if (payload.locationInfo != null && payload.locationInfo!.isNotEmpty) {
        systemPrompt +=
            '\n\n[INFO LOKASI SAAT INI]\n${payload.locationInfo}\nKamu TAHU lokasi teman kamu. Gunakan informasi ini untuk:\n- Menjawab pertanyaan "saya di mana?" atau "ini daerah apa?"\n- Jika ditanya tempat terdekat (supermarket, masjid, RS, ATM, dll), gunakan pengetahuan umummu tentang daerah ini untuk menyarankan tempat, tapi bilang bahwa ini berdasarkan pengetahuan umum dan sarankan untuk konfirmasi ke orang sekitar.\n- Memberikan konteks lingkungan (misal: area perkotaan, perumahan, dll).';
      }

      // Tentukan max_tokens berdasarkan mode
      final int maxTokens;
      switch (payload.mode) {
        case 'custom':
          maxTokens = 200;
          break;
        case 'autopilot':
          maxTokens = 80;
          break;
        default:
          maxTokens = 250;
      }

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
        ..._assistantHistory,
        {'role': 'user', 'content': userContent},
      ];

      final body = <String, dynamic>{
        'model': _model,
        'messages': messages,
        'max_tokens': maxTokens,
        'temperature': 0.3,
      };

      // Tambahkan tools hanya jika bukan autopilot/penghalang
      final enableTools =
          _toolsService != null &&
          payload.mode != 'autopilot' &&
          payload.mode != 'penghalang';
      if (enableTools) {
        body['tools'] = _toolsService!.getToolDeclarations();
      }

      final aiResponse = await _sendOpenRouterRequest(body, enableTools: enableTools);

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
          location: payload.locationInfo,
        );
      }

      return aiResponse;
    } on TimeoutException {
      AppLogger.error(_tag, 'Timeout saat mengirim ke API');
      return AiResponse.error('Koneksi terlalu lama. Coba lagi ya.');
    } on SocketException catch (e) {
      AppLogger.error(_tag, 'Tidak ada koneksi internet', e);
      return AiResponse.error('Tidak ada koneksi internet.');
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
  Future<AiResponse> sendChat(String userMessage,
      {String? locationInfo}) async {
    if (!_historyLoaded) {
      await initialize();
    }

    try {
      AppLogger.info(_tag, 'Mengirim chat ke OpenRouter...');

      // Bangun system prompt dengan lokasi jika tersedia
      String systemPrompt = _getSystemPrompt('obrolan');
      if (locationInfo != null && locationInfo.isNotEmpty) {
        systemPrompt +=
            '\n\n[INFO LOKASI SAAT INI]\n$locationInfo\nKamu TAHU lokasi teman kamu. Gunakan informasi ini untuk:\n- Menjawab pertanyaan "saya di mana?" atau "ini daerah apa?"\n- Jika ditanya tempat terdekat (supermarket, masjid, RS, ATM, dll), gunakan pengetahuan umummu tentang daerah ini untuk menyarankan tempat, tapi bilang bahwa ini berdasarkan pengetahuan umum dan sarankan untuk konfirmasi ke orang sekitar.\n- Memberikan konteks lingkungan (misal: area perkotaan, perumahan, dll).';
      }

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
        ..._chatHistory,
        {'role': 'user', 'content': userMessage},
      ];

      final body = <String, dynamic>{
        'model': _model,
        'messages': messages,
        'max_tokens': 300,
        'temperature': 0.7,
      };

      final enableTools = _toolsService != null;
      if (enableTools) {
        body['tools'] = _toolsService!.getToolDeclarations();
      }

      final aiResponse = await _sendOpenRouterRequest(body, enableTools: enableTools);

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
          location: locationInfo,
        );
      }

      return aiResponse;
    } on TimeoutException {
      AppLogger.error(_tag, 'Timeout saat mengirim chat ke API');
      return AiResponse.error('Koneksi terlalu lama. Coba lagi ya.');
    } on SocketException catch (e) {
      AppLogger.error(_tag, 'Tidak ada koneksi internet', e);
      return AiResponse.error('Tidak ada koneksi internet.');
    } catch (e) {
      AppLogger.error(_tag, 'Gagal mengirim chat ke API', e);
      return AiResponse.error('Gagal menghubungi server: $e');
    }
  }

  /// Bersihkan riwayat percakapan asisten.
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

  // ─── OpenRouter Request with Tool Calling Loop ─────────────

  Future<AiResponse> _sendOpenRouterRequest(
    Map<String, dynamic> body, {
    bool enableTools = false,
  }) async {
    var currentBody = Map<String, dynamic>.from(body);
    int iteration = 0;

    while (iteration < _maxToolCallIterations) {
      iteration++;

      final response = await http
          .post(
            Uri.parse(AppConstants.openRouterBaseUrl),
            headers: _buildHeaders(),
            body: jsonEncode(currentBody),
          )
          .timeout(Duration(seconds: AppConstants.httpTimeoutSeconds));

      if (response.statusCode != 200) {
        final errorBody = response.body;
        AppLogger.error(_tag, 'OpenRouter API Error ${response.statusCode}: $errorBody');
        return AiResponse.error('Server error: ${response.statusCode}');
      }

      final json = jsonDecode(response.body);
      final choice = json['choices']?[0];
      if (choice == null) {
        return AiResponse.error('Tidak ada pilihan respons');
      }

      final message = choice['message'] as Map<String, dynamic>?;
      if (message == null) {
        return AiResponse.error('Respons kosong dari server');
      }

      final toolCalls = message['tool_calls'] as List<dynamic>?;

      // Handle function calling jika AI memanggil tool
      if (toolCalls != null && toolCalls.isNotEmpty && enableTools && _toolsService != null) {
        final currentMessages =
            List<Map<String, dynamic>>.from(currentBody['messages'] as List);

        // Tambahkan response model (dengan tool_calls)
        currentMessages.add(message);

        // Jalankan setiap tool call
        for (final tc in toolCalls) {
          final toolCallId = tc['id'] as String? ?? 'call_1';
          final function = tc['function'] as Map<String, dynamic>? ?? {};
          final name = function['name'] as String? ?? '';
          final rawArgs = function['arguments'] as String? ?? '{}';

          Map<String, dynamic> args = {};
          try {
            args = jsonDecode(rawArgs);
          } catch (_) {}

          AppLogger.info(_tag, 'AI memanggil tool via OpenRouter: $name (iterasi $iteration)');
          final toolResult = await _toolsService!.executeTool(name, args);

          // Tambahkan tool response message
          currentMessages.add({
            'role': 'tool',
            'tool_call_id': toolCallId,
            'content': jsonEncode(toolResult),
          });
        }

        currentBody['messages'] = currentMessages;
        continue; // Lanjut iterasi berikutnya untuk menerima jawaban final
      }

      // Ambil respons teks
      final content = message['content'] as String? ?? 'Tidak ada respons';
      final modelUsed = json['model'] as String? ?? _model;

      AppLogger.info(_tag, 'Respons diterima dari $modelUsed');
      return AiResponse.success(description: content, model: modelUsed);
    }

    AppLogger.warning(
        _tag, 'Tool calling loop OpenRouter melebihi batas $_maxToolCallIterations');
    return AiResponse.error(
        'Terlalu banyak tool calls. Coba lagi dengan pertanyaan spesifik.');
  }
}
