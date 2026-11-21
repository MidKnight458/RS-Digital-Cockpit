import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/services.dart';
import '../models/obd_telemetry_frame.dart';

/// Perfil dinámico de sondeo K-Line (10.4 kbps) para evitar saturar el bus Bluetooth:
/// - `rpmOnly`: 100% del ancho de banda a RPM (`010C1`) cuando el piloto ve el tacómetro.
/// - `engineParameters`: 0% RPM; dedica el bus únicamente a los mini-gauges del motor F4R.
/// - `backgroundMinimal`: carga mínima en pestañas secundarias (solo velocidad `010D` lenta para odómetro).
enum ObdPollingProfile {
  rpmOnly,
  engineParameters,
  backgroundMinimal,
}

/// Estado real del enlace Bluetooth RFCOMM + ECU Siemens Sirius 34
enum ObdLinkStatus {
  disconnected,
  connecting,
  adapterConnectedEcuWaiting,
  connectedEcuReady,
  reconnecting,
}

/// Contrato Polimórfico de Origen de Datos OBD-II (ECU Siemens Sirius 34 - KWP2000).
abstract class ObdDataSource {
  Stream<ObdTelemetryFrame> get telemetryStream;
  Stream<List<String>> get rawTerminalLogStream;
  Stream<ObdLinkStatus> get linkStatusStream;
  ObdTelemetryFrame get currentFrame;
  List<String> get currentLogs;
  ObdLinkStatus get currentLinkStatus;
  bool get isConnected;
  String get sourceName;

  void setPollingProfile(
    ObdPollingProfile profile, {
    bool includeExtendedPids = false,
  });

  Future<void> connect({String? macAddress});
  Future<void> disconnect();
  Future<List<Sirius34DtcFault>> readSirius34DtcCodes();
  Future<void> clearSirius34DtcCodes();
}

/// Parser determinista de respuestas hexadecimales OBD-II (Modo 01 y Modo 03)
/// Compatible con respuestas con o sin espacios (`ATS0` / `ATS1`) y encabezados KWP2000.
class Sirius34KwpParser {
  const Sirius34KwpParser._();

  /// PID 010C: Engine RPM -> ((A * 256) + B) / 4
  static double? parseRpm(String rawHex) {
    final bytes = _extractMode01Payload(rawHex, '410C', expectedBytes: 2);
    if (bytes == null) return null;
    return ((bytes[0] * 256) + bytes[1]) / 4.0;
  }

  /// PID 010D: Vehicle Speed -> A (km/h)
  static int? parseSpeedKmh(String rawHex) {
    final bytes = _extractMode01Payload(rawHex, '410D', expectedBytes: 1);
    if (bytes == null) return null;
    return bytes[0];
  }

  /// PID 0111: Throttle Position Sensor (TPS) -> (A * 100) / 255
  static double? parseThrottleTps(String rawHex) {
    final bytes = _extractMode01Payload(rawHex, '4111', expectedBytes: 1);
    if (bytes == null) return null;
    return (bytes[0] * 100.0) / 255.0;
  }

  /// PID 0104: Calculated Engine Load -> (A * 100) / 255
  static double? parseEngineLoad(String rawHex) {
    final bytes = _extractMode01Payload(rawHex, '4104', expectedBytes: 1);
    if (bytes == null) return null;
    return (bytes[0] * 100.0) / 255.0;
  }

  /// PID 010E: Ignition Timing Advance -> (A / 2) - 64
  static double? parseTimingAdvance(String rawHex) {
    final bytes = _extractMode01Payload(rawHex, '410E', expectedBytes: 1);
    if (bytes == null) return null;
    return (bytes[0] / 2.0) - 64.0;
  }

  /// PID 010B: Intake Manifold Absolute Pressure (MAP) -> A (kPa)
  static int? parseMapKpa(String rawHex) {
    final bytes = _extractMode01Payload(rawHex, '410B', expectedBytes: 1);
    if (bytes == null) return null;
    return bytes[0];
  }

  /// PID 0105 / 010F: Temperature -> A - 40 (°C)
  static double? parseTemperatureC(String rawHex, String headerPrefix) {
    final bytes = _extractMode01Payload(rawHex, headerPrefix, expectedBytes: 1);
    if (bytes == null) return null;
    return (bytes[0] - 40).toDouble();
  }

  /// Voltaje por comando ATRV (ej. "14.2V" o "ATRV 12.6V") o PID 0142 (((A*256)+B)/1000)
  static double? parseVoltage(String rawResponse) {
    final upper = rawResponse.toUpperCase();
    final match = RegExp(r'(\d{1,2}\.\d{1,2})\s*V?').firstMatch(upper);
    if (match != null) {
      final directVal = double.tryParse(match.group(1)!);
      if (directVal != null && directVal > 5.0 && directVal < 20.0) {
        return directVal;
      }
    }
    final bytes = _extractMode01Payload(upper, '4142', expectedBytes: 2);
    if (bytes != null) {
      return ((bytes[0] * 256) + bytes[1]) / 1000.0;
    }
    return null;
  }

  /// Decodifica respuestas reales del Modo 03 (`43 ...`) de la ECU.
  /// Si la ECU responde `43 00`, `NO DATA` o todos los bytes en `00`, devuelve lista vacía `[]`.
  static List<Sirius34DtcFault> parseMode03Dtcs(String rawHex) {
    final cleanedHex = _stripElmStatusWords(rawHex);
    if (cleanedHex.isEmpty) return const <Sirius34DtcFault>[];

    final idx = cleanedHex.indexOf('43');
    if (idx == -1) return const <Sirius34DtcFault>[];

    var payload = cleanedHex.substring(idx + 2);
    if (payload.isEmpty || RegExp(r'^0+$').hasMatch(payload)) {
      return const <Sirius34DtcFault>[];
    }

    final byteCount = payload.length ~/ 2;
    if (byteCount.isOdd && payload.length >= 6) {
      payload = payload.substring(2);
    }

    final faults = <Sirius34DtcFault>[];
    final seenCodes = <String>{};

    for (var i = 0; i + 4 <= payload.length; i += 4) {
      final byteA = int.tryParse(payload.substring(i, i + 2), radix: 16);
      final byteB = int.tryParse(payload.substring(i + 2, i + 4), radix: 16);
      if (byteA == null || byteB == null) continue;
      if (byteA == 0 && byteB == 0) continue;

      const prefixes = <String>['P', 'C', 'B', 'U'];
      final prefix = prefixes[(byteA >> 6) & 0x03];
      final d1 = ((byteA >> 4) & 0x03).toString();
      final d2 = (byteA & 0x0F).toRadixString(16).toUpperCase();
      final d3 = ((byteB >> 4) & 0x0F).toRadixString(16).toUpperCase();
      final d4 = (byteB & 0x0F).toRadixString(16).toUpperCase();
      final code = '$prefix$d1$d2$d3$d4';

      if (seenCodes.add(code)) {
        final info = _lookupSirius34DtcMetadata(code);
        faults.add(
          Sirius34DtcFault(
            code: code,
            renaultDfCode: info.$1,
            description: info.$2,
            subsystem: info.$3,
            detectedAt: DateTime.now(),
          ),
        );
      }
    }
    return faults;
  }

  static (String, String, String) _lookupSirius34DtcMetadata(String code) {
    return switch (code) {
      'P0010' => (
          'DF119 / Sirius 34',
          'Circuito actuador decalador de árbol de levas VVT',
          'Distribución Variable F4R'
        ),
      'P0105' || 'P0106' || 'P0107' || 'P0108' => (
          'DF079 / Sirius 34',
          'Circuito sensor de presión absoluta del colector (MAP)',
          'Admisión F4R'
        ),
      'P0110' || 'P0112' || 'P0113' => (
          'DF002 / Sirius 34',
          'Circuito sensor de temperatura de aire de admisión (IAT)',
          'Sensores Motor'
        ),
      'P0115' || 'P0117' || 'P0118' => (
          'DF001 / Sirius 34',
          'Circuito sensor de temperatura de refrigerante (ECT)',
          'Sistema Térmico'
        ),
      'P0120' || 'P0121' || 'P0122' || 'P0123' => (
          'DF053 / Sirius 34',
          'Circuito sensor de posición de mariposa motorizada (TPS)',
          'Cuerpo de Aceleración'
        ),
      'P0130' || 'P0135' => (
          'DF092 / Sirius 34',
          'Circuito sonda lambda anterior (Banco 1 Sensor 1)',
          'Control de Emisiones'
        ),
      'P0136' || 'P0141' => (
          'DF093 / Sirius 34',
          'Circuito sonda lambda posterior (Banco 1 Sensor 2)',
          'Control de Emisiones'
        ),
      'P0300' || 'P0301' || 'P0302' || 'P0303' || 'P0304' => (
          'DF059 / Sirius 34',
          'Fallo de encendido detectado en cilindros',
          'Encendido / Inyección'
        ),
      'P0313' => (
          'DF061 / Sirius 34',
          'Fallo de encendido detectado con bajo nivel de combustible',
          'Inyección Secuencial'
        ),
      'P0325' => (
          'DF065 / Sirius 34',
          'Circuito sensor de picado / detonación (Knock Sensor)',
          'Encendido Sirius 34'
        ),
      'P0335' => (
          'DF045 / Sirius 34',
          'Circuito sensor de posición del cigüeñal (PMS / CKP)',
          'Sincronización Motor'
        ),
      'P0500' => (
          'DF017 / Sirius 34',
          'Señal de velocidad del vehículo',
          'Transmisión / ABS'
        ),
      _ => (
          'OBD-II / Sirius 34',
          'Código de diagnóstico reportado por la ECU ($code)',
          'Diagnóstico Motor'
        ),
    };
  }

  static String _stripElmStatusWords(String rawHex) {
    var upper = rawHex.toUpperCase();
    const statusTokens = <String>[
      'UNABLE TO CONNECT',
      'BUS INIT: ...OK',
      'BUS INIT: OK',
      'BUS INIT: ERROR',
      'BUS INIT',
      'SEARCHING...',
      'SEARCHING',
      'TIMEOUT',
      'NO DATA',
      'NODATA',
      'STOPPED',
      'CAN ERROR',
      'BUFFER FULL',
      'ELM327',
      'ERROR',
      'OK',
    ];
    for (final token in statusTokens) {
      upper = upper.replaceAll(token, ' ');
    }
    return upper.replaceAll(RegExp(r'[^0-9A-F]'), '');
  }

  static List<int>? _extractMode01Payload(
    String rawHex,
    String expectedPrefix, {
    required int expectedBytes,
  }) {
    final clean = _stripElmStatusWords(rawHex);
    final idx = clean.lastIndexOf(expectedPrefix);
    if (idx == -1) return null;
    final payloadStart = idx + expectedPrefix.length;
    final requiredChars = expectedBytes * 2;
    if (clean.length < payloadStart + requiredChars) return null;

    final result = <int>[];
    for (var i = 0; i < expectedBytes; i++) {
      final hexPair = clean.substring(
        payloadStart + (i * 2),
        payloadStart + (i * 2) + 2,
      );
      final parsed = int.tryParse(hexPair, radix: 16);
      if (parsed == null) return null;
      result.add(parsed);
    }
    return result;
  }

  /// Estima la marcha engranada en la caja JC5-129 del Clio RS 172 a partir de relación RPM/kmh
  static int estimateJc5Gear(double rpm, int speedKmh) {
    if (speedKmh < 4 || rpm < 700) return 0;
    final ratio = rpm / speedKmh;
    if (ratio > 105) return 1;
    if (ratio > 64) return 2;
    if (ratio > 45) return 3;
    if (ratio > 35) return 4;
    return 5;
  }
}

// =============================================================================
// 1. IMPLEMENTACIÓN REAL: BLUETOOTH CLASSIC RFCOMM -> ELM327 (KWP2000 / AUTO)
// =============================================================================

class RealElm327BluetoothDataSource implements ObdDataSource {
  static const MethodChannel _rfcommChannel =
      MethodChannel('com.renaultsport.clio172/rfcomm');

  final StreamController<ObdTelemetryFrame> _telemetryController =
      StreamController<ObdTelemetryFrame>.broadcast();
  final StreamController<List<String>> _logController =
      StreamController<List<String>>.broadcast();
  final StreamController<ObdLinkStatus> _linkStatusController =
      StreamController<ObdLinkStatus>.broadcast();

  final List<String> _terminalLogs = <String>[];
  ObdLinkStatus _linkStatus = ObdLinkStatus.disconnected;
  ObdPollingProfile _pollingProfile = ObdPollingProfile.rpmOnly;
  bool _includeExtendedPids = false;
  bool _pollingActive = false;
  bool _ecuReady = false;
  bool _turboConfigured = false;
  bool _supportsSingleFrameSuffix = false;
  int _sessionToken = 0;
  Future<void> _serialLock = Future<void>.value();
  ObdTelemetryFrame _currentFrame =
      ObdTelemetryFrame.initial(isSimulator: false);

  static const List<String> kGenuineElm327InitSequence = <String>[
    'ATZ',
    'ATE0',
    'ATL0',
    'ATS0',
    'ATH0',
    'ATAT1',
  ];

  @override
  Stream<ObdTelemetryFrame> get telemetryStream => _telemetryController.stream;

  @override
  Stream<List<String>> get rawTerminalLogStream => _logController.stream;

  @override
  Stream<ObdLinkStatus> get linkStatusStream => _linkStatusController.stream;

  @override
  ObdTelemetryFrame get currentFrame => _currentFrame;

  @override
  List<String> get currentLogs => List<String>.unmodifiable(_terminalLogs);

  @override
  ObdLinkStatus get currentLinkStatus => _linkStatus;

  @override
  bool get isConnected => _linkStatus == ObdLinkStatus.connectedEcuReady;

  @override
  String get sourceName => 'ELM327 RFCOMM (KWP2000 / Sirius 34)';

  @override
  void setPollingProfile(
    ObdPollingProfile profile, {
    bool includeExtendedPids = false,
  }) {
    final changed = _pollingProfile != profile ||
        _includeExtendedPids != includeExtendedPids;
    _pollingProfile = profile;
    _includeExtendedPids = includeExtendedPids;
    if (changed && _pollingActive) {
      final modeLabel = switch (profile) {
        ObdPollingProfile.rpmOnly => '100% RPM (010C1)',
        ObdPollingProfile.engineParameters => includeExtendedPids
            ? 'PARÁMETROS F4R COMPLETOS (0% RPM)'
            : 'PARÁMETROS F4R BÁSICOS (0% RPM)',
        ObdPollingProfile.backgroundMinimal => 'MODO MÍNIMO EN SEGUNDO PLANO',
      };
      _appendLog('Perfil K-Line cambiado -> $modeLabel');
    }
  }

  void _setLinkStatus(ObdLinkStatus nextStatus) {
    if (_linkStatus == nextStatus) return;
    _linkStatus = nextStatus;
    if (!_linkStatusController.isClosed) {
      _linkStatusController.add(nextStatus);
    }
  }

  void _appendLog(String entry) {
    final stamp = DateTime.now().toIso8601String().substring(11, 19);
    _terminalLogs.insert(0, '[$stamp] $entry');
    if (_terminalLogs.length > 80) {
      _terminalLogs.removeLast();
    }
    if (!_logController.isClosed) {
      _logController.add(List<String>.unmodifiable(_terminalLogs));
    }
  }

  void _emitCurrentFrame() {
    if (!_telemetryController.isClosed) {
      _telemetryController.add(_currentFrame);
    }
  }

  bool _isTimeoutOrEmpty(String resp) {
    final upper = resp.trim().toUpperCase();
    return upper.isEmpty || upper == 'TIMEOUT';
  }

  bool _isValidElmHandshakeReply(String resp) {
    if (_isTimeoutOrEmpty(resp)) return false;
    final upper = resp.toUpperCase();
    return upper.contains('OK') ||
        upper.contains('ELM') ||
        upper.contains('OBD') ||
        upper.contains('V1.') ||
        upper.contains('V2.');
  }

  @override
  Future<void> connect({String? macAddress}) async {
    final targetMac = macAddress ?? '00:1D:A5:68:98:8B';
    final token = ++_sessionToken;
    _pollingActive = false;
    _ecuReady = false;
    _turboConfigured = false;
    _supportsSingleFrameSuffix = false;
    _setLinkStatus(ObdLinkStatus.connecting);
    _appendLog('Abriendo socket RFCOMM SPP -> $targetMac...');

    try {
      await _rfcommChannel
          .invokeMethod<bool>('connect', <String, dynamic>{
            'address': targetMac,
          })
          .timeout(const Duration(seconds: 7));

      if (token != _sessionToken) return;

      var validAtReplies = 0;
      for (final cmd in kGenuineElm327InitSequence) {
        if (token != _sessionToken) return;
        final isReset = cmd == 'ATZ';
        final resp = await _sendCommandSerialized(
          cmd,
          timeoutMs: isReset ? 2200 : 800,
        );
        _appendLog('TX: $cmd  =>  RX: $resp');
        if (_isValidElmHandshakeReply(resp)) {
          validAtReplies++;
        }
        if (isReset) {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        }
      }

      if (token != _sessionToken) return;

      if (validAtReplies == 0) {
        _appendLog(
          'Timeout en puerto Bluetooth: el adaptador ELM327 no respondió a ATZ/ATE0. Cerrando socket para reintentar.',
        );
        await _closeSocketSilently();
        _resetFrameToZero();
        _setLinkStatus(ObdLinkStatus.reconnecting);
        throw StateError('Timeout en puerto OBD2: ELM327 sin respuesta.');
      }

      final rawVolts = await _sendCommandSerialized('ATRV', timeoutMs: 1100);
      _appendLog('TX: ATRV  =>  RX: $rawVolts');
      final initialVolts = Sirius34KwpParser.parseVoltage(rawVolts);
      if (initialVolts != null) {
        _currentFrame = _currentFrame.copyWith(
          batteryVolts: initialVolts,
          timestamp: DateTime.now(),
        );
        _emitCurrentFrame();
      }

      var ecuResponding = false;

      await _sendCommandSerialized('ATSP5', timeoutMs: 800);
      _appendLog('Iniciando K-Line Fast Init (ATSP5)...');
      final fastInitResp = await _sendCommandSerialized('010C', timeoutMs: 4200);
      _appendLog('TX: 010C (ATSP5)  =>  RX: $fastInitResp');
      if (Sirius34KwpParser.parseRpm(fastInitResp) != null ||
          fastInitResp.contains('410C') ||
          fastInitResp.contains('41 0C')) {
        ecuResponding = true;
      }

      if (!ecuResponding && token == _sessionToken) {
        _appendLog('Probando KWP2000 5-Baud Init (ATSP4)...');
        await _sendCommandSerialized('ATSP4', timeoutMs: 800);
        final slowInitResp =
            await _sendCommandSerialized('010C', timeoutMs: 5200);
        _appendLog('TX: 010C (ATSP4)  =>  RX: $slowInitResp');
        if (Sirius34KwpParser.parseRpm(slowInitResp) != null ||
            slowInitResp.contains('410C') ||
            slowInitResp.contains('41 0C')) {
          ecuResponding = true;
        }
      }

      if (!ecuResponding && token == _sessionToken) {
        _appendLog('Activando búsqueda automática de protocolo (ATSP0)...');
        await _sendCommandSerialized('ATSP0', timeoutMs: 800);
        final autoInitResp =
            await _sendCommandSerialized('010C', timeoutMs: 6000);
        _appendLog('TX: 010C (ATSP0)  =>  RX: $autoInitResp');
        if (Sirius34KwpParser.parseRpm(autoInitResp) != null ||
            autoInitResp.contains('410C') ||
            autoInitResp.contains('41 0C')) {
          ecuResponding = true;
        }
      }

      if (token != _sessionToken) return;

      final activeProto = await _sendCommandSerialized('ATDP', timeoutMs: 1000);
      _appendLog('Protocolo activo: $activeProto');

      _ecuReady = ecuResponding;
      if (ecuResponding) {
        await _configureTurboKLineAndSeedCoolant();
        _setLinkStatus(ObdLinkStatus.connectedEcuReady);
      } else {
        _appendLog(
          'Adaptador ELM327 listo, pero la ECU no responde aún. Esperando contacto (llave en ON)...',
        );
        _setLinkStatus(ObdLinkStatus.adapterConnectedEcuWaiting);
      }

      _currentFrame = _currentFrame.copyWith(
        activeProtocol:
            activeProto.isNotEmpty && activeProto != 'TIMEOUT'
                ? activeProto
                : 'ISO 14230-4 KWP2000',
        timestamp: DateTime.now(),
      );
      _emitCurrentFrame();

      _pollingActive = true;
      unawaited(_startAdaptivePollingLoop(token));
    } catch (e) {
      if (token != _sessionToken) return;
      _appendLog('Error al conectar con adaptador OBD2: $e');
      _pollingActive = false;
      _ecuReady = false;
      await _closeSocketSilently();
      _resetFrameToZero();
      _setLinkStatus(ObdLinkStatus.reconnecting);
      rethrow;
    }
  }

  Future<void> _configureTurboKLineAndSeedCoolant() async {
    if (_turboConfigured) return;
    await _sendCommandSerialized('ATST19', timeoutMs: 500);
    await _sendCommandSerialized('ATAT2', timeoutMs: 500);

    final singleFrameTest =
        await _sendCommandSerialized('010C1', timeoutMs: 900);
    final testRpmVal = Sirius34KwpParser.parseRpm(singleFrameTest);
    if (testRpmVal != null && !singleFrameTest.contains('?')) {
      _supportsSingleFrameSuffix = true;
      _currentFrame = _currentFrame.copyWith(rpm: testRpmVal);
      _appendLog('Modo Turbo K-Line activo (010C1 Single-Frame + ATST19 + ATAT2)');
    } else {
      _supportsSingleFrameSuffix = false;
      _appendLog('Modo K-Line rápido activo (ATST19 + ATAT2)');
    }

    final initTempRaw =
        await _sendCommandSerialized(_pidCmd('0105'), timeoutMs: 900);
    final initTemp = Sirius34KwpParser.parseTemperatureC(initTempRaw, '4105');
    if (initTemp != null) {
      _currentFrame = _currentFrame.copyWith(
        coolantTempC: initTemp,
        timestamp: DateTime.now(),
      );
      _emitCurrentFrame();
    }
    _turboConfigured = true;
  }

  String _pidCmd(String basePid) =>
      _supportsSingleFrameSuffix ? '${basePid}1' : basePid;

  void _resetFrameToZero() {
    _currentFrame = ObdTelemetryFrame.initial(isSimulator: false);
    _emitCurrentFrame();
  }

  Future<void> _closeSocketSilently() async {
    try {
      await _rfcommChannel.invokeMethod<bool>('disconnect');
    } catch (_) {}
  }

  Future<void> _startAdaptivePollingLoop(int token) async {
    var responsesInWindow = 0;
    var windowStart = DateTime.now();
    var lastCoolantRefreshInRpmMode = DateTime.now();
    var paramSlotIndex = 0;
    var cycleCount = 0;
    var consecutiveTimeouts = 0;
    var consecutiveIoErrors = 0;

    while (_pollingActive && token == _sessionToken) {
      try {
        cycleCount++;

        if (!_ecuReady) {
          final probe = await _sendCommandSerialized('010C', timeoutMs: 1800);
          if (token != _sessionToken || !_pollingActive) break;

          if (_isTimeoutOrEmpty(probe)) {
            consecutiveTimeouts++;
            if (consecutiveTimeouts >= 3) {
              await _handleLinkLost(
                token,
                'Sin respuesta del adaptador OBD2 (timeout). Iniciando reconexión...',
              );
              break;
            }
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            continue;
          }

          consecutiveTimeouts = 0;
          consecutiveIoErrors = 0;
          final probeRpm = Sirius34KwpParser.parseRpm(probe);
          if (probeRpm != null) {
            _ecuReady = true;
            await _configureTurboKLineAndSeedCoolant();
            _setLinkStatus(ObdLinkStatus.connectedEcuReady);
            _currentFrame = _currentFrame.copyWith(
              rpm: probeRpm,
              isSimulator: false,
              timestamp: DateTime.now(),
            );
            _emitCurrentFrame();
          } else {
            final rawVoltsWait =
                await _sendCommandSerialized('ATRV', timeoutMs: 900);
            if (_isTimeoutOrEmpty(rawVoltsWait)) {
              consecutiveTimeouts++;
              if (consecutiveTimeouts >= 3) {
                await _handleLinkLost(
                  token,
                  'El adaptador ELM327 dejó de responder. Reconectando...',
                );
                break;
              }
            } else {
              final voltsWait = Sirius34KwpParser.parseVoltage(rawVoltsWait);
              if (voltsWait != null) {
                _currentFrame = _currentFrame.copyWith(
                  batteryVolts: voltsWait,
                  rpm: 0.0,
                  speedKmh: 0,
                  timestamp: DateTime.now(),
                );
                _emitCurrentFrame();
              }
            }
            await Future<void>.delayed(const Duration(milliseconds: 1800));
          }
          continue;
        }

        final activeProfile = _pollingProfile;

        if (activeProfile == ObdPollingProfile.rpmOnly) {
          final rawRpm = await _sendCommandSerialized(
            _pidCmd('010C'),
            timeoutMs: 900,
          );
          if (token != _sessionToken || !_pollingActive) break;

          if (_isTimeoutOrEmpty(rawRpm)) {
            consecutiveTimeouts++;
            if (consecutiveTimeouts >= 4) {
              await _handleLinkLost(
                token,
                'Timeout consecutivo en Línea K (adaptador desconectado). Reconectando...',
              );
              break;
            }
            continue;
          }

          consecutiveTimeouts = 0;
          consecutiveIoErrors = 0;

          if (_isEcuUnavailableReply(rawRpm)) {
            _ecuReady = false;
            _setLinkStatus(ObdLinkStatus.adapterConnectedEcuWaiting);
            _appendLog('ECU sin respuesta (llave apagada / $rawRpm). En espera...');
            _currentFrame = _currentFrame.copyWith(
              rpm: 0.0,
              speedKmh: 0,
              kLineHz: 0,
              timestamp: DateTime.now(),
            );
            _emitCurrentFrame();
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            continue;
          }

          responsesInWindow++;
          final parsedRpm = Sirius34KwpParser.parseRpm(rawRpm);
          final kLineHz = _updateKLineHz(
            responsesInWindow: responsesInWindow,
            windowStart: windowStart,
            onReset: () {
              responsesInWindow = 0;
              windowStart = DateTime.now();
            },
          );

          if (parsedRpm != null) {
            final vvtOn = _currentFrame.coolantTempC >= 75.0 &&
                parsedRpm >= 5150.0 &&
                parsedRpm <= 7100.0;
            _currentFrame = _currentFrame.copyWith(
              rpm: parsedRpm,
              vvtDephaserActive: vvtOn,
              kLineHz: kLineHz,
              isSimulator: false,
              timestamp: DateTime.now(),
            );
            _emitCurrentFrame();
          }

          if (DateTime.now()
                  .difference(lastCoolantRefreshInRpmMode)
                  .inSeconds >=
              25) {
            lastCoolantRefreshInRpmMode = DateTime.now();
            final rawTemp = await _sendCommandSerialized(
              _pidCmd('0105'),
              timeoutMs: 900,
            );
            final tempC = Sirius34KwpParser.parseTemperatureC(rawTemp, '4105');
            if (tempC != null) {
              _currentFrame = _currentFrame.copyWith(
                coolantTempC: tempC,
                timestamp: DateTime.now(),
              );
              _emitCurrentFrame();
            }
          }

          if (cycleCount % 16 == 0) {
            _appendLog(
              'K-Line RPM (${kLineHz}Hz) -> ${_currentFrame.rpm.round()} RPM | ${_currentFrame.coolantTempC.toStringAsFixed(0)}°C',
            );
          }
        } else if (activeProfile == ObdPollingProfile.engineParameters) {
          final schedule = _includeExtendedPids
              ? const <String>[
                  '0105',
                  '0111',
                  '010B',
                  '010E',
                  '0104',
                  '010F',
                  'ATRV',
                ]
              : const <String>[
                  '0105',
                  '0111',
                  '010F',
                  'ATRV',
                ];

          final nextCmd = schedule[paramSlotIndex % schedule.length];
          paramSlotIndex++;

          final isAt = nextCmd.startsWith('AT');
          final rawResp = await _sendCommandSerialized(
            isAt ? nextCmd : _pidCmd(nextCmd),
            timeoutMs: 900,
          );
          if (token != _sessionToken || !_pollingActive) break;

          if (_isTimeoutOrEmpty(rawResp)) {
            consecutiveTimeouts++;
            if (consecutiveTimeouts >= 4) {
              await _handleLinkLost(
                token,
                'Timeout consecutivo leyendo sensores F4R. Reconectando...',
              );
              break;
            }
            continue;
          }

          consecutiveTimeouts = 0;
          consecutiveIoErrors = 0;

          if (!isAt && _isEcuUnavailableReply(rawResp)) {
            _ecuReady = false;
            _setLinkStatus(ObdLinkStatus.adapterConnectedEcuWaiting);
            await Future<void>.delayed(const Duration(milliseconds: 1200));
            continue;
          }

          responsesInWindow++;
          final kLineHz = _updateKLineHz(
            responsesInWindow: responsesInWindow,
            windowStart: windowStart,
            onReset: () {
              responsesInWindow = 0;
              windowStart = DateTime.now();
            },
          );

          var tps = _currentFrame.throttleTps;
          var coolant = _currentFrame.coolantTempC;
          var mapKpa = _currentFrame.intakeMapKpa;
          var load = _currentFrame.engineLoad;
          var advance = _currentFrame.timingAdvance;
          var iat = _currentFrame.intakeAirTempC;
          var volts = _currentFrame.batteryVolts;

          switch (nextCmd) {
            case '0111':
              tps = Sirius34KwpParser.parseThrottleTps(rawResp) ?? tps;
            case '0105':
              coolant =
                  Sirius34KwpParser.parseTemperatureC(rawResp, '4105') ??
                      coolant;
            case '010B':
              mapKpa = Sirius34KwpParser.parseMapKpa(rawResp) ?? mapKpa;
            case '0104':
              load = Sirius34KwpParser.parseEngineLoad(rawResp) ?? load;
            case '010E':
              advance =
                  Sirius34KwpParser.parseTimingAdvance(rawResp) ?? advance;
            case '010F':
              iat = Sirius34KwpParser.parseTemperatureC(rawResp, '410F') ?? iat;
            case 'ATRV':
              volts = Sirius34KwpParser.parseVoltage(rawResp) ?? volts;
          }

          _currentFrame = _currentFrame.copyWith(
            throttleTps: tps,
            engineLoad: load,
            timingAdvance: advance,
            intakeMapKpa: mapKpa,
            coolantTempC: coolant,
            intakeAirTempC: iat,
            batteryVolts: volts,
            kLineHz: kLineHz,
            isSimulator: false,
            timestamp: DateTime.now(),
          );
          _emitCurrentFrame();

          if (cycleCount % 12 == 0) {
            _appendLog(
              'K-Line F4R (${kLineHz}Hz) -> ${coolant.toStringAsFixed(0)}°C | TPS:${tps.toStringAsFixed(0)}% | MAP:${mapKpa}kPa | ${volts.toStringAsFixed(1)}V',
            );
          }
        } else {
          final rawSpd = await _sendCommandSerialized(
            _pidCmd('010D'),
            timeoutMs: 900,
          );
          if (token != _sessionToken || !_pollingActive) break;

          if (_isTimeoutOrEmpty(rawSpd)) {
            consecutiveTimeouts++;
            if (consecutiveTimeouts >= 3) {
              await _handleLinkLost(
                token,
                'Conexión OBD2 perdida en segundo plano. Reconectando...',
              );
              break;
            }
          } else {
            consecutiveTimeouts = 0;
            consecutiveIoErrors = 0;
            if (_isEcuUnavailableReply(rawSpd)) {
              _ecuReady = false;
              _setLinkStatus(ObdLinkStatus.adapterConnectedEcuWaiting);
            } else {
              final spd = Sirius34KwpParser.parseSpeedKmh(rawSpd);
              if (spd != null) {
                _currentFrame = _currentFrame.copyWith(
                  speedKmh: spd,
                  kLineHz: 1,
                  isSimulator: false,
                  timestamp: DateTime.now(),
                );
                _emitCurrentFrame();
              }
            }
          }
          await Future<void>.delayed(const Duration(milliseconds: 1200));
        }
      } catch (e) {
        if (token != _sessionToken || !_pollingActive) break;
        consecutiveIoErrors++;
        final msg = e.toString().toLowerCase();
        final isFatalSocketError = msg.contains('desconectado') ||
            msg.contains('closed') ||
            msg.contains('cerrada') ||
            msg.contains('broken pipe') ||
            msg.contains('rfcomm_io_err') ||
            consecutiveIoErrors >= 2;

        if (isFatalSocketError) {
          await _handleLinkLost(
            token,
            'Socket Bluetooth OBD2 desconectado ($e). Reintentando reconexión...',
          );
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 300));
      }
    }
  }

  bool _isEcuUnavailableReply(String raw) {
    final upper = raw.toUpperCase();
    return upper.contains('UNABLE') ||
        upper.contains('BUS INIT: ERROR') ||
        upper.contains('ERROR');
  }

  int _updateKLineHz({
    required int responsesInWindow,
    required DateTime windowStart,
    required VoidCallback onReset,
  }) {
    final elapsedWindowMs =
        DateTime.now().difference(windowStart).inMilliseconds;
    if (elapsedWindowMs >= 1000) {
      final hz =
          ((responsesInWindow * 1000) / elapsedWindowMs).round().clamp(1, 30);
      onReset();
      return hz;
    }
    return _currentFrame.kLineHz;
  }

  Future<void> _handleLinkLost(int token, String reason) async {
    if (token != _sessionToken) return;
    _pollingActive = false;
    _ecuReady = false;
    _turboConfigured = false;
    _appendLog(reason);
    await _closeSocketSilently();
    _resetFrameToZero();
    _setLinkStatus(ObdLinkStatus.reconnecting);
  }

  Future<String> _sendCommandSerialized(
    String cmd, {
    int timeoutMs = 1200,
  }) {
    final completer = Completer<String>();
    _serialLock = _serialLock.then((_) async {
      try {
        final resp = await _rfcommChannel
            .invokeMethod<String>(
              'sendCommand',
              <String, dynamic>{
                'command': cmd,
                'timeoutMs': timeoutMs,
              },
            )
            .timeout(Duration(milliseconds: timeoutMs + 800));
        completer.complete(resp ?? 'TIMEOUT');
      } catch (e) {
        completer.completeError(e);
      }
    });
    return completer.future;
  }

  @override
  Future<List<Sirius34DtcFault>> readSirius34DtcCodes() async {
    if (!_ecuReady && _linkStatus != ObdLinkStatus.connectedEcuReady) {
      return const <Sirius34DtcFault>[];
    }
    _appendLog('TX: 03 (Consultando códigos de falla DTC reales en ECU...)');
    try {
      final raw = await _sendCommandSerialized('03', timeoutMs: 3000);
      _appendLog('RX Mode 03: $raw');
      final dtcs = Sirius34KwpParser.parseMode03Dtcs(raw);
      _appendLog(
        dtcs.isEmpty
            ? 'Modo 03 completado: 0 códigos de falla en la ECU.'
            : 'Modo 03 completado: ${dtcs.length} código(s) detectado(s).',
      );
      return dtcs;
    } catch (e) {
      _appendLog('Error al leer DTCs Modo 03: $e');
      return const <Sirius34DtcFault>[];
    }
  }

  @override
  Future<void> clearSirius34DtcCodes() async {
    if (!_ecuReady && _linkStatus != ObdLinkStatus.connectedEcuReady) return;
    _appendLog('TX: 04 (Borrado de códigos DTC en ECU)...');
    try {
      final raw = await _sendCommandSerialized('04', timeoutMs: 3000);
      _appendLog('RX Mode 04: $raw');
    } catch (e) {
      _appendLog('Error al borrar DTCs Modo 04: $e');
    }
  }

  @override
  Future<void> disconnect() async {
    _sessionToken++;
    _pollingActive = false;
    _ecuReady = false;
    _turboConfigured = false;
    await _closeSocketSilently();
    _resetFrameToZero();
    _setLinkStatus(ObdLinkStatus.disconnected);
    _appendLog('Socket RFCOMM cerrado.');
  }
}

// =============================================================================
// 2. SIMULADOR FÍSICO REALISTA DE PISTA: CLIO RS 172 TRACK SIMULATOR (MODO DEMO)
// =============================================================================

class Clio172TrackSimulatorDataSource implements ObdDataSource {
  final StreamController<ObdTelemetryFrame> _telemetryController =
      StreamController<ObdTelemetryFrame>.broadcast();
  final StreamController<List<String>> _logController =
      StreamController<List<String>>.broadcast();
  final StreamController<ObdLinkStatus> _linkStatusController =
      StreamController<ObdLinkStatus>.broadcast();

  final List<String> _terminalLogs = <String>[];
  final List<Sirius34DtcFault> _simulatedDtcs = <Sirius34DtcFault>[
    Sirius34DtcFault(
      code: 'P0130',
      renaultDfCode: 'DF092 (Sonda Lambda Anterior)',
      description: 'Circuito sensor O2 Banco 1 Sensor 1 (Colector 4-2-1 Clio 172)',
      subsystem: 'Control de Gases / Catalizador',
      detectedAt: DateTime.now().subtract(const Duration(hours: 2)),
    ),
    Sirius34DtcFault(
      code: 'P0010',
      renaultDfCode: 'DF119 (Solenoide Decalador Árbol de Levas VVT)',
      description:
          'Actuador de posición del árbol de levas de admisión F4R 736 (circuito abierto intermitente)',
      subsystem: 'Distribución Variable VVT',
      detectedAt: DateTime.now().subtract(const Duration(minutes: 45)),
    ),
  ];

  Timer? _physicsTimer;
  bool _connected = false;
  ObdPollingProfile _pollingProfile = ObdPollingProfile.rpmOnly;
  double _lapTimeSec = 0.0;
  double _coolantTempC = 65.0;
  bool _forceWarmOverride = false;
  ObdTelemetryFrame _currentFrame = ObdTelemetryFrame.initial(isSimulator: true);

  static const Map<int, double> _jc5KmhPer1000Rpm = <int, double>{
    1: 8.3,
    2: 13.7,
    3: 19.3,
    4: 24.8,
    5: 31.8,
  };

  @override
  Stream<ObdTelemetryFrame> get telemetryStream => _telemetryController.stream;

  @override
  Stream<List<String>> get rawTerminalLogStream => _logController.stream;

  @override
  Stream<ObdLinkStatus> get linkStatusStream => _linkStatusController.stream;

  @override
  ObdTelemetryFrame get currentFrame => _currentFrame;

  @override
  List<String> get currentLogs => List<String>.unmodifiable(_terminalLogs);

  @override
  ObdLinkStatus get currentLinkStatus => _connected
      ? ObdLinkStatus.connectedEcuReady
      : ObdLinkStatus.disconnected;

  @override
  bool get isConnected => _connected;

  @override
  String get sourceName =>
      'Simulador Físico Circuito Clio 172 (F4R 736 / JC5-129)';

  @override
  void setPollingProfile(
    ObdPollingProfile profile, {
    bool includeExtendedPids = false,
  }) {
    _pollingProfile = profile;
  }

  void toggleColdWarmEngineDemo() {
    _forceWarmOverride = !_forceWarmOverride;
    _coolantTempC = _forceWarmOverride ? 89.5 : 66.0;
    _appendSimLog(
      _forceWarmOverride
          ? 'MODO PISTA CALIENTE ACTIVADO (89.5°C) -> Shift-Light Verde OEM 6,750 RPM / Corte 7,250 RPM'
          : 'MODO MOTOR FRÍO ACTIVADO (66.0°C) -> Protección F4R activa a 5,000 RPM',
    );
  }

  void _appendSimLog(String entry) {
    final stamp = DateTime.now().toIso8601String().substring(11, 19);
    _terminalLogs.insert(0, '[$stamp] $entry');
    if (_terminalLogs.length > 60) {
      _terminalLogs.removeLast();
    }
    if (!_logController.isClosed) {
      _logController.add(List<String>.unmodifiable(_terminalLogs));
    }
  }

  @override
  Future<void> connect({String? macAddress}) async {
    if (_connected) return;
    _connected = true;
    if (!_linkStatusController.isClosed) {
      _linkStatusController.add(ObdLinkStatus.connectedEcuReady);
    }

    _appendSimLog('INIT SIMULADOR ELM327 -> ATZ [ELM327 v1.5]');
    _appendSimLog('TX: ATE0 | ATL0 | ATS0 | ATH0 -> OK');
    _appendSimLog(
      'TX: ATSP5 (ISO 14230-4 KWP2000 Fast Init 10.4 kbps Pin 7) -> BUS INIT: OK',
    );

    var logCounter = 0;
    _physicsTimer = Timer.periodic(const Duration(milliseconds: 33), (_) {
      _lapTimeSec += 0.033;
      if (_lapTimeSec > 46.0) {
        _lapTimeSec = 0.0;
      }

      if (!_forceWarmOverride) {
        if (_coolantTempC < 91.0) {
          _coolantTempC += 0.028;
        } else {
          _coolantTempC = 89.5 + 2.0 * math.sin(_lapTimeSec * 0.25);
        }
      }

      final frame = _computeTrackPhysicsFrame(_lapTimeSec, _coolantTempC);
      _currentFrame = frame;
      if (!_telemetryController.isClosed) {
        _telemetryController.add(frame);
      }

      logCounter++;
      if (logCounter % 25 == 0) {
        if (_pollingProfile == ObdPollingProfile.rpmOnly) {
          final rpmHex = (frame.rpm * 4)
              .round()
              .toRadixString(16)
              .toUpperCase()
              .padLeft(4, '0');
          _appendSimLog(
            'KWP2000 [010C1->410C$rpmHex] 100% RPM (${frame.kLineHz} Hz)',
          );
        } else {
          _appendSimLog(
            'KWP2000 [F4R PARAMS] ${frame.coolantTempC.toStringAsFixed(0)}°C | TPS:${frame.throttleTps.toStringAsFixed(0)}% | MAP:${frame.intakeMapKpa}kPa',
          );
        }
      }
    });
  }

  ObdTelemetryFrame _computeTrackPhysicsFrame(double t, double coolantC) {
    var gear = 1;
    var rpm = 1100.0;
    var tps = 5.0;

    if (t < 4.5) {
      gear = 1;
      final p = t / 4.5;
      rpm = 1600.0 + (5700.0 * math.pow(p, 0.88));
      tps = 98.5;
    } else if (t < 5.0) {
      gear = 2;
      final p = (t - 4.5) / 0.5;
      rpm = 7280.0 - (2450.0 * p);
      tps = 12.0;
    } else if (t < 11.5) {
      gear = 2;
      final p = (t - 5.0) / 6.5;
      rpm = 4830.0 + (2350.0 * p);
      tps = 100.0;
    } else if (t < 12.0) {
      gear = 3;
      final p = (t - 11.5) / 0.5;
      rpm = 7180.0 - (2080.0 * p);
      tps = 10.0;
    } else if (t < 20.5) {
      gear = 3;
      final p = (t - 12.0) / 8.5;
      rpm = 5100.0 + (2180.0 * p);
      tps = 100.0;
    } else if (t < 21.0) {
      gear = 4;
      final p = (t - 20.5) / 0.5;
      rpm = 7280.0 - (1700.0 * p);
      tps = 15.0;
    } else if (t < 30.0) {
      gear = 4;
      final p = (t - 21.0) / 9.0;
      rpm = 5580.0 + (1480.0 * p);
      tps = 99.2;
    } else if (t < 36.0) {
      gear = 5;
      final p = (t - 30.0) / 6.0;
      rpm = 5600.0 + (980.0 * p);
      tps = 96.0;
    } else if (t < 41.0) {
      final sub = t - 36.0;
      if (sub < 2.2) {
        gear = 4;
        final blip = math.sin(sub * math.pi / 2.2);
        rpm = 5200.0 + (1250.0 * blip);
        tps = 8.0 + (58.0 * blip);
      } else {
        gear = 3;
        final blip = math.sin((sub - 2.2) * math.pi / 2.8);
        rpm = 4800.0 + (1400.0 * blip);
        tps = 6.0 + (64.0 * blip);
      }
    } else {
      gear = 2;
      final p = (t - 41.0) / 5.0;
      rpm = 4200.0 + (2920.0 * p);
      tps = 45.0 + (55.0 * p);
    }

    if (rpm >= 7240.0) {
      rpm += 45.0 * math.sin(t * 95.0);
    }

    final kmhFactor = _jc5KmhPer1000Rpm[gear] ?? 15.0;
    final speedKmh = ((rpm / 1000.0) * kmhFactor).round().clamp(0, 238);
    final mapKpa = (26.0 + (tps * 0.75)).round().clamp(24, 102);
    final engineLoad = (tps * 0.88 + (rpm / 8000.0) * 12.0).clamp(14.0, 99.6);
    final timingAdvance =
        (6.0 + (rpm / 7250.0) * 26.0 - (tps > 90 ? 3.5 : 0.0)).clamp(-4.0, 34.5);
    final vvtActive =
        coolantC >= 75.0 && rpm >= 5150.0 && rpm <= 7080.0 && engineLoad >= 50.0;
    final intakeAirTempC = 27.0 + 4.5 * math.sin(t * 0.15);
    final batteryVolts = 14.05 + 0.15 * math.cos(t * 0.8);

    return ObdTelemetryFrame(
      rpm: rpm.clamp(800.0, 7450.0),
      speedKmh: speedKmh,
      throttleTps: tps.clamp(0.0, 100.0),
      engineLoad: engineLoad,
      timingAdvance: timingAdvance,
      intakeMapKpa: mapKpa,
      coolantTempC: double.parse(coolantC.toStringAsFixed(1)),
      intakeAirTempC: double.parse(intakeAirTempC.toStringAsFixed(1)),
      batteryVolts: double.parse(batteryVolts.toStringAsFixed(2)),
      estimatedGear: gear,
      vvtDephaserActive: vvtActive,
      kLineHz: _pollingProfile == ObdPollingProfile.rpmOnly ? 14 : 9,
      activeProtocol: 'ISO 14230-4 KWP2000 (Simulador F4R 736 Sirius 34)',
      isSimulator: true,
      timestamp: DateTime.now(),
    );
  }

  @override
  Future<List<Sirius34DtcFault>> readSirius34DtcCodes() async {
    _appendSimLog(
      'TX: 03 -> RX: 43 02 01 30 00 10 (${_simulatedDtcs.length} DTCs en Sirius 34)',
    );
    return List<Sirius34DtcFault>.unmodifiable(_simulatedDtcs);
  }

  @override
  Future<void> clearSirius34DtcCodes() async {
    _simulatedDtcs.clear();
    _appendSimLog(
      'TX: 04 -> RX: 44 (Memoria de fallas Sirius 34 limpiada exitosamente)',
    );
  }

  @override
  Future<void> disconnect() async {
    _physicsTimer?.cancel();
    _physicsTimer = null;
    _connected = false;
    if (!_linkStatusController.isClosed) {
      _linkStatusController.add(ObdLinkStatus.disconnected);
    }
  }
}
