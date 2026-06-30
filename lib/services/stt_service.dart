import 'package:speech_to_text/speech_recognition_result.dart';
import 'package:speech_to_text/speech_to_text.dart';

import '../core/utils/logger.dart';

/// Service Speech-to-Text (STT).
///
/// Mendengarkan suara pengguna dan mengubahnya menjadi teks prompt.
/// Digunakan di mode Ambil Gambar agar tunanetra bisa memberikan
/// instruksi lewat suara.
class SttService {
  static const String _tag = 'SttService';

  final SpeechToText _stt = SpeechToText();
  bool _isAvailable = false;
  bool _isListening = false;
  String _lastResult = '';

  /// Callbacks untuk mengabari pihak luar tentang perubahan status & error
  void Function(String status)? onStatusChanged;
  void Function(String errorMsg)? onErrorOccurred;

  /// Apakah STT tersedia di perangkat ini
  bool get isAvailable => _isAvailable;

  /// Apakah sedang mendengarkan
  bool get isListening => _isListening;

  /// Hasil terakhir dari pengenalan suara
  String get lastResult => _lastResult;

  // ─── Initialize ────────────────────────────────────────────

  /// Inisialisasi STT engine.
  Future<bool> initialize() async {
    try {
      _isAvailable = await _stt.initialize(
        onError: (error) {
          AppLogger.error(_tag, 'STT Error: ${error.errorMsg}');
          _isListening = false;
          if (onErrorOccurred != null) {
            onErrorOccurred!(error.errorMsg);
          }
        },
        onStatus: (status) {
          AppLogger.info(_tag, 'STT Status: $status');
          if (status == 'done' || status == 'notListening') {
            _isListening = false;
          }
          if (onStatusChanged != null) {
            onStatusChanged!(status);
          }
        },
      );

      if (_isAvailable) {
        AppLogger.info(_tag, 'STT diinisialisasi');
        // Cek locale yang tersedia
        var locales = await _stt.locales();
        var localeNames = locales.map((l) => l.localeId).join(', ');
        AppLogger.info(_tag, 'Locale tersedia: $localeNames');
      } else {
        AppLogger.warning(_tag, 'STT tidak tersedia di perangkat ini');
      }

      return _isAvailable;
    } catch (e) {
      AppLogger.error(_tag, 'Gagal inisialisasi STT', e);
      return false;
    }
  }

  // ─── Listen ────────────────────────────────────────────────

  /// Mulai mendengarkan suara pengguna.
  ///
  /// [onResult] dipanggil setiap kali ada hasil pengenalan suara.
  /// [onDone] dipanggil saat selesai mendengarkan (final result).
  Future<void> startListening({
    required Function(String text, bool isFinal) onResult,
    String localeId = 'id-ID',
  }) async {
    if (!_isAvailable) {
      AppLogger.warning(_tag, 'STT tidak tersedia');
      return;
    }

    if (_isListening) {
      await stopListening();
    }

    _isListening = true;
    _lastResult = '';

    AppLogger.info(_tag, 'Mulai mendengarkan (locale: $localeId)...');

    await _stt.listen(
      onResult: (SpeechRecognitionResult result) {
        _lastResult = result.recognizedWords;
        onResult(result.recognizedWords, result.finalResult);

        if (result.finalResult) {
          AppLogger.info(_tag, 'Hasil akhir: ${result.recognizedWords}');
          _isListening = false;
        }
      },
      pauseFor: const Duration(seconds: 10),
      listenOptions: SpeechListenOptions(
        localeId: localeId,
        listenMode: ListenMode.dictation,
        cancelOnError: false,
        partialResults: true,
      ),
    );
  }

  /// Hentikan mendengarkan.
  Future<void> stopListening() async {
    if (_isListening) {
      await _stt.stop();
      _isListening = false;
      AppLogger.info(_tag, 'Berhenti mendengarkan');
    }
  }

  /// Batalkan mendengarkan (tanpa hasil).
  Future<void> cancelListening() async {
    if (_isListening) {
      await _stt.cancel();
      _isListening = false;
      _lastResult = '';
      AppLogger.info(_tag, 'Mendengarkan dibatalkan');
    }
  }

  // ─── Dispose ───────────────────────────────────────────────

  /// Bersihkan resource STT.
  Future<void> dispose() async {
    await stopListening();
    AppLogger.info(_tag, 'STT disposed');
  }
}
