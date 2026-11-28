import 'package:flutter_test/flutter_test.dart';

import 'package:daw_project_manager/services/external_player.dart';
import 'package:daw_project_manager/utils/audio_format_info.dart';

/// v3.0.6 — multichannel and immersive audio goes to an external player
/// (UTUVO Player Pro by default; Dolby Atmos Renderer only for Dolby Atmos
/// ADM masters), never to the app's stereo player.
void main() {
  const stereo = AudioFormatInfo(
      container: AudioContainer.wav, channels: 2, sampleRate: 48000);
  // A 7.1.4 bounce (12 ch, its mask says so) with no ADM: not Dolby Atmos.
  const bed714 = AudioFormatInfo(
      container: AudioContainer.wav,
      channels: 12,
      sampleRate: 48000,
      channelMask: 0x2D63F);
  const tenChAiff = AudioFormatInfo(
      container: AudioContainer.aiff, channels: 10, sampleRate: 96000);
  // ADM with Dolby's metadata: a Dolby Atmos master.
  const atmosAdm = AudioFormatInfo(
      container: AudioContainer.rf64,
      channels: 103,
      sampleRate: 48000,
      hasAxml: true,
      hasChna: true,
      hasDolbyMetadata: true);
  // ADM without Dolby's metadata: immersive, but not Dolby Atmos.
  const plainAdm = AudioFormatInfo(
      container: AudioContainer.bw64,
      channels: 16,
      sampleRate: 48000,
      hasAxml: true,
      hasChna: true);

  const both = {
    ExternalPlayer.utuvoPlayerPro,
    ExternalPlayer.dolbyAtmosRenderer,
  };

  test('stereo and unknown formats stay with the app\'s player', () {
    expect(needsExternalPlayer(stereo), isFalse);
    expect(needsExternalPlayer(null), isFalse);
    expect(
        externalPlayersFor(stereo,
            installed: both,
            preference: ExternalPlayerPreference.utuvoPlayerPro),
        isEmpty);
  });

  test('multichannel and ADM files need an external player', () {
    for (final f in [bed714, tenChAiff, atmosAdm, plainAdm]) {
      expect(needsExternalPlayer(f), isTrue);
    }
  });

  test('a 7.1.4 file is not Dolby Atmos: the Renderer is never offered', () {
    expect(externalPlayerSuits(ExternalPlayer.dolbyAtmosRenderer, bed714),
        isFalse);
    expect(externalPlayerSuits(ExternalPlayer.dolbyAtmosRenderer, plainAdm),
        isFalse);
    expect(
        externalPlayersFor(bed714,
            installed: both,
            preference: ExternalPlayerPreference.dolbyAtmosRenderer),
        [ExternalPlayer.utuvoPlayerPro]);
  });

  test('a Dolby Atmos ADM master suits both; the preferred one comes first',
      () {
    expect(
        externalPlayersFor(atmosAdm,
            installed: both,
            preference: ExternalPlayerPreference.utuvoPlayerPro),
        [ExternalPlayer.utuvoPlayerPro, ExternalPlayer.dolbyAtmosRenderer]);
    expect(
        externalPlayersFor(atmosAdm,
            installed: both,
            preference: ExternalPlayerPreference.dolbyAtmosRenderer),
        [ExternalPlayer.dolbyAtmosRenderer, ExternalPlayer.utuvoPlayerPro]);
  });

  test('only installed players are offered', () {
    expect(
        externalPlayersFor(atmosAdm,
            installed: {ExternalPlayer.dolbyAtmosRenderer},
            preference: ExternalPlayerPreference.utuvoPlayerPro),
        [ExternalPlayer.dolbyAtmosRenderer]);
    expect(
        externalPlayAction(tenChAiff,
            installed: {ExternalPlayer.dolbyAtmosRenderer},
            preference: ExternalPlayerPreference.utuvoPlayerPro),
        isNull);
  });

  test('"ask" asks only when there is a choice', () {
    final several = externalPlayAction(atmosAdm,
        installed: both, preference: ExternalPlayerPreference.ask)!;
    expect(several.openNow, isNull);
    expect(several.choices, hasLength(2));
    final one = externalPlayAction(tenChAiff,
        installed: both, preference: ExternalPlayerPreference.ask)!;
    expect(one.openNow, ExternalPlayer.utuvoPlayerPro);
  });

  test('the stored preference falls back to UTUVO Player Pro', () {
    expect(ExternalPlayerPreference.byName(null),
        ExternalPlayerPreference.utuvoPlayerPro);
    expect(ExternalPlayerPreference.byName('nonsense'),
        ExternalPlayerPreference.utuvoPlayerPro);
    expect(ExternalPlayerPreference.byName('ask'),
        ExternalPlayerPreference.ask);
  });

  test('bundle ids are the installed apps\' own', () {
    expect(ExternalPlayer.utuvoPlayerPro.bundleId,
        'com.mondaur.utuvo.player.pro');
    expect(ExternalPlayer.dolbyAtmosRenderer.bundleId,
        'com.dolby.atmos.renderer');
  });
}
