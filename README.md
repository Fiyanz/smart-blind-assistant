# 🌟 Smart Blind Assistant — Sinar

Asisten cerdas berbasis AI untuk membantu penyandang tunanetra menjalani kehidupan sehari-hari secara mandiri. Menggunakan **kamera**, **AI Vision**, dan **suara** untuk mendeskripsikan lingkungan, menjawab pertanyaan, membacakan teks, dan memandu navigasi — semuanya lewat perintah suara.

Terintegrasi dengan perangkat keras **ESP32-C3** melalui Bluetooth Low Energy (BLE) sebagai remote kontrol fisik dengan 2 tombol.

---

## ✨ Fitur

| Fitur | Deskripsi |
|-------|-----------|
| 🎙️ **Perintah Suara (STT)** | Berikan instruksi lewat suara dalam Bahasa Indonesia |
| 📷 **Analisis Gambar AI** | Kamera menangkap gambar → AI mendeskripsikan/menjawab pertanyaan |
| 🔊 **Text-to-Speech** | Semua respons AI dibacakan secara otomatis |
| 🔗 **Remote BLE (ESP32)** | 2 tombol fisik: voice command & ganti mode |
| 🧭 **Navigasi GPS** | Panduan arah dengan lokasi GPS + kamera |
| 📖 **Baca Teks (OCR)** | Membacakan teks yang terlihat di kamera |
| 💬 **Mode Obrolan** | Ngobrol bebas dengan AI tanpa gambar |
| 🚗 **Mode Autopilot** | Deteksi objek otomatis berkala via ML Kit |

## 🔄 5 Mode Operasi

```
General → Autopilot → Navigasi → Obrolan → Read → (kembali ke General)
```

| Mode | Cara Kerja | Butuh Kamera |
|------|------------|:------------:|
| **General** | Ambil gambar + tanya apa saja ke AI | ✅ |
| **Autopilot** | AI otomatis analisis berkala, fokus keselamatan | ✅ |
| **Navigasi** | GPS + kamera → AI bantu arah jalan | ✅ |
| **Obrolan** | Suara → AI text-only → suara (tanpa gambar) | ❌ |
| **Read** | Ambil gambar → AI bacakan teks yang terlihat | ✅ |

## 🎮 Kontrol ESP32 (2 Tombol)

| Tombol | Aksi | BLE Command |
|--------|------|:-----------:|
| Tombol 1 | Voice command (mulai/stop rekam suara) | `0x01` |
| Tombol 2 | Ganti mode (cycle) | `0x02` |
| Tombol 1+2 | Emergency stop (hentikan semua) | `0x03` |

---

## 🏗️ Arsitektur

```
┌─────────────────┐     BLE Notify      ┌──────────────────────────┐
│   ESP32-C3      │ ──────────────────→  │     Flutter App          │
│   (Peripheral)  │  0x01 / 0x02 / 0x03 │                          │
│                 │                      │  BleService              │
│  Tombol 1 (GPIO 2)                     │    ↓                     │
│  Tombol 2 (GPIO 3)                     │  AssistantProvider       │
└─────────────────┘                      │    ├─ CameraService      │
                                         │    ├─ ApiService (AI)    │
                                         │    ├─ SttService (STT)   │
                                         │    ├─ TtsService (TTS)   │
                                         │    └─ LocationService    │
                                         └──────────────────────────┘
```

### Alur Kerja (Pipeline)

```
Tombol ESP32 → BLE → AssistantProvider → STT (rekam suara)
                                        → Capture gambar
                                        → Kirim ke AI (OpenRouter)
                                        → Terima respons
                                        → TTS (bacakan ke user)
```

## 📁 Struktur Proyek

```
smart-blind-assistant/
├── lib/
│   ├── main.dart                          # Entry point + Provider setup
│   ├── app.dart                           # MaterialApp + Theme + Routes
│   ├── core/
│   │   ├── constants/
│   │   │   ├── app_constants.dart         # BLE UUIDs, API config, TTS defaults
│   │   │   └── app_strings.dart           # Semua teks UI (Bahasa Indonesia)
│   │   ├── theme/
│   │   │   └── app_theme.dart             # Dark theme kontras tinggi
│   │   └── utils/
│   │       ├── logger.dart                # Debug logger
│   │       ├── permissions_handler.dart   # Permission BLE, Kamera, Mikrofon
│   │       ├── platform_helper.dart       # Platform check (mobile/desktop)
│   │       └── time_utils.dart            # Format waktu WIB
│   ├── models/
│   │   ├── ble_device.dart                # Model perangkat BLE
│   │   ├── capture_payload.dart           # Model payload foto + metadata
│   │   └── ai_response.dart              # Model respons AI
│   ├── services/
│   │   ├── ble_service.dart               # Komunikasi BLE dengan ESP32
│   │   ├── camera_service.dart            # Capture gambar kamera belakang
│   │   ├── tts_service.dart               # Text-to-Speech (id-ID)
│   │   ├── stt_service.dart               # Speech-to-Text (id-ID)
│   │   ├── api_service.dart               # OpenRouter API + prompt engineering
│   │   ├── location_service.dart          # GPS + geocoding
│   │   └── background_service.dart        # Foreground service (Android)
│   ├── providers/
│   │   ├── ble_provider.dart              # State koneksi BLE
│   │   ├── assistant_provider.dart        # State machine + orkestrasi pipeline
│   │   └── settings_provider.dart         # Pengaturan user (persisten)
│   ├── features/
│   │   ├── home/                          # Layar utama (2 tombol + status)
│   │   ├── scan/                          # Scan & pilih perangkat BLE
│   │   ├── settings/                      # Pengaturan TTS, API, BLE
│   │   └── log/                           # Riwayat interaksi
│   └── routes/
│       └── app_router.dart                # Routing halaman
│
└── .env                                   # OPENROUTER_API_KEY
```

## ⚙️ Teknologi

| Komponen | Teknologi |
|----------|-----------|
| Mobile App | Flutter + Dart |
| State Management | Provider |
| AI Model | Google Gemini 2.5 Flash (via OpenRouter) |
| BLE | flutter_blue_plus |
| TTS | flutter_tts (id-ID) |
| STT | speech_to_text (id-ID) |
| Kamera | camera + flutter_image_compress |
| Object Detection | Google ML Kit |
| GPS | geolocator + geocoding |
| Hardware | ESP32-C3 + NimBLE |

## 🚀 Cara Menjalankan

### Prasyarat

- Flutter SDK (versi terbaru)
- Perangkat **Android/iOS fisik** (BLE, kamera, TTS tidak tersedia di emulator)
- API Key dari [OpenRouter](https://openrouter.ai)
- *(Opsional)* ESP32-C3 + PlatformIO untuk hardware remote

### Setup App Flutter

```bash
# 1. Clone repo
git clone https://github.com/Fiyanz/smart-blind-assistant.git
cd smart-blind-assistant

# 2. Buat file .env
echo "OPENROUTER_API_KEY=sk-or-xxxx" > .env

# 3. Install dependencies
flutter pub get

# 4. Jalankan di perangkat fisik
flutter run
```

### Setup Firmware ESP32

Firmware ESP32-C3 dipisah ke repo tersedia di:

**https://github.com/Fiyanz/hardware-smart-blind-assistant**

Ikuti petunjuk build & flash di repo tersebut.

> **Catatan**: Setelah flash, ESP32 akan muncul di BLE scan sebagai **"SightAssist-ESP32"**. Hubungkan dari halaman Scan di app Flutter.

## 🔧 Konfigurasi

| Parameter | File | Default |
|-----------|------|---------|
| API Key | `.env` | — |
| AI Model | `app_constants.dart` | `google/gemini-2.5-flash` |
| BLE Service UUID | `app_constants.dart` | `4fafc201-...` |
| BLE Char UUID | `app_constants.dart` | `beb5483e-...` |
| Bahasa TTS | `app_constants.dart` | `id-ID` |
| Kecepatan TTS | `app_constants.dart` | `0.5` |
| Tombol Voice (ESP32) | [hardware repo](https://github.com/Fiyanz/hardware-smart-blind-assistant) | GPIO 2 |
| Tombol Mode (ESP32) | [hardware repo](https://github.com/Fiyanz/hardware-smart-blind-assistant) | GPIO 3 |

## 📋 Perintah Development

```bash
flutter pub get          # Install dependencies
flutter analyze          # Static analysis
flutter test             # Jalankan widget tests
flutter run              # Jalankan di device
```

## 📄 Lisensi

MIT License
