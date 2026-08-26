import 'dart:io';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../../core/constants/app_strings.dart';
import '../../core/theme/app_theme.dart';
import '../../core/utils/logger.dart';
import '../../providers/assistant_provider.dart';
import '../../providers/ble_provider.dart';
import '../../routes/app_router.dart';
import '../../services/background_service.dart';
import 'widgets/assistant_status_indicator.dart';
import 'widgets/connection_status_card.dart';

/// Layar utama SightAssist.
///
/// Menampilkan:
/// - Preview kamera (mode general & autopilot)
/// - Chat view (mode obrolan)
/// - Status koneksi BLE
/// - Voice prompt input
/// - Tombol trigger (voice command + switch mode)
/// - Status asisten & mode aktif
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with WidgetsBindingObserver {
  BleProvider? _bleProvider;
  AssistantProvider? _assistantProvider;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // Inisialisasi assistant provider setelah frame pertama
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final assistant = context.read<AssistantProvider>();
      _assistantProvider = assistant;
      _bleProvider = context.read<BleProvider>();

      assistant.initialize();

      // Minta izin notifikasi dulu (Android 13+), lalu start background service
      await _requestNotificationPermissionAndStartService();

      BackgroundService.updateNotification(
        content: 'Mode: ${assistant.modeLabel} — ${assistant.statusLabel}',
      );

      // Listen ke perubahan BLE state (termasuk koneksi baru)
      _bleProvider!.addListener(_onBleStateChanged);

      // Listen ke perubahan assistant untuk update notifikasi
      assistant.addListener(_onAssistantStateChanged);

      // Subscribe langsung jika sudah terhubung
      if (_bleProvider!.isConnected) {
        assistant.listenToTrigger(_bleProvider!.triggerStream);
      } else {
        // Coba auto-connect saat aplikasi baru dibuka
        _bleProvider!.autoConnectToLastDevice();
      }
    });
  }

  /// Dipanggil saat lifecycle app berubah (resume/pause).
  /// Memastikan background service tetap hidup saat app kembali dari background.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed) {
      AppLogger.info('HomeScreen', 'App resumed — memastikan background service aktif');
      BackgroundService.ensureRunning();

      // Update notifikasi dengan status terbaru
      final assistant = _assistantProvider;
      if (assistant != null) {
        BackgroundService.updateNotification(
          content: 'Mode: ${assistant.modeLabel} — ${assistant.statusLabel}',
        );
      }
    }
  }

  /// Dipanggil setiap kali BleProvider berubah (connect/disconnect).
  /// Auto-subscribe ke trigger stream saat ESP32 terhubung.
  void _onBleStateChanged() {
    final ble = _bleProvider;
    if (ble == null) return;

    final assistant = context.read<AssistantProvider>();
    if (ble.isConnected) {
      assistant.listenToTrigger(ble.triggerStream);
      AppLogger.info('HomeScreen', 'BLE terhubung → trigger stream subscribed');

      // Update notifikasi: BLE terhubung
      BackgroundService.updateNotification(
        content: 'ESP32 terhubung — Mode: ${assistant.modeLabel}',
      );

      // Pastikan background service hidup saat BLE connect
      BackgroundService.ensureRunning();
    } else {
      // Update notifikasi: BLE terputus
      BackgroundService.updateNotification(
        content: 'ESP32 terputus — Menunggu koneksi...',
      );
    }
  }

  /// Dipanggil setiap kali AssistantProvider berubah.
  /// Update notifikasi foreground dengan status terbaru.
  void _onAssistantStateChanged() {
    final assistant = _assistantProvider;
    if (assistant == null) return;

    // Update notifikasi dengan status & mode terkini
    final ble = _bleProvider;
    final bleStatus = (ble != null && ble.isConnected)
        ? 'ESP32 ✓'
        : 'ESP32 ✗';

    BackgroundService.updateNotification(
      content: '$bleStatus | ${assistant.modeLabel} — ${assistant.statusLabel}',
    );
  }

  /// Minta izin notifikasi (Android 13+) lalu start background service.
  ///
  /// Pada Android 13+ (API 33), POST_NOTIFICATIONS harus di-grant
  /// sebelum foreground service bisa menampilkan notifikasi.
  /// Tanpa izin ini, startForeground() akan crash.
  Future<void> _requestNotificationPermissionAndStartService() async {
    if (Platform.isAndroid) {
      final notifStatus = await Permission.notification.status;
      if (!notifStatus.isGranted) {
        AppLogger.info('HomeScreen', 'Meminta izin notifikasi...');
        final result = await Permission.notification.request();
        if (!result.isGranted) {
          AppLogger.warning('HomeScreen', 'Izin notifikasi ditolak — background service tetap dicoba');
        }
      }
    }

    // Start background service (aman meskipun izin notifikasi ditolak pada Android <13)
    await BackgroundService.start();
    AppLogger.info('HomeScreen', 'Background service dimulai');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _bleProvider?.removeListener(_onBleStateChanged);
    _assistantProvider?.removeListener(_onAssistantStateChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(AppStrings.appName),
        actions: [
          // Tombol scan BLE
          IconButton(
            icon: const Icon(Icons.bluetooth_searching),
            tooltip: AppStrings.bleScanButton,
            onPressed: () => Navigator.pushNamed(context, AppRouter.scan),
          ),
          // Tombol settings
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            tooltip: AppStrings.settingsTitle,
            onPressed: () => Navigator.pushNamed(context, AppRouter.settings),
          ),
        ],
      ),
      body: SafeArea(
        child: Consumer<AssistantProvider>(
          builder: (context, assistant, child) {
            return OrientationBuilder(
              builder: (context, orientation) {
                if (orientation == Orientation.landscape) {
                  return _buildLandscapeLayout(assistant);
                }
                return _buildPortraitLayout(assistant);
              },
            );
          },
        ),
      ),
    );
  }

  /// Layout vertikal untuk orientasi Portrait
  Widget _buildPortraitLayout(AssistantProvider assistant) {
    return Column(
      children: [
        // ─── Area Utama (Kamera / Chat) ──────────────
        Expanded(
          flex: 3,
          child: assistant.mode == AssistantMode.obrolan
              ? _buildChatView(assistant)
              : _buildCameraPreview(assistant),
        ),

        // ─── Panel Bawah ─────────────────────────────
        Container(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
          decoration: BoxDecoration(
            color: AppTheme.scaffoldBg,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Status koneksi BLE (compact)
              const ConnectionStatusCard(),
              const SizedBox(height: 12),

              // Status asisten
              const AssistantStatusIndicator(),
              const SizedBox(height: 12),

              // Voice prompt (tampil di semua mode)
              _buildVoicePrompt(assistant),

              const SizedBox(height: 12),

              _buildActionButtons(assistant),
            ],
          ),
        ),
      ],
    );
  }

  /// Layout horizontal Split-View untuk orientasi Landscape
  Widget _buildLandscapeLayout(AssistantProvider assistant) {
    return Row(
      children: [
        // ─── Area Kiri (Kamera / Chat) ───────────────
        Expanded(
          flex: 5,
          child: Container(
            color: Colors.black,
            child: assistant.mode == AssistantMode.obrolan
                ? _buildChatView(assistant)
                : _buildCameraPreview(assistant),
          ),
        ),

        // ─── Area Kanan (Panel Kontrol & Status) ──────
        Expanded(
          flex: 4,
          child: Container(
            color: AppTheme.scaffoldBg,
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const ConnectionStatusCard(),
                  const SizedBox(height: 10),
                  const AssistantStatusIndicator(),
                  const SizedBox(height: 10),
                  _buildVoicePrompt(assistant),
                  const SizedBox(height: 10),
                  _buildActionButtons(assistant),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Build camera preview widget (mode General & Autopilot)
  Widget _buildCameraPreview(AssistantProvider assistant) {
    final controller = assistant.cameraController;

    if (!assistant.cameraReady || controller == null || !controller.value.isInitialized) {
      return Container(
        color: Colors.black,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.videocam_off,
                size: 64,
                color: AppTheme.textMuted,
              ),
              const SizedBox(height: 12),
              Text(
                'Kamera belum siap',
                style: TextStyle(
                  color: AppTheme.textMuted,
                  fontSize: 16,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        // Camera preview
        ClipRRect(
          child: Center(
            child: CameraPreview(controller),
          ),
        ),

        // Time and Location overlay
        Positioned(
          top: 12,
          right: 12,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.2),
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.access_time, size: 14, color: Colors.white),
                const SizedBox(width: 6),
                Text(
                  assistant.currentWibTime,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),

        if (assistant.mode == AssistantMode.asisten && assistant.shortLocationLabel.isNotEmpty)
          Positioned(
            top: 12,
            left: 12,
            right: 120, // Beri ruang untuk jam di kanan
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.secondaryColor.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.location_on, size: 14, color: Colors.white),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      assistant.shortLocationLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Autopilot overlay
        if (assistant.isAutopiloting)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: AppTheme.successColor.withValues(alpha: 0.9),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.speed, size: 16, color: Colors.white),
                  const SizedBox(width: 6),
                  Flexible(
                    child: Text(
                      assistant.autopilotInstruction.isNotEmpty
                          ? 'AUTOPILOT: ${assistant.autopilotInstruction}'
                          : 'AUTOPILOT AKTIF',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),

        // Status overlay saat processing
        if (assistant.status == AssistantStatus.capturing ||
            assistant.status == AssistantStatus.uploading ||
            assistant.status == AssistantStatus.processing)
          Container(
            color: Colors.black45,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(
                    color: Colors.white,
                  ),
                  const SizedBox(height: 12),
                  Text(
                    assistant.statusLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  /// Build chat view (mode Obrolan — tanpa kamera)
  Widget _buildChatView(AssistantProvider assistant) {
    return Container(
      color: Colors.black,
      child: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Ikon chat besar
              Icon(
                Icons.chat_bubble_outline,
                size: 72,
                color: AppTheme.accentColor.withValues(alpha: 0.6),
              ),
              const SizedBox(height: 16),
              Text(
                'Mode Obrolan',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Asisten pribadimu siap! Tanya apa aja,\ncurhat, atau sekadar ngobrol santai.',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 24),

              // Tampilkan respons terakhir jika ada
              if (assistant.lastResponse != null &&
                  assistant.lastResponse!.isSuccess)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: AppTheme.accentColor.withValues(alpha: 0.2),
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.smart_toy,
                            size: 16,
                            color: AppTheme.accentColor,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'AI',
                            style: TextStyle(
                              color: AppTheme.accentColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        assistant.lastResponse!.description,
                        style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          height: 1.4,
                        ),
                      ),
                    ],
                  ),
                ),

              // Processing indicator
              if (assistant.status == AssistantStatus.processing)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: AppTheme.accentColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Lagi mikir...',
                        style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Build voice prompt section
  Widget _buildVoicePrompt(AssistantProvider assistant) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surfaceBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: assistant.isRecording
              ? AppTheme.errorColor.withValues(alpha: 0.6)
              : AppTheme.accentColor.withValues(alpha: 0.2),
          width: assistant.isRecording ? 2 : 1,
        ),
      ),
      child: Column(
        children: [
          // Tombol mic + status
          Row(
            children: [
              // Tombol microphone
              GestureDetector(
                onTap: () => assistant.toggleVoiceInput(),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: assistant.isRecording
                        ? AppTheme.errorColor
                        : AppTheme.accentColor,
                    boxShadow: assistant.isRecording
                        ? [
                            BoxShadow(
                              color: AppTheme.errorColor.withValues(alpha: 0.4),
                              blurRadius: 12,
                              spreadRadius: 2,
                            ),
                          ]
                        : [],
                  ),
                  child: Icon(
                    assistant.isRecording ? Icons.stop : Icons.mic,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ),

              const SizedBox(width: 12),

              // Teks instruksi / hasil
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      assistant.isRecording
                          ? 'Mendengarkan...'
                          : _getVoiceHint(assistant.mode),
                      style: TextStyle(
                        color: assistant.isRecording
                            ? AppTheme.errorColor
                            : AppTheme.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    if (assistant.voiceText.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          '"${assistant.voiceText}"',
                          style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 14,
                            fontStyle: FontStyle.italic,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      )
                    else if (assistant.customPrompt.isNotEmpty &&
                        !assistant.isRecording)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text(
                          'Prompt: "${assistant.customPrompt}"',
                          style: TextStyle(
                            color: AppTheme.textMuted,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                ),
              ),

              // Recording indicator
              if (assistant.isRecording)
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.errorColor,
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  /// Dapatkan hint text sesuai mode
  String _getVoiceHint(AssistantMode mode) {
    final assistant = context.read<AssistantProvider>();
    switch (mode) {
      case AssistantMode.asisten:
        return 'Tanya apa saja, panduan arah, atau baca teks';
      case AssistantMode.autopilot:
        if (assistant.autopilotInstruction.isNotEmpty) {
          return 'Instruksi: "${assistant.autopilotInstruction}" (tekan mic untuk ganti)';
        }
        return 'Tekan mic untuk kasih perintah autopilot';
      case AssistantMode.obrolan:
        return 'Tekan mic untuk ngobrol sama asistenmu';
    }
  }

  /// Build action buttons (2 tombol: voice command + switch mode)
  Widget _buildActionButtons(AssistantProvider assistant) {
    final isIdle = assistant.status == AssistantStatus.idle;
    final isAutopiloting = assistant.isAutopiloting;
    final isBusy = !isIdle && !isAutopiloting &&
        assistant.status != AssistantStatus.listening;

    return Row(
      children: [
        // Tombol 1: Voice Command / Autopilot toggle
        Expanded(
          flex: 3,
          child: SizedBox(
            height: 56,
            child: _buildMainButton(assistant, isIdle, isAutopiloting, isBusy),
          ),
        ),

        const SizedBox(width: 12),

        // Tombol 2: Ganti Mode
        Expanded(
          flex: 2,
          child: SizedBox(
            height: 56,
            child: OutlinedButton(
              onPressed: isBusy ? null : () => assistant.switchMode(),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.accentColor,
                side: BorderSide(
                  color: AppTheme.accentColor.withValues(alpha: 0.4),
                  width: 1.5,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      _getModeIcon(assistant.mode),
                      size: 20,
                    ),
                    const SizedBox(width: 6),
                    const Text(
                      AppStrings.buttonSwitchMode,
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Build tombol utama berdasarkan mode
  Widget _buildMainButton(
    AssistantProvider assistant,
    bool isIdle,
    bool isAutopiloting,
    bool isBusy,
  ) {
    // Mode autopilot: tampilkan tombol start/stop autopilot
    if (assistant.mode == AssistantMode.autopilot) {
      return ElevatedButton(
        onPressed: (isIdle || isAutopiloting)
            ? () => assistant.toggleAutopilot()
            : null,
        style: ElevatedButton.styleFrom(
          backgroundColor: isAutopiloting
              ? AppTheme.errorColor
              : (isIdle ? AppTheme.successColor : AppTheme.surfaceBg),
          foregroundColor:
              (isIdle || isAutopiloting) ? Colors.white : AppTheme.textMuted,
          disabledBackgroundColor: AppTheme.surfaceBg,
          disabledForegroundColor: AppTheme.textMuted,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 8),
          elevation: (isIdle || isAutopiloting) ? 4 : 0,
        ),
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isAutopiloting ? Icons.stop : Icons.play_arrow,
                size: 22,
              ),
              const SizedBox(width: 6),
              Text(
                isAutopiloting
                    ? AppStrings.buttonStopAutopilot
                    : AppStrings.buttonStartAutopilot,
                style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      );
    }

    // Mode general & obrolan: tombol voice command
    return ElevatedButton(
      onPressed: !isBusy ? () => assistant.handleActionTrigger(1) : null,
      style: ElevatedButton.styleFrom(
        backgroundColor: !isBusy ? AppTheme.primaryColor : AppTheme.surfaceBg,
        foregroundColor: !isBusy ? Colors.black : AppTheme.textMuted,
        disabledBackgroundColor: AppTheme.surfaceBg,
        disabledForegroundColor: AppTheme.textMuted,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
        ),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        elevation: !isBusy ? 4 : 0,
      ),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              assistant.isRecording ? Icons.stop : Icons.mic,
              size: 22,
            ),
            const SizedBox(width: 6),
            Text(
              assistant.isRecording
                  ? 'Berhenti'
                  : (isBusy ? assistant.statusLabel : AppStrings.buttonVoiceCommand),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }

  /// Dapatkan ikon sesuai mode
  IconData _getModeIcon(AssistantMode mode) {
    switch (mode) {
      case AssistantMode.asisten:
        return Icons.visibility;
      case AssistantMode.autopilot:
        return Icons.speed;
      case AssistantMode.obrolan:
        return Icons.chat;
    }
  }


}
