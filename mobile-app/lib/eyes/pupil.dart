// The eye camera's pupil, on the phone: a port of the laptop's close-up eye
// method (backend/pupil.py locate() and backend/eye_tracking.py CloseupEye),
// step for step. test/eye_parity_test.dart runs both on the same frames
// (tools/make_eye_fixtures.py) and expects the same answers.
//
//   blob    threshold just above the darkest pixels, open away the lashes,
//           keep the round dark region near the last pupil. Its area against
//           the pupil's full area is how open the eye is (blinks, squints).
//   mass    where the pupil is and what shape its dark mass has, whatever the
//           lighting (gaze): ramp, exposure and contrast removed first.

import 'dart:math' as math;
import 'dart:typed_data';

import 'image_ops.dart';

const workW = 320, workH = 240;

/// The least each feature of [PupilFix.vector] is treated as steady (pupil.py FEATURE_FLOORS).
const featureFloors = [0.04, 0.02, 0.012, 0.07, 0.012, 0.045, 0.055, 0.035];
const _coreFrac = 0.8;

class PupilFix {
  const PupilFix({
    required this.x,
    required this.y,
    required this.contrast,
    required this.area,
    required this.aspect,
    required this.solidity,
    required this.leftEdge,
    required this.coreArea,
    required this.coreX,
    required this.coreY,
    required this.elong,
  });

  final double x, y; // 0..1 across and down the frame
  final double contrast, area, aspect, solidity, leftEdge, coreArea, coreX, coreY, elong;

  /// (x, y) in -1..1.
  (double, double) get signed => (2 * x - 1, 2 * y - 1);

  /// Position + shape (pupil.py FEATURE_NAMES).
  List<double> get vector => [
    2 * x - 1,
    2 * y - 1,
    leftEdge,
    contrast,
    coreArea,
    math.log(math.max(elong, 1e-3)),
    2 * coreX - 1,
    2 * coreY - 1,
  ];
}

/// pupil.normalize: 0..1 picture with the light ramp, exposure and contrast removed.
Float32List normalize(Grey frame) {
  final g8 = shrink(frame.px, frame.width, frame.height, workW, workH);
  // Fit a plane to every 2nd pixel, leaving out the pupil (darkest) and the glints (brightest).
  final sub = Uint8List((workW ~/ 2) * (workH ~/ 2));
  var n = 0;
  for (var y = 0; y < workH; y += 2) {
    for (var x = 0; x < workW; x += 2) {
      sub[n++] = g8[y * workW + x];
    }
  }
  final [lo, hi] = bytePercentiles(sub, [30, 97]);
  var kept = 0;
  for (final v in sub) {
    if (v >= lo && v <= hi) kept++;
  }
  // Normal equations of [x/W, y/H, 1] . coef = grey.
  final ata = List.generate(3, (_) => Float64List(3)), atb = Float64List(3);
  n = 0;
  for (var y = 0; y < workH; y += 2) {
    for (var x = 0; x < workW; x += 2) {
      final v = sub[n++];
      if (kept >= 50 && (v < lo || v > hi)) continue;
      final row = [x / workW, y / workH, 1.0];
      for (var i = 0; i < 3; i++) {
        for (var j = 0; j < 3; j++) {
          ata[i][j] += row[i] * row[j];
        }
        atb[i] += row[i] * v;
      }
    }
  }
  final c = _solve3(ata, atb);
  final planeMean = c[0] * (workW - 1) / 2 / workW + c[1] * (workH - 1) / 2 / workH + c[2];
  final g = Float32List(workW * workH);
  for (var y = 0; y < workH; y++) {
    for (var x = 0; x < workW; x++) {
      final plane = c[0] * x / workW + c[1] * y / workH + c[2];
      g[y * workW + x] = g8[y * workW + x] - plane + planeMean;
    }
  }
  final [p2, p98] = quantiles(g, [0.02, 0.98]);
  final range = math.max(p98 - p2, 12.0); // 12 grey levels: flat frames stay flat
  for (var i = 0; i < g.length; i++) {
    g[i] = ((g[i] - p2) / range).clamp(0.0, 1.0);
  }
  return g;
}

List<double> _solve3(List<Float64List> a, Float64List b) {
  double det(List<List<double>> m) =>
      m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1]) -
      m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0]) +
      m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0]);
  final d = det(a);
  if (d.abs() < 1e-12) return [0, 0, b[2] / math.max(a[2][2], 1)];
  return [
    for (var col = 0; col < 3; col++)
      det([
            for (var r = 0; r < 3; r++) [for (var k = 0; k < 3; k++) k == col ? b[r] : a[r][k]],
          ]) /
          d,
  ];
}

/// pupil.locate: the pupil's dark mass, or null when there isn't one (eye
/// closed, nothing dark, a thin dark line such as lashes).
PupilFix? locate(
  Grey frame, {
  double blur = 7.0,
  double frac = 0.5,
  double minContrast = 0.25,
  double minArea = 0.004,
  double maxArea = 0.45,
  double maxAspect = 3.5,
}) {
  final n = normalize(frame);
  for (var i = 0; i < n.length; i++) {
    n[i] = 1 - n[i];
  }
  final d = gaussianBlur(n, workW, workH, blur); // blurring 1 - n is 1 - blurring n
  final [base, peak] = quantiles(d, [0.5, 0.995]);
  final contrast = peak - base;
  if (contrast < minContrast) return null;
  final thr = base + frac * contrast;
  final mask = Uint8List(d.length);
  for (var i = 0; i < d.length; i++) {
    if (d[i] >= thr) mask[i] = 1;
  }
  final (labels, blobs) = components(mask, workW, workH);
  // Pupil-like candidates only (not tiny, not huge, not a long thin band), then the darkest by mass.
  final mass = Float64List(blobs.length + 1);
  for (var i = 0; i < d.length; i++) {
    if (labels[i] != 0) mass[labels[i]] += d[i];
  }
  Blob? best;
  for (final b in blobs) {
    final area = b.area / (workW * workH), aspect = b.width / math.max(b.height, 1);
    if (area < minArea || area > maxArea || aspect < 1 / maxAspect || aspect > maxAspect) continue;
    if (best == null || mass[b.label] > mass[best.label]) best = b;
  }
  if (best == null) return null;

  var total = 0.0, sx = 0.0, sy = 0.0;
  for (var y = best.y0; y <= best.y1; y++) {
    for (var x = best.x0; x <= best.x1; x++) {
      final i = y * workW + x;
      if (labels[i] != best.label) continue;
      final w = d[i] - thr;
      total += w;
      sx += w * x;
      sy += w * y;
    }
  }
  if (total <= 0) return null;
  final cx = sx / total, cy = sy / total;
  var vx = 0.0, vy = 0.0, cxy = 0.0;
  for (var y = best.y0; y <= best.y1; y++) {
    for (var x = best.x0; x <= best.x1; x++) {
      final i = y * workW + x;
      if (labels[i] != best.label) continue;
      final w = d[i] - thr;
      vx += w * (x - cx) * (x - cx);
      vy += w * (y - cy) * (y - cy);
      cxy += w * (x - cx) * (y - cy);
    }
  }
  vx /= total;
  vy /= total;
  cxy /= total;
  // Eigenvalues of [[vx, cxy], [cxy, vy]]: how long and how wide the mass is.
  final mid = (vx + vy) / 2, spread = math.sqrt(math.max(((vx - vy) / 2) * ((vx - vy) / 2) + cxy * cxy, 0));
  final elong = math.sqrt(math.max(mid + spread, 1e-9) / math.max(mid - spread, 1e-9));
  final hull = polygonArea(hullOf(labels, workW, best));
  final solidity = best.area / math.max(hull, 1.0);

  // The darkest core inside the mass: only the strongest 20% of darkness.
  final coreThr = base + _coreFrac * contrast;
  final coreMask = Uint8List(d.length);
  for (var i = 0; i < d.length; i++) {
    if (labels[i] == best.label && d[i] >= coreThr) coreMask[i] = 1;
  }
  final (coreLabels, cores) = components(coreMask, workW, workH);
  var coreArea = 0.0, coreX = cx / workW, coreY = cy / workH;
  if (cores.isNotEmpty) {
    final coreMass = Float64List(cores.length + 1);
    for (var i = 0; i < d.length; i++) {
      if (coreLabels[i] != 0) coreMass[coreLabels[i]] += d[i];
    }
    final bc = cores.reduce((a, b) => coreMass[b.label] > coreMass[a.label] ? b : a);
    var tc = 0.0, tx = 0.0, ty = 0.0;
    for (var y = bc.y0; y <= bc.y1; y++) {
      for (var x = bc.x0; x <= bc.x1; x++) {
        final i = y * workW + x;
        if (coreLabels[i] != bc.label) continue;
        final w = d[i] - coreThr;
        tc += w;
        tx += w * x;
        ty += w * y;
      }
    }
    coreArea = bc.area / (workW * workH);
    if (tc > 0) {
      coreX = tx / tc / workW;
      coreY = ty / tc / workH;
    }
  }
  return PupilFix(
    x: cx / workW,
    y: cy / workH,
    contrast: contrast,
    area: best.area / (workW * workH),
    aspect: best.width / math.max(best.height, 1),
    solidity: solidity,
    leftEdge: best.x0 / workW,
    coreArea: coreArea,
    coreX: coreX,
    coreY: coreY,
    elong: elong,
  );
}

/// What one eye frame shows.
class EyeFeatures {
  const EyeFeatures(this.openness, [this.pupil, this.vector]);

  /// Visible pupil area / its full area: ~1 open, lower when the lid covers it, 0 = none visible.
  final double openness;

  /// (x, y) in -1..1, or null when no pupil is visible.
  final (double, double)? pupil;

  /// Position + shape of the dark mass ([PupilFix.vector]), for gaze.
  final List<double>? vector;
}

class _Candidate {
  _Candidate(this.hull, this.area, this.circ, this.level);
  final List<math.Point<double>> hull;
  final double area, circ, level;
  double get dark => 255 - level;
}

/// eye_tracking.CloseupEye with the "mass" locator and no eyelid model (the
/// product's default): the blob decides whether a pupil is visible and how
/// open the eye is, the mass locator where it is.
class CloseupEye {
  CloseupEye({
    this.darkOffset = 22,
    this.darkPercentile = 1.0,
    this.minAreaFrac = 0.002,
    this.maxAreaFrac = 0.2,
    this.minCircularity = 0.55,
    this.refWindow = 600,
  });

  final double darkOffset, darkPercentile, minAreaFrac, maxAreaFrac, minCircularity;
  final int refWindow;

  final _areas = <double>[]; // recent visible areas
  double? pupilLevel; // learned grey level inside the pupil
  math.Point<double>? _lastCenter;
  double? _lastRadius;

  /// The full (unoccluded) pupil area: the 90th percentile of recent areas.
  double? get refArea => _areas.isEmpty ? null : percentile(_areas, 90);

  EyeFeatures extract(Grey frame) {
    final blob = _blob(frame);
    if (blob.pupil == null) return blob;
    final fix = locate(frame);
    if (fix == null) return blob;
    return EyeFeatures(blob.openness, fix.signed, fix.vector);
  }

  (List<_Candidate>, double) _candidates(Uint8List gray, int w, int h, (int, int, int, int) roi) {
    final (x0, y0, x1, y1) = roi;
    final sw = x1 - x0, sh = y1 - y0;
    final sub = Uint8List(sw * sh);
    for (var y = 0; y < sh; y++) {
      sub.setRange(y * sw, (y + 1) * sw, gray, (y0 + y) * w + x0);
    }
    var thresh = bytePercentiles(sub, [darkPercentile])[0] + darkOffset;
    if (pupilLevel != null) thresh = math.min(thresh, pupilLevel! + darkOffset);
    final cut = thresh.floor(); // cv2.threshold on bytes compares with the floor
    var mask = Uint8List(sw * sh);
    for (var i = 0; i < sub.length; i++) {
      if (sub[i] <= cut) mask[i] = 1;
    }
    final k = _lastRadius == null ? 5 : ((_lastRadius! * 0.35).clamp(3, 9).toInt() | 1);
    mask = open(mask, sw, sh, k);
    final (labels, blobs) = components(mask, sw, sh);
    final out = <_Candidate>[];
    for (final b in blobs) {
      // The filled region (glint holes don't count against it), its outline and its mean grey.
      final (count, edge, sum) = _fillHoles(labels, sub, sw, b);
      final area = count - edge / 2 - 1; // Pick: the area of the outline through the edge pixels' centres
      if (area < minAreaFrac * h * w || area > maxAreaFrac * h * w || edge < 5) continue;
      final hull = [for (final p in hullOf(labels, sw, b)) math.Point(p.x + x0, p.y + y0)];
      final hullArea = polygonArea(hull), perim = perimeter(hull);
      final circ = 4 * math.pi * hullArea / math.max(perim * perim, 1e-6);
      out.add(_Candidate(hull, hullArea, circ, sum / count));
    }
    return (out, thresh);
  }

  /// Pixel count, edge-pixel count and grey sum (from [grey]) of region [b] with its holes filled.
  (int, int, double) _fillHoles(Int32List labels, Uint8List grey, int w, Blob b) {
    // Background reachable from outside the box is outside; any other background inside is a hole.
    final bw = b.width + 2, bh = b.height + 2;
    final outside = Uint8List(bw * bh);
    final stack = <int>[0];
    outside[0] = 1;
    bool inRegion(int x, int y) {
      final gx = b.x0 + x - 1, gy = b.y0 + y - 1;
      return x > 0 && y > 0 && x < bw - 1 && y < bh - 1 && labels[gy * w + gx] == b.label;
    }

    while (stack.isNotEmpty) {
      final p = stack.removeLast(), x = p % bw, y = p ~/ bw;
      for (final (dx, dy) in const [(1, 0), (-1, 0), (0, 1), (0, -1)]) {
        final xx = x + dx, yy = y + dy;
        if (xx < 0 || yy < 0 || xx >= bw || yy >= bh) continue;
        final q = yy * bw + xx;
        if (outside[q] == 0 && !inRegion(xx, yy)) {
          outside[q] = 1;
          stack.add(q);
        }
      }
    }
    var count = 0, edge = 0;
    var sum = 0.0;
    for (var y = 1; y < bh - 1; y++) {
      for (var x = 1; x < bw - 1; x++) {
        if (outside[y * bw + x] != 0) continue;
        count++;
        sum += grey[(b.y0 + y - 1) * w + b.x0 + x - 1];
        if (outside[y * bw + x - 1] != 0 ||
            outside[y * bw + x + 1] != 0 ||
            outside[(y - 1) * bw + x] != 0 ||
            outside[(y + 1) * bw + x] != 0) {
          edge++;
        }
      }
    }
    return (count, edge, sum);
  }

  EyeFeatures _blob(Grey frame) {
    // Stretch the frame's own 2nd..98th percentile onto a fixed range, so the fixed thresholds
    // below mean the same in a dim room as in a bright one.
    final [lo, hi] = bytePercentiles(frame.px, [2, 98]);
    final scale = 141.0 / math.max(hi - lo, 30.0);
    var gray = Uint8List(frame.px.length);
    for (var i = 0; i < gray.length; i++) {
      gray[i] = ((frame.px[i] - lo) * scale + 40).clamp(0, 255).toInt();
    }
    final w = frame.width, h = frame.height;
    gray = medianBlur5(gray, w, h);
    var roi = (0, 0, w, h);
    if (_lastCenter != null && _lastRadius != null && _lastRadius! > 0) {
      final r = (_lastRadius! * 4).toInt(), c = _lastCenter!;
      roi = (
        math.max(0, (c.x - r).toInt()),
        math.max(0, (c.y - r).toInt()),
        math.min(w, (c.x + r).toInt()),
        math.min(h, (c.y + r).toInt()),
      );
    }
    var (cands, _) = _candidates(gray, w, h, roi);
    if (cands.isEmpty && roi != (0, 0, w, h)) {
      (cands, _) = _candidates(gray, w, h, (0, 0, w, h)); // lost it: search everywhere
    }

    var ref = refArea;
    double score(_Candidate c) {
      var s = c.circ * 2 + c.dark / 128;
      if (ref != null) s -= (math.log(math.max(c.area, 1) / ref)).abs(); // about the size we expect
      if (_lastCenter != null) {
        final mx = c.hull.fold(0.0, (a, p) => a + p.x) / c.hull.length;
        final my = c.hull.fold(0.0, (a, p) => a + p.y) / c.hull.length;
        s -= _lastCenter!.distanceTo(math.Point(mx, my)) / math.max(_lastRadius ?? 20, 1) * 0.3;
      }
      return s;
    }

    // A partly covered pupil is a flattened disc: allow less roundness when the area is also reduced.
    var good = [
      for (final c in cands)
        if (c.circ >= minCircularity || (ref != null && c.area < 0.8 * ref && c.circ >= minCircularity * 0.6)) c,
    ];
    final maxLevel = pupilLevel == null ? null : pupilLevel! + 1.5 * darkOffset;
    good = [
      for (final c in good)
        // no bigger than the pupil, and no brighter
        if ((ref == null || c.area <= 1.6 * ref) && (maxLevel == null || c.level <= maxLevel)) c,
    ];
    if (good.isEmpty) return const EyeFeatures(0); // no pupil visible: a blink, or not in view
    final best = good.reduce((a, b) => score(b) > score(a) ? b : a);
    final centre =
        polygonCentroid(best.hull) ??
        math.Point(
          best.hull.fold(0.0, (a, p) => a + p.x) / best.hull.length,
          best.hull.fold(0.0, (a, p) => a + p.y) / best.hull.length,
        );
    _areas.add(best.area);
    if (_areas.length > refWindow) _areas.removeAt(0);
    if (best.area >= 0.7 * (ref ?? best.area)) {
      // learn the pupil's darkness from a mostly visible pupil
      pupilLevel = pupilLevel == null ? best.level : 0.95 * pupilLevel! + 0.05 * best.level;
    }
    ref = refArea!;
    _lastCenter = centre;
    _lastRadius = math.sqrt(ref / math.pi);
    return EyeFeatures(math.min(best.area / ref, 1.5), (2 * centre.x / w - 1, 2 * centre.y / h - 1));
  }
}
