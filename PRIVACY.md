# Privacy policy – DPM Backup

*Last updated: 26 November 2026*

"DPM Backup" is the Google sign-in name of a personal, customised build of
[DAW Project Manager](https://github.com/bandpassrecords/daw-project-manager),
maintained in this fork (tea101/daw-project-manager). It is not an official
Bandpass Records release.

## What the app does with your Google account

- It asks only for the `drive.file` permission. It can see and change only the
  files and folders it creates itself in your Google Drive, not the rest of
  your Drive.
- It uses that access only to back up and restore your own DAW Project Manager
  library: a "DAW Project Manager" folder containing the library database
  (project details, notes, tags, phases, to-dos and releases), MIDI data,
  preview mixdowns and release artwork, plus earlier backup copies.
- Your project and audio files on your own drives are not uploaded.
- Your Google sign-in token is stored only on your own computer.

## What is not done

- No data is sent to the developer of this build or to any other server.
  The app talks directly to Google's sign-in and Drive services.
- No data is sold, shared, used for advertising or used to train AI models.

## Other network use

If you turn on "Check for updates", the app asks GitHub's public API for the
latest release number. No personal data is sent.

## Removing access

You can remove the app's access at any time at
<https://myaccount.google.com/permissions>, and delete the
"DAW Project Manager" folder from your Drive.

## Contact

Open an issue in this repository: <https://github.com/tea101/daw-project-manager/issues>
