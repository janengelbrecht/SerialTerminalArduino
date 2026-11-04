# Contributing til SerialTerminal

Tak for din interesse i at bidrage! Dette dokument beskriver, hvordan du
kan rapportere fejl, foreslå forbedringer og indsende pull requests.

## Adfærdskodeks

Alle bidragydere forventes at følge vores [Code of Conduct](CODE_OF_CONDUCT.md).
Ved at deltage accepterer du disse retningslinjer.

## Sådan rapporterer du en fejl

1. **Søg først** i [eksisterende issues](../../issues) for at undgå dubletter.
2. Åbn en ny issue med skabelonen **Bug report** og inkluder:
   - Operativsystem og version (Windows 10/11, Ubuntu 22.04, macOS 14 …)
   - Lazarus- og Free Pascal-version
   - Hvilken MCU (Arduino Uno, ESP32-S3, STM32 …)
   - Hvilken baudrate og hvilke rammeparametre
   - Eksakte trin til at reproducere
   - Forventet vs. faktisk adfærd
   - Eventuelle log-uddrag fra terminalen

## Sådan foreslår du en funktion

1. Åbn en issue med skabelonen **Feature request**.
2. Beskriv:
   - Hvilket problem funktionen løser
   - Hvordan den passer ind i den eksisterende arkitektur
   - Eventuelle påvirkninger på cross-platform-kompatibilitet

## Pull requests

1. **Fork** repository og opret en topic-branch:
   - `feature/<kort-beskrivelse>` — for ny funktionalitet
   - `fix/<kort-beskrivelse>` — for fejlrettelser
   - `docs/<kort-beskrivelse>` — for dokumentation
2. Følg kodestilen:
   - `{$mode objfpc}{$H+}` i alle units
   - 2-space indentation, ingen tabs
   - Kommentarer på dansk eller engelsk, konsistent inden for filen
   - Brug `Int64` til byte-tællere, `AnsiString` til byte-data
   - Platforms-specifik kode skal isoleres med `{$IFDEF WINDOWS}` / `{$ELSE}`
3. Opdater dokumentationen:
   - Tilføj relevante kommentarer i `synaser.pas` og `unitmain.pas`
   - Opdater `README.md`, hvis brugerfladen ændres
   - Opdater `kravspecifikation.txt`, hvis krav ændres
   - Tilføj en post i `CHANGELOG.md` under `[Unreleased]`
4. Test på mindst to platforme (fx Windows + Linux).
5. Sikr at projektet kompilerer uden warnings:
   ```bash
   lazbuild SerialTerminal.lpi