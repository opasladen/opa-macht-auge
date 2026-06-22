import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:pretty_dio_logger/pretty_dio_logger.dart';

/// Basis-URL des Backends. Spaeter aus Env / Build-Config laden.
const String kBackendBaseUrl = String.fromEnvironment(
  'BACKEND_BASE_URL',
  defaultValue: 'http://10.0.2.2:8000', // Android-Emulator -> Host
);

final dioProvider = Provider<Dio>((ref) {
  final dio = Dio(
    BaseOptions(
      baseUrl: kBackendBaseUrl,
      connectTimeout: const Duration(seconds: 10),
      receiveTimeout: const Duration(seconds: 30),
      sendTimeout: const Duration(seconds: 30),
      contentType: 'application/json',
      responseType: ResponseType.json,
    ),
  );
  dio.interceptors.add(
    PrettyDioLogger(
      requestHeader: false,
      requestBody: false,
      responseBody: false,
      compact: true,
    ),
  );
  return dio;
});
