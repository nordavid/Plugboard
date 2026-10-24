# Plugboard

Eine Mac-App, die alle installierten Audio-Plug-ins findet, anzeigt und sauber entfernt: für Logic Pro, FL Studio, Ableton Live, Pro Tools und jede andere DAW. Die Oberfläche ist auf Deutsch und Englisch und folgt der Systemsprache.

## Funktionen

- **Alle Formate und Orte**: Audio Units, VST3, VST, CLAP, AAX (inkl. „Plug-Ins (Unused)“), AUv3-Erweiterungen, Waves-Plug-ins und WaveShells, WPAPI, MAS, RTAS sowie Audio- und MIDI-Treiber. Jeweils im Benutzer- (`~/Library`) und im gemeinsamen Ordner (`/Library`), inklusive Hersteller-Unterordnern. Eigene Ordner lassen sich in den Einstellungen ergänzen.
- **Details pro Plug-in**: Name, Hersteller, Format, Typ (Instrument, Effekt, MIDI), Version, Architektur (Universal, Apple Silicon, nur Intel, 32-Bit), Größe, Installations- und Änderungsdatum, Ort, Bundle-ID, Signatur, Audio-Unit-Codes und enthaltene Plug-ins bei Shells.
- **Plug-ins statt Dateien**: Die AU-, VST3-, AAX- und CLAP-Version eines Produkts erscheinen als eine Zeile mit aufklappbaren Formaten. Umschaltbar auf eine Zeile pro Datei.
- **Entfernen**: In den Papierkorb legen mit Widerrufen (⌘Z oder im Hinweis), sofort löschen mit Bestätigung, oder komplett deinstallieren.
- **Komplett-Deinstallation**: Findet alle Formate eines Produkts plus Einstellungen, Caches, Presets, Logic-Plug-in-Einstellungen, Support-Ordner und Installationsbelege. Du wählst in einer Liste, was weg soll. Presets und Support-Dateien sind standardmäßig abgewählt.
- **Aufräum-Helfer**: Nicht ladbare Plug-ins, nur Intel (Rosetta), VST2-Duplikate von VST3-Plug-ins, AAX ohne installiertes Pro Tools, doppelte Kopien und ältere Waves-Versionen, jeweils mit freiwerdendem Speicherplatz.
- **Übersicht**: Anzahl, Speicherplatz nach Format und Hersteller, größte Plug-ins und welche Formate deine installierten DAWs überhaupt laden.
- **Export**: Die angezeigte Liste als CSV, passend für Excel und Numbers in jeder Region.
- **Werkzeuge**: Audio-Unit-Cache zurücksetzen (Logic Pro und GarageBand prüfen dann alle AUs neu). Die Liste aktualisiert sich automatisch, wenn ein Installationsprogramm Plug-ins ändert.

## Sicherheit

- Standard ist immer der Papierkorb. Endgültiges Löschen nur nach Bestätigung.
- Ein Administratorpasswort wird nur abgefragt, wenn ein Plug-in für alle Benutzer installiert ist und dir nicht gehört, und dann einmal pro Vorgang über den normalen macOS-Dialog. Objekte im Papierkorb gehören danach dir, sodass das Leeren kein Passwort braucht.
- Jeder Pfad wird vor dem Entfernen geprüft: Er muss in einem Plug-in- oder Support-Ordner liegen und darf nie ein Format-Ordner selbst oder dessen übergeordneter Ordner sein. Symbolische Links werden nie verfolgt.
- Hardlinks (Waves legt Shells so ab) werden erkannt, damit angezeigter und tatsächlich freiwerdender Speicherplatz stimmen.

## Voraussetzungen

- macOS 14 Sonoma oder neuer
- Xcode oder die Command Line Tools (`xcode-select --install`)

## Bauen und starten

```bash
make app        # Universal-App (Apple Silicon + Intel) nach build/Plugboard.app
make run        # bauen und öffnen
make install    # nach /Applications kopieren
make check      # Kern-Checks und Übersetzungs-Check
make debug      # schneller Debug-Build nur für diese Architektur
make snapshot   # Fenster in mehreren Zuständen nach build/snapshots rendern
make icon       # App-Icon neu zeichnen
```

Der Build läuft über `Scripts/build.sh` direkt mit `swiftc`, weil Swift Package Manager in den Command Line Tools 15.0 mit „unable to lookup item 'PlatformPath'“ abbricht. Mit Xcode oder neueren Command Line Tools funktioniert auch `swift build`, das `Package.swift` beschreibt dieselben Module.

Ohne Entwicklerzertifikat wird die App ad hoc signiert, was auf dem Mac, der sie gebaut hat, reicht. Zum Weitergeben mit Developer ID signieren und danach notarisieren:

```bash
SIGN_IDENTITY="Developer ID Application: Dein Name (TEAMID)" make app
```

## Aufbau

| Ordner | Inhalt |
| --- | --- |
| `Sources/PlugboardCore` | Scanner, Metadaten-Leser (Info.plist, VST3 `moduleinfo.json`, Mach-O, Code-Signatur), Größenberechnung, Gruppierung, Aufräum-Analyse, DAW-Erkennung, Entfernen mit Pfadschutz, Reste-Suche, CSV-Export |
| `Sources/Plugboard` | SwiftUI-App: Seitenleiste, Tabelle, Inspektor, Übersicht, Waves-Versionen, Prüf-Dialog, Einstellungen |
| `Sources/PlugboardChecks` | Checks für den Kern, inklusive echter Lösch- und Wiederherstellungsläufe in einem Wegwerf-Ordner |
| `Resources` | Info.plist, Übersetzungen (`en.lproj`, `de.lproj`), App-Icon |
| `Scripts` | Build, Bundle, Icon-Generator, Übersetzungs-Check |

Der Scan-Cache liegt in `~/Library/Caches/app.plugboard.Plugboard/`. Unveränderte Plug-ins werden beim nächsten Start nicht neu gelesen.
