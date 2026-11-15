# VideoMaster

macOS-Videoplayer für das Mastering (SwiftUI, AVFoundation).

- Layout: Video | Waveform-Monitor (Luma kombiniert / RGB einzeln / RGB überlagert) | Lautstärke-Meter; unten Timeline mit Audio-Waveform
- Messung nach ITU-R BS.1770 / EBU R128 (Momentary, Short-term, Integrated, LRA, True Peak)
- Waveform in der Timeline wird nach Zielbereich eingefärbt: grün = im Ziel, orange/rot = zu laut, cyan/blau = zu leise
- Automatische Markierungen für Über-/Unterbelichtung und True-Peak-Überschreitungen (Liste über „Markierungen“ in der Toolbar)
- Presets: YouTube, Spotify, Apple Music, Amazon, TIDAL, Deezer, SoundCloud, Podcast, EBU R128, ATSC A/85, ARIB, OP-59, Netflix

Bauen: `./build_app.sh` → `build/VideoMaster.app`  (nur Command Line Tools nötig)
Tests ohne GUI: `VIDEOMASTER_SELFTEST=/pfad/video.mp4 .build/release/VideoMaster`

## Installation auf einem anderen Mac

`./package.sh` baut eine universelle App (Apple Silicon + Intel, macOS 14 oder neuer) und packt sie in `build/VideoMaster-<Version>.dmg`.

1. DMG auf den Ziel-Mac kopieren und öffnen.
2. Im Terminal `sh ` eintippen und `install.sh` aus dem DMG-Fenster ins Terminal ziehen, Return drücken (oder: `sh "/Volumes/VideoMaster 1.0/install.sh"`).

Das Skript beendet eine laufende VideoMaster-App, ersetzt sie in `/Applications`, entfernt das Quarantäne-Flag (die App hat keine Developer-ID-Signatur, macOS würde sie sonst blockieren) und startet sie.

## Icon neu erzeugen

`swift scripts/make_icon.swift build/AppIcon.iconset && iconutil -c icns build/AppIcon.iconset -o Resources/AppIcon.icns`
