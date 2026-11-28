import '../utils/audio_format_info.dart';

/// Apps on the Mac that play what the app's own (stereo) player must not:
/// multichannel and immersive audio (v3.0.6). The app never downmixes such a
/// file and never "plays" it as silence; it hands it to one of these, or lets
/// the user drag it into one.
///
/// Product names are not translated: they are the apps' own names.
enum ExternalPlayer {
  /// Mondaur's UTUVO Player Pro: any multichannel or ADM file. The default.
  utuvoPlayerPro('com.mondaur.utuvo.player.pro', 'UTUVO Player Pro'),

  /// Dolby Atmos Renderer: only Dolby Atmos ADM BWF masters — an ADM file
  /// carrying Dolby's metadata. A 7.1.4 bounce is not Dolby Atmos.
  dolbyAtmosRenderer('com.dolby.atmos.renderer', 'Dolby Atmos Renderer');

  const ExternalPlayer(this.bundleId, this.displayName);

  final String bundleId;
  final String displayName;

  static ExternalPlayer? byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return null;
  }
}

/// Which external player the user prefers (Settings > Audio files),
/// device-local: it names apps on this Mac.
enum ExternalPlayerPreference {
  utuvoPlayerPro,
  dolbyAtmosRenderer,

  /// Ask each time, among the players that suit the file.
  ask;

  static ExternalPlayerPreference byName(String? name) {
    for (final p in values) {
      if (p.name == name) return p;
    }
    return ExternalPlayerPreference.utuvoPlayerPro;
  }

  ExternalPlayer? get player => switch (this) {
        utuvoPlayerPro => ExternalPlayer.utuvoPlayerPro,
        dolbyAtmosRenderer => ExternalPlayer.dolbyAtmosRenderer,
        ask => null,
      };
}

/// Whether [format] must not go through the app's stereo player: more than
/// two channels, or an ADM file. Unknown formats (no readable header: MP3,
/// AAC) are left to the stereo player, which plays them as they are.
bool needsExternalPlayer(AudioFormatInfo? format) =>
    format != null && (format.isAdm || format.isMultichannel);

/// Whether [player] suits [format]. UTUVO Player Pro takes any multichannel
/// or ADM file; Dolby Atmos Renderer only a Dolby Atmos ADM master — never
/// a plain multichannel bounce, whatever its layout.
bool externalPlayerSuits(ExternalPlayer player, AudioFormatInfo? format) {
  if (!needsExternalPlayer(format)) return false;
  return switch (player) {
    ExternalPlayer.utuvoPlayerPro => true,
    ExternalPlayer.dolbyAtmosRenderer => format!.isDolbyAtmosAdm,
  };
}

/// The installed players that suit [format], the preferred one first and
/// then in [ExternalPlayer]'s order. Empty when none is installed or the
/// file needs none.
List<ExternalPlayer> externalPlayersFor(
  AudioFormatInfo? format, {
  required Set<ExternalPlayer> installed,
  required ExternalPlayerPreference preference,
}) {
  final suitable = [
    for (final p in ExternalPlayer.values)
      if (installed.contains(p) && externalPlayerSuits(p, format)) p,
  ];
  final preferred = preference.player;
  if (preferred != null && suitable.remove(preferred)) {
    suitable.insert(0, preferred);
  }
  return suitable;
}

/// What a click on "play in an external player" does for [format]: open it
/// straight away in one player, or ask among several. Null when no
/// installed player suits it.
({ExternalPlayer? openNow, List<ExternalPlayer> choices})? externalPlayAction(
  AudioFormatInfo? format, {
  required Set<ExternalPlayer> installed,
  required ExternalPlayerPreference preference,
}) {
  final players = externalPlayersFor(format,
      installed: installed, preference: preference);
  if (players.isEmpty) return null;
  if (preference == ExternalPlayerPreference.ask && players.length > 1) {
    return (openNow: null, choices: players);
  }
  return (openNow: players.first, choices: players);
}
