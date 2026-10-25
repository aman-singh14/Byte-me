// HTTP JSON client for the laptop backend (backend/api.py). Uses dart:io, no extra
// package. The transport is injectable so tests never touch the network.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'backend_models.dart';

abstract class BackendTransport {
  /// Returns the decoded JSON body. Throws [BackendException] on any failure.
  /// [timeout] overrides the default for slow calls (a Muse answer takes seconds).
  Future<Object?> request(String method, Uri uri, {Map<String, Object?>? body, Duration? timeout});
}

class BackendException implements Exception {
  const BackendException(this.message, {this.statusCode});
  final String message;
  final int? statusCode;

  @override
  String toString() => message;
}

class HttpBackendTransport implements BackendTransport {
  HttpBackendTransport({this.timeout = const Duration(seconds: 3)});
  final Duration timeout;
  final HttpClient _client = HttpClient();

  @override
  Future<Object?> request(String method, Uri uri, {Map<String, Object?>? body, Duration? timeout}) async {
    final wait = timeout ?? this.timeout;
    try {
      final req = await _client.openUrl(method, uri).timeout(wait);
      if (body != null) {
        req.headers.contentType = ContentType.json;
        req.write(jsonEncode(body));
      }
      final res = await req.close().timeout(wait);
      final text = await res.transform(utf8.decoder).join().timeout(wait);
      final Object? json = text.isEmpty ? null : jsonDecode(text);
      if (res.statusCode >= 400) {
        final detail = json is Map && json['detail'] is String ? json['detail'] as String : 'HTTP ${res.statusCode}';
        throw BackendException(detail, statusCode: res.statusCode);
      }
      return json;
    } on BackendException {
      rethrow;
    } on TimeoutException {
      throw const BackendException('The backend did not answer in time.');
    } on SocketException catch (e) {
      throw BackendException("Can't reach the backend (${e.osError?.message ?? e.message}).");
    } on FormatException {
      throw const BackendException('The backend sent something that is not JSON.');
    } on HttpException catch (e) {
      throw BackendException(e.message);
    }
  }
}

class BackendApi {
  BackendApi(this.base, {BackendTransport? transport}) : transport = transport ?? HttpBackendTransport();

  /// e.g. http://172.20.10.2:8001
  final Uri base;
  final BackendTransport transport;

  Uri _uri(String path, [Map<String, String>? query]) =>
      base.replace(path: '${base.path.replaceAll(RegExp(r'/$'), '')}$path', queryParameters: query);

  Future<Map<String, dynamic>> _getMap(String path, [Map<String, String>? query]) async {
    final j = await transport.request('GET', _uri(path, query));
    if (j is! Map<String, dynamic>) throw const BackendException('Unexpected answer from the backend.');
    return j;
  }

  Future<EyesLive> eyesLive() async => EyesLive.fromJson(await _getMap('/eyes/live'));

  Future<EyesHistory> eyesHistory({String range = 'day'}) async =>
      EyesHistory.fromJson(await _getMap('/eyes/history', {'range': range}));

  Future<CloseupDay> closeupToday() async => CloseupDay.fromJson(await _getMap('/closeup/sessions'));

  Future<RingsDay> ringsToday() async => RingsDay.fromJson(await _getMap('/rings/today'));

  Future<List<RingsDay>> ringsHistory({int days = 7}) async {
    final j = await transport.request('GET', _uri('/rings/history', {'days': '$days'}));
    if (j is! List) throw const BackendException('Unexpected answer from the backend.');
    return [for (final d in j.whereType<Map<String, dynamic>>()) RingsDay.fromJson(d)];
  }

  /// Calibrate distance for one object type, held at a known distance from the glasses.
  Future<void> calibrateCloseup(String object, double knownCm) =>
      transport.request('POST', _uri('/closeup/calibrate'), body: {'object': object, 'known_cm': knownCm});

  /// "What am I looking at?": the backend crops the FRONT camera to [region] (left,
  /// center, right, all; null = where the wearer is looking), runs YOLO for a quick
  /// answer and asks Muse for a fuller one. Takes a few seconds.
  Future<LookResult> look({String? question, String? region, bool requireGaze = false}) async {
    final j = await transport.request(
      'POST',
      _uri('/assist/look'),
      body: {'question': question, 'region_override': region, if (requireGaze) 'require_gaze': true},
      timeout: const Duration(seconds: 45),
    );
    if (j is! Map<String, dynamic>) throw const BackendException('Unexpected answer from the backend.');
    return LookResult.fromJson(j);
  }

  /// One structured answer from the shared VLM service (backend/vlm.py).
  /// [images] are (camera, JPEG) pairs; [useFront] adds the laptop's newest
  /// FRONT frame. Returns the feature's JSON object.
  Future<Map<String, dynamic>> vlm(
    String feature, {
    List<(String, List<int>)> images = const [],
    bool useFront = false,
    String? question,
    Duration? timeout,
  }) async {
    final j = await transport.request(
      'POST',
      _uri('/vlm/$feature'),
      body: {
        'images': [for (final (camera, jpeg) in images) {'camera': camera, 'jpeg': base64Encode(jpeg)}],
        'use_front': useFront,
        'question': ?question,
      },
      timeout: timeout,
    );
    final result = j is Map<String, dynamic> ? j['result'] : null;
    if (result is! Map<String, dynamic>) throw const BackendException('Unexpected answer from the backend.');
    return result;
  }

  /// Dev mode only: force "outside" on/off, or null for automatic.
  Future<void> setOutside(bool? on) => transport.request('POST', _uri('/dev/outside'), body: {'on': on});
}
