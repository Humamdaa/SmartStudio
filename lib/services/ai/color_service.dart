import 'dart:typed_data';

import 'package:image/image.dart' as img;

class ColorService {
  ColorService._();

  static List<String> dominantColors(Uint8List imageBytes) {
    final image = img.decodeImage(imageBytes);
    if (image == null || image.width == 0 || image.height == 0) {
      return const [];
    }

    final counts = <String, int>{};
    var samples = 0;
    final stepX = image.width > 40 ? image.width ~/ 40 : 1;
    final stepY = image.height > 40 ? image.height ~/ 40 : 1;

    for (var y = 0; y < image.height; y += stepY) {
      for (var x = 0; x < image.width; x += stepX) {
        final pixel = image.getPixel(x, y);
        if (pixel.a.toDouble() < 80) continue;
        final label = _classify(
          pixel.r.toDouble(),
          pixel.g.toDouble(),
          pixel.b.toDouble(),
        );
        counts[label] = (counts[label] ?? 0) + 1;
        samples++;
      }
    }

    if (samples == 0) return const [];
    final ranked = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return ranked
        .where((entry) => entry.value / samples >= 0.10)
        .take(3)
        .map((entry) => entry.key)
        .toList(growable: false);
  }

  static String _classify(double r, double g, double b) {
    final max = [r, g, b].reduce((a, value) => a > value ? a : value);
    final min = [r, g, b].reduce((a, value) => a < value ? a : value);
    final delta = max - min;

    if (max < 42) return 'black';
    if (min > 218 && delta < 28) return 'white';
    if (delta < 20) return 'gray';

    final saturation = max == 0 ? 0 : delta / max;
    if (saturation < 0.16) {
      return max > 185 ? 'white' : 'gray';
    }

    double hue;
    if (max == r) {
      hue = 60 * (((g - b) / delta) % 6);
    } else if (max == g) {
      hue = 60 * (((b - r) / delta) + 2);
    } else {
      hue = 60 * (((r - g) / delta) + 4);
    }
    if (hue < 0) hue += 360;

    if (hue < 15 || hue >= 345) return 'red';
    if (hue < 42) {
      return max < 155 ? 'brown' : 'orange-color';
    }
    if (hue < 68) return 'yellow';
    if (hue < 165) return 'green';
    if (hue < 195) return 'cyan';
    if (hue < 255) return 'blue';
    if (hue < 290) return 'purple';
    if (hue < 345) return 'pink';
    return 'red';
  }
}
