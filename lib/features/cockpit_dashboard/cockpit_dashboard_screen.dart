import 'dart:io';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/theme/app_theme.dart';
import '../../core/theme/theme_provider.dart';
import '../auth_profile/providers/auth_profile_providers.dart';
import '../auth_profile/screens/pilot_profile_screen.dart';
import '../cloud_sync_fcm/blackbox_hub_screen.dart';
import '../cloud_sync_fcm/blackbox_realtime_service.dart';
import '../digital_garage_payments/providers/payment_garage_providers.dart';
import '../digital_garage_payments/screens/digital_garage_screen.dart';
import '../map_track/track_map_screen.dart';
import '../multimedia/multimedia_hub_screen.dart';
import '../telemetry/models/obd_telemetry_frame.dart';
import '../telemetry/providers/telemetry_providers.dart';
import '../telemetry/services/elm327_service.dart';
import '../telemetry/widgets/engine_mini_gauges_widget.dart';
import '../telemetry/widgets/g_force_ball_widget.dart';
import '../telemetry/widgets/renault_sport_tachometer_widget.dart';
import 'widgets/dtc_diagnostic_sheet.dart';
import 'widgets/launcher_dock_widget.dart';

/// Página activa dentro de la tarjeta deslizable de Cockpit:
/// - `rpmOnly`: 100% ancho de banda K-Line al tacómetro de RPM.
/// - `engineGauges`: 0% carga de RPM; 100% a mini-gauges de parámetros F4R.
enum CockpitClusterPage {
  rpmOnly,
  engineGauges,
}

class CockpitClusterPageNotifier extends Notifier<CockpitClusterPage> {
  @override
  CockpitClusterPage build() => CockpitClusterPage.rpmOnly;

  void selectPage(CockpitClusterPage page) => state = page;
}

final cockpitClusterPageProvider =
    NotifierProvider<CockpitClusterPageNotifier, CockpitClusterPage>(
  CockpitClusterPageNotifier.new,
);

final cockpitPageControllerProvider =
    Provider.autoDispose<PageController>((ref) {
  final initialPage =
      ref.read(cockpitClusterPageProvider) == CockpitClusterPage.rpmOnly ? 0 : 1;
  final controller = PageController(initialPage: initialPage);
  ref.onDispose(controller.dispose);
  return controller;
});

/// Sincroniza el perfil de sondeo K-Line con la vista activa para liberar ancho de banda Bluetooth.
final obdPollingProfileSyncProvider = Provider<void>((ref) {
  final activeTab = ref.watch(cockpitTabProvider);
  final clusterPage = ref.watch(cockpitClusterPageProvider);
  final includeExtended = ref.watch(
    digitalGaragePaymentProvider
        .select((s) => s.activeSubscription.unlocksExtendedSiriusPids),
  );
  final obdNotifier = ref.read(obdConnectionModeProvider.notifier);

  final ObdPollingProfile nextProfile;
  if (activeTab == CockpitSectionTab.cockpitHud) {
    nextProfile = clusterPage == CockpitClusterPage.rpmOnly
        ? ObdPollingProfile.rpmOnly
        : ObdPollingProfile.engineParameters;
  } else {
    nextProfile = ObdPollingProfile.backgroundMinimal;
  }

  Future.microtask(() {
    obdNotifier.updatePollingProfile(
      nextProfile,
      includeExtendedPids: includeExtended,
    );
  });
});

/// Pantalla Principal de **RS Digital Cockpit**.
/// Diseño 100% responsivo para tablets y teléfonos, libre de desbordamientos.
class CockpitDashboardScreen extends ConsumerWidget {
  const CockpitDashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final telemetryAsync = ref.watch(obdTelemetryStreamProvider);
    final frame = telemetryAsync.valueOrNull ??
        ObdTelemetryFrame.initial(isSimulator: false);
    final activeTab = ref.watch(cockpitTabProvider);
    ref.watch(blackboxRealtimeProvider);
    ref.watch(obdPollingProfileSyncProvider);

    return Scaffold(
      body: SafeArea(
        child: LayoutBuilder(
          builder: (context, constraints) {
            final isTabletLandscape =
                constraints.maxWidth >= 840 && constraints.maxHeight >= 480;

            return Padding(
              padding: EdgeInsets.symmetric(
                horizontal: isTabletLandscape ? 14 : 10,
                vertical: 8,
              ),
              child: Column(
                children: [
                  // 1. Barra Superior Compacta
                  _CockpitTopHeaderBar(frame: frame),
                  const SizedBox(height: 8),

                  // 2. Contenido Principal Responsivo
                  Expanded(
                    child: switch (activeTab) {
                      CockpitSectionTab.cockpitHud => isTabletLandscape
                          ? _TabletTwoColumnCockpitView(frame: frame)
                          : _CompactScrollableCockpitView(frame: frame),
                      CockpitSectionTab.multimediaHub =>
                        const MultimediaHubScreen(),
                      CockpitSectionTab.blackboxCloud =>
                        const BlackboxHubScreen(),
                      CockpitSectionTab.trackMapGps => const TrackMapScreen(
                          isMiniLiveMap: false,
                        ),
                      CockpitSectionTab.digitalGarage =>
                        const DigitalGarageScreen(),
                      CockpitSectionTab.pilotProfile =>
                        const PilotProfileScreen(),
                      CockpitSectionTab.ecuDiagnostics =>
                        const DtcDiagnosticSheet(),
                    },
                  ),
                  const SizedBox(height: 8),

                  // 3. Dock Inferior Centrado
                  const LauncherDockWidget(),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _CockpitTopHeaderBar extends ConsumerWidget {
  final ObdTelemetryFrame frame;

  const _CockpitTopHeaderBar({required this.frame});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final adapterState = ref.watch(obdConnectionModeProvider);
    final obdNotifier = ref.read(obdConnectionModeProvider.notifier);
    final themeMode = ref.watch(themeModeProvider);
    final profile = ref.watch(pilotAuthProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final isSimulator = adapterState.mode == ObdConnectionMode.trackSimulator;

    final Color obdBadgeColor;
    final String obdBadgeLabel;
    final IconData obdBadgeIcon;

    if (!adapterState.ecuEnabled) {
      obdBadgeColor = Colors.grey;
      obdBadgeLabel = 'ECU OFF';
      obdBadgeIcon = Icons.bluetooth_disabled_rounded;
    } else if (isSimulator) {
      obdBadgeColor = RenaultSportPalette.oemShiftGreen;
      obdBadgeLabel = 'SIMULADOR';
      obdBadgeIcon = Icons.sports_motorsports_rounded;
    } else {
      switch (adapterState.linkStatus) {
        case ObdLinkStatus.connectedEcuReady:
          obdBadgeColor = RenaultSportPalette.oemShiftGreen;
          obdBadgeLabel = adapterState.selectedDeviceName ?? 'OBD2 OK';
          obdBadgeIcon = Icons.bluetooth_connected_rounded;
        case ObdLinkStatus.adapterConnectedEcuWaiting:
          obdBadgeColor = RenaultSportPalette.coldEngineAmber;
          obdBadgeLabel = 'ESPERANDO ECU';
          obdBadgeIcon = Icons.hourglass_top_rounded;
        case ObdLinkStatus.connecting:
        case ObdLinkStatus.reconnecting:
          obdBadgeColor = RenaultSportPalette.siriusLiquidYellow;
          obdBadgeLabel = adapterState.linkStatus == ObdLinkStatus.reconnecting
              ? 'RECONECTANDO...'
              : 'CONECTANDO...';
          obdBadgeIcon = Icons.bluetooth_searching_rounded;
        case ObdLinkStatus.disconnected:
          obdBadgeColor = RenaultSportPalette.siriusLiquidYellow;
          obdBadgeLabel = 'CONECTAR OBD2';
          obdBadgeIcon = Icons.bluetooth_searching_rounded;
      }
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).cardTheme.color,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: primary.withValues(alpha: 0.4),
          width: 1.1,
        ),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: primary,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'RS',
              style: AppTheme.renaultSportHeaderStyle(
                fontSize: 14,
                color: Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'RS DIGITAL COCKPIT',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: AppTheme.renaultSportHeaderStyle(
                fontSize: 15,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Botón de Estado OBD2 / ECU ON-OFF
                InkWell(
                  onTap: () => ref
                      .read(cockpitTabProvider.notifier)
                      .selectTab(CockpitSectionTab.ecuDiagnostics),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: obdBadgeColor.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: obdBadgeColor),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(obdBadgeIcon, size: 15, color: obdBadgeColor),
                        const SizedBox(width: 6),
                        Text(
                          obdBadgeLabel,
                          style: AppTheme.telemetryNumericStyle(
                            fontSize: 11,
                            color: obdBadgeColor,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                if (isSimulator && adapterState.ecuEnabled) ...[
                  const SizedBox(width: 8),
                  InkWell(
                    onTap: obdNotifier.toggleSimulatorEngineWarmth,
                    borderRadius: BorderRadius.circular(8),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: (frame.isEngineCold
                                ? RenaultSportPalette.coldEngineAmber
                                : RenaultSportPalette.oemShiftGreen)
                            .withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: frame.isEngineCold
                              ? RenaultSportPalette.coldEngineAmber
                              : RenaultSportPalette.oemShiftGreen,
                        ),
                      ),
                      child: Text(
                        '${frame.coolantTempC.toStringAsFixed(0)}°C',
                        style: AppTheme.telemetryNumericStyle(
                          fontSize: 11,
                          color: frame.isEngineCold
                              ? RenaultSportPalette.coldEngineAmber
                              : RenaultSportPalette.oemShiftGreen,
                        ),
                      ),
                    ),
                  ),
                ],

                const SizedBox(width: 6),

                // Selector de Tema: Auto (Android) / Oscuro / Claro
                PopupMenuButton<ThemeMode>(
                  tooltip: 'Cambiar Tema (Auto / Oscuro / Claro)',
                  initialValue: themeMode,
                  onSelected: (mode) =>
                      ref.read(themeModeProvider.notifier).setThemeMode(mode),
                  itemBuilder: (context) => [
                    PopupMenuItem<ThemeMode>(
                      value: ThemeMode.system,
                      child: Row(
                        children: [
                          Icon(
                            Icons.brightness_auto_rounded,
                            size: 18,
                            color: primary,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Auto (Android)')),
                          if (themeMode == ThemeMode.system)
                            Icon(Icons.check_rounded, size: 17, color: primary),
                        ],
                      ),
                    ),
                    PopupMenuItem<ThemeMode>(
                      value: ThemeMode.dark,
                      child: Row(
                        children: [
                          Icon(
                            Icons.nightlight_round,
                            size: 18,
                            color: primary,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Oscuro (Night Stage)')),
                          if (themeMode == ThemeMode.dark)
                            Icon(Icons.check_rounded, size: 17, color: primary),
                        ],
                      ),
                    ),
                    PopupMenuItem<ThemeMode>(
                      value: ThemeMode.light,
                      child: Row(
                        children: [
                          Icon(
                            Icons.wb_sunny_rounded,
                            size: 18,
                            color: primary,
                          ),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Claro (Daylight Cup)')),
                          if (themeMode == ThemeMode.light)
                            Icon(Icons.check_rounded, size: 17, color: primary),
                        ],
                      ),
                    ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.all(6),
                    child: Icon(
                      switch (themeMode) {
                        ThemeMode.system => Icons.brightness_auto_rounded,
                        ThemeMode.dark => Icons.nightlight_round,
                        ThemeMode.light => Icons.wb_sunny_rounded,
                      },
                      size: 20,
                      color: primary,
                    ),
                  ),
                ),

                // Avatar del Piloto
                if (profile != null) ...[
                  const SizedBox(width: 4),
                  InkWell(
                    onTap: () => ref
                        .read(cockpitTabProvider.notifier)
                        .selectTab(CockpitSectionTab.pilotProfile),
                    customBorder: const CircleBorder(),
                    child: CircleAvatar(
                      radius: 15,
                      backgroundColor: primary,
                      child: ClipOval(
                        child: profile.localAvatarPath != null &&
                                File(profile.localAvatarPath!).existsSync()
                            ? Image.file(
                                File(profile.localAvatarPath!),
                                width: 28,
                                height: 28,
                                fit: BoxFit.cover,
                              )
                            : CachedNetworkImage(
                                imageUrl: profile.avatarUrl,
                                width: 28,
                                height: 28,
                                fit: BoxFit.cover,
                                errorWidget: (_, __, ___) =>
                                    const Icon(Icons.person, size: 16),
                              ),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Vista apaisada en Tablet: Cluster ampliado deslizable (izquierda/centro) + G-Force & Minimapa (derecha)
class _TabletTwoColumnCockpitView extends StatelessWidget {
  final ObdTelemetryFrame frame;

  const _TabletTwoColumnCockpitView({required this.frame});

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          flex: 8,
          child: _SwipeableTelemetryClusterCard(frame: frame),
        ),
        const SizedBox(width: 10),
        const Expanded(
          flex: 3,
          child: Column(
            children: [
              Expanded(
                flex: 5,
                child: GForceBallWidget(),
              ),
              SizedBox(height: 8),
              Expanded(
                flex: 5,
                child: TrackMapScreen(isMiniLiveMap: true),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Vista vertical en Smartphone: Cluster deslizable + G-Force + Minimapa
class _CompactScrollableCockpitView extends StatelessWidget {
  final ObdTelemetryFrame frame;

  const _CompactScrollableCockpitView({required this.frame});

  @override
  Widget build(BuildContext context) {
    final clusterHeight =
        (MediaQuery.sizeOf(context).width * 1.05).clamp(360.0, 440.0);

    return SingleChildScrollView(
      child: Column(
        children: [
          SizedBox(
            height: clusterHeight,
            child: _SwipeableTelemetryClusterCard(frame: frame),
          ),
          const SizedBox(height: 10),
          const SizedBox(
            height: 250,
            child: GForceBallWidget(),
          ),
          const SizedBox(height: 10),
          const SizedBox(
            height: 220,
            child: TrackMapScreen(isMiniLiveMap: true),
          ),
        ],
      ),
    );
  }
}

/// Tarjeta ampliada y deslizable del Cockpit:
/// - Página 0: Tacómetro 100% RPM (`010C1`), liberando carga Bluetooth.
/// - Página 1: Mini-gauges radiales de parámetros del motor F4R (0% carga de RPM).
class _SwipeableTelemetryClusterCard extends ConsumerWidget {
  final ObdTelemetryFrame frame;

  const _SwipeableTelemetryClusterCard({required this.frame});

  void _goToPage(WidgetRef ref, CockpitClusterPage target) {
    ref.read(cockpitClusterPageProvider.notifier).selectPage(target);
    final controller = ref.read(cockpitPageControllerProvider);
    if (controller.hasClients) {
      controller.animateToPage(
        target == CockpitClusterPage.rpmOnly ? 0 : 1,
        duration: const Duration(milliseconds: 240),
        curve: Curves.easeOutCubic,
      );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activePage = ref.watch(cockpitClusterPageProvider);
    final pageController = ref.watch(cockpitPageControllerProvider);
    final primary = Theme.of(context).colorScheme.primary;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isRpmPage = activePage == CockpitClusterPage.rpmOnly;

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
        child: Column(
          children: [
            // Barra superior de cambio rápido / indicador de deslizamiento
            Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _ClusterModePill(
                          label: 'TACÓMETRO RPM',
                          icon: Icons.speed_rounded,
                          selected: isRpmPage,
                          primary: primary,
                          isDark: isDark,
                          onTap: () =>
                              _goToPage(ref, CockpitClusterPage.rpmOnly),
                        ),
                        const SizedBox(width: 6),
                        _ClusterModePill(
                          label: 'PARÁMETROS F4R',
                          icon: Icons.tune_rounded,
                          selected: !isRpmPage,
                          primary: primary,
                          isDark: isDark,
                          onTap: () =>
                              _goToPage(ref, CockpitClusterPage.engineGauges),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: (frame.kLineHz > 0
                            ? RenaultSportPalette.oemShiftGreen
                            : Colors.grey)
                        .withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: (frame.kLineHz > 0
                              ? RenaultSportPalette.oemShiftGreen
                              : Colors.grey)
                          .withValues(alpha: 0.6),
                    ),
                  ),
                  child: Text(
                    '${frame.kLineHz} Hz',
                    style: AppTheme.telemetryNumericStyle(
                      fontSize: 10.5,
                      color: frame.kLineHz > 0
                          ? RenaultSportPalette.oemShiftGreen
                          : Colors.grey,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _PageDot(active: isRpmPage, primary: primary),
                    const SizedBox(width: 4),
                    _PageDot(active: !isRpmPage, primary: primary),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 8),

            // Contenido deslizable horizontalmente
            Expanded(
              child: PageView(
                controller: pageController,
                onPageChanged: (index) {
                  ref.read(cockpitClusterPageProvider.notifier).selectPage(
                        index == 0
                            ? CockpitClusterPage.rpmOnly
                            : CockpitClusterPage.engineGauges,
                      );
                },
                children: [
                  RenaultSportTachometerWidget(
                    frame: frame,
                    rpmOnlyMode: true,
                  ),
                  EngineMiniGaugesWidget(frame: frame),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ClusterModePill extends StatelessWidget {
  final String label;
  final IconData icon;
  final bool selected;
  final Color primary;
  final bool isDark;
  final VoidCallback onTap;

  const _ClusterModePill({
    required this.label,
    required this.icon,
    required this.selected,
    required this.primary,
    required this.isDark,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final fg = selected
        ? (isDark ? Colors.black : Colors.white)
        : (isDark ? Colors.white70 : const Color(0xFF334155));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: selected ? primary : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: selected
                ? primary
                : (isDark ? Colors.white24 : Colors.black12),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: fg),
            const SizedBox(width: 5),
            Text(
              label,
              style: AppTheme.renaultSportHeaderStyle(
                fontSize: 11,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _PageDot extends StatelessWidget {
  final bool active;
  final Color primary;

  const _PageDot({
    required this.active,
    required this.primary,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 180),
      width: active ? 14 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: active ? primary : Colors.white24,
        borderRadius: BorderRadius.circular(4),
      ),
    );
  }
}
