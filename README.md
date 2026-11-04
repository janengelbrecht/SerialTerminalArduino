# Lazarus / Free Pascal Arduino Seriel Terminal
**Komplet installations- og kompileringsvejledning**

Dette projekt er en fuld funktionsdygtig seriel terminal skrevet i Free Pascal og bygget til **Lazarus IDE**. Den er skabt specielt til at kommunikere med **Arduino, ESP32, ESP8266, STM32** og lignende mikrokontrollere.

---

## 📁 Medfølgende projektfiler

1. `SerialTerminal.lpi` - Lazarus Project Information (åbnes i Lazarus).
2. `SerialTerminal.lpr` - Hovedprogrammets startpunkt.
3. `unitmain.pas` - Hovedformens Pascal kildekode med COM-scanning, tråd/timer-polling og afkodning.
4. `unitmain.lfm` - Den visuelle form-definition (GUI med knapper, dropdowns, TMemo).
5. `synaser.pas` - Letvægts cross-platform seriel bibliotek (TBlockSerial), som taler direkte med hardwaren.
6. `Arduino_Serial_Demo.ino` - Testsketch til Arduino/ESP32, der sender måledata, æ/ø/å, Modbus ASCII og IBM Bisync.

---

## 🚀 Sådan åbner og kompilerer du i Lazarus (Trin for trin)

### Trin 1: Download filerne
Klik på knappen **"Download alle filer (.ZIP)"** her i appen. Pak ZIP-arkivet ud i en mappe på din computer, f.eks.:
`C:\Projekter\LazarusSerialTerminal\`

### Trin 2: Åbn projektet i Lazarus
1. Start **Lazarus IDE** (kan hentes gratis på https://www.lazarus-ide.org/).
2. Vælg i menuen: **Projekt -> Åbn projekt...** (eller tast `Ctrl + O`).
3. Vælg filen **`SerialTerminal.lpi`**.

### Trin 3: Kompiler og kør (F9)
1. Tryk blot på **F9** (eller vælg menuen **Kør -> Kør**).
2. Lazarus kompilerer koden lynhurtigt til en selvstændig `SerialTerminal.exe` (på Windows.
3. Vælg din Arduinos COM-port (f.eks. `COM3` eller `/dev/ttyUSB0`), sæt Baud rate til `115200`, og tryk **[Forbind]**!

---

## ⚙️ Understøttede funktioner

- **Baud rates**: Fra 300 helt op til 2.000.000 baud (9600 og 115200 er forudindstillet).
- **Paritet**: Ingen (None - N), Ulige (Odd - O), Lige (Even - E), Mark (M), Space (S).
- **Start- og stopbits**: 1 stop bit, 1.5 stop bits, 2 stop bits.
- **Databits**: 5, 6, 7, 8 bits.
- **Tegnkodninger**:
  - **UTF-8**: Standard for moderne Arduino og ESP32.
  - **ASCII**: 7-bit standard, filtrerer ukendte kontrolkoder.
  - **ISO-8859-1 (Latin-1)**: Korrekt visning af danske bogstaver **æ, ø, å, Æ, Ø, Å**.
  - **Unicode (UTF-16 LE / BE)**: Bred tegnsætstøtte.
  - **Modbus ASCII**: Viser starttegn `:`, hex-bytes og LRC-checksum.
  - **IBM Bisync**: Tolker SYN, STX, ETX, EOT, ACK, NAK protokolrammer.
- **Terminalfunktioner**:
  - Tidsstempel på modtagne linjer.
  - Automatisk scrollning så nyeste sensorværdier altid er i fokus.
  - Rå HEX-visning til fejlfinding af binære protokoller.
  - Send kommandoer til Arduinoen med valgbar linjeskift (CR+LF, kun LF, kun CR).
