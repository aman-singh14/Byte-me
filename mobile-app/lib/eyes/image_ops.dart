// The few OpenCV / NumPy operations the laptop's eye code uses, in plain
// Dart, on grey frames: percentiles, Gaussian and median blur, opening,
// connected components and convex hulls. Each one behaves like its OpenCV
// namesake (same kernel sizes, same borders), so lib/eyes/pupil.dart can
// follow backend/pupil.py and backend/eye_tracking.py line by line.

import 'dart:math' as math;
import 'dart:typed_data';

/// A grey frame, one byte per pixel, row by row.
class Grey {
  Grey(this.width, this.height, this.px) : assert(px.length == width * height);
  final int width, height;
  final Uint8List px;
}

/// np.percentile (linear interpolation) of bytes, for each of [ps] (0..100).
List<double> bytePercentiles(Uint8List a, List<double> ps) {
  final hist = Int32List(256);
  for (final v in a) {
    hist[v]++;
  }
  double at(int rank) {
    var seen = 0;
    for (var v = 0; v < 256; v++) {
      seen += hist[v];
      if (seen > rank) return v.toDouble();
    }
    return 255;
  }

  return [
    for (final p in ps)
      () {
        final r = p / 100 * (a.length - 1);
        final lo = r.floor();
        return at(lo) + (at(math.min(lo + 1, a.length - 1)) - at(lo)) * (r - lo);
      }(),
  ];
}

/// np.quantile (0..1) of floats. Binned finely rather than sorted, which is
/// much faster per frame and off by at most 1/16384 of the value range.
List<double> quantiles(Float32List a, List<double> qs) {
  var lo = double.infinity, hi = -double.infinity;
  for (final v in a) {
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  if (!(hi > lo)) return [for (final _ in qs) lo];
  const bins = 16384;
  final scale = (bins - 1) / (hi - lo);
  final hist = Int32List(bins);
  for (final v in a) {
    hist[((v - lo) * scale).toInt()]++;
  }
  double at(int rank) {
    var seen = 0;
    for (var b = 0; b < bins; b++) {
      if (seen + hist[b] > rank) return lo + (b + (rank - seen + 0.5) / hist[b]) / scale;
      seen += hist[b];
    }
    return hi;
  }

  return [
    for (final q in qs)
      () {
        final r = q * (a.length - 1);
        final i = r.floor();
        return at(i) + (at(math.min(i + 1, a.length - 1)) - at(i)) * (r - i);
      }(),
  ];
}

/// The median of a short list (np.median).
double median(List<double> a) {
  final s = [...a]..sort();
  final n = s.length;
  return n.isOdd ? s[n ~/ 2] : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2;
}

/// np.percentile of a short list.
double percentile(Iterable<double> a, double p) {
  final s = [...a]..sort();
  final r = p / 100 * (s.length - 1);
  final i = r.floor();
  return s[i] + (s[math.min(i + 1, s.length - 1)] - s[i]) * (r - i);
}

int _reflect101(int i, int n) {
  if (n == 1) return 0;
  while (i < 0 || i >= n) {
    i = i < 0 ? -i : 2 * n - 2 - i;
  }
  return i;
}

/// cv2.GaussianBlur(src, (0, 0), sigma) on a float picture: kernel size
/// round(8 sigma + 1) | 1, borders reflected (BORDER_REFLECT_101).
Float32List gaussianBlur(Float32List src, int w, int h, double sigma) {
  final k = (sigma * 8 + 1).round() | 1, r = k ~/ 2;
  final kernel = Float64List(k);
  var sum = 0.0;
  for (var i = 0; i < k; i++) {
    sum += kernel[i] = math.exp(-((i - r) * (i - r)) / (2 * sigma * sigma));
  }
  for (var i = 0; i < k; i++) {
    kernel[i] /= sum;
  }
  final tmp = Float32List(w * h), out = Float32List(w * h);
  final xs = Int32List(w + 2 * r), ys = Int32List(h + 2 * r);
  for (var i = 0; i < xs.length; i++) {
    xs[i] = _reflect101(i - r, w);
  }
  for (var i = 0; i < ys.length; i++) {
    ys[i] = _reflect101(i - r, h);
  }
  for (var y = 0; y < h; y++) {
    final row = y * w;
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var i = 0; i < k; i++) {
        acc += kernel[i] * src[row + xs[x + i]];
      }
      tmp[row + x] = acc;
    }
  }
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var acc = 0.0;
      for (var i = 0; i < k; i++) {
        acc += kernel[i] * tmp[ys[y + i] * w + x];
      }
      out[y * w + x] = acc;
    }
  }
  return out;
}

/// cv2.medianBlur(src, 5): borders repeat the edge pixel.
Uint8List medianBlur5(Uint8List src, int w, int h) {
  final out = Uint8List(w * h), win = Int32List(25);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      var n = 0;
      for (var dy = -2; dy <= 2; dy++) {
        final row = (y + dy).clamp(0, h - 1) * w;
        for (var dx = -2; dx <= 2; dx++) {
          win[n++] = src[row + (x + dx).clamp(0, w - 1)];
        }
      }
      // Insertion sort is quick for 25 nearly random bytes; the middle one is the median.
      for (var i = 1; i < 25; i++) {
        final v = win[i];
        var j = i - 1;
        while (j >= 0 && win[j] > v) {
          win[j + 1] = win[j];
          j--;
        }
        win[j + 1] = v;
      }
      out[y * w + x] = win[12];
    }
  }
  return out;
}

/// The offsets of cv2.getStructuringElement(MORPH_ELLIPSE, (k, k)).
List<(int, int)> _ellipse(int k) {
  final r = k ~/ 2, c = k ~/ 2, out = <(int, int)>[];
  for (var i = 0; i < k; i++) {
    final dy = i - r;
    if (dy.abs() > r) continue;
    final dx = (c * math.sqrt((r * r - dy * dy) / (r * r))).round();
    for (var j = math.max(c - dx, 0); j < math.min(c + dx + 1, k); j++) {
      out.add((j - c, dy));
    }
  }
  return out;
}

/// cv2.morphologyEx(mask, MORPH_OPEN, ellipse k x k) on a 0/1 mask: erode,
/// then dilate. Pixels outside the picture never count (OpenCV's default).
Uint8List open(Uint8List mask, int w, int h, int k) {
  final offs = _ellipse(k);
  Uint8List pass(Uint8List src, bool erode) {
    final out = Uint8List(w * h);
    for (var y = 0; y < h; y++) {
      for (var x = 0; x < w; x++) {
        var v = erode ? 1 : 0;
        for (final (dx, dy) in offs) {
          final xx = x + dx, yy = y + dy;
          if (xx < 0 || yy < 0 || xx >= w || yy >= h) continue;
          final s = src[yy * w + xx];
          if (erode ? s == 0 : s != 0) {
            v = erode ? 0 : 1;
            break;
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  return pass(pass(mask, true), false);
}

/// One connected region of a mask.
class Blob {
  Blob(this.label);
  final int label;
  int area = 0;
  int x0 = 1 << 30, y0 = 1 << 30, x1 = -1, y1 = -1;

  int get width => x1 - x0 + 1;
  int get height => y1 - y0 + 1;
}

/// cv2.connectedComponentsWithStats(mask) (8-connected): the label of every
/// pixel (0 = background) and each region's box and area.
(Int32List, List<Blob>) components(Uint8List mask, int w, int h) {
  final labels = Int32List(w * h), blobs = <Blob>[];
  final stack = Int32List(w * h);
  for (var start = 0; start < w * h; start++) {
    if (mask[start] == 0 || labels[start] != 0) continue;
    final b = Blob(blobs.length + 1);
    blobs.add(b);
    var top = 0;
    stack[top++] = start;
    labels[start] = b.label;
    while (top > 0) {
      final p = stack[--top], x = p % w, y = p ~/ w;
      b.area++;
      if (x < b.x0) b.x0 = x;
      if (x > b.x1) b.x1 = x;
      if (y < b.y0) b.y0 = y;
      if (y > b.y1) b.y1 = y;
      for (var dy = -1; dy <= 1; dy++) {
        final yy = y + dy;
        if (yy < 0 || yy >= h) continue;
        for (var dx = -1; dx <= 1; dx++) {
          final xx = x + dx;
          if (xx < 0 || xx >= w) continue;
          final q = yy * w + xx;
          if (mask[q] != 0 && labels[q] == 0) {
            labels[q] = b.label;
            stack[top++] = q;
          }
        }
      }
    }
  }
  return (labels, blobs);
}

/// The convex hull (counter-clockwise, no collinear points) of the pixel
/// centres labelled [label] inside [b]'s box: cv2.convexHull of its contour.
List<math.Point<double>> hullOf(Int32List labels, int w, Blob b) {
  final pts = <math.Point<double>>[];
  for (var y = b.y0; y <= b.y1; y++) {
    int? first, last;
    for (var x = b.x0; x <= b.x1; x++) {
      if (labels[y * w + x] == b.label) {
        first ??= x;
        last = x;
      }
    }
    if (first != null) {
      pts.add(math.Point(first.toDouble(), y.toDouble()));
      if (last != first) pts.add(math.Point(last!.toDouble(), y.toDouble()));
    }
  }
  return convexHull(pts);
}

/// Andrew's monotone chain.
List<math.Point<double>> convexHull(List<math.Point<double>> points) {
  final p = [...points]..sort((a, b) => a.x != b.x ? a.x.compareTo(b.x) : a.y.compareTo(b.y));
  if (p.length < 3) return p;
  double cross(math.Point<double> o, math.Point<double> a, math.Point<double> b) =>
      (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x);
  final lower = <math.Point<double>>[], upper = <math.Point<double>>[];
  for (final q in p) {
    while (lower.length >= 2 && cross(lower[lower.length - 2], lower.last, q) <= 0) {
      lower.removeLast();
    }
    lower.add(q);
  }
  for (final q in p.reversed) {
    while (upper.length >= 2 && cross(upper[upper.length - 2], upper.last, q) <= 0) {
      upper.removeLast();
    }
    upper.add(q);
  }
  return [...lower.sublist(0, lower.length - 1), ...upper.sublist(0, upper.length - 1)];
}

/// cv2.contourArea of a polygon.
double polygonArea(List<math.Point<double>> p) {
  var a = 0.0;
  for (var i = 0; i < p.length; i++) {
    final q = p[(i + 1) % p.length];
    a += p[i].x * q.y - q.x * p[i].y;
  }
  return a.abs() / 2;
}

/// cv2.arcLength(polygon, closed: true).
double perimeter(List<math.Point<double>> p) {
  var l = 0.0;
  for (var i = 0; i < p.length; i++) {
    l += p[i].distanceTo(p[(i + 1) % p.length]);
  }
  return l;
}

/// The centre of mass of a filled polygon (cv2.moments m10/m00, m01/m00),
/// or null for a degenerate one.
math.Point<double>? polygonCentroid(List<math.Point<double>> p) {
  var a = 0.0, cx = 0.0, cy = 0.0;
  for (var i = 0; i < p.length; i++) {
    final q = p[(i + 1) % p.length];
    final c = p[i].x * q.y - q.x * p[i].y;
    a += c;
    cx += (p[i].x + q.x) * c;
    cy += (p[i].y + q.y) * c;
  }
  if (a.abs() < 1e-9) return null;
  return math.Point(cx / (3 * a), cy / (3 * a));
}

/// cv2.resize(INTER_AREA) for shrinking: each output pixel averages its box.
Uint8List shrink(Uint8List src, int w, int h, int ow, int oh) {
  if (w == ow && h == oh) return src;
  final out = Uint8List(ow * oh);
  for (var y = 0; y < oh; y++) {
    final sy0 = y * h ~/ oh, sy1 = math.max(sy0 + 1, (y + 1) * h ~/ oh);
    for (var x = 0; x < ow; x++) {
      final sx0 = x * w ~/ ow, sx1 = math.max(sx0 + 1, (x + 1) * w ~/ ow);
      var sum = 0;
      for (var yy = sy0; yy < sy1; yy++) {
        for (var xx = sx0; xx < sx1; xx++) {
          sum += src[yy * w + xx];
        }
      }
      out[y * ow + x] = (sum / ((sy1 - sy0) * (sx1 - sx0))).round();
    }
  }
  return out;
}
