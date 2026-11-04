# SerialTerminal — Avanceret seriel terminal

**Dokument ID:** ST-README-002  
**Standarder:** ISO/IEC/IEEE 29148:2018, EU CRA 2024/2847 (Secure by design)  
**Platform:** Windows (32/64-bit)  

SerialTerminal er en fritstående, GUI-baseret applikation udviklet i Free Pascal og Lazarus. Programmet er målrettet embedded-udviklere, hardware-ingeniører og undervisere, der arbejder med mikrokontrollere (Arduino, ESP32, ESP8266, STM32 m.fl.) over USB-til-serial eller native UART. 

Programmet adskiller sig fra standardterminaler ved at have en fuldstændig **non-blocking polling-arkitektur**, indbygget protokolafkodning for industrielle standarder (Modbus, Bisync) og et avanceret hukommelsesværn, der forhindrer UI-frysning ved tung telemetri.

---

## 🏗 Arkitektur & designvalg

### "Pull, ikke push" (Polling-model)
For at sikre fuldstændig stabilitet og undgå race-conditions, anvender programmet ikke en traditionel, separat læsetråd. I stedet polles den serielle port via en `TTimer` (50–100 ms interval). Ved baudrates op til 2.000.000 (f.eks. 115200 baud = ~11.5 KB/s) er dette rigeligt til at tømme operativsystemets 4 KB RX-buffer, uden at grafiske opdateringer fryser vinduet. Læsningen (via `RecvBufferStr`) kaldes med en timeout på 0 ms, hvilket gør operationen 100% non-blocking.

### Specialudviklet Seriel Driver (`synaser.pas`)
Systemet afhænger ikke af eksterne 3. parts komponenter udover Free Pascal/Lazarus-økosystemet. Al seriel kommunikation håndteres af den indlejrede, letvægts `TBlockSerial` driver, som taler direkte med Windows API'et (`CreateFileA`, `DCB`, `COMMTIMEOUTS`). 
Dette sikrer, at porten åbnes med eksklusiv adgang (share-mode 0), hvilket forhindrer, at andre programmer (som Arduino IDE) skaber datakorruption.

---

## 🌟 Detaljerede funktioner

### 1. Dobbeltverificeret Portdetektering
Terminalen viser *kun* porte, der fysisk eksisterer på maskinen. 
* **Skanning:** Aflæser systemets registry (`HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM`).
* **Verifikation:** Alle fundne porte testes med `CreateFileA`. 
* **Optaget-status:** Hvis en port returnerer `ERROR_ACCESS_DENIED` eller `ERROR_SHARING_VIOLATION`, inkluderes porten stadig i listen, da den fysisk eksisterer, men er låst af f.eks. Arduino IDE. Brugeren får i så fald en handlingsorienteret fejlbesked med hjælp til at løse problemet.

### 2. Streaming-semantik & hukommelsesbeskyttelse
* **Bevarer `Serial.print()`:** Modsat simple terminaler, der tvinger linjeskift ind ved hver læsning, indsætter SerialTerminal data direkte i tekstbufferen via `SelStart` og `SelText`. Dette betyder, at en `Serial.print("A")` fulgt af `Serial.print("B")` vises korrekt som `AB` på samme linje.
* **Tidsstempler:** Tidsstempler (`[hh:nn:ss.zzz]`) tilføjes *kun* ved starten af en ny logisk linje, så layoutet af telemetrien bevares.
* **Hukommelsesværn (Rolling Window):** Modtages ekstreme mængder data, begrænses terminalen automatisk. Når linjeantallet overstiger 2500, suspenderes UI-opdateringer (`BeginUpdate`), og de ældste linjer slettes, indtil der er 1500 linjer tilbage. Dette sikrer, at applikationen kan køre i dagevis ved høje baudrates uden at Windows' `RichEdit`-kerne bryder sammen.

### 3. Avanceret tegn- og protokolafkodning
Terminalen tillader on-the-fly afkodning af indgående bytes via dispatcher-motoren i `unitmain.pas`:

| Kodning/Protokol | Beskrivelse & Adfærd |
| :--- | :--- |
| **UTF-8** | Standard for Arduino/ESP32. Rå bytes castes direkte til tekst. |
| **ASCII** | 7-bit standard. Usynlige kontroltegn udskiftes med punktum (`.`), men strukturelle tegn som `CR`, `LF` og `TAB` bevares. |
| **ISO-8859-1** | Optimeret konvertering (Latin-1 til UTF-8) direkte i programkoden, der sikrer perfekt visning af æ, ø og å uden at trække på tunge eksterne biblioteker. |
| **UTF-16 LE/BE** | Understøtter Windows Unicode og netværksrækkefølge. |
| **Modbus ASCII** | Håndterer industrielle Modbus-rammer. Det usynlige starttegn `:` (0x3A) ændres til `[MODBUS START :]`, og `CRLF` afslutninger markeres som `[END CRLF]`. |
| **IBM Bisync** | Oversætter binære styretegn til læsbare tags (fx 0x02 bliver `<STX>`, 0x03 bliver `<ETX>`, 0x06 bliver `<ACK>`). Viser al anden binær støj som hex-tags, fx `[0x0A]`. |
| **Rå Hex-visning** | Outputter alle bytes som to-cifrede hex-værdier adskilt af mellemrum (fx `48 65 6C 6C 6F`). Essentielt til fejlfinding af Modbus RTU og binære sensordata. |

### 4. Hardware-kontrol & DTR/RTS
* **Manuel DTR/RTS:** Styr hardwarens kontrolsignaler direkte via checkboxes. Dette gør det muligt at fastholde en MCU i bootloader-tilstand eller eksperimentere med hardware flow-control.
* **Hardware Reset (Reset MCU):** Sender en præcis 150 ms DTR-puls (trækker DTR lav, venter, sætter DTR høj). Dette udnytter den 100 nF kondensator, der sidder i de fleste Arduino/ESP32 auto-reset kredsløb, og genstarter mikrokontrolleren omgående uden at man skal fjerne USB-kablet.

---

## ⚙️ Systemkrav og installation

### Begrænsninger og Krav (CON-01 til CON-04)
* **OS:** Windows (32/64-bit). *(macOS og Linux understøttes ikke i denne specifikke distribution).*
* **Compiler:** Free Pascal Compiler (FPC) ≥ 3.2.0.
* **IDE:** Lazarus ≥ 2.2.0.
* **Rettigheder:** Systemet kræver almindelig læse-/skriveadgang til COM-portene via Windows' rettighedsmodel (ingen administratoradgang påkrævet).

### Kompilering (Trin-for-trin)
1. **Åbn projektet:** Hent alle kildekoder (`SerialTerminal.lpi`, `SerialTerminal.lpr`, `unitmain.pas`, `unitmain.lfm` og `synaser.pas`) ned i samme mappe.
2. Start Lazarus og vælg `Projekt -> Åbn projekt...` (`Ctrl + O`). Vælg `SerialTerminal.lpi`.
3. **Byg applikationen:** Tryk på `F9` (Kør). Projektet kompileres lynhurtigt til en enkelt, fritstående `SerialTerminal.exe` i mappen, fuldstændig klar til brug.

---

## 📖 Brugervejledning til daglig brug

1. **Tilslutning:** Sæt din Arduino/ESP32 i USB-porten. Klik evt. på **[Genopfrisk]** i programmet, hvis det allerede var åbent.
2. **Forbind:**
   * Vælg COM-porten i drop-down menuen (programmet forhindrer dig i at vælge 'tomme' porte).
   * Vælg Baudrate (standard `115200`), Databits (`8`), Paritet (`None`) og Stopbits (`1`).
   * Klik **[Forbind]**. Statusikonet bliver grønt, og portens indstillinger låses (for at forhindre fatale ændringer midt i en session).
3. **Telemetri & Fejlfinding:** 
   * Skift mellem kodninger (f.eks. til Hex-visning eller Modbus) undervejs via `Encoding` dropdownen — systemet dispatcher automatisk næste indgående bytestrøm til den valgte afkoder.
   * Brug **[Reset MCU]** for at genstarte en "hængt" sketch og se boot-beskeder forfra.
4. **Afsend kommandoer:** Skriv din kommando i bund-feltet, vælg den rigtige `Line ending` (oftest `CR + LF`) og tryk `Enter` eller **[Send]**.
5. **Afslut:** Klik **[Afbryd]** for at lukke porten og frigive den til f.eks. firmware-upload via din normale IDE.

---

## 📜 CRA 2024/2847 / Sikkerhedsdeklaration
*Systemet indsamler ingen telemetri, kommunikerer ikke over netværk og bruger udelukkende native OS-kald. Databehandling af serielle inputs er begrænset af buffere og Int64 byte-tællere for at forhindre overflow-angreb eller crash ved ekstreme datamængder.*
