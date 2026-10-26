# Running PES 2017 Recompiled on macOS

Panduan instalasi, kompilasi, dan penggunaan native **PES 2017 (Pro Evolution Soccer 2017)** di sistem operasi macOS (Apple Silicon ARM64 & Intel x86_64).

---

## 1. System Requirements (Persyaratan Sistem)

- **OS**: macOS 12 (Monterey), macOS 13 (Ventura), macOS 14 (Sonoma), atau macOS 15 (Sequoia).
- **Arsitektur**:
  - **Apple Silicon** (M1, M2, M3, M4 - Pro / Max / Ultra / Base) - *Sangat Direkomendasikan (60 FPS stabil)*
  - **Intel Mac** (Core i5 / i7 / i9 dengan dukungan Metal 2+)
- **RAM**: Minimal 8 GB RAM (Direkomendasikan 16 GB).
- **Game Files**: Salinan retail disc Xbox 360 PES 2017 (file `default.xex` dan folder game, atau ISO retail).

---

## 2. Persiapan Dependensi (Prerequisites)

Gunakan [Homebrew](https://brew.sh) untuk menginstal pustaka yang dibutuhkan:

```bash
# 1. Install Command Line Tools Apple (jika belum)
xcode-select --install

# 2. Install dependensi via Homebrew
brew install cmake ninja molten-vk sdl3 vulkan-headers python3
```

> [!NOTE]
> Pada Apple Silicon, Homebrew berada di `/opt/homebrew`. Pada Intel Mac, Homebrew berada di `/usr/local`. Skrip kompilasi otomatis mendeteksi lokasi tersebut.

---

## 3. Menyiapkan File Game Xbox 360

Ada dua cara untuk menyediakan file game:

### Cara A: Ekstrak `default.xex` ke folder `pes/` (Otomatis Rekompilasi Penuh)
Salin file `default.xex` dari disc Xbox 360 Anda ke dalam folder `pes/`:
```bash
mkdir -p pes
cp /path/to/extracted/disc/default.xex pes/default.xex
```

### Cara B: Menggunakan Launcher GUI
Jika Anda belum mengekstrak game, Anda cukup membangun Launcher terlebih dahulu. Launcher akan menyediakan antarmuka grafis untuk memilih disc ISO atau folder game.

---

## 4. Cara Menjalankan & Menghasilkan `PES 2017.app`

Tersedia 3 cara termudah:

### Cara 1: Dobel-Klik `Run-PES2017.command` (Paling Praktis)
Jika Anda memiliki folder repositori ini di Mac:
1. Buka folder repositori di **Finder**.
2. **Klik dua kali** pada file **`Run-PES2017.command`**.
3. Terminal akan terbuka dan secara otomatis memasang dependensi yang belum ada, melakukan kompilasi native, membuat bundle **`PES 2017.app`**, dan langsung meluncurkannya!

### Cara 2: Download Otomatis dari GitHub Actions (Tanpa Build Manual)
Setiap update pada repositori ini otomatis dibangun oleh **GitHub Actions** menggunakan mesin Apple Silicon (`macos-14`) dan Intel (`macos-13`):
1. Buka tab **Actions** di repositori GitHub Anda.
2. Pilih workflow **Build macOS App** terbaru.
3. Unduh artifact **`PES-2017-macOS-AppleSilicon`** (untuk Mac M1/M2/M3/M4) atau **`PES-2017-macOS-Intel`** (untuk Mac Intel).
4. Ekstrak zip, lalu langsung dobel-klik **`PES 2017.app`**.

### Cara 3: Kompilasi Manual via Terminal
Gunakan skrip otomatis [`build-macos.sh`](file:///content/gdrive/MyDrive/GITHUB/pes2017-recomp/build-macos.sh):

```bash
# Memberikan izin eksekusi skrip (jika perlu)
chmod +x build-macos.sh tools/package_macos.sh

# Jalankan proses kompilasi native
./build-macos.sh
```

### Opsi Tambahan:
- **Membangun dan langsung membuat Application Bundle (`PES 2017.app`)**:
  ```bash
  ./build-macos.sh --package
  ```
- **Kompilasi dengan optimasi register tertentu**:
  ```bash
  PROFILE=balanced ./build-macos.sh       # Default, stabil dan cepat (-18% overhead)
  PROFILE=aggressive ./build-macos.sh     # Maksimal performa (-31% overhead)
  ```
- **Menentukan jumlah core prosesor**:
  ```bash
  JOBS=8 ./build-macos.sh
  ```

---

## 5. Membuat Application Bundle (`PES 2017.app`)

Jika Anda ingin membungkus binary hasil kompilasi menjadi aplikasi macOS resmi yang dapat dibuka langsung dari Finder:

```bash
./tools/package_macos.sh build-macos
```

Perintah ini akan membuat `PES 2017.app` yang berisi:
- `Contents/MacOS/PES2017_Runner`: Skrip loader dengan environment MoltenVK otomatis.
- `Contents/MacOS/pes17-launcher`: GUI launcher resmi.
- `Contents/MacOS/pes17-sp`: Game binary native.
- `Contents/Resources/PES2017.icns`: Ikon resolusi tinggi macOS.
- `Contents/Info.plist`: Metadata bundle Retina/HiDPI.

Untuk membuat file disk image `.dmg`:
```bash
./tools/package_macos.sh build-macos --dmg
```

---

## 6. Menjalankan Game (Running & Controls)

### Menjalankan via Finder:
Klik dua kali pada `PES 2017.app`.

### Menjalankan via Terminal:
```bash
./build-macos/launcher/pes17-launcher
```

### Dukungan Controller (Gamepad):
PES 2017 Recompiled menggunakan SDL3 yang mendukung plug-and-play untuk berbagai gamepad di macOS tanpa driver tambahan:
- **Sony PlayStation DualSense (PS5) & DualShock 4 (PS4)** (Bluetooth / USB)
- **Xbox Wireless Controller (Series X|S & Xbox One)** (Bluetooth / USB)
- **Nintendo Switch Pro Controller**
- **Keyboard & Mouse**

---

## 7. Troubleshooting & FAQ

### Q: Muncul peringatan *"PES 2017.app cannot be opened because the developer cannot be verified"* (Gatekeeper)?
Buka terminal dan hapus atribut karantina macOS:
```bash
xattr -cr "PES 2017.app"
```
Atau buka **System Settings > Privacy & Security**, lalu klik **Open Anyway**.

### Q: MoltenVK tidak ditemukan saat game dijalankan?
Pastikan MoltenVK telah terinstal via Homebrew:
```bash
brew install molten-vk
```
Bundle `PES 2017.app` otomatis memeriksa `/opt/homebrew/share/vulkan/icd.d/MoltenVK_icd.json` atau `/usr/local/share/vulkan/icd.d/MoltenVK_icd.json`.

Jika Anda menginstal Vulkan SDK resmi dari LunarG, Anda dapat mengekspor:
```bash
export VULKAN_SDK=~/VulkanSDK/1.3.x.x/macOS
export VK_DRIVER_FILES="$VULKAN_SDK/share/vulkan/icd.d/MoltenVK_icd.json"
```

### Q: Bagaimana performa di Apple Silicon (M1/M2/M3/M4)?
PES 2017 Recompiled berjalan sebagai kode ARM64 native (bukan emulasi instruksi x86 atau JIT runtime), sehingga overhead CPU sangat rendah. Grafis diterjemahkan ke Apple Metal melalui Vulkan/MoltenVK dengan native framerate 60 FPS pada resolusi 1080p / 1440p / 4K.
