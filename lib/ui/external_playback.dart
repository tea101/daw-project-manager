import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:path/path.dart' as p;
import 'package:super_drag_and_drop/super_drag_and_drop.dart';

import '../generated/l10n/app_localizations.dart';
import '../providers/providers.dart';
import '../services/external_player.dart';
import '../services/macos_file_integration.dart';
import '../utils/audio_format_info.dart';
import 'app_snack_bar.dart';
import 'widgets/semantics_safe.dart';

/// What the app does with a file its stereo player must not play
/// ([needsExternalPlayer]): hand it to the user's external player (v3.0.6).
///
/// Never a downmix, never silence: when no suitable player is installed the
/// user is told so. The file itself is only handed over — nothing in it, or
/// in the player, is changed.
Future<void> openInExternalPlayer(
  BuildContext context,
  WidgetRef ref,
  String path,
  AudioFormatInfo? format,
) async {
  final l10n = AppLocalizations.of(context)!;
  final messenger = ScaffoldMessenger.of(context);
  final installed =
      await ref.read(installedExternalPlayersProvider.future);
  if (!context.mounted) return;
  final action = externalPlayAction(
    format,
    installed: installed,
    preference: ref.read(externalPlayerPreferenceProvider),
  );
  if (action == null) {
    messenger.showAppSnackBar(
        SnackBar(content: Text(l10n.externalPlayerNoneInstalled)));
    return;
  }
  var player = action.openNow;
  if (player == null) {
    player = await showDialog<ExternalPlayer>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(l10n.externalPlayerChooseTitle),
        children: [
          for (final choice in action.choices)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, choice),
              child: Text(choice.displayName),
            ),
        ],
      ),
    );
    if (player == null) return;
  }
  final ok = await MacFileIntegration.openWith(player.bundleId, path);
  messenger.showAppSnackBar(SnackBar(
    content: Text(ok
        ? l10n.externalPlayerSent(player.displayName)
        : l10n.externalPlayerFailed(player.displayName)),
  ));
}

/// The name of the player a click would use for [format], for a button's
/// label or tooltip; null when none suits it (or "ask" with several).
ExternalPlayer? externalPlayerShownFor(
  AudioFormatInfo? format, {
  required Set<ExternalPlayer> installed,
  required ExternalPlayerPreference preference,
}) =>
    externalPlayAction(format, installed: installed, preference: preference)
        ?.openNow;

/// A handle that drags the file itself (its own path, never a copy) out of
/// the app — into UTUVO Player Pro's window ("Drag a mix here"), Finder, or
/// any app that takes a dropped file. The way that always works, whatever
/// the player does with a file handed to it by macOS.
class ExternalPlayerDragHandle extends StatelessWidget {
  const ExternalPlayerDragHandle({super.key, required this.path});

  final String path;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return DragItemWidget(
      allowedOperations: () => [DropOperation.copy],
      dragItemProvider: (request) async {
        final item = DragItem(suggestedName: p.basename(path));
        item.add(Formats.fileUri(Uri.file(path)));
        return item;
      },
      child: DraggableWidget(
        child: StandaloneTooltip(
          message: l10n.externalPlayerDragTooltip,
          child: const Padding(
            padding: EdgeInsets.all(6),
            child: Icon(Icons.drag_indicator, size: 18),
          ),
        ),
      ),
    );
  }
}
