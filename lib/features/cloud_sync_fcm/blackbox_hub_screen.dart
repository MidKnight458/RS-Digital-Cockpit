import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../auth_profile/providers/auth_profile_providers.dart';
import '../cockpit_dashboard/widgets/launcher_dock_widget.dart';
import '../map_track/map_providers.dart';
import '../telemetry/models/obd_telemetry_frame.dart';
import '../telemetry/providers/telemetry_providers.dart';
import 'blackbox_realtime_service.dart';

/// Pestaña dedicada **BLACKBOX**:
/// Muestra la sesión actual en vivo (Peak RPM, Vel máx, Temp máx, 0-100, DTCs),
/// el estado de sincronización con Firebase Realtime Database, resumen de Laps GPS
/// y el historial completo de registros sincronizados entre dispositivos.
class BlackboxHubScreen extends ConsumerWidget {
  const BlackboxHubScreen({super.key});

  String _formatDate(DateTime dt) {
    final d = dt.day.toString().padLeft(2, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$d/$m/${dt.year} • $h:$min';
  }

  String _formatLapClock(double seconds) {
    final totalTenths = (seconds * 10).round();
    final mins = totalTenths ~/ 600;
    final secs = (totalTenths % 600) ~/ 10;
    final tenths = totalTenths % 10;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}.$tenths';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final sessions = ref.watch(blackboxRealtimeProvider);
    final syncMeta = ref.watch(blackboxSyncMetaProvider);
    final notifier = ref.read(blackboxRealtimeProvider.notifier);
    final stats = ref.watch(telemetrySessionStatsProvider);
    final dtcs =
        ref.watch(sirius34DtcProvider).valueOrNull ?? const <Sirius34DtcFault>[];
    final mapState = ref.watch(trackMapTelemetryProvider);
    final pilot = ref.watch(pilotAuthProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final firebaseCount = sessions.where((s) => s.syncedToFirebase).length;
    final localPendingCount = sessions.length - firebaseCount;

    final String syncLabel;
    final Color syncColor;
    final IconData syncIcon;
    if (syncMeta.isSyncing) {
      syncLabel = 'SINCRONIZANDO...';
      syncColor = RenaultSportPalette.siriusLiquidYellow;
      syncIcon = Icons.sync_rounded;
    } else if (syncMeta.errorMessage != null) {
      syncLabel = 'SOLO LOCAL';
      syncColor = RenaultSportPalette.coldEngineAmber;
      syncIcon = Icons.cloud_off_rounded;
    } else {
      syncLabel = 'FIREBASE EN VIVO';
      syncColor = RenaultSportPalette.oemShiftGreen;
      syncIcon = Icons.cloud_done_rounded;
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(14),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1180),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 1. Cabecera y estado de sincronización Firebase
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Icon(
                                Icons.cloud_done_rounded,
                                color: RenaultSportPalette.siriusLiquidYellow,
                                size: 26,
                              ),
                              const SizedBox(width: 10),
                              Flexible(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'BLACKBOX CLOUD TELEMETRY',
                                      style: AppTheme.renaultSportHeaderStyle(
                                        fontSize: 16,
                                        color: primary,
                                      ),
                                    ),
                                    Text(
                                      pilot != null
                                          ? 'Cuenta: ${pilot.email} • $firebaseCount en nube / $localPendingCount locales'
                                          : 'Sin sesión activa ($localPendingCount locales)',
                                      style: const TextStyle(fontSize: 12),
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: syncColor.withValues(alpha: 0.14),
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(color: syncColor),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(syncIcon, size: 15, color: syncColor),
                                    const SizedBox(width: 6),
                                    Text(
                                      syncLabel,
                                      style: AppTheme.telemetryNumericStyle(
                                        fontSize: 11,
                                        color: syncColor,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              OutlinedButton.icon(
                                onPressed: syncMeta.isSyncing
                                    ? null
                                    : notifier.refreshFromCloud,
                                icon: syncMeta.isSyncing
                                    ? SizedBox(
                                        width: 15,
                                        height: 15,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          color: primary,
                                        ),
                                      )
                                    : const Icon(Icons.refresh_rounded,
                                        size: 17),
                                label: const Text('SINCRONIZAR'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      if (syncMeta.lastSyncedAt != null &&
                          syncMeta.errorMessage == null) ...[
                        const SizedBox(height: 8),
                        Text(
                          'Última sincronización: ${_formatDate(syncMeta.lastSyncedAt!)}',
                          style: AppTheme.telemetryNumericStyle(
                            fontSize: 11,
                            color: isDark ? Colors.white60 : Colors.black54,
                          ),
                        ),
                      ],
                      if (syncMeta.errorMessage != null) ...[
                        const SizedBox(height: 8),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: RenaultSportPalette.coldEngineAmber
                                .withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: RenaultSportPalette.coldEngineAmber
                                  .withValues(alpha: 0.6),
                            ),
                          ),
                          child: Text(
                            syncMeta.errorMessage!,
                            style: const TextStyle(
                              fontSize: 12,
                              color: RenaultSportPalette.coldEngineAmber,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),

              const SizedBox(height: 12),

              // 2. Sesión actual en vivo (Guardar / Reiniciar picos)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Wrap(
                        spacing: 10,
                        runSpacing: 8,
                        alignment: WrapAlignment.spaceBetween,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            'SESIÓN ACTUAL EN VIVO',
                            style: AppTheme.renaultSportHeaderStyle(
                              fontSize: 15,
                              color: RenaultSportPalette.siriusLiquidYellow,
                            ),
                          ),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              OutlinedButton.icon(
                                onPressed: () => ref
                                    .read(telemetrySessionStatsProvider.notifier)
                                    .resetSessionStats(),
                                icon: const Icon(
                                  Icons.restart_alt_rounded,
                                  size: 16,
                                ),
                                label: const Text('REINICIAR PICOS'),
                              ),
                              ElevatedButton.icon(
                                onPressed: notifier.syncCurrentSessionToCloud,
                                icon: const Icon(
                                  Icons.cloud_upload_rounded,
                                  size: 16,
                                ),
                                label: const Text('GUARDAR SESIÓN'),
                              ),
                            ],
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 12,
                        runSpacing: 10,
                        children: [
                          _LiveStatChip(
                            label: 'PEAK RPM',
                            value: '${stats.peakRpm.round()}',
                            color: primary,
                          ),
                          _LiveStatChip(
                            label: 'MAX KM/H',
                            value: '${stats.maxSpeedKmh}',
                            color: RenaultSportPalette.oemShiftGreen,
                          ),
                          _LiveStatChip(
                            label: 'TEMP MÁX',
                            value: '${stats.maxCoolantTempC.toStringAsFixed(0)} °C',
                            color: RenaultSportPalette.coldEngineAmber,
                          ),
                          _LiveStatChip(
                            label: '0-100 KM/H',
                            value: stats.bestZeroToHundredSec != null
                                ? '${stats.bestZeroToHundredSec}s'
                                : '--',
                            color: RenaultSportPalette.siriusLiquidYellow,
                          ),
                          _LiveStatChip(
                            label: 'MUESTRAS',
                            value: '${stats.totalSamples}',
                            color: Colors.cyanAccent,
                          ),
                          _LiveStatChip(
                            label: 'FALLAS DTC',
                            value: '${dtcs.length}',
                            color: dtcs.isEmpty
                                ? RenaultSportPalette.oemShiftGreen
                                : RenaultSportPalette.revLimiterRed,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),

              // 3. Resumen de Laps GPS si existe sesión activa o vueltas completadas
              if (mapState.isLapSessionActive ||
                  mapState.completedLaps.isNotEmpty) ...[
                const SizedBox(height: 12),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Wrap(
                      spacing: 12,
                      runSpacing: 8,
                      alignment: WrapAlignment.spaceBetween,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.flag_rounded,
                              color: RenaultSportPalette.oemShiftGreen,
                              size: 20,
                            ),
                            const SizedBox(width: 8),
                            Flexible(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'LAPS GPS • ${mapState.startStreetName.isNotEmpty ? mapState.startStreetName : mapState.currentStreetName}',
                                    style: AppTheme.renaultSportHeaderStyle(
                                      fontSize: 13.5,
                                      color: RenaultSportPalette.oemShiftGreen,
                                    ),
                                  ),
                                  Text(
                                    '${mapState.completedLaps.length} vueltas'
                                    '${mapState.bestLapSec != null ? ' • Mejor: ${_formatLapClock(mapState.bestLapSec!)}' : ''}',
                                    style: const TextStyle(fontSize: 12),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        OutlinedButton.icon(
                          onPressed: () => ref
                              .read(cockpitTabProvider.notifier)
                              .selectTab(CockpitSectionTab.trackMapGps),
                          icon: const Icon(Icons.map_rounded, size: 16),
                          label: const Text('VER EN TRACK'),
                        ),
                      ],
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 14),

              // 4. Historial completo de sesiones Blackbox Cloud
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'HISTORIAL DE SESIONES (${sessions.length})',
                    style: AppTheme.renaultSportHeaderStyle(
                      fontSize: 15,
                      color: primary,
                    ),
                  ),
                  Text(
                    'Sincronización multi-dispositivo',
                    style: TextStyle(
                      fontSize: 11.5,
                      color: isDark ? Colors.white60 : Colors.black54,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              if (sessions.isEmpty)
                const Card(
                  child: Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20, vertical: 34),
                    child: Center(
                      child: Text(
                        'Todavía no has guardado sesiones en Blackbox Cloud.\nPresiona "GUARDAR SESIÓN" arriba para registrar tus picos en Firebase.',
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
                )
              else
                LayoutBuilder(
                  builder: (context, constraints) {
                    final useTwoCols = constraints.maxWidth >= 780;
                    final cardWidth = useTwoCols
                        ? (constraints.maxWidth - 12) / 2
                        : constraints.maxWidth;

                    return Wrap(
                      spacing: 12,
                      runSpacing: 12,
                      children: sessions.map((rec) {
                        return SizedBox(
                          width: cardWidth,
                          child: Card(
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceBetween,
                                    children: [
                                      Expanded(
                                        child: Text(
                                          _formatDate(rec.syncedAt),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style:
                                              AppTheme.renaultSportHeaderStyle(
                                            fontSize: 13.5,
                                            color: primary,
                                          ),
                                        ),
                                      ),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 7,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: (rec.syncedToFirebase
                                                  ? RenaultSportPalette
                                                      .oemShiftGreen
                                                  : RenaultSportPalette
                                                      .coldEngineAmber)
                                              .withValues(alpha: 0.16),
                                          borderRadius:
                                              BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          rec.syncedToFirebase
                                              ? 'FIREBASE OK'
                                              : 'LOCAL',
                                          style: AppTheme.telemetryNumericStyle(
                                            fontSize: 9.5,
                                            color: rec.syncedToFirebase
                                                ? RenaultSportPalette
                                                    .oemShiftGreen
                                                : RenaultSportPalette
                                                    .coldEngineAmber,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      IconButton(
                                        visualDensity: VisualDensity.compact,
                                        tooltip: 'Eliminar sesión',
                                        onPressed: () => notifier
                                            .deleteSession(rec.sessionId),
                                        icon: const Icon(
                                          Icons.delete_outline_rounded,
                                          size: 18,
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 16,
                                    runSpacing: 8,
                                    children: [
                                      _RecordStatColumn(
                                        label: 'PEAK RPM',
                                        value: '${rec.peakRpm.round()}',
                                      ),
                                      _RecordStatColumn(
                                        label: 'MAX VEL',
                                        value: '${rec.maxSpeedKmh} km/h',
                                      ),
                                      _RecordStatColumn(
                                        label: 'TEMP MÁX',
                                        value:
                                            '${rec.maxCoolantTempC.toStringAsFixed(0)} °C',
                                      ),
                                      _RecordStatColumn(
                                        label: '0-100 KM/H',
                                        value: rec.zeroToHundredSec != null
                                            ? '${rec.zeroToHundredSec}s'
                                            : '--',
                                      ),
                                      _RecordStatColumn(
                                        label: 'FALLAS DTC',
                                        value: '${rec.dtcCount}',
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _LiveStatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _LiveStatChip({
    required this.label,
    required this.value,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 9.5, fontWeight: FontWeight.w700),
          ),
          Text(
            value,
            style: AppTheme.telemetryNumericStyle(
              fontSize: 15,
              color: color,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _RecordStatColumn extends StatelessWidget {
  final String label;
  final String value;

  const _RecordStatColumn({
    required this.label,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontSize: 9)),
        Text(
          value,
          style: AppTheme.telemetryNumericStyle(
            fontSize: 13.5,
            color: RenaultSportPalette.oemShiftGreen,
          ),
        ),
      ],
    );
  }
}
