# Changelog

Alle væsentlige ændringer i dette projekt dokumenteres her.

Formatet følger [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
og projektet følger [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planlagt
- Fuld termios-konfiguration på Linux/macOS (baudrate, databits, paritet, stopbits)
- `ioctl(TIOCMBIS/TIOCMBIC)`-baseret DTR/RTS-styring på UNIX
- `ioctl(FIONREAD)` i `WaitingData` på UNIX for præcis læsning
- Multi-form-arkitektur (flere samtidige terminal-vinduer)
- Understøttelse af RS-485 (half-duplex) via RTS-styring
- Automatisk LRC-validering i Modbus ASCII-visning
- Automatisk BCC-validering i IBM Bisync-visning
- Eksport af terminal-log til fil
- Yderligere testdækning og CI-pipeline

## [1.0.0] — 2026-11-04

### Tilføjet
- Første stabile udgivelse af SerialTerminal
- Cross-platform seriel terminal til Windows, Linux og macOS
- Understøttelse af Arduino Uno/Nano/Mega, ESP32, ESP8266 og STM32
- Portdetektering på Windows (Registry + CreateFileA-verifikation)
- Portdetektering på Linux (`/dev/ttyUSB*`, `/dev/ttyACM*`)
- Ikke-blokerende polling-baseret datalæsning via TTimer (50–100 ms)
- Syv tegnkodninger: UTF-8, ASCII, ISO-8859-1, UTF-16 LE, UTF-16 BE,
  Modbus ASCII, IBM Bisync
- Manuel DTR/RTS-styring via checkboxes
- Hardware-reset via DTR-puls (150 ms) til Arduino/ESP32
- Streaming-indsættelse i TMemo, der bevarer `Serial.print()`-semantik
- Hukommelsesværn (rullende vindue 2500/1500 linjer)
- Tidsstempler med millisekund-præcision
- HEX-visning til binære protokoller
- Valgbar linjeafslutning (CR+LF, LF, CR, ingen)
- Komplet dansk dokumentation (`README.md`, `kravspecifikation.txt`)
- Omfattende Pascal-dokumentation i `synaser.pas` og `unitmain.pas`
- Arduino demo-sketch (`Arduino_Serial_Demo.ino`)

### Kendte begrænsninger
- UNIX-grenen gemmer rammeparametre men anvender dem ikke fuldt via `tcsetattr`
- `WaitingData` returnerer 0 på UNIX (læsning sker via `fpread` med `O_NONBLOCK`)
- DTR/RTS-styring på UNIX er ikke implementeret med `ioctl`
- Ingen kryptering af seriel data (ikke relevant for fysisk tilsluttet UART)