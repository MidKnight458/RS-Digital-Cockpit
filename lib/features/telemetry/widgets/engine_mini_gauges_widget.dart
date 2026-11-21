import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../digital_garage_payments/providers/payment_garage_providers.dart';
import '../models/obd_telemetry_frame.dart';

/// Cuadrícula de mini-gauges radiales para los parámetros del motor F4R 736.
/// Al mostrarse esta vista en Cockpit, el bus K-Line dedica 0% a RPM y 100% a estos sensores.
class EngineMiniGaugesWidget extends ConsumerWidget {
  final ObdTelemetryFrame frame;

  const EngineMiniGaugesWidget({
    super.key,
    required this.frame,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePlan = ref.watch(
      digitalGaragePaymentProvider.select((s) => s.activeSubscription),
    );
    final hasExtendedPids = activePlan.unlocksExtendedSiriusPids;
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final coolantColor = frame.coolantTempC >= 102.0
        ? RenaultSportPalette.revLimiterRed
        : (frame.isEngineCold
            ? RenaultSportPalette.coldEngineAmber
            : RenaultSportPalette.oemShiftGreen);

    final batteryColor = frame.batteryVolts > 0 && frame.batteryVolts < 11.8
        ? RenaultSportPalette.coldEngineAmber
        : Colors.cyanAccent;

    final gauges = <Widget>[
      _MiniRadialGaugeCard(
        title: 'TEMP MOTOR',
        value: frame.coolantTempC,
        minValue: 0.0,
        maxValue: 120.0,
        displayValue: '${frame.coolantTempC.toStringAsFixed(0)}°C',
        subtitle: frame.isEngineCold ? 'FRÍO <75°C' : 'ÓPTIMA',
        accentColor: coolantColor,
        isDark: isDark,
      ),
      _MiniRadialGaugeCard(
        title: 'ACELERADOR',
        value: frame.throttleTps,
        minValue: 0.0,
        maxValue: 100.0,
        displayValue: '${frame.throttleTps.toStringAsFixed(0)}%',
        subtitle: 'MARIPOSA TPS',
        accentColor: primary,
        isDark: isDark,
      ),
      _MiniRadialGaugeCard(
        title: 'BATERÍA',
        value: frame.batteryVolts,
        minValue: 10.0,
        maxValue: 16.0,
        displayValue: '${frame.batteryVolts.toStringAsFixed(1)}V',
        subtitle: 'IAT ${frame.intakeAirTempC.toStringAsFixed(0)}°C',
        accentColor: batteryColor,
        isDark: isDark,
      ),
      _MiniRadialGaugeCard(
        title: 'PRESIÓN MAP',
        value: hasExtendedPids ? frame.intakeMapKpa.toDouble() : 10.0,
        minValue: 10.0,
        maxValue: 110.0,
        displayValue: hasExtendedPids ? '${frame.intakeMapKpa} kPa' : 'PLAN 2+',
        subtitle: 'COLECTOR F4R',
        accentColor: RenaultSportPalette.siriusLiquidYellow,
        isDark: isDark,
        locked: !hasExtendedPids,
      ),
      _MiniRadialGaugeCard(
        title: 'AVANCE',
        value: hasExtendedPids ? frame.timingAdvance : -10.0,
        minValue: -10.0,
        maxValue: 45.0,
        displayValue:
            hasExtendedPids ? '${frame.timingAdvance.toStringAsFixed(1)}°' : 'PLAN 2+',
        subtitle: 'ENCENDIDO',
        accentColor: RenaultSportPalette.oemShiftGreen,
        isDark: isDark,
        locked: !hasExtendedPids,
      ),
      _MiniRadialGaugeCard(
        title: 'CARGA ECU',
        value: hasExtendedPids ? frame.engineLoad : 0.0,
        minValue: 0.0,
        maxValue: 100.0,
        displayValue:
            hasExtendedPids ? '${frame.engineLoad.toStringAsFixed(0)}%' : 'PLAN 2+',
        subtitle: 'SIRIUS 34',
        accentColor: primary,
        isDark: isDark,
        locked: !hasExtendedPids,
      ),
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= 520;
        final cols = isWide ? 3 : 2;
        final rows = isWide ? 2 : 3;

        // Si el contenedor tiene altura suficiente, repartir uniformemente sin scroll
        if (constraints.maxHeight >= (rows * 92.0)) {
          return Column(
            children: List<Widget>.generate(rows, (rowIndex) {
              return Expanded(
                child: Padding(
                  padding: EdgeInsets.only(
                    bottom: rowIndex < rows - 1 ? 8.0 : 0.0,
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: List<Widget>.generate(cols, (colIndex) {
                      final idx = (rowIndex * cols) + colIndex;
                      return Expanded(
                        child: Padding(
                          padding: EdgeInsets.only(
                            right: colIndex < cols - 1 ? 8.0 : 0.0,
                          ),
                          child: gauges[idx],
                        ),
                      );
                    }),
                  ),
                ),
              );
            }),
          );
        }

        // Respaldo seguro para alturas muy compactas
        return GridView.count(
          crossAxisCount: cols,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          childAspectRatio: isWide ? 1.25 : 1.15,
          children: gauges,
        );
      },
    );
  }
}

class _MiniRadialGaugeCard extends StatelessWidget {
  final String title;
  final double value;
  final double minValue;
  final double maxValue;
  final String displayValue;
  final String subtitle;
  final Color accentColor;
  final bool isDark;
  final bool locked;

  const _MiniRadialGaugeCard({
    required this.title,
    required this.value,
    required this.minValue,
    required this.maxValue,
    required this.displayValue,
    required this.subtitle,
    required this.accentColor,
    required this.isDark,
    this.locked = false,
  });

  @override
  Widget build(BuildContext context) {
    final normalized = maxValue > minValue
        ? ((value - minValue) / (maxValue - minValue)).clamp(0.0, 1.0)
        : 0.0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF101319) : const Color(0xFFF1F5F9),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: locked
              ? (isDark ? Colors.white12 : Colors.black12)
              : accentColor.withValues(alpha: 0.42),
          width: 1.1,
        ),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Flexible(
                child: Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                    color: locked
                        ? (isDark ? Colors.white54 : Colors.black45)
                        : (isDark ? Colors.white70 : const Color(0xFF334155)),
                  ),
                ),
              ),
              if (locked)
                Icon(
                  Icons.lock_outline_rounded,
                  size: 12,
                  color: isDark ? Colors.white54 : Colors.black45,
                ),
            ],
          ),
          const SizedBox(height: 2),
          Expanded(
            child: LayoutBuilder(
              builder: (context, gaugeConstraints) {
                final dialSize = math.min(
                  gaugeConstraints.maxWidth,
                  gaugeConstraints.maxHeight,
                );
                return Center(
                  child: TweenAnimationBuilder<double>(
                    tween: Tween<double>(end: normalized),
                    duration: const Duration(milliseconds: 180),
                    curve: Curves.easeOutCubic,
                    builder: (context, animRatio, _) {
                      return SizedBox(
                        width: dialSize,
                        height: dialSize,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            CustomPaint(
                              size: Size(dialSize, dialSize),
                              painter: _MiniDialPainter(
                                ratio: locked ? 0.0 : animRatio,
                                accentColor: locked
                                    ? (isDark
                                        ? Colors.white24
                                        : Colors.black26)
                                    : accentColor,
                                isDark: isDark,
                              ),
                            ),
                            Positioned(
                              bottom: dialSize * 0.06,
                              width: dialSize * 0.72,
                              height: dialSize * 0.28,
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  displayValue,
                                  style: AppTheme.telemetryNumericStyle(
                                    fontSize: 15,
                                    color: locked
                                        ? (isDark
                                            ? Colors.white54
                                            : Colors.black45)
                                        : accentColor,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              subtitle,
              maxLines: 1,
              style: AppTheme.telemetryNumericStyle(
                fontSize: 9.5,
                color: isDark ? Colors.white54 : Colors.black54,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _MiniDialPainter extends CustomPainter {
  final double ratio;
  final Color accentColor;
  final bool isDark;

  const _MiniDialPainter({
    required this.ratio,
    required this.accentColor,
    required this.isDark,
  });

  static const double _startAngle = 135.0 * (math.pi / 180.0);
  static const double _sweepAngle = 270.0 * (math.pi / 180.0);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = math.max(8.0, (math.min(size.width, size.height) / 2) - 4);
    final scale = (radius / 46.0).clamp(0.5, 1.8);

    // Fondo sutil del mini reloj
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..color = isDark ? const Color(0xFF161A22) : const Color(0xFFFFFFFF),
    );

    final arcRect = Rect.fromCircle(center: center, radius: radius * 0.80);

    // Pista base
    canvas.drawArc(
      arcRect,
      _startAngle,
      _sweepAngle,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.5 * scale
        ..strokeCap = StrokeCap.round
        ..color = isDark ? const Color(0xFF252B36) : const Color(0xFFCBD5E1),
    );

    // Arco activo
    if (ratio > 0.005) {
      canvas.drawArc(
        arcRect,
        _startAngle,
        _sweepAngle * ratio,
        false,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5.5 * scale
          ..strokeCap = StrokeCap.round
          ..color = accentColor,
      );
    }

    // Marcas de escala (9 ticks)
    for (var i = 0; i <= 8; i++) {
      final angle = _startAngle + (_sweepAngle * (i / 8.0));
      final outerR = radius * 0.92;
      final innerR = outerR - (i % 2 == 0 ? 4.5 * scale : 2.6 * scale);
      canvas.drawLine(
        Offset(
          center.dx + outerR * math.cos(angle),
          center.dy + outerR * math.sin(angle),
        ),
        Offset(
          center.dx + innerR * math.cos(angle),
          center.dy + innerR * math.sin(angle),
        ),
        Paint()
          ..strokeWidth = (i % 2 == 0 ? 1.5 : 1.0) * scale
          ..color = isDark ? Colors.white38 : Colors.black38,
      );
    }

    // Aguja del mini gauge
    final needleAngle = _startAngle + (_sweepAngle * ratio);
    final tip = Offset(
      center.dx + (radius * 0.66) * math.cos(needleAngle),
      center.dy + (radius * 0.66) * math.sin(needleAngle),
    );
    final tail = Offset(
      center.dx - (radius * 0.16) * math.cos(needleAngle),
      center.dy - (radius * 0.16) * math.sin(needleAngle),
    );

    canvas.drawLine(
      tail,
      tip,
      Paint()
        ..color = accentColor
        ..strokeWidth = 2.4 * scale
        ..strokeCap = StrokeCap.round,
    );

    canvas.drawCircle(
      center,
      3.8 * scale,
      Paint()..color = isDark ? const Color(0xFF262B35) : const Color(0xFF475569),
    );
    canvas.drawCircle(center, 1.8 * scale, Paint()..color = accentColor);
  }

  @override
  bool shouldRepaint(covariant _MiniDialPainter oldDelegate) {
    return oldDelegate.ratio != ratio ||
        oldDelegate.accentColor != accentColor ||
        oldDelegate.isDark != isDark;
  }
}
