# PixMind

**PixMind** is an offline-first, AI-powered photo gallery built with Flutter.  
It brings intelligent photo search and organization directly to the device, so users can explore their gallery using AI without sending personal photos to the cloud.

---

## ✨ What PixMind Can Do

### 🔎 Smart Photo Search
PixMind can search and organize photos using multiple types of visual information:

- **Visual similarity search** — choose a photo and find the most visually similar images.
- **Object detection** — recognize common objects inside photos.
- **OCR** — extract searchable text from images.
- **Face analysis** — detect faces and support person-based organization.
- **Metadata search** — use information already stored with each photo.

### 🖼️ Visual Similarity Search
The visual search pipeline works completely on-device:

```text
Image
  ↓
EfficientNetB0
  ↓
1280-D image embedding
  ↓
Image Projection Model
  ↓
256-D normalized embedding
  ↓
Similarity comparison
```

Each image embedding is stored locally in SQLite, so already indexed photos do not need to be processed again.

Search results are displayed in two sections:

- **Top 10 Matches** — the closest visual results.
- **Other Results** — remaining photos ordered by similarity.

### 👥 People & Smart Albums
PixMind includes tools for working with faces and albums, including:

- Face detection
- Person-based photo grouping
- Smart album organization
- Copying and moving photos between albums

### 📝 OCR
Text inside images can be extracted and used for search, making screenshots, documents, posters, and other text-heavy photos easier to find.

### 🎯 Object Detection
Object detection helps PixMind understand the contents of a photo and improves intelligent search and organization.

---

## 🔐 Privacy First

PixMind is designed as an **offline-first application**.

AI inference is performed directly on the Android device. Personal gallery images do not need to be uploaded to an external server for analysis.

This provides:

- Better privacy
- Offline availability
- No dependency on cloud AI services
- Local control over indexed data

---

## 🧠 AI Models

PixMind uses lightweight models suitable for on-device inference.

Current AI components include:

| Task | Model / Technology |
|---|---|
| Visual image encoder | EfficientNetB0 |
| Visual projection | Custom TFLite projection model |
| Visual embedding size | 256 dimensions |
| Object detection | YOLO |
| Face embeddings | MobileFaceNet |
| OCR | On-device OCR pipeline |
| Inference runtime | TensorFlow Lite / LiteRT |

Visual search uses **L2-normalized embeddings** and cosine-style similarity through the dot product between normalized vectors.

---

## 🛠️ Tech Stack

- **Flutter**
- **Dart**
- **Android**
- **TensorFlow Lite / LiteRT**
- **SQLite / sqflite**
- **Photo Manager**
- **Riverpod**
- **GoRouter**

---

## 📁 Project Structure

A simplified view of the project:

```text
lib/
├── core/
│   ├── router/
│   └── theme/
│
├── data/
│   ├── database/
│   ├── models/
│   └── repositories/
│
├── features/
│   ├── albums/
│   ├── detail/
│   ├── home/
│   ├── people/
│   ├── search/
│   └── visual_search/
│       ├── similar_images_screen.dart
│       ├── visual_embedding_service.dart
│       ├── visual_search_config.dart
│       ├── visual_search_indexer.dart
│       └── visual_search_repository.dart
│
└── services/
    └── ai/
```

---

## 📦 Visual Search Models

The visual search models are expected under:

```text
assets/models/visual_search/
├── EfficientNetB0_quant.tflite
└── image_projection.tflite
```

Other AI models are stored under:

```text
assets/models/
```

Make sure the corresponding asset directories are included in `pubspec.yaml`.

---

## 🚀 Running the Project

### Requirements

Before running PixMind, make sure you have:

- Flutter SDK
- Android SDK
- JDK 17
- An Android device or emulator

Check your setup:

```bash
flutter doctor -v
```

Install dependencies:

```bash
flutter pub get
```

Check the project:

```bash
flutter analyze
```

Run on a connected Android device:

```bash
flutter devices
flutter run
```

---

## 🔍 Using Visual Search

1. Open the main gallery.
2. Open any image.
3. Tap the **Search Similar Images** button.
4. If the gallery has not been fully indexed, tap **Complete Photo Indexing**.
5. PixMind calculates and stores embeddings for missing images.
6. Similar images are shown from the closest result to the least similar.

Previously indexed images reuse their stored embeddings instead of running the model again.

---

## 💾 Local Indexing

PixMind stores visual embeddings locally in SQLite.

The visual search table keeps:

- Asset ID
- Embedding data
- Embedding dimension
- Model version
- Last update time

Using a model version allows the application to distinguish embeddings produced by different versions of the AI pipeline.

---

## ⚙️ Android Notes

PixMind uses native AI libraries on Android.

If TensorFlow Lite reports an error related to:

```text
libtensorflowlite_jni.so
```

make sure the required native libraries are present under the Android `jniLibs` directories for the supported architectures.

The Android build is configured to use **JDK 17**.

---

## 🎯 Project Goal

PixMind explores how modern AI features can be integrated into a mobile gallery while keeping the application practical, private, and fully usable offline.

The project focuses on combining:

**Mobile Development + Computer Vision + Local AI + Intelligent Search**

into one unified photo-management experience.

---

## 🚧 Development Status

PixMind is under active development.

Current work focuses on:

- Improving visual search quality and indexing speed
- Improving face grouping
- Improving OCR accuracy
- Expanding intelligent multi-criteria search
- Improving performance on mid-range Android devices

---

## 🤝 Contributions

Contributions, suggestions, and improvements are welcome.

If you find an issue or have an idea, feel free to open an issue or submit a pull request.

---

## 📄 License

This project is intended for educational and development purposes.  
Add the appropriate license file before distributing or publishing production builds.

---

<p align="center">
  <b>PixMind — Your gallery, understood by AI.</b>
</p>
