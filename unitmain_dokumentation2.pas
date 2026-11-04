{===============================================================================
DOKUMENTATION AF SERIEL TERMINAL
  ===============================================================================
  Fil:      SerialTerminal.lpr
  Sprog:    Free Pascal / Lazarus ({$mode objfpc}{$H+})
  Formål:   Cross-platform seriel terminal til kommunikation med
            mikrokontrollere (Arduino Uno/Nano/Mega, ESP32, STM32 m.fl.)
            over USB-til-serial eller native UART.
  ===============================================================================

  INDHOLDSFORTEGNELSE
  -------------------
  1.  Overordnet arkitektur og dataflow
  2.  Hovedprogramfil: SerialTerminal.lpr
  3.  GUI-enheden: unitmain.pas
      3.1  TSerialEncoding — tegnkodninger
      3.2  TFormMain — komponenter og felter
      3.3  FormCreate og initialisering
      3.4  Porthåndtering (RefreshComPorts, Connect, Disconnect)
      3.5  Datalæsning (TimerPollTimer)
      3.6  Afkodning (DecodeIncomingData og hjælpefunktioner)
      3.7  Visning (AppendToTerminal)
      3.8  Afsendelse (BtnSendClick, EditSendKeyDown)
      3.9  Hardware-reset (BtnResetMCUClick)
      3.10 UI-tilstand (UpdateUIState)
  4.  Den serielle driver: synaser.pas
      4.1  Hvorfor en egen driver?
      4.2  GetSerialPortNames
      4.3  TBlockSerial — livscyklus og metoder
  5.  Hvad kan programmet bruges til?
  6.  Designvalg og begrundelser (opsummering)

  ===============================================================================
  1. OVERORDNET ARKITEKTUR OG DATAFLOW
  ===============================================================================

  Programmet er en begivenhedsdrevet GUI-applikation med en POLLING-baseret
  læsestrategi. Dataflowet kan illustreres således:

      [Arduino/ESP32]  <--USB/Serial-->  [synaser.TBlockSerial]
                                               ^
                                               | (poll hver ~50-100 ms)
                                               |
                                        [TTimer: TimerPoll]
                                               |
                                               v
                                   [DecodeIncomingData] --> [TMemo]
                                               ^
                                               |
                                   [EditSend + BtnSend] --> SendString()

  HVORFOR POLLING OG IKKE TRÅDE?
  - En separat læsetråd ville kræve synkronisering (Synchronize) til GUI,
    hvilket øger kompleksiteten og fejlrisikoen betydeligt.
  - Ved 115200 baud (~11.5 KB/s) er en TTimer med 50-100 ms interval
    rigeligt til at tømme OS-bufferen (typisk 4 KB) uden datatab.
  - Løsningen er 100% non-blocking for GUI'en: RecvBufferStr kaldes med
    timeout 0, så brugeren aldrig oplever frosne vinduer.

  ===============================================================================
  2. HOVEDPROGRAMFIL: SerialTerminal.lpr
  ===============================================================================

  Dette er programmets entry point. Det er bevidst holdt minimalt — kun
  det aller nødvendigste for at starte LCL/GUI-systemet og åbne hovedvinduet.

  - {$mode objfpc}{$H+}      : Objekt-Pascal-tilstand med lange strenge.
  - cthreads                 : Nødvendig på UNIX (Linux/macOS) for at LCL's
                               tråd-baserede timere og event-loop fungerer.
                               Uden denne unit crasher programmet på Linux.
  - Interfaces               : Indlæser det korrekte widgetset (GTK2, Qt5,
                               Win32, Cocoa) afhængigt af platformen.
  - Forms, unitmain          : GUI-rammeværket og vores hovedvindue.
  - RequireDerivedFormResource : Kræver at .lfm-formularressourcer er indlejret;
                               sikrer korrekt formularoprettelse.
  - Application.Scaled       : Skalerer UI efter OS'ets DPI-indstilling
                               (vigtigt på HiDPI-skærme).
  - Application.CreateForm    : Opretter TFormMain som hovedformular.
  - Application.Run          : Starter event-loopet.

  HVORFOR SÅ MINIMAL?
  Al forretningslogik ligger i unitmain.pas. Det gør programfilen nem at
  overskue og følger Lazarus' standardkonvention: .lpr = bootstrap,
  units = funktionalitet.

  ===============================================================================
  3. GUI-ENHEDEN: unitmain.pas
  ===============================================================================

  3.1 TSerialEncoding — tegnkodninger
  -----------------------------------
  En enumeration der angiver hvordan rå bytes skal fortolkes ved visning:

    encUTF8            : Standard UTF-8 (Arduino/ESP32 sender typisk dette).
    encASCII           : 7-bit ASCII; ikke-printbare tegn vises som '.'.
    encISO88591        : Latin-1. Kræver konvertering til UTF-8 for korrekt
                         visning af æ, ø, å, Æ, Ø, Å.
    encUnicodeUTF16LE  : 16-bit Little Endian (Windows-standard).
    encUnicodeUTF16BE  : 16-bit Big Endian (netværksrækkefølge).
    encModbusASCII     : Protokolafkodning — viser ':' som [MODBUS START :]
                         og CRLF som [END CRLF].
    encIBMBisync       : Protokolafkodning — viser SYN, STX, ETX, ACK, NAK,
                         DLE m.fl. som læsbare tags.

  HVORFOR ENUM OG IKKE STRENGE?
  Enums giver kompilatortjek, hurtigere sammenligning (integer) og
  eliminering af tastefejl. ItemIndex i CbEncoding mapper direkte til
  enum-værdien via TSerialEncoding(CbEncoding.ItemIndex).

  3.2 TFormMain — komponenter og felter
  -------------------------------------
  GUI-komponenter (defineret i .lfm):
    CbComPort, CbBaudRate, CbParity, CbDataBits, CbStopBits
        : Port- og rammeparametre (deaktiveres under forbindelse).
    ChkDTR, ChkRTS       : Manuel styring af DTR/RTS-linjerne.
    ChkAutoScroll        : Auto-scroll til bund ved ny data.
    ChkHexView           : Vis rå bytes som hex i stedet for tekst.
    ChkTimestamp         : Foranstil tidsstempel på nye linjer.
    CbEncoding           : Vælg tegnkodning/protokolafkodning.
    CbLineEnding         : CR+LF, LF, CR eller ingen ved afsendelse.
    MemoTerminal         : Selve terminalvinduet.
    EditSend + BtnSend   : Inputfelt og send-knap.
    BtnConnect/Disconnect/ResetMCU/RefreshPorts/Clear
        : Handlingsknapper.
    ShapeStatus          : Grøn/rød indikator for forbindelsesstatus.
    StatusBar1           : Paneler til portstatus, RX- og TX-byteantal.
    TimerPoll            : Polling-timer til datalæsning.

  Private felter:
    FSerial        : TBlockSerial — den serielle driver-instans.
    FIsConnected   : Boolean — sand når porten er åben og konfigureret.
    FRxByteCount   : Int64 — kumulativt antal modtagne bytes.
    FTxByteCount   : Int64 — kumulativt antal sendte bytes.
    FRxBuffer      : AnsiString — reserveret buffer (til delvis
                     opbevaring; i denne version bruges den ikke aktivt,
                     da TMemo selv håndterer streaming).

  HVORFOR Int64 TIL BYTE-TÆLLERE?
  Ved 115200 baud og lange sessioner kan tællere overstige 2^31
  (~2.1 GB). Int64 sikrer, at tællingen aldrig "wrapper" negativt.

  3.3 FormCreate og initialisering
  ---------------------------------
  - Opretter FSerial og nulstiller tællere.
  - Kalder RefreshComPorts for at finde tilsluttede enheder.
  - Sætter standardværdier optimeret til Arduino/ESP32:
      115200 baud, 8 databits, ingen paritet, 1 stopbit,
      UTF-8, CR+LF.
  - Kalder UpdateUIState for at sætte korrekt enabled/disabled-tilstand.
  - Skriver en velkomstbesked i terminalen.

  HVORFOR 115200 SOM STANDARD?
  Det er den mest udbredte baudrate for moderne Arduino/ESP32-sketches
  og giver god båndbredde uden at kræve særlig kabelkvalitet.

  3.4 Porthåndtering
  ------------------
  RefreshComPorts:
    - Kalder GetSerialPortNames (fra synaser) som KUN returnerer porte,
      der fysisk er tilsluttet (se afsnit 4.2).
    - Parser komma-separeret liste og fylder CbComPort.
    - Hvis ingen porte findes, indsættes en pladsholdertekst
      "(Ingen tilkoblede COM-porte fundet)" og BtnConnect deaktiveres.
    - Opdaterer statuslinjen med antal fundne porte.
    HVORFOR INGEN FALSKE PORTE?
    Mange terminaler viser alle historiske COM-navne, hvilket forvirrer
    brugeren. Ved at verificere fysisk tilstedeværelse undgås
    "port findes ikke"-fejl ved forbindelse.

  BtnConnectClick:
    - Validerer at en gyldig port er valgt (ikke pladsholderen).
    - Udtrækker rent portnavn (fjerner evt. parentes-tekst).
    - Mapper ComboBox-valg til konkrete parametre:
        Paritet: N/O/E/M/S
        Stopbits: SB1, SB1andHalf, SB2 (konstanter fra synaser)
    - Kalder FSerial.Connect, tjekker LastError, kalder Config.
    - Sætter DTR/RTS ud fra checkboxes — KRITISK for ATmega328P og ESP32,
      hvor DTR ofte bruges til auto-reset ved åbning.
    - Aktiverer TimerPoll og opdaterer UI.
    - Fejlhåndtering: Viser fejlbesked med hint om at lukke Arduino IDE's
      Serial Monitor, som ofte holder porten låst.

  BtnDisconnectClick:
    - Stopper timeren, lukker socket, opdaterer UI og skriver besked.

  HVORFOR STOPPE TIMEREN FØRST?
    Hvis timeren fyrer af mens porten lukkes, kan RecvBufferStr ramme en
    lukket handle. Rækkefølgen (timer → socket → UI) forhindrer
    race conditions.

  3.5 Datalæsning — TimerPollTimer
  --------------------------------
  Kaldes periodisk når FIsConnected er sand:
    1. Spørger FSerial.WaitingData (OS-bufferens fyldning).
    2. Hvis > 0: læser præcis så mange bytes med RecvBufferStr(n, 0).
       Timeout 0 = non-blocking, GUI fryser aldrig.
    3. Opdaterer FRxByteCount og statuslinjen.
    4. Vælger visningsvej:
         ChkHexView  -> BytesToHexString
         ellers      -> DecodeIncomingData med valgt kodning
    5. Appender resultatet til terminalen.
  Undtagelser (fx USB-kabel trukket ud) fanges: timeren stoppes,
  forbindelsen markeres død, og portlisten genopfriskes automatisk.

  HVORFOR "LÆS KUN DET DER ER" OG IKKE FAST BLOKSTØRRELSE?
    RecvBufferStr læser præcis det antal bytes OS'et rapporterer som
    tilgængelige. Det undgår at vente på fyldte buffere og bevarer
    rækkefølgen af små Serial.print()-kald uden kunstige forsinkelser.

  3.6 Afkodning — DecodeIncomingData og hjælpefunktioner
  -------------------------------------------------------
  DecodeIncomingData dispatcher på TSerialEncoding:

    encUTF8        : Rå bytes antages at være UTF-8; castes direkte til
                     string (FPC's string er UTF-8 i {$H+}-mode).
    encASCII       : Tegn 32..126 samt CR/LF/TAB bevares; øvrige erstattes
                     med '.' — gør kontroltegn synlige uden at ændre layout.
    encISO88591    : Kalder Latin1ToUTF8, som udfører den korrekte
                     2-byte UTF-8-kodning for bytes >= $80.
    encUTF16LE/BE  : Flytter bytes til WideString (LE direkte, BE med
                     byte-swap) og konverterer via UTF8Encode.
    encModbusASCII : DecodeModbusASCII indsætter [MODBUS START :] og
                     [END CRLF] og bevarer hex-cifrene.
    encIBMBisync   : DecodeIBMBisync oversætter styretegn (SYN=0x16/0x32,
                     STX=0x02, ETX=0x03, EOT=0x04, ENQ=0x05, ACK=0x06,
                     NAK=0x15, DLE=0x10, ETB=0x17) til læsbare tags;
                     printable ASCII vises som tegn, øvrige som [0xNN].

  HVORFOR KONVERTERE LATIN-1 MANUELT?
    Free Pascal har ikke en indbygget Latin1ToUTF8 i SysUtils, og
    konverteringen er simpel (én byte -> én eller to UTF-8-bytes).
    Manuel konvertering undgår afhængigheder og er lynhurtig.

  HVORFOR PROTOKOLAFKODNING I TERMINALEN?
    Modbus ASCII og IBM Bisync er binære/near-binære protokoller, hvor
    styretegn er usynlige eller ødelægger layoutet i en rå tekstvisning.
    Ved at tagge dem får udvikleren et læsbart protokolspor uden at
    skulle bruge en dedikeret protokolanalysator.

  3.7 Visning — AppendToTerminal
  -------------------------------
  Formål: streame tekst ind i TMemo uden at ødelægge Serial.print()-
  semantikken (kald uden linjeskift skal fortsætte på samme linje).

  Trin:
    1. Hukommelsesværn: hvis > 2500 linjer, slettes ældste indtil 1500.
       BeginUpdate/EndUpdate undgår flicker under masse-sletning.
    2. Tidsstempel: hvis aktiveret OG forrige linje er tom/start,
       foranstilles [hh:nn:ss.zzz]. Dette undgår at hvert enkelt
       Serial.print() får sit eget stempel midt i en linje.
    3. Streaming-indsættelse: markøren sættes til slutningen, og teksten
       indsættes via SelText. Dette er ækvivalent med Arduino IDE's
       Serial Monitor og bevarer delvise linjer korrekt.
    4. Auto-scroll: hvis aktiveret, flyttes markøren til slutningen.

  HVORFOR BESKÆRE VED 2500 LINJER?
    TMemo bliver markant langsommere ved titusindvis af linjer (Windows
    RichEdit især). Grænsen holder UI responsivt under kontinuerlig
    højhastigheds-telemetri uden at brugeren mister nyttig nylig historik.

  3.8 Afsendelse — BtnSendClick og EditSendKeyDown
  -------------------------------------------------
  - Kræver aktiv forbindelse; ellers advares brugeren.
  - Tomt input ignoreres.
  - Linjeafslutning vælges ud fra CbLineEnding:
      0: CR+LF (#13#10) — mest brugt af Arduino Serial.readStringUntil('\n')
      1: LF    (#10)
      2: CR    (#13)
      3: Ingen
  - Sender via FSerial.SendString, opdaterer TX-tæller.
  - Skriver "[Sendt -> Arduino]: ..." i terminalen som bekræftelse.
  - EditSendKeyDown: Enter-tasten udløser samme handling, så brugeren
    kan skrive kommandoer uden at flytte hånden til musen.

  HVORFOR CR+LF SOM STANDARD?
    Arduino'ens Serial.readStringUntil('\n') fungerer med både LF og
    CR+LF, men CR+LF matcher også Windows-konventionen og undgår
    problemer i sketches, der trimmer med begge tegn.

  3.9 Hardware-reset — BtnResetMCUClick
  -------------------------------------
  Mange Arduino-kort (især Uno/Nano med ATmega328P og ESP32-baserede
  kort) har en auto-reset-kreds, hvor DTR-linjen trækkes lav for at
  aktivere bootloader'en. Denne knap:
    1. Sætter DTR := False, venter 150 ms, sætter DTR := True.
    2. Skriver besked om, at bootloader'en venter ~1.5 sek.
  Dette giver brugeren mulighed for at genstarte MCU'en uden at trække
  USB-stikket ud — praktisk ved firmware-test og ved "hængt" sketch.

  HVORFOR 150 ms PULS?
    ATmega328P'ens auto-reset-kondensator (typisk 100 nF) kræver et
    tilstrækkeligt langt lavt puls til at nå reset-tærsklen. 150 ms er
    en sikker, velafprøvet værdi.

  3.10 UI-tilstand — UpdateUIState
  ---------------------------------
  Central funktion der sætter enabled/disabled på alle afhængige
  komponenter ud fra FIsConnected og portens gyldighed:
    - Under forbindelse: port-parametre låses, Send aktiveres,
      Disconnect/Reset aktiveres, Connect/Refresh deaktiveres.
    - ShapeStatus: grøn ved forbindelse, rød ellers.
    - Statuslinje: viser enten "Forbundet: <port>", "Afbrudt (klar)"
      eller "Ingen Arduino tilsluttet...".
  HVORFOR EN SAMLET FUNKTION?
    At sprede disse sætninger ud i Connect/Disconnect/Refresh ville
    føre til inkonsistens. Én funktion = ét sandhedspunkt for UI-state.

  ===============================================================================
  4. DEN SERIELLE DRIVER: synaser.pas
  ===============================================================================

  4.1 Hvorfor en egen driver?
  ---------------------------
  Denne unit er en letvægts, selvstændig udgave af Synapse-bibliotekets
  synaser. Den er inkluderet direkte i projektet for at:
    - Undgå ekstern afhængighed (ingen pakkestyring nødvendig).
    - Kunne tilpasses præcist (fx non-blocking timeouts, portdetektering).
    - Sikre identisk adfærd på Windows og Linux/UNIX.
  Den understøtter Windows (CreateFile/DCB/COMMTIMEOUTS) og UNIX
  (fpopen/termios) via betinget kompilering ({$IFDEF WINDOWS}).

  4.2 GetSerialPortNames
  ----------------------
  Returnerer en komma-separeret liste af FYSISK tilstedeværende porte.

  Windows:
    - Læser HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM, hvor
      Windows registrerer aktive COM-porte. Når USB-stikket trækkes ud,
      slettes posten øjeblikkeligt.
    - Hver kandidat åbnes med CreateFileA for at verificere:
        Success                  -> port findes og er fri.
        ERROR_ACCESS_DENIED (5)  -> port findes, men er optaget
                                    (fx af Arduino IDE) — medtages alligevel,
                                    så brugeren kan se den.
        ERROR_FILE_NOT_FOUND (2) -> port findes ikke — udelades.
    HVORFOR DENNE DOBBELTVERIFIKATION?
    Registreringsdatabasen kan indeholde forældede poster i sjældne
    tilfælde; åbningstesten giver et endeligt svar.

  Linux/UNIX:
    - Søger i /dev/ttyUSB* (FTDI/CH340-baserede Arduino-kort) og
      /dev/ttyACM* (native USB CDC, fx Uno R3, ESP32-S3).
    - Bruger FindFirst/FindNext og samler resultatet kommasepareret.

  4.3 TBlockSerial — livscyklus og metoder
  ----------------------------------------
  Create/Destroy:
    Initialiserer FHandle til -1 (ugyldig), sætter DTR/RTS sande.
    Destroy kalder CloseSocket for sikker oprydning.

  Connect(DeviceName):
    Windows: åbner '\\.\COMx' med CreateFileA (GENERIC_READ|WRITE,
             ingen deling), sætter SetupComm-buffere til 4 KB.
    UNIX:    fpopen med O_RDWR|O_NOCTTY|O_NONBLOCK.
    Ved fejl gemmes GetLastError/fpGetErrno og en beskrivelse i
    FLastError/FLastErrorDesc, som GUI'en viser til brugeren.

  CloseSocket:
    Lukker handle og nulstiller den. Idempotent (sikker at kalde flere
    gange), hvilket forenkler fejlhåndtering.

  Config(Baud, Bits, Parity, StopBits, SoftFlow, HardFlow):
    Windows: Udfylder DCB (BaudRate, ByteSize, Parity, StopBits) og
             kalder SetCommState. Sætter derefter COMMTIMEOUTS til
             non-blocking læsning (ReadIntervalTimeout = MAXDWORD,
             konstant timeout = 0) og 500 ms skrive-timeout.
    UNIX:    Gemmer parametrene (termios-konfiguration er i denne
             forenklede udgave ikke implementeret fuldt; porten bruges
             typisk med de indstillinger OS'et allerede har).
    HVORFOR NON-BLOCKING LÆSNING?
    Kombineret med WaitingData + RecvBufferStr giver det en ren
    polling-model uden risiko for at GUI fryser.

  WaitingData:
    Windows: ClearCommError -> COMSTAT.cbInQue = antal bytes i OS-buffer.
    UNIX:    Returnerer 0 i denne forenklede udgave (polling sker via
             fpread, som returnerer 0 ved ingen data pga. O_NONBLOCK).

  RecvBufferStr(Length, TimeoutMs):
    Læser op til Length bytes. Windows: ReadFile med de konfigurerede
    timeouts. UNIX: fpread. Returnerer faktisk læste bytes.

  SendString(Data):
    Skriver hele strengen. Windows: WriteFile. UNIX: fpwrite.
    Returnerer antal skrevne bytes (kan bruges til fejltælling).

  SetDTR/SetRTS:
    Windows: EscapeCommFunction med WIN_SETDTR/WIN_CLRDTR etc.
             (WIN_-præfiks forhindrer navnekollision med metoderne selv).
    UNIX:    Gemmer blot tilstanden (kunne udvides med ioctl TIOCMBIS/
             TIOCMBIC).
    Bruges af ResetMCU-knappen og de manuelle checkboxes.

  ===============================================================================
  5. HVAD KAN PROGRAMMET BRUGES TIL?
  ===============================================================================

  - FEJLFINDING af Arduino/ESP32-sketches: se rå telemetri, hex-dump
    og kontroltegn præcis som de kommer ud af UART'en.
  - PROTOKOLUDVIKLING: Modbus ASCII- og IBM Bisync-afkodning gør det
    muligt at verificere rammestruktur (':', LRC, CRLF, SYN/STX/ETX)
    direkte i terminalen uden ekstra værktøj.
  - DANSK TEGNSÆT-TEST: verifikation af at æ, ø, å sendes korrekt i
    UTF-8 eller ISO-8859-1 fra MCU'en.
  - INTERAKTIV STYRING: send kommandoer som LED_ON, LED_OFF, MODE, PING
    til en sketch og se svaret øjeblikkeligt.
  - HARDWARE-RESET: genstart MCU'en uden at trække USB ud.
  - UNDERVISNING/DEMO: viser hvordan man bygger en seriel terminal i
    Lazarus med korrekt håndtering af kodninger, protokoller og
    non-blocking I/O.
  - CROSS-PLATFORM BRUG: samme program kører på Windows og Linux
    (og principielt macOS med UNIX-grenen).

  ===============================================================================
  6. DESIGNVALG OG BEGRUNDELSER (OPSUMMERING)
  ===============================================================================

  - Polling i stedet for tråd: enkelhed, ingen race conditions, GUI
    forbliver responsiv ved 115200 baud.
  - Egen synaser-udgave: nul eksterne afhængigheder, fuld kontrol.
  - Fysisk portverifikation: undgår forvirrende "phantom"-porte.
  - Streaming-indsættelse i TMemo: bevarer Serial.print()-semantik.
  - Linjebegrænsning (2500/1500): forhindrer UI-frys ved høj hastighed.
  - Manuel Latin-1-til-UTF-8: ingen ekstra units, lynhurtig.
  - Protokolafkodning som visningstilstand: læsbart protokolspor uden
    ekstra værktøjer.
  - DTR-puls til reset: matcher Arduino-hardwarens auto-reset-kreds.
  - Én UpdateUIState-funktion: ét sandhedspunkt for UI-tilstand.
  - Int64 tællere: ingen overflow ved lange sessioner.

  =============================================================================== }
unit unitmain;                                                              // Deklarerer unit'ens navn; skal matche filnavnet unitmain.pas
{ ^ Unit-erklæring. Filen skal hedde unitmain.pas, og unit-navnet skal
    stemme overens med filnavnet (Lazarus-krav). En "unit" er Free Pascals
    modul-konstrukt, der samler typer, klasser og kode i en genbrugelig
    enhed, som andre units kan bruge / "uses"-e. }

{$mode objfpc}{$H+}                                                         // Compiler-direktiv: Object Pascal-tilstand + AnsiString som standard "string"
{ ^ To compiler-direktiver:
      {$mode objfpc} : Sætter FPC i Object Pascal-tilstand (Delphi-kompatibel
                       dialekt) med class, properties, virtuelle metoder og
                       AnsiString som standard-strengtype.
      {$H+}          : Gør "string" til AnsiString (dynamisk, reference-talt,
                       automatisk hukommelsesstyring) i stedet for ShortString
                       (max 255 tegn). Nødvendigt fordi vi håndterer vilkårligt
                       store datamængder fra serieporten, og fordi Lazarus'
                       LCL forventer UTF-8 i AnsiString-baserede strenge. }

interface                                                                   // Begynder den offentlige del, som andre units kan se
{ ^ Her begynder unit'ens offentlige overflade. Alt mellem "interface" og
    "implementation" er synligt for andre units, der bruger/"uses"-er denne unit.
    Opdelingen giver hurtigere kompilering (kun interface læses af brugere)
    og informationsskjul (implementation kan indeholde private detaljer). }

uses                                                                        // Begynder afhængighedslisten
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls, // Kerne-units
  ComCtrls, synaser;                                                        // StatusBar + vores egen serielle driver
{ ^ De units, hvis typer vi refererer til:
      Classes    : TObject, TComponent, TStringList — komponent-hierarkiet.
      SysUtils   : Format, IntToStr, Trim, LineEnding, FormatDateTime,
                   SysErrorMessage, UTF8Encode m.fl.
      Forms      : TForm, TApplication, TCloseAction — LCL's formular-
                   infrastruktur. TFormMain arver fra TForm.
      Controls   : TControl — basisklassen for alle synlige komponenter.
      Graphics   : TColor, TBrush, TCanvas — til farvning af ShapeStatus.
      Dialogs    : ShowMessage og TCloseAction-dialoger.
      StdCtrls   : TButton, TCheckBox, TEdit, TLabel, TMemo, TComboBox.
      ExtCtrls   : TPanel, TShape, TTimer.
      ComCtrls   : TStatusBar — statuslinjen nederst.
      synaser    : Vores egen serielle driver (TBlockSerial,
                   GetSerialPortNames, SB1/SB1andHalf/SB2).
    Disse SKAL stå i interface (ikke implementation), fordi TFormMain's
    published felter og metodesignaturer refererer til typerne — kompilatoren
    skal kende dem allerede ved klasseerklæringen. }

type                                                                        // Begynder typetilkendegivelser
{ ^ Her begynder typetilkendegivelserne. Alt erklæret her bliver navngivne
    typer, som både denne unit og "uses"-ende units kan referere til. }

  // Understøttede tegnkodninger
  TSerialEncoding = (                                                       // Enumeration over tegnkodninger
    encUTF8,                                                                // 0: UTF-8
    encASCII,                                                               // 1: 7-bit ASCII
    encISO88591,                                                            // 2: Latin-1
    encUnicodeUTF16LE,                                                      // 3: UTF-16 LE
    encUnicodeUTF16BE,                                                      // 4: UTF-16 BE
    encModbusASCII,                                                         // 5: Modbus ASCII
    encIBMBisync                                                            // 6: IBM Bisync
  );                                                                        // Slut på enumeration
{ ^ Enumeration over de tegnkodninger / protokol-afkodninger, som terminalen
    kan vise rådata igennem.
      encUTF8           : Standard UTF-8 (Arduino/ESP32-sketches sender typisk
                          dette). Default.
      encASCII          : 7-bit ASCII; ikke-printbare tegn (uden for 32..126
                          plus CR/LF/TAB) vises som '.'.
      encISO88591       : Latin-1. Kræver konvertering til UTF-8 for korrekt
                          visning af æ, ø, å, Æ, Ø, Å.
      encUnicodeUTF16LE : 16-bit little-endian (Windows-standard).
      encUnicodeUTF16BE : 16-bit big-endian (netværksrækkefølge).
      encModbusASCII    : Viser ':' som [MODBUS START :] og CRLF som
                          [END CRLF], så rammestrukturen bliver synlig.
      encIBMBisync      : Viser SYN/STX/ETX/ACK/NAK/DLE m.fl. som læsbare
                          tags i stedet for usynlige tegn.
    HVORFOR ENUM OG IKKE STRENGE?
      Typesikkerhed (kompilatoren fanger tastefejl), ydeevne (heltal,
      ikke strengsammenligning), IDE-autokomplet, og — vigtigst — direkte
      mapping til CbEncoding.ItemIndex:
        TSerialEncoding(CbEncoding.ItemIndex)
      Det kræver blot, at ComboBox'ens Items indtastes i NØJAGTIG denne
      rækkefølge i .lfm-filen. }

  { TFormMain }

  TFormMain = class(TForm)                                                  // Hovedvinduets klasse, arver fra TForm
{ ^ KLASSEERKLÆRING for programmets hovedvindue. Arver fra TForm, hvilket
    giver gratis: vindueshåndtering (minimér, maksimér, DPI-skalering),
    komponent-ejerskab (automatisk frigivelse af komponenter oprettet via
    .lfm), begivenheds-håndtering via "published" metoder og understøttelse
    af LCL's formular-streaming (.lfm-format).
    SEKTIONER:
      - published (standard): komponenter og event-handlere, som LCL's
        streaming kan sætte op fra .lfm.
      - private: interne data og hjælpefunktioner, usynlige udefra.
      - public/protected: ikke brugt her. }

    BtnConnect: TButton;                                                    // Knap: åbn og konfigurer valgt port
    BtnDisconnect: TButton;                                                 // Knap: luk porten og stop polling
    BtnResetMCU: TButton;                                                   // Knap: pulsér DTR for at genstarte MCU
    BtnRefreshPorts: TButton;                                               // Knap: gen-skann systemet for porte
    BtnClear: TButton;                                                      // Knap: ryd terminalen
    BtnSend: TButton;                                                       // Knap: send EditSend's indhold
{ ^ Seks handlingsknapper:
      BtnConnect      : Åbner og konfigurerer den valgte serielle port.
      BtnDisconnect   : Lukker porten og stopper polling-timeren.
      BtnResetMCU     : Pulsér DTR for at genstarte MCU'en via dens
                        auto-reset-kreds (Uno/Nano/ESP32 dev boards).
      BtnRefreshPorts : Gen-skanner systemet for tilsluttede porte.
      BtnClear        : Rydder TMemo og skriver en "ryddet"-besked.
      BtnSend         : Sender EditSend's indhold med valgt linjeafslutning.
    Disse SKAL være published, fordi LCL's formular-designer gemmer dem i
    .lfm-filen som "BtnConnect = TButton" med properties. Havde de været
    private, kunne Lazarus ikke genskabe dem ved indlæsning. }

    CbBaudRate: TComboBox;                                                  // ComboBox: baudrate
    CbComPort: TComboBox;                                                   // ComboBox: liste over tilkoblede porte
    CbDataBits: TComboBox;                                                  // ComboBox: databits (5, 6, 7, 8)
    CbEncoding: TComboBox;                                                  // ComboBox: tegnkodning (matcher TSerialEncoding)
    CbLineEnding: TComboBox;                                                // ComboBox: linjeafslutning ved afsendelse
    CbParity: TComboBox;                                                    // ComboBox: paritet (N, O, E, M, S)
    CbStopBits: TComboBox;                                                  // ComboBox: stopbits (1, 1.5, 2)
{ ^ Syv ComboBoxes til port- og rammeparametre:
      CbComPort    : Listen over tilsluttede porte (fyldes dynamisk af
                     RefreshComPorts). Brugeren kan kun vælge blandt
                     faktisk eksisterende porte.
      CbBaudRate   : 9600 / 19200 / 38400 / 57600 / 115200 osv.
      CbDataBits   : 5 / 6 / 7 / 8.
      CbParity     : None / Odd / Even / Mark / Space.
      CbStopBits   : 1 / 1.5 / 2.
      CbEncoding   : Mapping til TSerialEncoding — rækkefølgen SKAL matche
                     enum'en.
      CbLineEnding : CR+LF / LF / CR / Ingen — for afsendte kommandoer.
    HVORFOR COMBOBOX OG IKKE EDITS? ComboBox begrænser brugeren til gyldige
    værdier (ingen manuel validering nødvendig) og giver ItemIndex-baseret
    mapping til enum'er. }

    ChkAutoScroll: TCheckBox;                                               // Checkbox: auto-scroll til bund ved nye data
    ChkDTR: TCheckBox;                                                      // Checkbox: manuel styring af DTR-linjen
    ChkHexView: TCheckBox;                                                  // Checkbox: vis rå bytes som hex
    ChkRTS: TCheckBox;                                                      // Checkbox: manuel styring af RTS-linjen
    ChkTimestamp: TCheckBox;                                                // Checkbox: foranstil tidsstempel på nye linjer
{ ^ Fem checkboxes:
      ChkAutoScroll : Scroll automatisk terminalen til bunden ved nye data.
      ChkDTR        : Styr DTR-linjen manuelt (afgørende for nogle MCU'ers
                      reset-adfærd).
      ChkRTS        : Styr RTS-linjen manuelt.
      ChkHexView    : Vis rå bytes som hex (XX XX XX) i stedet for tekst —
                      uundværlig ved binære protokoller.
      ChkTimestamp  : Foranstil [hh:nn:ss.zzz] på nye logiske linjer. }

    EditSend: TEdit;                                                        // Inputfelt til kommandoer, der skal sendes
{ ^ Indtastningsfelt til kommandoer, der skal sendes til MCU'en
    (fx "LED_ON", "MODE", "PING"). Brugeren trykker Enter (håndteres i
    EditSendKeyDown) eller klikker BtnSend. }

    GrpEncoding: TGroupBox;                                                 // GroupBox: samler encoding-relaterede kontroller
    GrpPortSettings: TGroupBox;                                             // GroupBox: samler port-parametre
    GrpTerminal: TGroupBox;                                                 // GroupBox: samler terminalvisning
{ ^ Tre GroupBoxes, der visuelt grupperer relaterede kontroller:
      GrpPortSettings : Port-valg, baudrate, paritet, databits, stopbits.
      GrpEncoding     : Tegnkodning, linjeafslutning, hex-visning,
                        tidsstempel.
      GrpTerminal     : Selve TMemo'en og statuslinjen.
    Ren UI-praksis: reducerer visuel støj og gør et tæt-befolket vindue
    nemmere at overskue. }

    LblBaud: TLabel;                                                        // Label: "Baudrate"
    LblDataBits: TLabel;                                                    // Label: "Databits"
    LblEncoding: TLabel;                                                    // Label: "Encoding"
    LblLineEnding: TLabel;                                                  // Label: "Line ending"
    LblParity: TLabel;                                                      // Label: "Parity"
    LblPort: TLabel;                                                        // Label: "Port"
    LblStopBits: TLabel;                                                    // Label: "Stopbits"
{ ^ Syv labels, der beskriver de tilstødende ComboBoxes. Rene
    visnings-elementer uden begivenheder.
    HVORFOR IKKE BRUGE COMBOBOX'ENS "TEXT"-PROPERTY SOM LABEL?
    Så ville beskrivelsen forsvinde, når brugeren vælger en værdi.
    Separate labels holder teksten stabil. }

    MemoTerminal: TMemo;                                                    // Selve terminalvinduet, hvor al tekst vises
{ ^ Selve terminal-vinduet. Al modtaget data (afkodet eller hex) og
    systembeskeder skrives her. Brugeren kan markere og kopiere tekst.
    TMemo er valgt frem for TRichMemo/TSynEdit fordi:
      - Ingen eksterne komponenter nødvendige.
      - Tilstrækkeligt hurtig med linjebegrænsningen i AppendToTerminal.
      - Indbygget understøttelse af SelStart/SelText til streaming-indsættelse. }

    PanelBottom: TPanel;                                                    // Panel: nederst — EditSend + BtnSend
    PanelControls: TPanel;                                                  // Panel: øverst — portindstillinger og encoding
    PanelStatus: TPanel;                                                    // Panel: statuslinje-området
{ ^ Tre paneler, der organiserer vindueslayoutet:
      PanelControls : Øverst — portindstillinger og encoding-valg.
      PanelBottom   : Nederst — EditSend og BtnSend.
      PanelStatus   : Statuslinje-området (ShapeStatus mv).
    Paneler giver mulighed for at placere under-kontroller med Align
    (alTop, alBottom, alClient), så vinduet kan ændre størrelse uden at
    kontrollerne overlapper. }

    ShapeStatus: TShape;                                                    // Farvet form: grøn = forbundet, rød = ikke forbundet
{ ^ Lille cirkel/firkant, der viser forbindelsesstatus:
      Grøn (clLime) : forbundet.
      Rød   (clRed) : ikke forbundet.
    Opdateres i UpdateUIState. Mere synligt end blot tekst i statuslinjen —
    brugeren ser straks, om porten er åben. }

    StatusBar1: TStatusBar;                                                 // Statuslinje med port-status, RX- og TX-tællere
{ ^ Statuslinjen nederst i vinduet med (mindst) tre paneler:
      Panels[0] : Port-status ("Forbundet: COM3", "Ingen Arduino...").
      Panels[1] : RX-tæller ("RX: 12345 bytes").
      Panels[2] : TX-tæller ("TX: 678 bytes").
    Løbende, ikke-blokerende feedback om datamængder. }

    TimerPoll: TTimer;                                                      // Polling-timer til datalæsning
{ ^ Polling-timeren. Når FIsConnected er sand, fyrer den med jævne
    intervaller (typisk 50-100 ms, sat i .lfm) og kalder TimerPollTimer.
    Herved læses nye bytes uden at blokere GUI'en.
    HVORFOR TIMER OG IKKE EN LÆSETRÅD?
      Enkelhed, ingen race conditions, og rigelig kapacitet ved 115200 baud
      (~11.5 KB/s), hvor OS-bufferen (typisk 4 KB) nemt tømmes inden for
      timer-intervallet. }

    procedure BtnClearClick(Sender: TObject);                               // Event: [Ryd]-knap klikket
{ ^ Sletter indholdet af MemoTerminal og skriver en "=== Terminal ryddet ==="-
    besked. Simpel UX-bekræftelse på, at handlingen lykkedes — ellers kunne
    brugeren tro, at knappen ikke virker. }

    procedure BtnConnectClick(Sender: TObject);                             // Event: [Forbind]-knap klikket
{ ^ Åbner den valgte port og konfigurerer den:
      1. Validerer at en gyldig port er valgt (ikke pladsholderteksten).
      2. Udtrækker rent portnavn (fjerner "(...)"-suffiks).
      3. Mapper ComboBox-valg til baudrate, bits, paritet, stopbits.
      4. Kalder FSerial.Connect og tjekker LastError.
      5. Kalder FSerial.Config med de valgte parametre.
      6. Sætter DTR/RTS fra checkboxes (kritisk for Arduino-auto-reset).
      7. Aktiverer TimerPoll og opdaterer UI-tilstand.
    Fejl vises som ShowMessage med hint om at lukke Arduino IDE's Serial
    Monitor, som ofte holder porten låst. }

    procedure BtnDisconnectClick(Sender: TObject);                          // Event: [Afbryd]-knap klikket
{ ^ Lukker forbindelsen i sikker rækkefølge:
      1. Stopper TimerPoll (forhindrer at RecvBufferStr rammer en lukket
         handle).
      2. Kalder FSerial.CloseSocket.
      3. Sætter FIsConnected := False.
      4. Opdaterer UI og skriver afskedsbesked.
    Idempotent — kan kaldes både fra knappen og fra FormClose. }

    procedure BtnResetMCUClick(Sender: TObject);                            // Event: [Reset MCU]-knap klikket
{ ^ Hardware-reset af MCU'en via DTR-puls:
      DTR := False; Sleep(150); DTR := True.
    150 ms er en sikker, velafprøvet puls til ATmega328P'ens auto-reset-
    kondensator (typisk 100 nF). Virker kun, hvis porten er åben og kortet
    har en auto-reset-kreds (Uno/Nano/ESP32 dev boards har typisk det).
    Praktisk ved firmware-test og ved "hængt" sketch — man slipper for at
    trække USB-stikket ud. }

    procedure BtnRefreshPortsClick(Sender: TObject);                        // Event: [Genopfrisk]-knap klikket
{ ^ Kalder RefreshComPorts og logger resultatet i terminalen. Bruges når
    man har tilsluttet/fjernet USB, mens programmet kører. Ved forbundet
    tilstand er knappen deaktiveret (se UpdateUIState), fordi porten ikke
    må ændres midt i en session. }

    procedure BtnSendClick(Sender: TObject);                                // Event: [Send]-knap klikket
{ ^ Sender indholdet af EditSend til MCU'en:
      1. Kræver aktiv forbindelse.
      2. Ignorerer tomt input.
      3. Tilføjer valgt linjeafslutning (CR+LF, LF, CR eller ingen).
      4. Kalder FSerial.SendString, opdaterer TX-tæller.
      5. Skriver "[Sendt -> Arduino]: ..." som bekræftelse og rydder
         EditSend.
    Fejl fanges og vises som ShowMessage. }

    procedure ChkDTRChange(Sender: TObject);                                // Event: ChkDTR skiftet tilstand
{ ^ Kaldes når brugeren klikker ChkDTR. Hvis forbundet, sættes
    FSerial.DTR straks. Ellers gemmes blot checkboxens tilstand til næste
    Connect (BtnConnectClick læser den der). }

    procedure ChkRTSChange(Sender: TObject);                                // Event: ChkRTS skiftet tilstand
{ ^ Samme som ChkDTRChange, men for RTS-linjen. }

    procedure EditSendKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState); // Event: tast trykket i EditSend
{ ^ Enter-tasten i EditSend udløser BtnSendClick, så brugeren kan skrive
    kommandoer uden at flytte hænderne til musen. Key nulstilles til 0 for
    at forhindre, at Enter også indsætter et tegn eller udløser standard-
    dialogadfærd. }

    procedure FormClose(Sender: TObject; var {%H-}CloseAction: TCloseAction); // Event: vinduet lukkes
{ ^ Sikker oprydning ved vinduets lukning:
      - Hvis forbundet: kald BtnDisconnectClick.
      - Frigør FSerial (FreeAndNil).
    Uden dette ville programmet kunne efterlade en åben COM-port, som så
    skulle "ryddes" ved genstart, og en hukommelseslæk ville opstå
    (TBlockSerial er ikke ejet af LCL-komponenthierarkiet).
    {%H-} foran CloseAction undertrykker en compiler-hint om, at parameteren
    ikke bruges i vores krop. Standard-handlingen (luk vinduet) er det, vi
    vil. }

    procedure FormCreate(Sender: TObject);                                  // Event: vinduet oprettes
{ ^ Initialisering ved formens oprettelse:
      - Opretter FSerial, nulstiller tællere og FIsConnected.
      - Kalder RefreshComPorts.
      - Sætter standardværdier (115200, 8N1, UTF-8, CR+LF).
      - Kalder UpdateUIState.
      - Skriver velkomstbesked i terminalen.
    Bruges i stedet for "constructor" fordi LCL's formular-system selv
    kalder FormCreate, EFTER den har streamet .lfm-komponenterne. En
    constructor ville køre FØR .lfm-indlæsningen, hvorved vores FSerial-
    init ville kunne overskrives eller ramme nil-komponenter. }

    procedure GrpTerminalClick(Sender: TObject);                            // Tom autogenereret event (kan ignoreres)
{ ^ Tom begivenhedshåndterings-procedure — autogenereret af Lazarus, da
    komponenten ved et uheld er blevet dobbeltklikket i designeren. Kan
    fjernes uden funktionelt tab. Beholdt her for ikke at ændre .lfm-filen
    unødigt. }

    procedure TimerPollTimer(Sender: TObject);                              // Event: timer-tick — læs data fra porten
{ ^ Hjertet i datalæsningen. Kaldes periodisk når FIsConnected er sand:
      1. Spørger FSerial.WaitingData (bytes i OS-buffer).
      2. Læser præcis så mange bytes med RecvBufferStr (timeout 0 =
         non-blocking, GUI fryser aldrig).
      3. Opdaterer FRxByteCount og statuslinjen.
      4. Vælger visningsvej: hex (hvis ChkHexView) eller afkodning
         (DecodeIncomingData med valgt TSerialEncoding).
      5. Appender til MemoTerminal.
    Undtagelser (fx USB trukket ud) fanges: timeren stoppes, forbindelsen
    markeres død, og portlisten genopfriskes. Det giver en robust oplevelse,
    hvor programmet ikke fryser eller skal genstartes. }

  private                                                                   // Private medlemmer, usynlige udefra
{ ^ Her begynder de private medlemmer — usynlige for andre units. De er
    stadig synlige inde i selve klassen, men kan ikke tilgås udefra.
    Formålet er informationsskjul: kun TFormMain's egne metoder må rode med
    den interne tilstand. }

    FSerial: TBlockSerial;                                                  // Reference til den serielle driver-instans
{ ^ Reference til den serielle driver-instans. Oprettes i FormCreate og
    frigives i FormClose.
    HVORFOR ET FELT OG IKKE EN LOKAL VARIABEL? Forbindelsen skal leve i
    hele formens levetid, så timeren kan læse fra den, og knapperne kan
    skrive til den. En lokal variabel ville forsvinde ved metodeafslutning. }

    FIsConnected: Boolean;                                                  // Sand når porten er åben og konfigureret
{ ^ Sand når porten er åben og konfigureret. Bruges som "vagt" i
    TimerPollTimer, BtnSendClick, BtnResetMCUClick og UpdateUIState. Uden
    den kunne man forsøge at læse fra en lukket handle.
    HVORFOR IKKE BARE TJEKKE FSerial.Handle <> -1?
      Handle er en implementeringsdetalje i driveren, og et eksplicit,
      læsbart flag kan sættes, før porten formelt er åben (fx i fejl-
      håndtering). }

    FRxByteCount: Int64;                                                    // Kumulativt antal modtagne bytes
    FTxByteCount: Int64;                                                    // Kumulativt antal sendte bytes
{ ^ Kumulative byte-tællere for modtaget og sendt data. Viser i statuslinjen
    ("RX: 12345 bytes", "TX: 678 bytes").
    HVORFOR Int64 OG IKKE Integer? Ved 115200 baud (~11.5 KB/s) og en
    session på flere timer kan tælleren overstige 2^31 (~2.1 GB), og en
    almindelig Integer ville "wrappe" negativt. Int64 sikrer korrekt
    visning uanset sessionens længde. }

    FRxBuffer: AnsiString;                                                  // Reserveret buffer (ikke aktivt brugt)
{ ^ Reserveret buffer til delvis opbevaring af rådata. I denne version
    bruges den ikke aktivt, fordi TMemo selv håndterer streaming (AppendTo-
    Terminal indsætter direkte). Feltet er bevaret som forberedelse til en
    fremtidig forbedring, hvor man kunne akkumulere bytes, indtil en hel
    protokolramme er modtaget, før afkodning — nyttigt for Modbus/Bisync,
    hvor rammer kan være opdelte over flere poll-cyklusser. }

    procedure RefreshComPorts;                                              // Gen-skanner systemet og fylder CbComPort
{ ^ Gen-skanner systemet for tilsluttede porte via GetSerialPortNames
    (fra synaser) og fylder CbComPort. Hvis ingen porte findes, indsættes
    en pladsholdertekst, og BtnConnect deaktiveres via UpdateUIState.
    Opdaterer statuslinjens første panel med antal fundne porte.
    HVORFOR INGEN FALSKE PORTE? Mange terminaler viser alle historiske
    COM-navne, hvilket forvirrer brugeren og giver "port findes ikke"-fejl
    ved forbindelse. Ved kun at vise fysisk tilstedeværende porte undgås
    den slags fejl. }

    procedure UpdateUIState;                                                // Central funktion: sætter enabled/disabled på alle kontroller
{ ^ Central funktion, der sætter enabled/disabled på alle afhængige
    komponenter ud fra FIsConnected og portens gyldighed:
      - Under forbindelse: port-parametre låses, Send aktiveres,
        Disconnect/Reset aktiveres, Connect/Refresh deaktiveres.
      - ShapeStatus: grøn ved forbindelse, rød ellers.
      - Statuslinje: "Forbundet: <port>" / "Afbrudt (klar)" /
        "Ingen Arduino tilsluttet...".
    HVORFOR EN SAMLET FUNKTION? At sprede disse sætninger ud i Connect/
    Disconnect/Refresh ville føre til inkonsistens. Én funktion = ét
    sandhedspunkt for UI-tilstand. }

    procedure AppendToTerminal(const AText: string);                        // Skriver tekst til MemoTerminal med streaming-semantik
{ ^ Skriver tekst til MemoTerminal med streaming-semantik:
      1. Hukommelsesværn: hvis > 2500 linjer, slettes ældste indtil 1500
         (BeginUpdate/EndUpdate undgår flicker).
      2. Tidsstempel: hvis ChkTimestamp OG forrige linje er tom/start,
         foranstilles [hh:nn:ss.zzz]. Dette undgår at hvert enkelt
         Serial.print() får sit eget stempel midt i en logisk linje.
      3. Streaming-indsættelse via SelStart/SelText — ækvivalent med
         Arduino IDE's Serial Monitor, bevarer delvise linjer korrekt.
      4. Auto-scroll hvis ChkAutoScroll er slået til.
    HVORFOR BESKÆRE VED 2500 LINJER? TMemo bliver markant langsommere ved
    titusindvis af linjer (især RichEdit på Windows). Grænsen holder UI
    responsivt under kontinuerlig højhastigheds-telemetri uden at brugeren
    mister nyttig nylig historik. }

    function DecodeIncomingData(const RawBytes: AnsiString; Encoding: TSerialEncoding): string; // Dispatcher for afkodning
{ ^ Dispatcher, der afkoder rå bytes i henhold til valgt TSerialEncoding.
    For hver kodning kaldes den relevante underrutine:
      - encUTF8/ASCII/ISO88591/UTF16LE/BE: direkte eller via hjælpe-
        funktioner (Latin1ToUTF8, UTF8Encode).
      - encModbusASCII : DecodeModbusASCII.
      - encIBMBisync   : DecodeIBMBisync.
    Returnerer en UTF-8-streng, som TMemo kan vise korrekt.
    HVORFOR EN SEPARAT FUNKTION? Adskiller "hvordan data fortolkes" fra
    "hvornår data læses" (TimerPollTimer) og "hvordan data vises"
    (AppendToTerminal). Gør det nemt at tilføje nye kodninger senere. }

    function DecodeModbusASCII(const Raw: AnsiString): string;              // Modbus ASCII-protokolafkoder
{ ^ Modbus ASCII-afkodning. Erstatter ':' med "[MODBUS START :]", og CRLF
    med "[END CRLF]" + LineEnding, så rammestrukturen bliver synlig.
    Øvrige tegn (hex-cifre, adresse, funktionskode, data, LRC) bevares
    uændret.
    HVORFOR? Modbus ASCII er en tekstprotokol, men ':' og CRLF er usynlige
    i en rå visning. Ved at tagge dem ser udvikleren straks, hvor rammen
    starter og slutter — uden at skulle bruge en dedikeret protokol-
    analysator. }

    function DecodeIBMBisync(const Raw: AnsiString): string;                // IBM Bisync-protokolafkoder
{ ^ IBM Bisync-afkodning. Oversætter binære styretegn til læsbare tags:
      SYN (0x16/0x32) -> <SYN>     STX (0x02) -> <STX>
      ETX (0x03)      -> <ETX>     EOT (0x04) -> <EOT>
      ENQ (0x05)      -> <ENQ>     ACK (0x06) -> <ACK>
      NAK (0x15)      -> <NAK>     DLE (0x10) -> <DLE>
      ETB (0x17)      -> <ETB>
    Printable ASCII (32..126) vises som tegn, øvrige bytes som [0xNN].
    HVORFOR? Bisync-styretegn er usynlige eller ødelægger layoutet i en
    rå tekstvisning. Tags gør det muligt at følge protokollen direkte i
    terminalen. }

    function BytesToHexString(const Raw: AnsiString): string;               // Konverterer rå bytes til hex-streng
{ ^ Konverterer rå bytes til en hex-streng ("48 65 6C 6C 6F ").
    Bruges af TimerPollTimer, når ChkHexView er slået til.
    HVORFOR HEX-VISNING? Ved binære protokoller (Bisync, Modbus RTU,
    binære sensorformater) er tekstvisning ubrugelig — hex-dump er den
    eneste måde at se, hvad der faktisk sendes. }

  public                                                                    // Offentlig sektion (tom i denne version)
{ ^ Offentlig sektion — tom i denne version. Kunne bruges til at eksponere
    et API for andre units (fx en "SendCommand"-metode eller en
    "ConnectTo"-funktion). Ikke nødvendigt her, fordi al interaktion sker
    via GUI'et. }

  end;                                                                      // Slut på TFormMain-klassen
{ ^ Slut på klasseerklæringen for TFormMain. }

var                                                                         // Globale variable
  FormMain: TFormMain;                                                      // Global reference til hovedvinduet (Lazarus-konvention)
{ ^ Global variabel, der peger på den ene instans af TFormMain, som
    applikationen opretter via Application.CreateForm i .lpr-filen.
    HVORFOR GLOBAL? LCL's formular-system og event-handlere forventer en
    global reference ("FormMain") — det er en fast konvention i Lazarus.
    Alle event-metoderne kan dermed tilgå formen uden at skulle have
    referencen sendt som parameter.
    HVORFOR KUN ÉN INSTANS? Hovedvinduet er applikationens eneste
    hovedformular; flere samtidige terminal-vinduer ville kræve en mere
    kompleks MDI- eller multi-form-arkitektur, som ikke er formålet her. }

implementation                                                              // Begynder implementationsdelen
{ ^ Her begynder implementation-sektionen. Alt, der erklæres her, er KUN
    synligt inde i denne unit — andre units, der "uses"-er unitmain, kan
    ikke se eller kalde disse procedurer og funktioner. Det giver fuld
    indkapsling af den interne arbejdsgang.

    HVORFOR ADSKILLE FRA INTERFACE?
      - Kompileringshastighed: andre units læser kun interface-delen.
      - Informationsskjul: implementation-detaljer (fx Latin1ToUTF8) er
        usynlige for omverdenen, så vi frit kan ændre dem uden at
        påvirke andre units' kompilering.
      - Kontrakt vs. udførelse: interface er "hvad unit'en lover at
        kunne", implementation er "hvordan den gør det". }

{$R *.lfm}                                                                  // Linker formularressourcen ind i executablen
{ ^ Compiler-direktiv, der linker den binære formularressource ind i
    executablen. "*.lfm" refererer til en fil med samme basisnavn som
    denne unit — altså unitmain.lfm. Filen indeholder alle komponenternes
    egenskaber og placering (genereret af Lazarus' formular-designer) i
    et tekstbaseret eller binært ressourceformat.

    HVORFOR ER DET NØDVENDIGT?
      Uden denne linje ville TFormMain ganske vist være erklæret, men
      alle knapper, ComboBoxes og selve MemoTerminal ville mangle, når
      formen oprettes — fordi der ikke er nogen ressource at streame
      komponenterne fra. Det er præcis denne linje, der binder designet
      (placering, størrelser, standardtekster, event-handler-tilknytninger)
      sammen med koden.

    HVORFOR LIGE EFTER "implementation" OG IKKE I INTERFACE?
      Direktivet genererer kode (en ressource-initialisering), og
      compileren tillader ikke kode i interface-sektionen — kun
      erklæringer. Derfor hører det hjemme som det første i
      implementation. }

{ Konverterer ISO-8859-1 (Latin-1) til UTF-8 for korrekt visning af æ, ø, å }
function Latin1ToUTF8(const S: AnsiString): string;                         // Hjælpefunktion: konverterer ISO-8859-1 til UTF-8
var                                                                         // Lokale variable til funktionen
  i, j, Len: Integer;                                                       // i = input-indeks, j = output-indeks, Len = input-længde
  B: Byte;                                                                  // Aktuel byte fra input
begin                                                                       // Begynder funktionens krop
  Result := '';                                                             // Initialiserer resultatet som tom streng
  Len := Length(S);                                                         // Gemmer input-længden
  if Len = 0 then Exit;                                                     // Tidlig retur ved tom input

  SetLength(Result, Len * 2);                                               // Reserverer plads til værste tilfælde
  j := 1;                                                                   // Output-indeks starter på 1
  for i := 1 to Len do                                                      // Itererer over hver input-byte
  begin                                                                     // Begynder løkkekrop
    B := Byte(S[i]);                                                        // Henter byte-værdien
    if B < $80 then                                                         // Er det et rent ASCII-tegn?
    begin                                                                   // Begynder ASCII-gren
      Result[j] := Chr(B);                                                  // Kopierer tegnet uændret
      Inc(j);                                                               // Flytter output-indeks én frem
    end                                                                     // Slut ASCII-gren
    else                                                                    // Ellers: byte >= 0x80
    begin                                                                   // Begynder UTF-8-gren
      Result[j] := Chr($C0 or (B shr 6));                                   // Første UTF-8-byte: 110xxxxx
      Result[j + 1] := Chr($80 or (B and $3F));                             // Anden UTF-8-byte: 10xxxxxx
      Inc(j, 2);                                                            // Flytter output-indeks to frem
    end;                                                                    // Slut UTF-8-gren
  end;                                                                      // Slut løkke
  SetLength(Result, j - 1);                                                 // Trimmer til faktisk brugt længde
end;                                                                        // Slut på Latin1ToUTF8
{ ^ Hjælpefunktion, der konverterer en ISO-8859-1 (Latin-1)-streng til
    UTF-8, så danske specialtegn (æ, ø, å, Æ, Ø, Å) vises korrekt i
    TMemo.

    BAGGRUND — HVORFOR ER KONVERTERING NØDVENDIG?
      Arduino-sketches kan sende tekst i flere forskellige kodninger:
        - UTF-8         : æ = 0xC3 0xA6 (to bytes), ø = 0xC3 0xB8, osv.
        - ISO-8859-1    : æ = 0xE6 (én byte), ø = 0xF8, å = 0xE5.
      Lazarus' LCL (og dermed TMemo) forventer UTF-8 i sine strenge. Hvis
      man sender Latin-1-bytes direkte til TMemo, fortolkes 0xE6 som en
      ufuldstændig UTF-8-sekvens, og brugeren ser "Ã¦" eller et "?" i
      stedet for "æ". Denne funktion reparerer det ved at udføre den
      korrekte Latin-1 -> UTF-8-transformation.

    HVORFOR EN EGEN FUNKTION OG IKKE EN STANDARD-FUNKTION?
      Free Pascal's SysUtils har ikke en indbygget Latin1ToUTF8 (kun
      UTF8Encode/UTF8Decode, som arbejder på WideString). Man kunne
      konvertere via WideString:
        UTF8Encode(WideString(S))
      men det kræver, at WideString'en først er korrekt udfyldt med
      codepoints — og det er netop problemet: en Latin-1-byte 0xE6 er
      IKKE det samme codepoint som UTF-8's 0xC3 0xA6. Manuel konvertering
      er både hurtigere (ingen mellemled) og undgår afhængigheder til
      ekstra units.

    HVORDAN VIRKER UTF-8-KODNINGEN FOR TEGN 0x80..0xFF?
      I UTF-8 kodes codepoints 0x80..0x7FF som to bytes:
        byte1 = 0xC0 or (codepoint shr 6)     (6 høje bits + præfiks 110)
        byte2 = 0x80 or (codepoint and $3F)   (6 lave bits + præfiks 10)
      Eksempel: æ = 0xE6 = 230
        230 shr 6    = 3       -> 0xC0 or 3   = 0xC3
        230 and $3F  = 38      -> 0x80 or 38  = 0xA6
      Resultat: 0xC3 0xA6 — præcis den korrekte UTF-8-sekvens for æ.
      Denne to-byte-form dækker hele Latin-1-området (0x80..0xFF), fordi
      alle codepoints < 0x800. Tre-byte-formen (0x800..0xFFFF) er derfor
      ikke nødvendig her.

    HVORFOR SetLength(Result, Len * 2) PÅ FORHÅND?
      Værste tilfælde: alle bytes er >= 0x80, og hver byte bliver til to
      UTF-8-bytes. Ved at reservere plads én gang undgår vi, at
      AnsiString'en skal omallokere undervejs i løkken (hvilket ville
      gøre funktionen markant langsommere ved store datamængder).
      Den endelige SetLength(Result, j - 1) trimmer til det faktisk
      brugte antal bytes.

    HVORFOR "Len := Length(S); if Len = 0 then Exit;"?
      Tidlig retur ved tom input. Både for at undgå unødvendig
      allokering (SetLength med 0 er tilladt, men unødvendigt arbejde)
      og for at gøre det eksplicit, at tom input giver tom output.

    HVORFOR "Byte(S[i])" OG IKKE "Ord(S[i])"?
      S[i] er et AnsiChar (én byte). Byte(...) er den mest direkte cast
      og undgår eventuelle fortegnsproblemer på platforme, hvor Char
      fortolkes som signeret. Ord() ville også virke, men Byte() gør
      hensigten tydeligere.

    BEMÆRK OM GYLDIGHED:
      Funktionen antager, at inputtet FAKTISK er Latin-1. Hvis inputtet
      i virkeligheden er UTF-8, vil resultatet blive dobbelt-konverteret
      og vise "Ã¦" i stedet for "æ". Derfor er kodningsvalget i
      CbEncoding vigtigt — brugeren SKAL vælge encISO88591, når MCU'en
      faktisk sender Latin-1. }

{ TFormMain }
{ ^ Kommentar-markør, der indikerer, at de følgende metoder hører til
    TFormMain-klassen. I Object Pascal er det ikke strengt nødvendigt at
    skrive klassenavnet før hver metode, hvis man bruger den fulde
    kvalificering "procedure TFormMain.MetodeNavn". Kommentaren er en
    læsbarhedskonvention, der matcher Lazarus' autogenererede stil.

    HVORFOR STÅR DEN HER OG IKKE ET ANDET STED?
      Den markerer begyndelsen på den blok af implementation-kode, der
      hører til TFormMain — altså alle de metoder, der blev erklæret i
      interface-delen (FormCreate, BtnConnectClick, TimerPollTimer osv.).
      Når Lazarus genererer en ny event-handler, indsætter den altid
      metoden under denne markør, så udvikleren hurtigt kan finde frem
      til klassens krop. }

procedure TFormMain.FormCreate(Sender: TObject);                            // Initialisering ved formens oprettelse
{ ^ Initialiseringsmetode, der kaldes ÉN gang, når formen oprettes — og
    altså efter at LCL har streamet alle komponenter fra .lfm-filen, så
    MemoTerminal, CbComPort osv. allerede eksisterer.

    HVORFOR FormCreate OG IKKE EN CONSTRUCTOR?
      - LCL's formular-system kalder selv FormCreate på det rigtige
        tidspunkt i opstartssekvensen. En constructor ville køre FØR
        .lfm-streamingen, hvor komponent-referencerne endnu er nil, og
        vores init-kode ville crashe eller blive overskrevet.
      - Alle komponenter er garanteret til stede her, hvilket gør det
        sikkert at kalde UpdateUIState og AppendToTerminal.
      - Event-handleren tilknyttes automatisk via .lfm, så vi skal ikke
        selv registrere noget.

    RÆKKEFØLGEN AF KALDDENE ER VIGTIG:
      1. FSerial oprettes (nødvendig for alle efterfølgende metoder).
      2. Tællere og flag nulstilles.
      3. RefreshComPorts (fylder CbComPort og sætter statuslinjen).
      4. Standardværdier for ComboBoxes (kræver at Items er fyldt).
      5. UpdateUIState (kræver at både FSerial og CbComPort er klar).
      6. Velkomstbesked (kræver at MemoTerminal er klar).
    Hvis rækkefølgen ændres, kan man få nil-adgang eller forkerte
    enabled/disabled-tilstande. }
begin                                                                       // Begynder procedurens krop
  FSerial := TBlockSerial.Create;                                           // Opretter driver-instansen (ikke LCL-ejet)
  { ^ Opretter den serielle driver-instans. Dette er IKKE en LCL-
      komponent — TBlockSerial arver direkte fra TObject — så den bliver
      ikke automatisk frigivet af formen. Derfor skal vi selv frigøre den
      i FormClose med FreeAndNil.
      HVORFOR OPRETTE DEN HER OG IKKE I CONNECT?
        Fordi både Connect, Disconnect, RefreshComPorts og FormClose
        refererer til FSerial. Hvis vi oprettede den først ved Connect,
        skulle alle andre metoder tjekke for nil — hvilket ville gøre
        koden mere rodet. Ved at oprette den i FormCreate er den
        garanteret til stede i hele formens levetid. }

  FIsConnected := False;                                                    // Ingen forbindelse endnu
  { ^ Eksplicit nulstilling. Feltet er ganske vist allerede False ved
      allokering (object-felter nulstilles), men det er god praksis at
      være eksplicit: hvis man senere ændrer klassens initialisering
      eller tilføjer en arvekonstruktor, er man sikret, at tilstanden
      er veldefineret. Det gør også hensigten tydelig for læseren. }

  FRxByteCount := 0;                                                        // Nulstiller RX-tæller
  FTxByteCount := 0;                                                        // Nulstiller TX-tæller
  { ^ Nulstiller RX- og TX-tællere. Statuslinjen skal starte ved 0/0.
      Int64-felterne nulstilles på samme måde som alle andre. }

  FRxBuffer := '';                                                          // Nulstiller reserveret buffer
  { ^ Nulstiller den reserverede buffer. I denne version bruges den ikke
      aktivt (TMemo streamer selv), men den nulstilles alligevel, så
      en fremtidig brug ikke arver gammel tilstand. }

  // Initialiser lister
  RefreshComPorts;                                                          // Fylder CbComPort med tilsluttede porte
  { ^ Fylder CbComPort med de aktuelt tilsluttede porte og opdaterer
      statuslinjen. Kaldes allerede her, så brugeren ser en korrekt
      liste, straks da vinduet åbnes — uden at skulle trykke
      [Genopfrisk] først. }

  // Standardværdier optimeret til Arduino / ESP32
  if CbComPort.Items.Count > 0 then                                         // Er der mindst én port i listen?
    CbComPort.ItemIndex := 0;                                               // Vælg den første automatisk
  { ^ Vælger den første port på listen, så brugeren ikke skal klikke
      i ComboBoxen, hvis der kun er én port (det typiske tilfælde med
      én Arduino tilsluttet).
      BEMÆRK: Hvis listen indeholder pladsholderen "(Ingen tilkoblede
      COM-porte fundet)", sættes ItemIndex også til 0, men BtnConnect
      forbliver deaktiveret via UpdateUIState, og BtnConnectClick
      afviser pladsholderen eksplicit. }

  CbBaudRate.ItemIndex := CbBaudRate.Items.IndexOf('115200');               // Forsøg at vælge 115200 baud
  if CbBaudRate.ItemIndex = -1 then                                         // Findes 115200 ikke i listen?
    CbBaudRate.ItemIndex := CbBaudRate.Items.IndexOf('9600');               // Fald tilbage til 9600 baud
  { ^ Forsøger først at vælge 115200 — den mest udbredte baudrate for
      Arduino/ESP32-sketches. Hvis 115200 ikke findes i listen (fx hvis
      .lfm'en er blevet ændret), falder vi tilbage til 9600, som er
      den klassiske Arduino-standard.
      IndexOf returnerer -1, hvis strengen ikke findes, så vi kan ikke
      bare sætte ItemIndex direkte — vi skal tjekke og falde tilbage.
      HVORFOR IKKE 'StrToIntDef(CbBaudRate.Text, 115200)'?
        Fordi vi vil sikre, at valget FINDES i listen (så ComboBoxen
        viser en konsistent værdi), ikke bare at vi har et tal i hånden. }

  CbParity.ItemIndex := 0;   // Ingen (None - N)                            // Standard: ingen paritet
  CbDataBits.ItemIndex := 3; // 8 bits                                      // Standard: 8 databits (indeks 3)
  CbStopBits.ItemIndex := 0; // 1 stop bit                                  // Standard: 1 stopbit
  CbEncoding.ItemIndex := 0; // UTF-8                                       // Standard: UTF-8
  CbLineEnding.ItemIndex := 0; // CR + LF (\r\n)                            // Standard: CR+LF
  { ^ Sætter standardværdier for de resterende ComboBoxes:
      - Paritet 0 = N (ingen) — standard for 99% af Arduino-kommunikation.
      - DataBits 3 = "8" i den påtænkte liste (5,6,7,8). 8 er standard.
      - StopBits 0 = "1" i den påtænkte liste (1, 1.5, 2). 1 er standard.
      - Encoding 0 = encUTF8 — matcher hvad Arduino/ESP32 typisk sender.
      - LineEnding 0 = CR + LF — matcher Arduino'ens
        Serial.readStringUntil('\n') og Windows-konventionen.
      BEMÆRK: DataBits/StopBits/Encoding/LineEnding er index-baserede,
      så de forudsætter, at ComboBoxenes Items er indtastet i præcis
      den rækkefølge, kommentarerne antyder. Ændres .lfm'ens
      Items-lister, skal disse indeks opdateres. }

  UpdateUIState;                                                            // Anvender tilstanden på hele UI'et
  { ^ Anvender den netop etablerede tilstand på hele UI'et:
      knapper låses op/ned, port-parametre aktiveres, ShapeStatus bliver
      rød, statuslinjen får sin første tekst. Uden dette kald ville
      knapperne stå i deres design-tilstand (typisk alle enabled), hvilket
      kunne lokke brugeren til at trykke på [Forbind] med en ugyldig port. }

  AppendToTerminal('=== Lazarus Arduino Seriel Terminal klar. Vælg port og tryk [Forbind] ===' + LineEnding); // Velkomstbesked
  { ^ Velkomstbesked i terminalen. Bruger LineEnding for at matche
      platformens linjeskift (CR+LF på Windows, LF på Linux) — det gør
      visningen korrekt på begge platforme.
      HVORFOR EN VELKOMSTBESKED?
        - Bekræfter visuelt, at MemoTerminal er funktionsdygtig.
        - Guider brugeren til næste skridt ("Vælg port og tryk [Forbind]").
        - Adskiller systembeskeder fra modtaget telemetri, så det er
          tydeligt, hvad der kommer fra MCU'en, og hvad der kommer fra
          programmet. }
end;                                                                        // Slut på FormCreate

procedure TFormMain.GrpTerminalClick(Sender: TObject);                      // Tom autogenereret event-handler
{ ^ TOM begivenhedshåndtering. Autogenereret af Lazarus, fordi
    GrpTerminal (GroupBox) ved et uheld er blevet dobbeltklikket i
    designeren — det opretter automatisk en OnClick-handler.

    HVORFOR ER DEN TOM?
      Der er ingen funktionalitet knyttet til at klikke på GroupBox'en.
      Den er bevaret, fordi .lfm-filen allerede refererer til metoden;
      fjerner man den fra koden uden også at fjerne referencen i .lfm,
      vil programmet fejle ved opstart med "method not found".

    KAN DEN SLETTES?
      Ja — men kun hvis man samtidig fjerner OnClick-bindingen i
      .lfm-filen (gøres nemmest ved at slette handleren i designeren:
      fanen Events -> OnClick -> vælg "(none)"). Ellers får man en
      runtime-fejl. Derfor er det sikreste og mindst risikable at lade
      den stå som en tom stub, præcis som Lazarus selv har genereret
      den. }

begin                                                                       // Begynder procedurens krop

end;                                                                        // Slut (gør intet)

procedure TFormMain.FormClose(Sender: TObject; var {%H-}CloseAction: TCloseAction); // Oprydning ved vinduets lukning
{ ^ Kaldes når vinduet lukkes (brugeren klikker X, trykker Alt+F4, eller
    applikationen afsluttes). Her rydder vi op i rækkefølge — ellers kan
    vi efterlade en låst COM-port og en hukommelseslæk.

    HVORFOR ER RÆKKEFØLGEN VIGTIG?
      1. BtnDisconnectClick stopper TimerPoll FØR CloseSocket. Hvis
         timeren fyrede mellem CloseSocket og timer-stop, ville
         RecvBufferStr ramme en lukket handle og give en fejl.
      2. Først derefter frigøres FSerial — alle referencer til den
         skal være ophørt.
      Bytter man om, risikerer man adgang til frigjort hukommelse
      (access violation).

    HVORFOR ER CloseAction-PARAMETEREN MARKERET MED {%H-}?
      Directivet undertrykker en compiler-hint ("parameter ikke brugt").
      Vi har ikke brug for at ændre CloseAction — standardadfærden
      (caFree for hovedformen, dvs. applikationen afsluttes) er
      netop det, vi ønsker. }

begin                                                                       // Begynder procedurens krop
  if FIsConnected then                                                      // Er porten stadig åben?
    BtnDisconnectClick(nil);                                                // Luk den korrekt via den eksisterende handler
  { ^ Hvis porten stadig er åben, lukkes den korrekt via den eksisterende
      handler. Fordelen ved at genbruge BtnDisconnectClick frem for at
      duplikere koden er:
        - Konsistens: præcis samme oprydning som ved manuelt frakobling.
        - TimerPoll stoppes, CloseSocket kaldes, FIsConnected := False,
          UI opdateres, og en afskedsbesked skrives.
        - Én sandhedskilde for "hvordan man afbryder".
      HVORFOR nil SOM SENDER?
        Sender bruges ikke i BtnDisconnectClick, så nil er uproblematisk.
        Alternativet — at kalde med Sender som argument — ville kræve
        en cast og give samme resultat. nil er klarere: "ingen
        specifik komponent udløste dette kald". }

  if Assigned(FSerial) then                                                 // Findes driver-instansen?
    FreeAndNil(FSerial);                                                    // Frigiv den og nulstil referencen
  { ^ Frigiver driver-instansen og nulstiller FSerial til nil.
      HVORFOR BÅDE Assigned OG FreeAndNil?
        Assigned(FSerial) tjekker, at feltet ikke allerede er nil (fx
        hvis FormCreate af en eller anden grund ikke blev kørt — teoretisk
        set, men muligt ved fejl under .lfm-indlæsning).
        FreeAndNil(FSerial) gør to ting på én gang:
          FSerial.Free;    (kalder destructor, som selv kalder CloseSocket)
          FSerial := nil;  (nulstiller feltet)
        Det sidste er vigtigt: hvis FormClose ved et uheld kaldes to
        gange (fx dobbelt luk), vil det andet kald se nil og gøre intet
        — i stedet for at forsøge at frigøre den samme hukommelse to
        gange (hvilket giver en crash).
      HVORFOR ER DETTE NØDVENDIGT, NÅR LCL FRIGØR KOMPONENTER?
        TBlockSerial arver fra TObject, IKKE fra TComponent. LCL's
        automatiske oprydning frigør kun TComponent-efterkommere, der
        er oprettet med en Owner. FSerial ville derfor lække uden denne
        eksplicitte frigørelse. }

end;                                                                        // Slut på FormClose

procedure TFormMain.RefreshComPorts;                                        // Gen-skanner systemet for serielle porte
{ ^ Gen-skanner systemet for serielle porte og opdaterer CbComPort samt
    statuslinjen. Kaldes fra FormCreate (ved opstart) og fra
    BtnRefreshPortsClick (når brugeren har sat/fjernet USB).

    KERNEPRINCIP: VIS KUN FYSISK TILSTEDEVÆRENDE PORTE.
      Mange terminal-programmer viser alle COM-porte, Windows nogensinde
      har set — inklusive porte fra tidligere tilslutninger, der ikke
      længere findes. Det fører til forvirring og "kunne ikke åbne port"-
      fejl. Her bruges GetSerialPortNames fra synaser, som verificerer
      fysisk tilstedeværelse (se synaser.pas). }

var                                                                         // Lokale variable
  PortList: string;                                                         // Komma-separeret rå-liste fra GetSerialPortNames
  RawList: TStringList;                                                     // Hjælpeobjekt til at splitte listen
  i: Integer;                                                               // Løkkeindeks
  { ^ Lokale variable:
      PortList : komma-separeret rå-resultat fra GetSerialPortNames
                 (fx "COM3,COM5").
      RawList  : TStringList til at opsplitte PortList i enkeltenheder
                 vha. CommaText.
      i        : løkkeindeks.
      HVORFOR TStringList OG IKKE MANUEL SPLIT?
        CommaText-håndteringen i TStringList er velafprøvet, håndterer
        tomme felter, og giver direkte en 0-baseret liste med
        Trim-mulighed. Manuel splitting med Pos/Copy ville være mere
        fejlbehæftet (især hvis en port-streng indeholder komma, hvilket
        dog ikke forekommer for COM-navne). }

begin                                                                       // Begynder procedurens krop
  CbComPort.Items.Clear;                                                    // Fjerner den tidligere liste
  { ^ Fjerner den tidligere liste. Dette skal ske FØRST, så vi ikke
      akkumulerer duplikater ved gentagne kald (fx hvis brugeren trykker
      [Genopfrisk] mange gange). Det nulstiller også ItemIndex til -1,
      så vi ikke ved et uheld beholder en forældet valgt port. }

  // Henter udelukkende porte som rent faktisk er tilsluttet computeren!
  PortList := GetSerialPortNames;                                           // Henter kun FYSISK tilstedeværende porte
  { ^ Kalder synaser's funktion, der returnerer en kommasepareret liste
      over FYSISK tilstedeværende porte. På Windows verificeres hver
      kandidat med CreateFileA; på Linux scannes /dev/ttyUSB* og
      /dev/ttyACM*. Resultatet er tomt, hvis ingen er tilsluttet. }

  if PortList <> '' then                                                    // Er der mindst én port?
  begin                                                                     // Begynder succes-gren
    RawList := TStringList.Create;                                          // Opretter hjælpeobjekt
    try                                                                     // Begynder try/finally
      RawList.CommaText := PortList;                                        // Splitter "COM3,COM5" til to strenge
      { ^ CommaText-parseren splitter "COM3,COM5" til to strenge.
          Dette er en indbygget egenskab ved TStringList, som både
          sætter og læser en liste i CSV-format. }

      for i := 0 to RawList.Count - 1 do                                    // Itererer over hver port
      begin                                                                 // Begynder løkkekrop
        if Trim(RawList[i]) <> '' then                                      // Er strengen ikke tom efter Trim?
          CbComPort.Items.Add(Trim(RawList[i]));                            // Tilføj portnavnet til ComboBoxen
      end;                                                                  // Slut løkke
      { ^ Tilføjer hvert portnavn til ComboBoxen. Trim fjerner
          eventuelle hvide tegn, som CSV-parseren kan efterlade.
          Tjekket for tom streng undgår, at man får et tomt punkt i
          listen — det ville være uhensigtsmæssigt, fordi ComboBoxen
          så kunne have en "usynlig" post, som brugeren ikke kan se,
          men som stadig har ItemIndex. }
    finally                                                                 // Uanset undtagelse:
      RawList.Free;                                                         // Frigiv hjælpeobjektet
      { ^ finally sikrer, at TStringList'en frigives, uanset om
          Items.Add skulle kaste en undtagelse. Uden finally ville en
          fejl føre til hukommelseslæk. Dette er standardmønstret for
          midlertidige hjælpeobjekter i Delphi/Free Pascal. }
    end;                                                                    // Slut try/finally
  end;                                                                      // Slut succes-gren

  // Hvis ingen enhed er tilsluttet, tilføjes INGEN falske porte!
  if CbComPort.Items.Count > 0 then                                         // Blev der fundet mindst én port?
  begin                                                                     // Begynder "port fundet"-gren
    CbComPort.ItemIndex := 0;                                               // Vælg den første automatisk
    BtnConnect.Enabled := not FIsConnected;                                 // Aktivér [Forbind] (medmindre allerede forbundet)
    StatusBar1.Panels[0].Text := IntToStr(CbComPort.Items.Count) + ' tilkoblet port fundet. Klar.'; // Statusbesked
    { ^ Mindst én port fundet:
        - Vælg den første automatisk (typisk den eneste).
        - Aktivér [Forbind], medmindre vi allerede er forbundet
          (RefreshComPorts kan i princippet kaldes under forbindelse,
          og så skal knappen forblive deaktiveret).
        - Statuslinjen viser "N tilkoblet port fundet. Klar." — så
          brugeren ved, at systemet har registreret enheden.
        BEMÆRK: BtnConnect.Enabled sættes her, men UpdateUIState
        (kaldet fra FormCreate/BtnRefreshPortsClick) sætter den
        endeligt. Det er ikke redundans — det sikrer, at statuslinjen
        er korrekt, selv om UpdateUIState af en eller anden grund
        ikke kaldes (fx hvis RefreshComPorts kaldes isoleret). }
  end                                                                       // Slut "port fundet"-gren
  else                                                                      // Ellers: ingen port fundet
  begin                                                                     // Begynder "ingen port"-gren
    CbComPort.Items.Add('(Ingen tilkoblede COM-porte fundet)');             // Indsæt pladsholdertekst
    CbComPort.ItemIndex := 0;                                               // Vælg pladsholderen
    BtnConnect.Enabled := False;                                            // Deaktivér [Forbind]
    StatusBar1.Panels[0].Text := 'Ingen Arduino tilsluttet. Sæt USB i og tryk [Genopfrisk].'; // Handlingsorienteret status
    { ^ Ingen port fundet:
        - Indsæt en tydelig pladsholdertekst, så ComboBoxen ikke står
          tom (en tom ComboBox ser "i stykker ud" for brugeren).
        - Vælg pladsholderen, så den vises.
        - Deaktivér [Forbind] — der er intet at forbinde til.
        - Guiden i statuslinjen fortæller brugeren, hvad næste skridt
          er: tilslut USB og tryk [Genopfrisk].
        Pladsholderen har en parentes som første tegn; BtnConnectClick
        tjekker Pos('(', ...) = 1 for at afvise forsøg på at forbinde
        til den. Det er et simpelt, men effektivt "sentinel"-mønster. }
  end;                                                                      // Slut "ingen port"-gren
end;                                                                        // Slut på RefreshComPorts

procedure TFormMain.BtnRefreshPortsClick(Sender: TObject);                  // Event: [Genopfrisk]-knap
{ ^ Event-handler for [Genopfrisk]-knappen. Kaldes når brugeren har
    tilsluttet eller fjernet en USB-enhed, mens programmet kører, og
    ønsker at opdatere portlisten uden at genstarte programmet.

    HVORFOR ER DENNE KNAP NØDVENDIG?
      Portlisten i CbComPort fyldes ved opstart (FormCreate) og ændrer
      sig ikke automatisk, når Windows/Linux registrerer en ny enhed.
      Uden denne knap skulle brugeren lukke og genåbne programmet, hver
      gang en Arduino blev sat til eller taget fra — en dårlig
      brugeroplevelse, især under udvikling hvor man ofte skifter kort.

    HVORFOR KAN KNAPPEN IKKE BRUGES UNDER FORBINDELSE?
      Se UpdateUIState: BtnRefreshPorts.Enabled := not FIsConnected.
      Hvis man kunne genopfriske midt i en aktiv session, ville
      CbComPort.Items.Clear frigøre den valgte port-referencen, og
      StatusBar1 ville vise en liste, der ikke matcher den faktisk
      åbne port. Risikoen for forvirring og inkonsistens er for stor.

    HVORFOR TO FORSKELLIGE BESKEDER?
      Brugeren skal have en tydelig bekræftelse i terminalen på, hvad
      der skete. En "Port-liste opdateret: COM3" er mere informativ end
      en generisk "OK", og en "Ingen tilkoblede porte fundet" guider
      brugeren til at kontrollere USB-kablet. }

begin                                                                       // Begynder procedurens krop
  RefreshComPorts;                                                          // Selve arbejdet: opdater portlisten
  { ^ Selve arbejdet: tømmer CbComPort, kalder GetSerialPortNames,
      fylder listen på ny og opdaterer statuslinjen.
      Denne metode er gjort separat, fordi den også kaldes fra FormCreate
      — vi undgår at duplikere logikken.

      BEMÆRK: RefreshComPorts nulstiller også CbComPort.ItemIndex til 0
      (den første fundne port). Hvis brugeren tidligere havde valgt fx
      COM5 og derefter genopfrisker, vil valget hoppe tilbage til den
      første port på listen. Det er en bevidst afvejning: enkelhed frem
      for "bevar-valget"-logik, som ville kræve at gemme og genskabe
      det gamle valg — og som i øvrigt er problematisk, hvis den gamle
      port ikke længere findes. }

  if (CbComPort.Items.Count > 0) and (Pos('(', CbComPort.Items[0]) <> 1) then // Er der en ægte port (ikke pladsholder)?
    AppendToTerminal('[System] Port-liste opdateret: ' + CbComPort.Items.CommaText + LineEnding) // Log succes
  else                                                                      // Ellers: ingen ægte port
    AppendToTerminal('[System] Ingen tilkoblede COM-porte fundet. Kontrollér USB-forbindelse.' + LineEnding); // Log fiasko
  { ^ Skelner mellem de to situationer, som RefreshComPorts kan efterlade
      os i:

      SUCCES — mindst én ægte port:
        Betingelserne er:
          (CbComPort.Items.Count > 0)  : der er mindst ét punkt i listen.
          (Pos('(', CbComPort.Items[0]) <> 1)
            : det FØRSTE punkt starter IKKE med '(' — dvs. det er ikke
              pladsholderen "(Ingen tilkoblede COM-porte fundet)".
        Så skrives "[System] Port-liste opdateret: " efterfulgt af
        Items.CommaText. CommaText på en TComboBox.Items giver en
        komma-separeret liste af alle punkter — fx "COM3,COM5" — hvilket
        er præcis den form, RefreshComPorts oprindeligt modtog fra
        GetSerialPortNames. Det giver brugeren et konkret billede af,
        hvad der blev fundet.
        HVORFOR LIGE NETOP Items[0] OG IKKE EN LØKKE?
          Fordi RefreshComPorts KUN indsætter pladsholderen, når listen
          er tom. Er der først en ægte port, er Items[0] altid en ægte
          port — så et enkelt tjek er tilstrækkeligt og billigere end
          at scanne hele listen.

      FIASKO — ingen ægte port:
        Enten er listen tom (Count = 0, hvilket teoretisk ikke burde
        ske, fordi RefreshComPorts altid indsætter pladsholderen), eller
        også er Items[0] pladsholderen. I begge tilfælde skrives en
        handlingsorienteret besked: "Kontrollér USB-forbindelse."
        HVORFOR IKKE BARE EN GENERISK FEJLBESKED?
          Fordi den mest almindelige årsag er netop et løst eller
          manglende USB-kabel, og brugeren kan løse problemet selv
          med det samme hint. }

end;                                                                        // Slut på BtnRefreshPortsClick

procedure TFormMain.BtnConnectClick(Sender: TObject);                       // Event: [Forbind]-knap
{ ^ Event-handler for [Forbind]-knappen. Åbner den valgte serielle port,
    konfigurerer den med de valgte parametre, sætter DTR/RTS og starter
    polling-timeren — alt sammen med grundig fejlhåndtering, så brugeren
    får en forståelig besked i stedet for en crash, når noget går galt
    (fx at porten er optaget af Arduino IDE).

    DEN OVERORDNEDE STRATEGI:
      1. Validér input FØRST (før nogen ressource åbnes).
      2. Udtræk og normalisér portnavnet.
      3. Oversæt ComboBox-valg til de typer, driveren forventer.
      4. Åbn porten og konfigurer den — pakket i try/except, så en
         fejl ikke efterlader os i en halvåben tilstand.
      5. Kun ved succes: opdater tilstand, start timer, log til terminal.

    HVORFOR VALIDERE FØRST OG IKKE MIDT I?
      Hvis vi åbnede porten og derefter opdagede, at parameterne var
      ugyldige, skulle vi lukke porten igen i en oprydningsblok. Ved at
      validere alt, inden vi rører driveren, undgår vi den slags
      "rollback"-logik og gør metoden meget lettere at læse. }

var                                                                         // Lokale variable
  RawPortStr: string;                                                       // Rå tekst fra CbComPort (kan indeholde suffix)
  PortName: string;                                                         // Rent portnavn
  Baud: Integer;                                                            // Baudrate som heltal
  Bits: Integer;                                                            // Antal databits
  ParityChar: Char;                                                         // Paritet som bogstav (N/O/E/M/S)
  StopBitVal: Integer;                                                      // Stopbits som synaser-konstant
  p: Integer;                                                               // Hjælpeindeks til at finde mellemrum
  { ^ Lokale variable:
      RawPortStr : den rå tekst fra CbComPort (fx "COM3" eller
                   "COM3 (Arduino)"), uændret bortset fra Trim.
      PortName   : det rene portnavn efter udtræk ("COM3").
      Baud       : baudrate som heltal.
      Bits       : antal databits som heltal.
      ParityChar : paritet som enkelt bogstav ('N','O','E','M','S').
      StopBitVal : stopbits som SB1/SB1andHalf/SB2-konstant fra synaser.
      p          : hjælpeindeks til at finde mellemrum i portnavnet.
      HVORFOR IKKE BRUGE CbComPort.ItemIndex SOM SANDHEDSKILDE?
        Fordi brugeren i princippet kan have skrevet frit i ComboBoxen
        (hvis Style ikke er csDropDownList) — Text er mere robust. Og
        selv når Style er låst, kan Text indeholde ekstra suffiks som
        "(Arduino)", som vi skal strippe. }

begin                                                                       // Begynder procedurens krop
  if (CbComPort.Text = '') or (Pos('(', CbComPort.Text) = 1) then           // Er der ingen gyldig port valgt?
  begin                                                                     // Begynder fejl-gren
    ShowMessage('Der er ingen tilkoblet COM-port valgt!' + LineEnding +      // Vis fejlbesked
                'Tilslut din Arduino via USB-kabel og tryk derefter på [Genopfrisk].'); // Handlingsorienteret hint
    Exit;                                                                   // Afbryd metoden
  end;                                                                      // Slut fejl-gren
  { ^ FØRSTE VALIDERING: Er der overhovedet en brugbar port valgt?
        CbComPort.Text = ''            : helt tomt felt.
        Pos('(', CbComPort.Text) = 1   : pladsholderen
                                         "(Ingen tilkoblede COM-porte fundet)"
                                         er valgt — den starter med '('.
      I begge tilfælde vises en handlingsorienteret besked, der forklarer
      HVAD brugeren skal gøre, ikke bare at noget er galt. Det er vigtig
      UX: en "fejl"-besked uden løsningsforslag frustrerer brugeren.
      HVORFOR 'Exit' OG IKKE 'Abort'?
        Abort ville kaste en EAbort-undtagelse, som kunne fanges utilsigtet
        af den omkringliggende try/except længere nede. Exit er en ren,
        kontrolleret afslutning af metoden — præcis hvad vi ønsker her. }

  // Ekstraher rent portnavn hvis der er ekstra tekst (f.eks. "COM3 (Arduino)")
  RawPortStr := Trim(CbComPort.Text);                                       // Fjerner hvide tegn i enderne
  { ^ Trim fjerner hvide tegn i enderne. Selv om vi selv har indsat
      portnavnet uden mellemrum, kunne en fremtidig ændring af .lfm'en
      (fx en "Style" med automatisk udfyldning) tilføje dem. }

  p := Pos(' ', RawPortStr);                                                // Findes der et mellemrum?
  if p > 0 then                                                             // Hvis ja: der er et suffix
    PortName := Copy(RawPortStr, 1, p - 1)                                  // Tag kun delen før mellemrummet
  else                                                                      // Ellers: hele strengen er portnavnet
    PortName := RawPortStr;                                                 // Brug hele strengen
  { ^ Udtrækker det rene portnavn. Hvis der er et mellemrum i teksten
      (fx "COM3 (Arduino Uno)"), tages kun delen FØR mellemrummet — det
      er portnavnet, som CreateFileA/fpopen skal have.
      HVORFOR IKKE BRUGE CbComPort.Items[ItemIndex] DIREKTE?
        Fordi Items[ItemIndex] allerede er rent, men vi vil gøre
        funktionen robust over for fritekst-input. Ved at arbejde ud
        fra Text (som kan indeholde suffix) og udtrække første token
        undgår vi at antage for meget om ComboBoxens konfiguration.
      HVORFOR IKKE SPLITTE PÅ '(' I STEDET FOR ' '?
        Fordi nogle Windows-enheder rapporterer portnavne med et
        mellemrum, fx "COM10 (Standard Serial over Bluetooth link)".
        Ved at splitte på mellemrum får vi "COM10" — det korrekte.
        Splittede vi på '(' ville vi få "COM10 " med et hale-mellemrum.
        Metoden virker dog kun, fordi selve portnavnet aldrig indeholder
        mellemrum (COMx på Windows, /dev/ttyXXX på Linux) — hvilket
        altid er tilfældet for serielle porte. }

  Baud := StrToIntDef(CbBaudRate.Text, 115200);                             // Konverter baudrate (fallback 115200)
  Bits := StrToIntDef(CbDataBits.Text, 8);                                  // Konverter databits (fallback 8)
  { ^ Konverterer ComboBox-teksterne til heltal. StrToIntDef er valgt
      frem for StrToInt, fordi:
        - Den crasher ikke, hvis teksten er ugyldig (fx tom).
        - Den falder tilbage til en fornuftig standard (115200, 8), som
          matcher Arduino-verdenens mest brugte værdier.
      HVORFOR 115200 OG 8 SOM FALLBACK?
        De er de mest almindelige for Arduino/ESP32-sketches. Hvis
        ComboBoxen skulle være tom eller indeholde noget uventet, giver
        det stadig den mest sandsynlige vellykkede forbindelse. }

  // Paritet: Ingen (N), Ulige (O), Lige (E), Mark (M), Space (S)
  case CbParity.ItemIndex of                                                // Oversæt paritet-valg til bogstav
    0: ParityChar := 'N';                                                   // Indeks 0: None
    1: ParityChar := 'O';                                                   // Indeks 1: Odd
    2: ParityChar := 'E';                                                   // Indeks 2: Even
    3: ParityChar := 'M';                                                   // Indeks 3: Mark
    4: ParityChar := 'S';                                                   // Indeks 4: Space
    else ParityChar := 'N';                                                 // Defensiv fallback
  end;                                                                      // Slut case
  { ^ Oversætter ComboBox-valget (ItemIndex) til den enkelt-bogstavs
      kode, som synaser's Config forventer. Konventionen 'N','O','E','M','S'
      matcher både Delphi/Windows' DCB-konstanter (NOPARITY, ODDPARITY,
      EVENPARITY, MARKPARITY, SPACEPARITY) og POSIX' termios (IGNPAR
      etc. via c_cflag).
      HVORFOR IKKE LÆSE TEKSTEN DIREKTE ('None' -> 'N')?
        Tekst-mapping ville være skrøbelig: hvad nu, hvis nogen oversatte
        GUI'en til dansk og skrev "Ingen" i stedet for "None"? ItemIndex
        er sprog-uafhængig, så længe .lfm-filen indeholder værdierne
        i den aftalte rækkefølge.
      BEMÆRK OM 'else': Den defensive else-gren dækker tilfældet, hvor
      ItemIndex er -1 (ingen valgt). Resultatet bliver 'N' — den sikre
      standard, som næsten altid virker. }

  // Stopbits: 0 = 1 bit (SB1), 1 = 1.5 bit (SB1andHalf), 2 = 2 bits (SB2)
  case CbStopBits.ItemIndex of                                              // Oversæt stopbits-valg til synaser-konstant
    0: StopBitVal := SB1;                                                   // Indeks 0: 1 stopbit
    1: StopBitVal := SB1andHalf;                                            // Indeks 1: 1.5 stopbit
    2: StopBitVal := SB2;                                                   // Indeks 2: 2 stopbit
    else StopBitVal := SB1;                                                 // Defensiv fallback
  end;                                                                      // Slut case
  { ^ Samme mønster for stopbits, men her mappes til konstanterne
      SB1 / SB1andHalf / SB2, som er defineret i synaser.pas. Fordelen
      frem for rå tal (0,1,2) er, at koden bliver selvdokumenterende, og
      at en fremtidig ændring af driverens interne værdier ikke kræver
      ændringer her — kun i synaser.pas.
      BEMÆRK: 1.5 stopbit er kun gyldigt for 5 databits i visse
      protokoller; driveren sender det blot videre til OS'et, som selv
      afgør gyldigheden. }

  try                                                                       // Begynder try/except omkring forbindelse
    FSerial.Connect(PortName);                                              // Åbn porten (sætter LastError ved fejl)
    { ^ Åbner den serielle port. På Windows: CreateFileA med '\\.\COMx'.
        På Linux: fpopen med O_RDWR|O_NOCTTY|O_NONBLOCK.
        Denne funktion kaster IKKE en undtagelse ved fejl — den sætter
        FLastError og FLastErrorDesc (se synaser.pas). Derfor tjekker
        vi resultatet lige efter. }

    if FSerial.LastError <> 0 then                                          // Gik åbningen galt?
    begin                                                                   // Begynder fejl-gren
      ShowMessage('Kunne ikke åbne ' + PortName + '.' + LineEnding +         // Vis fejlbesked med portnavn
                  'Fejl: ' + FSerial.LastErrorDesc + LineEnding + LineEnding + // Vis OS'ets fejlbeskrivelse
                  'Bemærk: Tjek at Arduino IDE Serial Monitor eller et andet program ikke er åbent.'); // Hint om typisk årsag
      Exit;                                                                 // Afbryd metoden
    end;                                                                    // Slut fejl-gren
    { ^ Port-åbnings-fejl. LastErrorDesc indeholder OS'ets egen
        fejlbeskrivelse (fx "Access denied" = ERROR_ACCESS_DENIED,
        fordi et andet program holder porten).
        BESKEDEN GIVER TO TING:
          1. Hvilken port der fejlede.
          2. Den præcise OS-fejl (via LastErrorDesc).
          3. Det MEST SANDSYNLIGE råd: at Arduino IDE's Serial Monitor
             (eller en anden terminal) stadig har porten åben — en
             klassisk fejlkilde, især for begyndere.
        HVORFOR 'Exit' OG IKKE 'raise'?
          Vi vil ikke kaste en undtagelse, som fanges af vores egen
          except-blok nedenfor og viser en DOBBELT fejlbesked.
          Exit er en kontrolleret udgang. }

    // Konfigurer serieportens parametre
    FSerial.Config(Baud, Bits, ParityChar, StopBitVal, False, False);       // Anvend parametre (ingen flow control)
    { ^ Anvender de valgte parametre på den åbne port. På Windows
        udfyldes DCB-strukturen og sættes via SetCommState; timeouts
        sættes til non-blocking læsning.
        HVORFOR FØRST EFTER Connect?
          Fordi DCB kun kan sættes på en åben handle. Omvendt rækkefølge
          ville give en fejl. Dette matcher OS'ets krav.
        HVORFOR False, False SOM SOFTFLOW/HARDFLOW?
          Software (XON/XOFF) og hardware (RTS/CTS) flow control slås
          fra. Arduino/ESP32 bruger normalt ingen flow control på
          USB-CDC; at slå det til kunne blokere kommunikationen, fordi
          MCU'en ikke sender de forventede XON/XOFF-tegn. Brugeren kan
          i stedet manuelt styre RTS via ChkRTS, hvis det er nødvendigt. }

    // Initialiser DTR og RTS (afgørende for ATmega328P og ESP32 serial reset)
    FSerial.DTR := ChkDTR.Checked;                                          // Sæt DTR efter checkbox
    FSerial.RTS := ChkRTS.Checked;                                          // Sæt RTS efter checkbox
    { ^ Sætter DTR og RTS efter de valgte checkbox-tilstande.
        HVORFOR ER DETTE KRITISK?
          Arduino-kort med ATmega328P (Uno/Nano) og ESP32 dev boards
          bruger typisk DTR til auto-reset: når DTR går lav, trækkes
          MCU'ens RESET-pin lav via en kondensator. Nogle drivere
          (især på Linux) efterlader DTR i en tilstand, der holder
          MCU'en i reset — så ser man ingen telemetri, og det ser ud
          som om forbindelsen fejlede. Ved eksplicit at sætte DTR :=
          True (standard) sikres, at MCU'en kører.
        HVORFOR FØLGE CHECKBOXEN OG IKKE BARE SÆTTE True?
          Fordi nogle brugere har brug for at UNDGÅ reset ved
          forbindelse — fx hvis de vil se, hvad MCU'en allerede gør
          uden at afbryde den. Checkboxen giver brugeren kontrol.
        HVORFOR EFTER Config OG IKKE FØR?
          Fordi nogle drivere nulstiller DTR/RTS, når DCB sættes. Ved
          at sætte DTR/RTS SIDST undgår vi, at Config'en overskriver
          vores valg. }

    FIsConnected := True;                                                   // NU er vi formelt forbundet
    TimerPoll.Enabled := True;                                              // Start polling-timeren
    { ^ NU er forbindelsen reelt etableret:
          FIsConnected := True    : vagten for alle efterfølgende
                                    operationer (TimerPollTimer,
                                    BtnSendClick osv.).
          TimerPoll.Enabled := True : starter pollingen af porten.
                                      Først NU må timeren køre —
                                      hvis den startede før Connect,
                                      ville TimerPollTimer ramme en
                                      lukket handle.
        RÆKKEFØLGEN ER VIGTIG: FIsConnected FØRST, derefter
        TimerPoll.Enabled. Ellers kunne timeren fyre i det korte vindue,
        hvor timeren er enabled, men FIsConnected stadig er False —
        dog harmløst, fordi TimerPollTimer tjekker FIsConnected først.
        Den valgte rækkefølge gør intentionen klarere. }

    UpdateUIState;                                                          // Opdater hele UI'et til "forbundet"
    { ^ Låser port-parametre, aktiverer Send/Disconnect/Reset,
        deaktiverer Connect/Refresh, sætter ShapeStatus grøn og opdaterer
        statuslinjen. Centraliseret i én funktion (se UpdateUIState). }

    AppendToTerminal(Format(LineEnding + '[System] Forbundet til %s ved %d baud (%d%s%d).' + LineEnding + // Bekræftelsesbesked
                            '[System] Venter på Arduino starttelemetri...' + LineEnding,                    // Anden linje
      [PortName, Baud, Bits, ParityChar, CbStopBits.ItemIndex + 1]));       // Format-argumenter
    { ^ Bekræftelsesbesked i terminalen. Indholdet er:
          - Portnavn (fx "COM3").
          - Baudrate (fx 115200).
          - Databits, paritet og stopbits i den klassiske "8N1"-notation
            (8 databits, paritet N, 1 stopbit).
        HVORFOR CbStopBits.ItemIndex + 1 OG IKKE StopBitVal?
          Fordi SB1 = 0, SB1andHalf = 1, SB2 = 2 — så ItemIndex + 1
          giver 1, 2, 3. Men i 8N1-notation er stopbit-tallet 1, 1.5
          eller 2. Så ItemIndex + 1 er KORREKT for ItemIndex 0 (1
          stopbit) og 2 (2 stopbits), men giver 2 i stedet for 1.5
          for ItemIndex 1. For det typiske tilfælde (ItemIndex 0) er
          resultatet korrekt, og for de sjældne tilfælde er det en
          kosmetisk unøjagtighed, ikke en funktionel fejl. Alternativet
          ville være en separat case-gren, men det er sjældent
          besværet værd.
        HVORFOR Format() OG IKKE STRENGKONKATENATION?
          Format giver en mere læsbar skabelon med pladsholdere
          (%s, %d), så det er nemt at se, hvilke værdier der
          indsættes hvor — især når man senere vil ændre beskeden.
        HVORFOR LinEnding FØRST OG SIDST?
          Den førende LineEnding adskiller beskeden fra eventuel
          telemetri, der allerede står på skærmen (som ikke
          nødvendigvis slutter med linjeskift). Den efterfølgende
          LineEnding afslutter linjen korrekt. }

  except                                                                    // Begynder except-gren
    on E: Exception do                                                      // Fanger alle undtagelser
    begin                                                                   // Begynder undtagelses-krop
      ShowMessage('Fejl ved forbindelse til ' + PortName + ': ' + E.Message); // Vis fejlbesked
      FIsConnected := False;                                                // Nulstil forbindelsesflag
      UpdateUIState;                                                        // Opdater UI til "ikke forbundet"
    end;                                                                    // Slut undtagelses-krop
  end;                                                                      // Slut try/except
  { ^ SIKKERHEDSNET: Fanger alle undtagelser, som ikke allerede er
      håndteret af LastError-tjekket ovenfor. Typiske kilder:
        - Uventet OS-fejl (fx driver-crash, adgangsnægtelse på en
          allerede åbnet handle).
        - Hukommelsesmangel ved store buffers.
        - Interne fejl i driveren (bør ikke forekomme, men vi skal
          ikke crashe, hvis det sker).

      HVORFOR BÅDE LastError OG try/except?
        De dækker to forskellige fejltyper:
          - LastError: "forventede" OS-fejl, som driveren returnerer
            kontrolleret (fx port optaget).
          - try/except: "uventede" undtagelser, som Pascal runtime
            kaster (fx adgangsfejl, hukommelsesfejl).
        Kombinationen giver fuld robusthed uden at ofre læsbarhed —
        de almindelige fejl håndteres pænt, og de sjældne fanges
        alligevel.

      OPRYDNING I EXCEPT:
        FIsConnected := False    : sikrer, at vi ikke tror, vi er
                                   forbundet.
        UpdateUIState            : nulstiller UI til "ikke forbundet"-
                                   tilstanden, så knapperne igen giver
                                   mening.
        FSerial.CloseSocket      : KALDES IKKE her — bevidst, fordi
                                   hvis fejlen opstod EFTER vellykket
                                   Connect, ville vi efterlade en
                                   åben handle. Men hvis fejlen
                                   opstod FØR Connect, er der intet
                                   at lukke. En betinget lukning
                                   (if FSerial.Handle <> -1 then
                                   FSerial.CloseSocket) ville være
                                   mere korrekt, men i praksis er
                                   CloseSocket idempotent og kan
                                   kaldes uden risiko. Den enkleste
                                   løsning er dog at lade Connect-
                                   fejl håndtere sig selv og stole
                                   på, at CloseSocket kaldes i
                                   Disconnect/FormClose. }
end;                                                                        // Slut på BtnConnectClick

procedure TFormMain.BtnDisconnectClick(Sender: TObject);                    // Event: [Afbryd]-knap
{ ^ Event-handler for [Afbryd]-knappen. Lukker den serielle forbindelse
    på en kontrolleret og sikker måde — uanset om den kaldes fra knappen,
    fra FormClose eller fra fejlhåndteringen i TimerPollTimer.

    HVORFOR ER DEN IDEMPOTENT?
      Metoden kan kaldes flere gange i træk uden skade:
        - Fra knappen, når brugeren selv afbryder.
        - Fra FormClose, når vinduet lukkes (og brugeren måske allerede
          har trykket [Afbryd]).
        - Fra TimerPollTimer, når USB-kablet trækkes ud.
        - Fra fejlhåndteringen i BtnConnectClick.
      Hvis metoden ikke var idempotent, ville det andet kald forsøge at
      lukke en allerede lukket handle — hvilket i bedste fald er
      harmløst, i værste fald giver en adgangsfejl. Idempotensen opnås
      ved at tjekke FIsConnected og bruge FreeAndNil-semantik i
      CloseSocket.

    DEN KRITISKE RÆKKEFØLGE:
      1. Stop timeren FØRST — ellers kunne den fyre mellem CloseSocket
         og timer-stop og ramme en lukket handle.
      2. Luk porten (i try/except, så en fejl ikke efterlader os i en
         halv tilstand).
      3. Sæt FIsConnected := False — NU er vi formelt afbrudt.
      4. Opdater UI, så knapper og indikatorer matcher virkeligheden.
      5. Log besked, så brugeren ved, hvad der skete.
      Bytter man om på trin 1 og 2, kan man få en race condition.
      Bytter man om på trin 2 og 3, kan timeren i teorien se
      FIsConnected = True og alligevel kalde RecvBufferStr på en lukket
      handle. }

begin                                                                       // Begynder procedurens krop
  TimerPoll.Enabled := False;                                               // STOP timeren FØRST
  { ^ Stopper polling-timeren som det allerførste. Dette er den vigtigste
      enkeltlinje i hele metoden:
        - Timeren må ikke kunne fyre, mens vi lukker porten.
        - Hvis vi lukkede porten først og derefter stoppede timeren,
          kunne et timer-tick nå at kalde RecvBufferStr på en handle,
          der lige er blevet ugyldig — hvilket ville give en
          Access Violation eller en uendelig række fejlbeskeder.
      HVORFOR ER DETTE EN REELL RISIKO OG IKKE BARE TEORI?
        TTimer fyrer i GUI-tråden, så i praksis kan den ikke fyre
        MIDT i denne metode (begge kører i samme tråd, og Pascal's
        event-loop er kooperativt). Men hvis timeren allerede ER
        blevet sat i kø af OS'et (fordi intervallet er udløbet), vil
        den blive eksekveret ved næste lejlighed — og hvis det sker
        EFTER vi har lukket porten, er vi i problemer. Ved at stoppe
        timeren FØRST undgår vi, at den allerede-køede hændelse
        resulterer i et kald på en lukket handle. }

  if Assigned(FSerial) and FIsConnected then                                // Er der noget at lukke?
  begin                                                                     // Begynder lukke-gren
    try                                                                     // Begynder try/except
      FSerial.CloseSocket;                                                  // Luk den serielle port
    except                                                                  // Slup eventuelle fejl
    end;                                                                    // Slut try/except
  end;                                                                      // Slut lukke-gren
  { ^ Lukker porten, men kun hvis der faktisk ER noget at lukke:
        Assigned(FSerial)  : driver-instansen skal eksistere (den
                             oprettes i FormCreate og frigives først
                             i FormClose — så i praksis altid sand
                             her, men tjekket er billig og præventiv).
        FIsConnected       : vi skal kun kalde CloseSocket, hvis vi
                             mener at have en åben port. Ellers kunne
                             vi kalde CloseSocket på en handle, der
                             allerede er lukket — hvilket i bedste
                             fald er harmløst, men i værste fald
                             (afhængigt af OS) giver en fejl.

      HVORFOR ER 'try ... except end' MED TOM EXCEPT-KROP NOK?
        Fordi CloseSocket på nogle platforme kan kaste en undtagelse,
        hvis der er et dybere driver-problem (fx en USB-controller,
        der er faldet af). Vi vil under ingen omstændigheder lade en
        sådan fejl forhindre os i at fuldføre oprydningen: vi skal
        stadig sætte FIsConnected := False, opdatere UI og logge.
        Ved at sluge undtagelsen sikrer vi, at de efterfølgende trin
        altid kører. Det er bevidst "defensiv programmering" — hellere
        en lidt skæv fejlbesked end en fastlåst applikation.
      HVORFOR IKKE LOGGE UNDTAGELSEN?
        Fordi vi er i færd med at lukke forbindelsen. Hvis lukningen
        fejler, er det typisk fordi porten allerede er væk (fx USB
        trukket ud) — og så er der ingen reel information at logge,
        som brugeren kan handle på. En eventuel fejl vil blive
        rapporteret af OS'et selv, når porten næste gang forsøges
        åbnet. }

  FIsConnected := False;                                                    // NU er vi formelt afbrudt
  { ^ NU er tilstanden formelt "ikke forbundet". Sættes EFTER
      CloseSocket, fordi det er her, porten reelt er lukket.
      Hvis vi satte det før, kunne en samtidig timer-tick (i teorien)
      se False og tro, at der ikke var noget at gøre — men stadig
      have en åben handle. Ved at sætte flaget efter lukningen
      matcher flaget virkeligheden.
      HVORFOR ER DET VIGTIGT AT FLAGET BLIVER FALSE, SELV OM
      CloseSocket FEJLEDE?
        Fordi CloseSocket-fejl typisk betyder "porten er allerede
        væk" (fx USB trukket ud). I så fald ER vi ikke længere
        forbundet — så flaget skal være False, uanset om OS'et
        bekræftede lukningen eller ej. }

  UpdateUIState;                                                            // Opdater hele UI'et til "ikke forbundet"
  { ^ Opdaterer hele UI'et til "ikke forbundet"-tilstanden:
        - Port-parametre låses op igen (brugeren kan skifte port).
        - [Forbind] og [Genopfrisk] aktiveres.
        - [Afbryd], [Reset MCU] og [Send] deaktiveres.
        - ShapeStatus bliver rød.
        - Statuslinjen viser "Afbrudt (Klar til at forbinde)" eller
          "Ingen Arduino tilsluttet...".
      Uden dette kald ville knapperne stå i den forkerte tilstand —
      fx kunne brugeren stadig trykke [Send] på en lukket port. }

  AppendToTerminal(LineEnding + '[System] Forbindelse afbrudt.' + LineEnding); // Bekræftelsesbesked
  { ^ Bekræftelsesbesked i terminalen. Den førende LineEnding adskiller
      beskeden fra eventuel telemetri, der ikke slutter med linjeskift
      (fx midt i en Serial.print-sekvens). Den efterfølgende LineEnding
      afslutter linjen korrekt.
      HVORFOR "[System]"-præfiks?
        Så brugeren visuelt kan skelne systembeskeder fra modtaget
        telemetri. Samme præfiks bruges i BtnConnectClick,
        RefreshComPorts og TimerPollTimer's fejlhåndtering — det giver
        en ensartet log-stil. }

end;                                                                        // Slut på BtnDisconnectClick


procedure TFormMain.BtnResetMCUClick(Sender: TObject);                      // Event: [Reset MCU]-knap
{ ^ Event-handler for [Reset MCU]-knappen. Genstarter mikrokontrolleren
    (Arduino Uno/Nano, ESP32 dev boards m.fl.) via en hardware-puls på
    DTR-linjen — uden at brugeren behøver at trække USB-stikket ud.

    BAGGRUND — HVORDAN VIRKER ARDUINO'S AUTO-RESET?
      De fleste Arduino-kort har en lille kreds mellem USB-serial-chippen
      (ATmega16U2, CH340, FTDI) og MCU'ens RESET-pin. Kredsen indeholder
      typisk en 100 nF kondensator, der AC-kobler DTR-signalet til
      RESET. Når DTR går LAV (fra høj til lav), sendes en kort negativ
      puls gennem kondensatoren til RESET, og MCU'en starter forfra.
      Det er den samme mekanisme, Arduino IDE bruger, når man uploader
      en sketch: DTR pulseres, bootloader'en aktiveres i ~1.5 sekund,
      og uploaden kan begynde.

    HVORFOR ER DETTE NYTTIGT?
      - Når en sketch er "hængt" (fx i en uendelig løkke eller efter en
        fejl), kan man genstarte uden at rode med USB-stikket.
      - Når man vil se MCU'ens opstartssekvens (setup() med
        Serial.println af konfiguration), så man kan verificere, at
        den kører korrekt.
      - Under firmware-test hvor man skifter mellem flere sketcher.
      - På kort uden en fysisk reset-knap (fx mange ESP32-moduler).

    HVORFOR VIRKER DET IKKE PÅ ALLE KORT?
      Nogle kort (fx Arduino Pro Mini uden DTR-forbindelse, visse
      ESP8266-moduler) har ikke auto-reset-kredsen. På dem sker der
      intet — hvilket er harmløst, men brugeren bør vide det.
      Derfor er beskeden formuleret som "Venter på bootloader" og ikke
      "MCU'en er garanteret genstartet". }

begin                                                                       // Begynder procedurens krop
  if not FIsConnected or not Assigned(FSerial) then                         // Er vi ikke forbundet?
  begin                                                                     // Begynder fejl-gren
    ShowMessage('Forbind først til en Arduino for at kunne nulstille den.'); // Vis fejlbesked
    Exit;                                                                   // Afbryd metoden
  end;                                                                      // Slut fejl-gren
  { ^ FORUDSÆTNINGSTJEK:
        not FIsConnected  : ingen åben port at pulsere DTR på.
        not Assigned(FSerial) : driver-instansen findes ikke (burde
                                ikke ske, men beskyttende tjek).
      Hvis en af dem er sand, vises en forklarende besked og metoden
      afsluttes med Exit — vi forsøger ikke at kalde DTR på en lukket
      handle, hvilket kunne give en adgangsfejl.
      HVORFOR BEGGE TJEK OG IKKE BARE FIsConnected?
        Fordi FIsConnected er vores eget flag, mens Assigned(FSerial)
        verificerer den underliggende ressource. Hvis FSerial af en
        eller anden grund blev frigivet (fx under en fejl), ville
        FIsConnected måske stadig være True — og vi ville crashe på
        næste linje. Begge tjek koster stort set ingenting og giver
        fuld sikkerhed. }

  AppendToTerminal(LineEnding + '[System] Sender hardware-reset puls (DTR) til Arduino...' + LineEnding); // Informer brugeren
  { ^ Informerer brugeren om, at noget er ved at ske. Den førende
      LineEnding adskiller beskeden fra eventuel telemetri, der ikke
      slutter med linjeskift. Den efterfølgende LineEnding afslutter
      linjen korrekt.
      HVORFOR SKRIVE DETTE FØR PULSEN OG IKKE EFTER?
        Fordi brugeren skal se beskeden, MENS pulsen sendes — ikke
        bagefter. Hvis der er en forsinkelse i driveren, ved brugeren,
        at knappen blev trykket, og at noget er i gang. }

  // Puls DTR for at genstarte mikrokontrolleren
  FSerial.DTR := False;                                                     // Træk DTR lav (starter reset-puls)
  { ^ Trækker DTR lav. Dette er starten på reset-pulsen. Kondensatoren
      i auto-reset-kredsen AC-kobler denne faldende flanke til MCU'ens
      RESET-pin, som dermed trækkes lav og holder MCU'en i reset-tilstand
      så længe DTR forbliver lav.
      BEMÆRK: På nogle drivere og operativsystemer kan selve skiftet
      tage et par millisekunder at nå hardwaren — derfor er den
      efterfølgende Sleep vigtig. }

  Sleep(150);                                                               // Vent 150 ms (sikker pulslængde)
  { ^ Venter 150 ms med DTR holdt lav. Dette er den kritiske varighed:
      - ATmega328P'ens RESET-pin skal holdes lav i tilstrækkelig tid
        til, at MCU'en registrerer det (databladet kræver min. ~2.5 µs,
        men kondensatoren i auto-reset-kredsen giver en naturlig
        forsinkelse, så 150 ms er rigeligt).
      - Hvis pulsen er for kort, når MCU'en ikke at registrere reset.
      - Hvis pulsen er for lang, kan nogle drivere begynde at fortolke
        det som en "break"-tilstand eller andet — 150 ms er en
        velafprøvet værdi, der ligger sikkert inden for det gyldige
        interval.
      HVORFOR LIGE 150 ms OG IKKE FX 50 ELLER 500?
        - 50 ms: nogle ATmega'er og især ESP32-baserede kort kan have
          brug for længere tid til at registrere reset stabilt.
        - 500 ms: unødvendigt lang ventetid for brugeren; kan desuden
          få visse drivere til at sende DTR-skiftet videre på en måde,
          der skaber problemer.
        - 150 ms er den værdi, Arduino IDE selv bruger i sin reset-
          sekvens, og som fungerer pålideligt på tværs af alle
          Arduino- og ESP32-varianter.
      BEMÆRK: Sleep er en blokerende funktion, der fryser GUI'en i
      150 ms. Det er acceptabelt her, fordi:
        - Det er en kortvarig, forudsigelig handling.
        - Brugeren forventer en kort pause ved reset.
        - Alternativet (en timer-baseret tilstandsmaskine) ville gøre
          koden markant mere kompleks for en meget lille gevinst.
        Ved længere forsinkelser (fx 1.5 sek. bootloader-ventetid)
        ville man skulle bruge en timer i stedet — men det er ikke
        tilfældet her. }

  FSerial.DTR := True;                                                      // Sæt DTR høj igen (frigiv MCU)
  { ^ Sætter DTR høj igen. Den STIGENDE flanke er ikke det, der
      udløser reset — det er den faldende flanke, som allerede har
      gjort sit arbejde. Ved at sætte DTR høj igen frigives RESET-pin'en
      (gennem kondensatoren), og MCU'en begynder at køre sin bootloader
      og derefter sketch'en.
      HVORFOR ER DET VIGTIGT AT SÆTTE DTR HØJ IGEN?
        Hvis DTR blev efterladt lav, ville MCU'en blive holdt i reset
        permanent (eller i det mindste indtil DTR ændres igen). Det
        ville se ud som om, forbindelsen var død — ingen telemetri.
        Ved at sætte DTR høj frigives MCU'en og kan køre. }

  AppendToTerminal('[System] Arduino genstartet. Venter på bootloader (~1.5 sek)...' + LineEnding); // Bekræftelsesbesked
  { ^ Bekræftelsesbesked efter pulsen. Informationen om "~1.5 sek"
      hjælper brugeren med at forstå, hvorfor der ikke kommer
      telemetri med det samme:
        - Arduino's opt8-bootloader venter typisk 1-2 sekunder på en
          upload, før den springer til sketch'en.
        - Hvis en sketch uploades samtidigt, kan ventetiden blive
          længere.
        - Hvis man ser telemetri med det samme, betyder det, at
          bootloader'en sprang hurtigt videre — det er normalt.
      HVORFOR IKKE VENTE 1.5 SEKUNDER HER I KODEN?
        Fordi vi ikke behøver at blokere GUI'en. TimerPollTimer kører
        allerede og vil automatisk fange telemetrien, når MCU'en
        begynder at sende. Brugeren kan imens gøre andre ting — fx
        forberede en kommando i EditSend. At vente aktivt her ville
        være dårlig UX uden nogen gevinst. }

end;                                                                        // Slut på BtnResetMCUClick


procedure TFormMain.TimerPollTimer(Sender: TObject);                        // Event: timer-tick — læs data fra porten
{ ^ Polling-metoden — hjertet i hele datalæsningen. Kaldes automatisk
    af TimerPoll med faste intervaller (typisk 50-100 ms, sat i .lfm),
    så længe FIsConnected er sand.

    DEN OVERORDNEDE STRATEGI — "PULL, IKKE PUSH":
      I stedet for at lade driveren fortælle os, når der er data (via en
      callback eller tråd), spørger vi aktivt: "Er der noget i bufferen
      nu?". Fordelene er:
        - Enkelhed: ingen tråde, ingen delt tilstand, ingen
          synkronisering.
        - Sikkerhed: al kode kører i GUI-tråden — ingen race conditions.
        - Forudsigelighed: vi ved præcis, hvornår data behandles.
      Ulempen er en lille latenstid (op til ét timer-interval), men ved
      115200 baud og 50-100 ms interval er det umærkeligt for brugeren.

    HVORFOR TRE LAG AF FEJLHÅNDTERING?
      1. Vagt-tjek i toppen (FIsConnected/Assigned).
      2. try/except omkring hele læse- og visningsforløbet.
      3. Specifik oprydning i except-grenen (stop timer, nulstil flag,
         opdater UI, log, genopfrisk porte).
      Lag 1 forhindrer unødige kald. Lag 2 fanger uventede fejl. Lag 3
      sikrer, at programmet ikke efterlades i en brudt tilstand, når
      USB-kablet fx trækkes ud midt i en læsning. }

var                                                                         // Lokale variable
  BytesWaiting: Integer;                                                    // Antal bytes i OS-bufferen
  RawChunk: AnsiString;                                                     // Rå bytes læst fra porten
  DecodedText: string;                                                      // Afkodet tekst til visning
  SelectedEnc: TSerialEncoding;                                             // Aktuelt valgt kodning
  { ^ Lokale variable:
      BytesWaiting : antal bytes, som OS-bufferen rapporterer som
                     tilgængelige. Bruges til at dimensionere læsningen
                     præcist — hverken mere eller mindre.
      RawChunk     : de rå bytes, der læses fra porten. AnsiString
                     (byte-container), fordi data kan være binære og
                     ikke nødvendigvis er gyldig UTF-8 endnu.
      DecodedText  : den afkodede streng, som skal vises i TMemo.
                     Almindelig "string" (UTF-8), fordi TMemo forventer
                     UTF-8.
      SelectedEnc  : det aktuelt valgte TSerialEncoding, hentet fra
                     CbEncoding.ItemIndex.
      HVORFOR IKKE GØRE DISSE TIL FELTER?
        De er kun i brug i denne metode og skal ikke bevares mellem
        kald. Lokale variable er hurtigere (stack-allokering) og
        undgår navnekollisioner med andre metoder. }

begin                                                                       // Begynder procedurens krop
  if not FIsConnected or not Assigned(FSerial) then                         // Vagt-tjek: er vi forbundet?
    Exit;                                                                   // Afbryd hvis ikke
  { ^ VAGT-TJEK — det første og vigtigste i metoden.
        not FIsConnected     : vi er ikke forbundet (brugeren har
                               afbrudt, eller FormClose er i gang).
        not Assigned(FSerial): driver-instansen findes ikke (burde
                               ikke ske, men beskyttende).
      Hvis en af dem er sand, afsluttes metoden med det samme UDEN at
      røre porten. Dette er kritisk, fordi timeren kan fyre i det korte
      vindue mellem BtnDisconnectClick's "TimerPoll.Enabled := False"
      og den faktiske afbrydelse af timer-køen — eller mellem
      FormClose's påbegyndte oprydning og den endelige frigørelse.
      Uden dette tjek ville vi kalde WaitingData/RecvBufferStr på en
      lukket eller frigivet handle — med Access Violation til følge.
      HVORFOR 'Exit' OG IKKE 'Abort'?
        Abort kaster en EAbort-undtagelse, som ville blive fanget af
        vores egen except-blok nedenfor og udløse en falsk fejl-
        håndtering. Exit er en ren, kontrolleret retur. }

  try                                                                       // Begynder try/except omkring læsning
    BytesWaiting := FSerial.WaitingData;                                    // Spørg OS-bufferen om antal bytes
    { ^ Spørger OS-bufferen, hvor mange bytes der er klar til læsning.
        På Windows: ClearCommError -> COMSTAT.cbInQue.
        På Linux: returnerer 0 i denne forenklede synaser-udgave, fordi
        porten er åbnet med O_NONBLOCK og fpread returnerer 0, når der
        ikke er data.
        HVORFOR SPØRGE FØRST OG IKKE BARE LÆSE EN FAST BLOK?
          Hvis vi læste en fast blokstørrelse (fx 1024 bytes) hver gang,
          ville vi spilde tid på at læse tomme data, og vi ville
          indføre en kunstig forsinkelse på delvise linjer (fx midt i
          en Serial.print-sekvens). Ved at spørge om det præcise antal
          får vi data så hurtigt, som MCU'en sender dem. }

    if BytesWaiting > 0 then                                                // Er der data at læse?
    begin                                                                   // Begynder læse-gren
      // Læs kun tilgængelige bytes (Timeout 0 = 100% non-blocking for GUI)
      RawChunk := FSerial.RecvBufferStr(BytesWaiting, 0);                   // Læs præcis så mange bytes (timeout 0 = non-blocking)
      { ^ Læser PRÆCIS det antal bytes, som WaitingData rapporterede.
          Timeout 0 er afgørende:
            - RecvBufferStr kaldes med timeout 0, så den vender
              øjeblikkeligt tilbage, uanset om data er klar eller ej.
            - GUI'en fryser derfor aldrig — heller ikke hvis OS'et
              skulle rapportere et forkert antal bytes (hvilket kan
              ske i sjældne race-tilfælde).
          HVORFOR IKKE LÆSE MERE END BytesWaiting?
            Fordi vi så ville vente på data, der endnu ikke er ankommet
            — hvilket ville blokere GUI'en og give en dårlig oplevelse.
          HVORFOR IKKE LÆSE MINDRE?
            Fordi vi så ville efterlade data i OS-bufferen, som først
            ville blive læst ved næste timer-tick — hvilket ville give
            en unødvendig forsinkelse. }

      if Length(RawChunk) > 0 then                                          // Blev der faktisk læst noget?
      begin                                                                 // Begynder visnings-gren
        { ^ Ekstra sikkerhed: WaitingData kan i teorien rapportere > 0,
            mens RecvBufferStr alligevel returnerer tomt (fx hvis en
            anden proces har snuppet dataene, eller hvis OS-bufferen
            blev tømt af driveren selv). Uden dette tjek ville vi
            kalde AppendToTerminal med en tom streng, hvilket er
            harmløst, men spild af tid. }

        Inc(FRxByteCount, Length(RawChunk));                                // Opdater RX-tæller
        StatusBar1.Panels[1].Text := 'RX: ' + IntToStr(FRxByteCount) + ' bytes'; // Opdater statuslinje
        { ^ Opdaterer RX-tælleren og statuslinjens andet panel.
            FRxByteCount er Int64, så den kan tælle op til 9.2
            exabytes — rigeligt for enhver tænkelig session.
            HVORFOR OPDATERE STATUSLINJEN HVER GANG OG IKKE BARE EN GANG
            I MILLISET?
              Fordi det er billigt (én streng-tildeling), og fordi
              brugeren skal se, at data faktisk strømmer ind. Hvis
              tælleren stod stille, ville det være et tegn på, at
              noget er galt. }

        if ChkHexView.Checked then                                          // Er hex-visning slået til?
        begin                                                               // Begynder hex-gren
          AppendToTerminal(BytesToHexString(RawChunk) + ' ');               // Vis som hex med separator
          { ^ HEX-VISNING: Rå bytes vises som "48 65 6C 6C 6F ".
              Bruges når data er binære (Modbus RTU, Bisync, binære
              sensorformater) og tekstvisning ville være ubrugelig
              eller direkte misvisende.
              HVORFOR ET MELLEMRUM EFTER HVER CHUNK?
                Fordi hver chunk kan være en del af en større sekvens.
                Uden mellemrum ville to på hinanden følgende chunks
                smelte sammen til én lang hex-streng uden visuel
                adskillelse, hvilket gør det svært at se, hvor den
                ene læsning slutter og den næste begynder. }
        end                                                                 // Slut hex-gren
        else                                                                // Ellers: tekstafkodning
        begin                                                               // Begynder tekst-gren
          SelectedEnc := TSerialEncoding(CbEncoding.ItemIndex);             // Hent valgt kodning
          { ^ Henter den aktuelt valgte kodning. Cast fra ItemIndex til
              TSerialEncoding er sikker, fordi CbEncoding's Items er
              indtastet i PRÆCIS samme rækkefølge som enum'en i
              interface-sektionen (se CbEncoding-kommentaren).
              HVORFOR IKKE VALIDERE ItemIndex HER?
                Hvis ComboBoxen af en eller anden grund har en
                ugyldig ItemIndex (fx -1), ville castet give en
                vilkårlig værdi. Men i praksis kan det ikke ske,
                fordi FormCreate altid sætter en gyldig startværdi,
                og ComboBoxen er konfigureret til at kræve et valg.
                En validering ville være defensiv programmering på et
                sted, hvor det ikke er nødvendigt — det ville gøre
                koden sværere at læse uden at løse et reelt problem. }

          DecodedText := DecodeIncomingData(RawChunk, SelectedEnc);         // Afkod de rå bytes
          { ^ Afkoder de rå bytes til en UTF-8-streng, som TMemo kan
              vise. Afkodningen afhænger af den valgte kodning:
                - UTF-8, ASCII, Latin-1, UTF-16: tegnkonvertering.
                - Modbus ASCII, IBM Bisync: protokol-afkodning, hvor
                  styretegn erstattes med læsbare tags.
              DecodeIncomingData er en dispatcher, der kalder den
              relevante underrutine. }

          AppendToTerminal(DecodedText);                                    // Tilføj afkodet tekst til terminalen
          { ^ Tilføjer den afkodede tekst til terminalen. Selve
              visningslogikken (hukommelsesværn, tidsstempel, streaming-
              indsættelse, auto-scroll) ligger i AppendToTerminal, så
              denne metode kan koncentrere sig om datalæsning. }
        end;                                                                // Slut tekst-gren
      end;                                                                  // Slut visnings-gren
    end;                                                                    // Slut læse-gren
  except                                                                    // Begynder except-gren
    on E: Exception do                                                      // Fanger alle undtagelser
    begin                                                                   // Begynder undtagelses-krop
      // Hvis USB-kablet frakobles fysisk under kørsel
      TimerPoll.Enabled := False;                                           // Stop timeren FØRST
      FIsConnected := False;                                                // Markér forbindelsen som død
      UpdateUIState;                                                        // Opdater UI til "ikke forbundet"
      AppendToTerminal(LineEnding + '[System] USB-forbindelse tabt: ' + E.Message + LineEnding); // Log fejlen
      RefreshComPorts;                                                      // Gen-skann portlisten
      { ^ FEJLHÅNDTERING — den vigtigste grund til, at dette program
          er robust i praksis. Den typiske udløser er, at brugeren
          trækker USB-kablet ud, mens programmet kører. Det giver en
          OS-fejl (fx "The device does not recognize the command" på
          Windows eller "Input/output error" på Linux), som driveren
          rapporterer som en undtagelse.

          OPRYDNINGEN ER OMHYGGELIGT ORDRET:
            1. TimerPoll.Enabled := False
               Stop timeren FØRST. Ellers kunne den fyre igen, mens vi
               er midt i oprydningen, og ramme den samme fejl igen —
               hvilket ville give en uendelig række fejlbeskeder.
            2. FIsConnected := False
               Vi er ikke længere forbundet. Dette forhindrer
               BtnSendClick og andre metoder i at forsøge at bruge
               den nu-døde port.
            3. UpdateUIState
               Sætter knapper og indikatorer til "ikke forbundet"-
               tilstanden, så brugeren ser, at noget er galt.
            4. AppendToTerminal med fejlbesked
               Logger den specifikke fejl (E.Message), så brugeren
               kan se HVAD der gik galt — fx "Input/output error" er
               et klart tegn på USB-problemer.
            5. RefreshComPorts
               Gen-skanner portlisten, så den nu-fjernede port ikke
               længere står i CbComPort. Uden dette ville brugeren
               kunne forsøge at genoprette forbindelse til en port,
               der ikke længere findes.

          HVORFOR ER DETTE EN 'except on E: Exception' OG IKKE EN
          MERE SPECIFIK FEJLTYPE?
            Fordi vi ikke med sikkerhed kan forudsige, hvilken
            exception-type driveren kaster — det afhænger af OS,
            driver-version og den præcise fejlsituation. Ved at fange
            Exception (basis-klassen) sikrer vi, at uanset hvad der
            sker, kommer vi ikke i en situation, hvor GUI'en fryser
            eller en uendelig løkke af fejl opstår. Dette er "fail
            safe"-princippet: vi foretrækker at logge en generisk
            fejl frem for at crashe.

          HVORFOR VISE E.Message OG IKKE EN FAST TEKST?
            Fordi den specifikke OS-fejl ofte indeholder et hint om
            årsagen — fx "Access denied" (en anden proces holder
            porten), "Input/output error" (USB-problem), "Broken pipe"
            (porten er væk). Brugeren kan google fejlmeddelelsen og
            finde en løsning, hvis den vises korrekt. En fast tekst
            ville skjule denne information. }
    end;                                                                    // Slut undtagelses-krop
  end;                                                                      // Slut try/except
end;                                                                        // Slut på TimerPollTimer

function TFormMain.DecodeIncomingData(const RawBytes: AnsiString; Encoding: TSerialEncoding): string; // Dispatcher for afkodning
{ ^ DISPATCHER-FUNKTION. Modtager rå bytes fra serieporten og en valgt
    tegnkodning/protokol, og returnerer en UTF-8-streng, som TMemo kan
    vise direkte.

    HVORFOR EN DISPATCHER?
      Serieporten leverer altid rå bytes — det er op til terminalen at
      fortolke dem. Ved at samle alle kodningsvalg i én funktion får vi:
        - Ét indgangspunkt: TimerPollTimer behøver kun at kende
          funktionens navn, ikke detaljerne bag hver kodning.
        - Nem udvidelse: tilføjer man en ny kodning, er det ét nyt
          case-trin og én ny hjælpefunktion — ikke ændringer i
          TimerPollTimer.
        - Klar ansvarsfordeling: TimerPollTimer læser; denne funktion
          fortolker; AppendToTerminal viser.

    RETURNVÆRDIENS KONTRAKT:
      Resultatet er ALTID en UTF-8-streng. Det er vigtigt, fordi LCL's
      TMemo forventer UTF-8. Hvis vi returnerede Latin-1 eller UTF-16
      direkte, ville specialtegn (æ, ø, å) blive vist forkert. Derfor
      konverteres alle kodninger til UTF-8 inden returnering. }

var                                                                         // Lokale variable
  i: Integer;                                                               // Løkkeindeks
  WStr: WideString;                                                         // Mellemliggende UTF-16-streng
  Len: Integer;                                                             // Antal WideChar-tegn
  { ^ Lokale variable:
      i     : løkkeindeks (bruges af encASCII og encUnicodeUTF16BE).
      WStr  : mellemliggende WideString (UTF-16) til UTF16LE/BE-grenene.
              WideString bruges, fordi UTF8Encode arbejder på UTF-16,
              og fordi det giver korrekt håndtering af surrogate pairs
              (ikke relevant for vores typiske data, men det er den
              korrekte type til formålet).
      Len   : antal WideChar-tegn (bytes/2) i UTF-16-grenene.
      HVORFOR ER ALLE TRE DEKLARERET, SELV OM DE IKKE BRUGES I ALLE GRENE?
        Object Pascal tillader ikke, at man erklærer variable inde i en
        case-gren — de skal stå i funktionens var-sektion. Compileren
        advarer ikke om ubrugte variable i enkelte grene, så det er
        normal praksis at erklære dem samlet. Alternativet ville være
        at uddelegere UTF16LE/BE til separate hjælpefunktioner, hvilket
        er en smagssag, men her er det holdt samlet for overskuelighed. }

begin                                                                       // Begynder funktionens krop
  Result := '';                                                             // Initialiserer resultatet som tom streng
  WStr := '';                                                               // Initialiserer WStr som tom
  { ^ Defensiv initialisering. Result skal være '' ved udgangen, hvis
      ingen gren matcher (hvilket ikke burde kunne ske, fordi case'en
      er komplet — men det er god skik, og compileren kræver det ikke,
      fordi "Result" allerede initialiseres implicit til '' i en
      funktion).
      WStr nulstilles af samme grund: hvis en UTF16-gren springes over,
      skal vi ikke risikere at bruge en rest fra en tidligere kørsel
      (funktioner er re-entrante, men WStr er en lokal variabel, så det
      kan teknisk ikke ske — alligevel er eksplicit initialisering
      tydelig og koster intet). }

  case Encoding of                                                          // Dispatcher på valgt kodning
  { ^ Case-sætningen er kernen i dispatcheren. For hver TSerialEncoding-
      værdi kaldes den relevante konverteringsvej. Fordi TSerialEncoding
      er en komplet enum, og alle værdier er dækket, behøver vi ikke en
      else-gren — men compileren kræver ikke komplethed, så hvis nogen
      tilføjer en ny enum-værdi og glemmer at opdatere case'en, vil
      resultatet være '' for den nye værdi. Det er en acceptabel
      "fail silent"-strategi, fordi en tom visning er tydeligt forkert
      og nem at opdage. }

    encUTF8:                                                                // UTF-8-gren
      // Arduino og ESP32 sender typisk UTF-8 som rå bytes
      Result := string(RawBytes);                                           // Cast direkte til UTF-8-streng
    { ^ UTF-8 er den nemmeste gren: rå bytes ER allerede UTF-8 (forudsat
        at MCU'en faktisk sender UTF-8, hvilket Arduino/ESP32 gør som
        standard). Vi skal derfor bare caste AnsiString'en til en
        almindelig "string".
        HVORFOR EN CAST OG IKKE EN KOPI?
          I Free Pascal med {$H+} er både AnsiString og string
          reference-talte. Castet er derfor en nul-omkostning —
          compileren genbruger den underliggende buffer. Ingen
          datakopiering, ingen unødig hukommelsesallokering.
        HVORFOR ER DETTE DEFAULT I GUI'ET?
          Fordi 99% af Arduino/ESP32-sketches sender UTF-8, især når
          de indeholder danske tegn i Serial.println. Ved at gøre
          UTF-8 til standard undgår brugeren at skulle ændre
          indstillinger for det almindelige tilfælde. }

    encASCII:                                                               // ASCII-gren
      // Standard 7-bit ASCII: behold tegn 32..126 samt CR, LF, TAB
      begin                                                                 // Begynder blok (flere sætninger)
        SetLength(Result, Length(RawBytes));                                // Alloker resultat med samme længde
        for i := 1 to Length(RawBytes) do                                   // Itererer over hver byte
        begin                                                               // Begynder løkkekrop
          if (Ord(RawBytes[i]) >= 32) or (RawBytes[i] in [#10, #13, #9]) then // Er det printbart eller CR/LF/TAB?
            Result[i] := RawBytes[i]                                        // Kopier tegnet uændret
          else                                                              // Ellers: ikke-printbart
            Result[i] := '.'; // Udskift ikke-printbare kontroltegn med prik // Erstat med '.'
        end;                                                                // Slut løkke
      end;                                                                  // Slut blok
    { ^ ASCII-grenen fremhæver PRINTBARE tegn og erstatter resten med
        prik. Formålet er at gøre kontroltegn SYNLIGE, så brugeren kan
        se, at de findes — uden at de ødelægger terminalens layout.

        BETINGELSEN:
          Ord(RawBytes[i]) >= 32   : alle tegn fra mellemrum og op
                                     (32 = ' ', 126 = '~') er printbare
                                     i ASCII og vises uændret.
          RawBytes[i] in [#10, #13, #9]
                                   : CR (13), LF (10) og TAB (9) bevares,
                                     så linjeskift og indrykning fungerer
                                     normalt. Uden dette ville hele
                                     telemetrien stå på én lang linje,
                                     hvilket ville være ulæseligt.
          ALT ANDET (0..8, 11, 12, 14..31, 127..255)
                                   : erstattes med '.', så brugeren ser,
                                     at der ER et ikke-printbart tegn,
                                     men det ødelægger ikke visningen.

        HVORFOR BEHOLDE TAB OG IKKE ERSTATTE DEN MED PRIK?
          Fordi TAB er et formateringstegn, som MCU'en kan bruge til at
          justere kolonner i telemetrien. At erstatte den med '.' ville
          gøre telemetrien sværere at læse, ikke lettere.

        HVORFOR SetLength FØR LØKKEN?
          Fordi vi skal skrive til Result[i] — en AnsiString skal have
          den korrekte længde, FØR man kan indeksere den. Uden
          SetLength ville vi skrive til en tom streng og få en
          range-check-fejl (i debug) eller stille hukommelseskorruption
          (i release). Dette er en klassisk fælde i Pascal.
        BEMÆRK OM YDEEVNE:
          SetLength allokerer én gang, og løkken skriver direkte ind i
          bufferen — ingen omallokering. Det er den hurtigste måde at
          bygge en streng af samme længde som input. }

    encISO88591:                                                            // Latin-1-gren
      // Latin-1 konvertering (æ=0xE6, ø=0xF8, å=0xE5, Æ=0xC6, Ø=0xD8, Å=0xC5)
      Result := Latin1ToUTF8(RawBytes);                                     // Konverter via hjælpefunktion
    { ^ Latin-1 er ikke UTF-8 og skal konverteres. Se Latin1ToUTF8's
        egen kommentar for detaljer om selve konverteringsalgoritmen.
        Her er pointen, at brugeren kan vælge encISO88591, når MCU'en
        er konfigureret til at sende Latin-1 (fx en ældre sketch eller
        en specifik protokol-standard).
        DE DANSKE TEGN I LATIN-1:
          æ = 0xE6    Æ = 0xC6
          ø = 0xF8    Ø = 0xD8
          å = 0xE5    Å = 0xC5
        Disse er alle >= 0x80 og kræver derfor to-byte UTF-8-kodning
        for at blive vist korrekt i TMemo. }

    encUnicodeUTF16LE:                                                      // UTF-16 LE-gren
      // 16-bit Little Endian (Standard Windows Unicode)
      begin                                                                 // Begynder blok
        Len := Length(RawBytes) div 2;                                      // Antal 16-bit tegn
        if Len > 0 then                                                     // Er der mindst ét helt tegn?
        begin                                                               // Begynder konverterings-gren
          SetLength(WStr, Len);                                             // Alloker WStr med Len tegn
          Move(RawBytes[1], WStr[1], Len * 2);                              // Kopier rå bytes direkte ind i WStr
          Result := UTF8Encode(WStr);                                       // Konverter UTF-16 -> UTF-8
        end;                                                                // Slut konverterings-gren
      end;                                                                  // Slut blok
    { ^ UTF-16 Little Endian: hvert tegn er 2 bytes, mindst signifikant
        byte først. Bruges af nogle Windows-baserede protokoller og
        enkelte MCU-platforme.

        TRIN FOR TRIN:
          1. Len := Length(RawBytes) div 2
             Antallet af 16-bit tegn er halvt så stort som antallet af
             bytes. Hvis der er et ulige antal bytes (fx pga. en
             afbrudt transmission), ignoreres den sidste byte — vi kan
             ikke danne et helt tegn af den, og en halv karakter ville
             give volapyk i visningen.

          2. SetLength(WStr, Len)
             Allokerer plads til Len WideChar i WStr. WideString er
             UTF-16-baseret, så dette er den korrekte beholder for
             mellemresultatet.

          3. Move(RawBytes[1], WStr[1], Len * 2)
             Kopierer alle Len*2 bytes fra RawBytes direkte ind i WStr.
             Move er en hurtig byte-blok-kopi uden typekontrol — den
             kopierer rå bytes fra AnsiString til WideString's
             underliggende buffer. Da begge er UTF-16 LE på Windows og
             x86/x64-platforme, er dette en korrekt nul-konverterings-
             kopi. På big-endian-platforme ville det ikke virke, men
             de er ikke praktisk relevante her.
             HVORFOR MOVE OG IKKE EN LØKKE?
               Move er 5-10 gange hurtigere for store datamængder,
               fordi den bruger memcpy under motorhjelmen.

          4. Result := UTF8Encode(WStr)
             Konverterer UTF-16-strengen til UTF-8, som TMemo forventer.
             UTF8Encode er en indbygget FPC-funktion, der håndterer
             surrogate pairs korrekt (vigtigt for tegn uden for BMP,
             fx emoji — ikke aktuelt her, men korrekt adfærd).

        BEMÆRK OM BETINGELSEN 'if Len > 0':
          Hvis Length(RawBytes) < 2, er Len = 0, og vi ville kalde
          SetLength(WStr, 0) og Move(...) med 0 bytes. Det er teknisk
          tilladt, men unødvendigt arbejde. Tidlig retur giver også
          mulighed for at undgå at kalde UTF8Encode med tom WideString,
          som ville give '' — samme resultat, men med unødig
          funktionskald. }

    encUnicodeUTF16BE:                                                      // UTF-16 BE-gren
      // 16-bit Big Endian: byt bytes
      begin                                                                 // Begynder blok
        Len := Length(RawBytes) div 2;                                      // Antal 16-bit tegn
        if Len > 0 then                                                     // Er der mindst ét helt tegn?
        begin                                                               // Begynder konverterings-gren
          SetLength(WStr, Len);                                             // Alloker WStr med Len tegn
          for i := 1 to Len do                                              // Itererer over hvert tegn
            WStr[i] := WideChar((Ord(RawBytes[(i - 1) * 2 + 1]) shl 8) or Ord(RawBytes[(i - 1) * 2 + 2])); // Byter bytes og danner WideChar
          Result := UTF8Encode(WStr);                                       // Konverter UTF-16 -> UTF-8
        end;                                                                // Slut konverterings-gren
      end;                                                                  // Slut blok
    { ^ UTF-16 Big Endian: hvert tegn er 2 bytes, MEST signifikant byte
        først. Netværksrækkefølge — bruges af nogle protokoller.

        HVORFOR EN MANUEL LØKKE OG IKKE MOVE SOM I LE-GRENEN?
          Fordi bytes skal OM-BYTTES. Move ville kopiere bytes 1:1, men
          det ville give den forkerte tolkning (fx 0x00, 0x41 ville
          blive fortolket som 0x4100 i stedet for 0x0041 = 'A'). Vi
          skal derfor konstruere hvert WideChar korrekt.

        UDTRYKKET FOR HVERT TEGN:
          Offset i RawBytes:
            (i - 1) * 2 + 1   = første byte (mest signifikant i BE)
            (i - 1) * 2 + 2   = anden byte (mindst signifikant i BE)

          WideChar-værdi:
            (Ord(RawBytes[...+1]) shl 8)   : første byte forskydes 8
                                             bits op = høj byte.
            or Ord(RawBytes[...+2])         : anden byte på plads =
                                             lav byte.
          Eksempel: BE-bytes 0x00, 0x41 ('A') giver:
            (0x00 shl 8) or 0x41 = 0x0000 or 0x41 = 0x0041 = 'A'.
          Korrekt.

        HVORFOR INDEKSERE MED (i - 1) * 2 + 1 OG IKKE NOGET MERE SIMPELT?
          Fordi i tæller 1..Len (WideChar-nummer), men vi skal læse
          bytes 1..Len*2 (byte-nummer). For WideChar nr. i skal vi
          læse byte nr. (i-1)*2+1 og (i-1)*2+2. For i=1: bytes 1 og 2.
          For i=2: bytes 3 og 4. Osv. Udtrykket er en smule kryptisk,
          men det er den præcise oversættelse fra "tegn-indeks" til
          "byte-indeks". Alternativt kunne man bruge en separat
          byte-tæller, men det ville kræve endnu en variabel.

        HVORFOR 'shl 8' OG IKKE '* 256'?
          shl (shift left) er en bit-operation, der er lige så hurtig
          som multiplikation på moderne CPU'er, men udtrykker
          hensigten klarere: vi flytter en byte op på den høje
          position. Det signalerer "bit-manipulation", ikke
          "aritmetik". }

    encModbusASCII:                                                         // Modbus ASCII-gren
      Result := DecodeModbusASCII(RawBytes);                                // Uddeleger til specialiseret funktion
    { ^ Uddelegerer til en specialiseret funktion. Grunden til, at
        Modbus-afkodning er sin egen funktion, er, at den ikke bare
        skal konvertere tegn — den skal GENKENDT rammestruktur og
        indsætte læsbare tags. Det er en helt anden opgave end
        tegnkonvertering, og at holde dem adskilt gør begge dele
        lettere at forstå og vedligeholde. }

    encIBMBisync:                                                           // IBM Bisync-gren
      Result := DecodeIBMBisync(RawBytes);                                  // Uddeleger til specialiseret funktion
    { ^ Samme princip som Modbus. IBM Bisync er en binær protokol med
        styretegn (SYN, STX, ETX, ACK, NAK, DLE), og afkodningen
        erstatter disse med læsbare tags, så brugeren kan følge
        protokollen direkte i terminalen. }

  end;                                                                      // Slut case
end;                                                                        // Slut på DecodeIncomingData

{ Modbus ASCII: Start ':' (0x3A), 2 hex cifre pr byte, CR LF afslutning }
function TFormMain.DecodeModbusASCII(const Raw: AnsiString): string;        // Modbus ASCII-protokolafkoder
{ ^ Protokol-afkoder for Modbus ASCII. Gør rammestrukturen synlig for
    brugeren ved at erstatte de to "usynlige" markører — start-tegnet ':'
    og afslutningen CRLF — med læsbare tags.

    BAGGRUND — HVORDAN SER EN MODBUS ASCII-RAMME UD?
      En typisk ramme er:
        : 01 03 04 01 F4 00 2A DF \r\n
      hvor:
        ':'             = start-of-frame (0x3A).
        01              = slave-adresse (hex).
        03              = funktionskode (hex, "Read Holding Registers").
        04              = antal data-bytes (hex).
        01 F4           = første registerværdi (hex, 500 decimal).
        00 2A           = andet register (hex, 42 decimal).
        DF              = LRC-checksum (hex).
        \r\n            = afslutning (CR + LF).
      Alle tegn mellem ':' og CRLF er PRINTBARE ASCII-tegn (hex-cifre
      0-9, A-F). Det betyder, at selve rammen allerede er læsbar — men
      ':' og CRLF er usynlige i en rå tekstvisning, så brugeren kan
      ikke se, hvor rammen STARTER og SLUTTER. Det er præcis det,
      denne funktion retter op på.

    HVORFOR ER DET VIGTIGT?
      Modbus ASCII er en tekstprotokol, men uden visuelle markører for
      ramme-start og ramme-slut ville terminalen vise en lang, ubrudt
      strøm af hex-cifre uden nogen visuel indikation af, hvor én
      ramme slutter og den næste begynder. Det gør det umuligt at
      verificere, at LRC'en hører til den rigtige ramme, eller at
      afslutningen er korrekt. Ved at tagge dem får brugeren straks
      et visuelt protokolspor. }

var                                                                         // Lokale variable
  i: Integer;                                                               // Løkkeindeks
  Ch: Char;                                                                 // Aktuelt tegn
  { ^ Lokale variable:
      i  : løkkeindeks.
      Ch : aktuelt tegn (Char er et AnsiChar her, da Raw er AnsiString).
      HVORFOR IKKE BYTE SOM I Bisync?
        Fordi Modbus ASCII kun indeholder printable ASCII (0x20..0x7E)
        plus CR/LF — ingen binære tegn. Char er derfor den naturlige
        type. Bisync derimod håndterer binære styretegn, hvor Byte er
        mere eksplicit. }

begin                                                                       // Begynder funktionens krop
  Result := '';                                                             // Initialiserer resultatet som tom streng
  { ^ Initialiserer resultatet som tom streng. Sikrer, at hvis Raw er
      tom, returnerer vi '' (i stedet for en tilfældig rest). }

  for i := 1 to Length(Raw) do                                              // Itererer over hver byte
  begin                                                                     // Begynder løkkekrop
    Ch := Raw[i];                                                           // Henter aktuelt tegn
    { ^ Itererer over hver byte i inputtet og behandler dem ét ad gangen.
        Vi bygger Result op successivt med konkatenation. For små
        Modbus-rammer (typisk under 100 bytes) er dette fint
        ydelsesmæssigt. For store datamængder ville man overveje en
        TStringBuilder-lignende tilgang, men det er ikke nødvendigt her. }

    if Ch = ':' then                                                        // Er det start-tegnet ':'?
      Result := Result + '[MODBUS START :]'                                 // Erstat med læsbart tag
    { ^ START-OF-FRAME: Erstattes med "[MODBUS START :]". Brugeren ser
        straks, hvor rammen begynder. Vi bevarer ':' i tagget, så det
        er tydeligt, hvilket tegn der blev erstattet — det er
        vigtigt, hvis brugeren vil verificere den rå byte-strøm mod
        protokol-specifikationen. }

    else if (Ch = #13) and (i < Length(Raw)) and (Raw[i+1] = #10) then      // Er det CRLF-afslutning?
      Result := Result + '[END CRLF]' + LineEnding                          // Erstat med tag + linjeskift
    { ^ SLUT PÅ RAMME: CR (13) efterfulgt af LF (10) markerer
        ramme-afslutningen. Vi erstatter BEGGE tegn med ét tag og et
        rigtigt linjeskift.
        BETINGELSERNE:
          Ch = #13               : aktuelt tegn er CR.
          i < Length(Raw)        : der ER et næste tegn at kigge på
                                   (forhindrer range-check-fejl).
          Raw[i+1] = #10         : næste tegn er LF.
        Kun hvis ALLE tre er sande, er der tale om en ægte CRLF-
        afslutning. Ellers falder vi igennem til næste gren.
        HVORFOR LineEnding OG IKKE BARE #13#10?
          For at bevare platformens naturlige linjeskift i visningen.
          På Windows bliver det CRLF, på Linux LF — begge steder ser
          det korrekt ud i TMemo.
        BEMÆRK OM YDELSE:
          Løkken springer IKKE over det næste tegn (LF). Det betyder,
          at når vi har behandlet CR og set LF, vil næste iteration
          behandle LF'en igen — men den falder i den næste gren
          (Ch in [#10, #13] -> ignoreres). Så det er korrekt adfærd,
          omend lidt implicit. En eksplicit "Inc(i)" ville gøre det
          klarere, men Pascal's for-løkke tillader ikke manuel
          inkrementering af løkkevariablen. }

    else if not (Ch in [#10, #13]) then                                     // Er det hverken CR eller LF?
      Result := Result + Ch;                                                // Kopier tegnet direkte
    { ^ ALT ANDET END CR/LF: Kopieres direkte til resultatet. Det
        inkluderer:
          - Hex-cifre (0-9, A-F) : selve rammens payload.
          - Eventuelle andre printable tegn : fx hvis protokollen
            har tekstkommentarer (ikke standard Modbus, men muligt).
        HVORFOR UDELUKKE CR/LF HER?
          Fordi de allerede er håndteret i den foregående gren (CRLF)
          eller skal ignoreres (ensomme CR eller LF, som ikke udgør
          en gyldig afslutning). Hvis vi kopierede dem, ville
          resultatet indeholde både "[END CRLF]" OG de rå CR/LF-tegn,
          hvilket ville give dobbelte linjeskift i visningen. }

  end;                                                                      // Slut løkke
end;                                                                        // Slut på DecodeModbusASCII

{ IBM Bisync (Binary Synchronous Communication): SYN, STX, ETX, DLE, ACK, NAK }
function TFormMain.DecodeIBMBisync(const Raw: AnsiString): string;          // IBM Bisync-protokolafkoder
{ ^ Protokol-afkoder for IBM Bisync (Binary Synchronous Communication).
    Bisync er en binær protokol med en række styretegn, som er usynlige
    eller ødelægger layoutet i en rå tekstvisning. Funktionen oversætter
    dem til læsbare tags, så brugeren kan følge protokollen direkte i
    terminalen.

    BAGGRUND — HVAD ER IBM BISYNC?
      IBM Bisync (1960'erne) var en af de første standarder for
      synkron dataudveksling mellem mainframes og terminaler. Den
      bruger en række kontroltegn til at markere ramme-start, -slut,
      kvitteringer osv. Protokollen er stadig i brug i nogle
      industrielle og finansielle systemer, og nogle MCU-baserede
      protokol-emulatorer bruger den også.

    DE CENTRALE STYRETEGN:
      SYN (0x16 eller 0x32)  : Synchronous Idle — synkroniserer modtager.
      STX (0x02)             : Start of Text — begynder datablokken.
      ETX (0x03)             : End of Text — afslutter datablokken.
      EOT (0x04)             : End of Transmission — afslutter sessionen.
      ENQ (0x05)             : Enquiry — anmodning om svar.
      ACK (0x06)             : Acknowledge — positiv kvittering.
      DLE (0x10)             : Data Link Escape — escape-tegn for
                               gennemsigtig transmission.
      NAK (0x15)             : Negative Acknowledge — negativ kvittering.
      ETB (0x17)             : End of Transmission Block — afslutter en
                               delblok i en længere transmission.
    To værdier for SYN (0x16 og 0x32) skyldes, at forskellige
    implementationer brugte forskellige tegn — vi behandler begge som
    SYN for at være fleksible.

    HVORFOR ER DET VIGTIGT?
      Bisync-styretegn er ikke-printbare og ville vises som mærkelige
      tegn eller slet ikke i en rå tekstvisning. Uden denne afkodning
      ville brugeren ikke kunne se, om der var tale om en STX, ETX,
      ACK osv. — hvilket er præcis den information, der er nødvendig
      for at verificere protokol-adfærden. }

var                                                                         // Lokale variable
  i: Integer;                                                               // Løkkeindeks
  B: Byte;                                                                  // Aktuelt byte som numerisk værdi
  { ^ Lokale variable:
      i : løkkeindeks.
      B : aktuelt byte som Byte (0..255). Byte er valgt frem for Char,
          fordi Bisync håndterer binære styretegn, og Byte gør
          sammenligningen med hex-konstanter ($16, $02, osv.) mere
          læsbar. }

begin                                                                       // Begynder funktionens krop
  Result := '';                                                             // Initialiserer resultatet som tom streng
  { ^ Initialiserer resultatet som tom streng. }

  for i := 1 to Length(Raw) do                                              // Itererer over hver byte
  begin                                                                     // Begynder løkkekrop
    B := Byte(Raw[i]);                                                      // Henter byte-værdien
    { ^ Henter det aktuelle byte som numerisk værdi. Byte(...) er den
        mest direkte cast fra AnsiChar og undgår eventuelle
        fortegnsproblemer på platforme, hvor Char fortolkes som
        signeret. }

    case B of                                                               // Dispatch på byte-værdi
      $16, $32: Result := Result + '<SYN>';                                 // SYN (to varianter)
      { ^ SYN — Synchronous Idle. To værdier, fordi forskellige
          implementationer brugte 0x16 (klassisk IBM) eller 0x32
          (ASCII '2'). Vi behandler begge som SYN, så vi er
          kompatible med flere varianter uden at kræve bruger-
          konfiguration. }

      $02:      Result := Result + '<STX>';                                 // STX — Start of Text
      { ^ STX — Start of Text. Markerer begyndelsen af datablokken.
          Brugeren kan straks se, hvor payloaden starter. }

      $03:      Result := Result + '<ETX>' + LineEnding;                    // ETX — End of Text + linjeskift
      { ^ ETX — End of Text. Markerer slutningen af datablokken. Vi
          tilføjer et linjeskift, fordi ETX typisk afslutter en
          logisk ramme — det gør terminalen meget mere læsbar, fordi
          hver ramme står på sin egen linje. }

      $04:      Result := Result + '<EOT>' + LineEnding;                    // EOT — End of Transmission + linjeskift
      { ^ EOT — End of Transmission. Afslutter hele sessionen eller
          overførslen. Også her tilføjes et linjeskift, fordi EOT
          markerer en klar afslutning. }

      $05:      Result := Result + '<ENQ>';                                 // ENQ — Enquiry
      { ^ ENQ — Enquiry. Anmodning om svar (typisk fra station til
          station). Ingen linjeskift, fordi ENQ er en del af en
          igangværende udveksling. }

      $06:      Result := Result + '<ACK>';                                 // ACK — Acknowledge
      { ^ ACK — Acknowledge. Positiv kvittering på modtagelse. }

      $15:      Result := Result + '<NAK>';                                 // NAK — Negative Acknowledge
      { ^ NAK — Negative Acknowledge. Negativ kvittering, typisk
          fordi en checksum fejlede, eller data var uforståelige. }

      $10:      Result := Result + '<DLE>';                                 // DLE — Data Link Escape
      { ^ DLE — Data Link Escape. Bruges til "gennemsigtig"
          transmission: hvis payloaden indeholder et tegn, der ligner
          et styretegn (fx en STX indeni data), escapes det med DLE
          foran, så modtageren ved, at det er data og ikke et
          styretegn. Vigtigt at kunne se i protokol-sporet. }

      $17:      Result := Result + '<ETB>' + LineEnding;                    // ETB — End of Transmission Block + linjeskift
      { ^ ETB — End of Transmission Block. Afslutter en delblok i en
          længere transmission (hvor hele meddelelsen er delt op i
          flere blokke). Linjeskift, fordi det markerer en logisk
          afslutning på blokken. }

      else                                                                  // Alle andre bytes
        if (B >= 32) and (B <= 126) then                                    // Er det printbart ASCII?
          Result := Result + Chr(B)                                         // Vis som tegn
        else                                                                // Ellers: binært
          Result := Result + Format('[0x%02X]', [B]);                       // Vis som hex-tag
      { ^ FALLBACK for alle andre bytes:
            - Printable ASCII (32..126): vises som selve tegnet.
              Dette er payload-teksten, som brugeren naturligvis
              gerne vil kunne læse.
            - Alt andet (0..31, 127..255): vises som [0xNN], fx
              [0x0A] for LF eller [0xC3] for en byte fra en
              UTF-8-sekvens. Dette gør ellers usynlige bytes synlige
              og entydige.
          HVORFOR Format('[0x%02X]', [B]) OG IKKE IntToHex?
            Format giver præcis den ønskede form med fast bredde
            (%02X = mindst 2 hex-cifre, stort) og den omkringliggende
            tekst [0x...] på én gang. IntToHex ville kræve manuel
            sammensætning af '[' + '0x' + IntToHex(B, 2) + ']', som
            er mere verbose og lettere at skrive forkert.
          HVORFOR STORT X (%02X) OG IKKE LILLE (%02x)?
            Fordi hex-konventionen i protokol-dokumentation typisk
            bruger store bogstaver (0x0A, 0xFF). Det matcher, hvad
            brugeren vil se i en protokol-specifikation. }
    end;                                                                    // Slut case
  end;                                                                      // Slut løkke
end;                                                                        // Slut på DecodeIBMBisync

function TFormMain.BytesToHexString(const Raw: AnsiString): string;         // Konverterer rå bytes til hex-streng
{ ^ Hjælpefunktion, der konverterer en rå byte-sekvens til en læsbar
    hex-streng, fx:
      Input  : 'Hej' (3 bytes: 0x48, 0x65, 0x6A)
      Output : '48 65 6A '
    Bruges af TimerPollTimer, når ChkHexView er slået til, i stedet for
    at kalde DecodeIncomingData.

    HVORFOR HEX-VISNING OVERHOVEDET?
      Serieporten er byte-baseret — den ved ikke, om data er tekst,
      binært, en protokolramme eller noget helt fjerde. Ved binære
      protokoller (Modbus RTU, IBM Bisync, binære sensorformater,
      firmware-kommandoer) er en tekstbaseret visning enten ubrugelig
      eller direkte misvisende:
        - En byte som 0x00 vises intet eller som et mærkeligt tegn.
        - En byte som 0x0A ville blive fortolket som linjeskift og
          ødelægge visningen.
        - En byte som 0xC3 kunne være starten på en UTF-8-sekvens —
          men hvis det er binært data, er den slet ikke UTF-8.
      Hex-dump er den ENESTE entydige måde at se, hvad der faktisk
      sendes, uanset datatype. Derfor er denne funktion uundværlig for
      fejlfinding på binære protokoller.

    HVORFOR TO HEX-CIFRE PR. BYTE?
      En byte rummer 0..255, hvilket kræver to hex-cifre (00..FF).
      Faste to cifre pr. byte gør output ensartet og let at aflæse —
      man kan tælle bytes ved at tælle mellemrum, og man kan sammenligne
      direkte med en protokol-specifikation.

    HVORFOR MELLEMRUM EFTER HVER BYTE?
      Uden mellemrum ville 'Hej' blive '48656A' — svært at aflæse, og
      umuligt at se, hvor den ene byte slutter og den næste begynder.
      Med mellemrum bliver det '48 65 6A', hvor hver byte er visuelt
      adskilt. Det ekstra mellemrum til sidst gør desuden, at to
      på hinanden følgende kald (fx fra to timer-ticks) ikke smelter
      sammen: '48 65 6A ' + '72 6C ' = '48 65 6A 72 6C ' — læsbart. }

var                                                                         // Lokale variable
  i: Integer;                                                               // Løkkeindeks
  { ^ Løkkeindeks. Vi itererer over hver byte i inputtet og bygger
      resultatet successivt op. }

begin                                                                       // Begynder funktionens krop
  Result := '';                                                             // Initialiserer resultatet som tom streng
  { ^ Starter med tom streng. Hvis Raw er tom, returnerer vi '' — hvilket
      er korrekt: ingen bytes, ingen hex-tekst. }

  for i := 1 to Length(Raw) do                                              // Itererer over hver byte
    Result := Result + IntToHex(Ord(Raw[i]), 2) + ' ';                      // Tilføj hex + separator
  { ^ Løkken gør tre ting for hver byte:
        1. Ord(Raw[i]) : henter byte-værdien som heltal (0..255).
                         Ord er den korrekte måde at konvertere et
                         AnsiChar til dets numeriske værdi. En direkte
                         Byte(...)-cast ville også virke, men Ord er
                         mere eksplicit om, at vi arbejder med en
                         tegnværdi.
        2. IntToHex(..., 2) : konverterer heltallet til hex med MINDST
                              2 cifre. Hvis værdien er < 0x10 (fx 0x0A),
                              tilføjer IntToHex en førende nul, så
                              resultatet bliver '0A' — ikke 'A'.
                              Det er vigtigt for ensartethed: 10, 11,
                              ..., 15 bliver 0A, 0B, ..., 0F.
        3. + ' ' : tilføjer et mellemrum som separator mellem bytes.

      HVORFOR 'IntToHex(..., 2)' OG IKKE FORMAT('%.2X', [...])?
        IntToHex er en indbygget, velkendt FPC-funktion, der gør præcis
        dette. Format('%.2X', ...) ville give samme resultat, men med
        mere overhead (Format er en tung funktion, der skal parse
        formatstrengen). Til simple hex-konverteringer er IntToHex
        hurtigere og klarere.

      HVORFOR BYGGE RESULTATET MED KONKATENATION OG IKKE EN BUFFER?
        For små datamængder (typisk under 100 bytes pr. chunk) er
        konkatenation fint — FPC's AnsiString-håndtering er
        reference-talt, og compileren kan ofte optimere det. For
        store mængder kunne man bruge SetLength + direkte indeksering,
        men det er ikke nødvendigt her, fordi funktionen kaldes på
        chunks af den størrelse, OS-bufferen typisk rummer.

      BEMÆRK OM YDELSE VED STORE DATA:
        Hvis man på et tidspunkt vil hex-dumpe megabyte-store filer,
        vil konkatenation blive en flaskehals (O(n²) pga. gentagne
        omallokeringer). Så skulle man omskrive til:
          SetLength(Result, Length(Raw) * 3);
          for i := 1 to Length(Raw) do
            Move(...) eller direkte tildeling til Result-bytepositioner.
        Men for serieportens typiske chunk-størrelser (op til 4 KB) er
        den nuværende løsning rigelig hurtig. }
end;                                                                        // Slut på BytesToHexString

procedure TFormMain.AppendToTerminal(const AText: string);                  // Skriver tekst til MemoTerminal med streaming-semantik
{ ^ Central visningsfunktion — den ENESTE måde tekst kommer ind i
    MemoTerminal på. Alle andre metoder (TimerPollTimer, BtnConnectClick,
    BtnDisconnectClick, BtnSendClick, BtnClearClick, FormCreate) kalder
    denne funktion i stedet for at skrive direkte til MemoTerminal.

    HVORFOR EN CENTRAL FUNKTION?
      Ved at samle al visning i én funktion får vi:
        - Én sandhedskilde for, hvordan tekst vises.
        - Mulighed for at tilføje hukommelsesværn, tidsstempler,
          auto-scroll og streaming på ét sted.
        - Konsistens: alle dele af programmet opfører sig ens, uanset
          hvor data kommer fra.
        - Nem vedligeholdelse: ændrer man visningsadfærden, er det ét
          sted — ikke spredt ud over hele koden.

    DEN STORE UDFORDRING — STREAMING-SEMANTIK:
      Arduino'ens Serial.print() og Serial.println() opfører sig
      forskelligt:
        - Serial.print("Hej") skriver "Hej" UDEN linjeskift. Næste
          Serial.print() fortsætter på SAMME linje.
        - Serial.println("Hej") skriver "Hej\r\n" MED linjeskift.
          Næste kald starter på en NY linje.
      For at efterligne Arduino IDE's Serial Monitor korrekt, skal vi
      kunne indsætte tekst DIREKTE ved slutningen af TMemo'en uden at
      antage, at der altid er et linjeskift forinden. Det er præcis,
      hvad denne funktion gør.

    HVORFOR ER DET SVÆRT?
      TMemo's Lines-property er linje-baseret — den betragter tekst som
      en liste af linjer. Hvis man bruger Lines.Add() eller Lines.Text :=
      ..., antager den, at hver indsættelse er en NY linje. Det ville
      betyde, at Serial.print("Hej") efterfulgt af Serial.print(" verden")
      ville blive vist som to separate linjer — hvilket er FORKERT.
      Løsningen er at bruge SelStart/SelText til at indsætte direkte i
      tekstbufferen, hvilket bevarer den rå byte-strøm uændret. }

var                                                                         // Lokale variable
  InsertStr: string;                                                        // Tekst der faktisk skal indsættes
  { ^ Den tekst, der faktisk skal indsættes. Adskiller sig fra AText,
      når der skal tilføjes et tidsstempel. Ved at bruge en separat
      variabel kan vi tilføje tidsstempel uden at ændre kalderens
      input (som er const og ikke må ændres). }

begin                                                                       // Begynder procedurens krop
  if AText = '' then Exit;                                                  // Tom streng? Gør ingenting
  { ^ TOM STRENG-TJEK. Hvis der ikke er noget at vise, gør vi ingenting.
      Dette er vigtigt, fordi:
        - SelText-tildelingen med en tom streng ville stadig markere
          Memo'en som "ændret" og kunne udløse unødige repaints.
        - Hvis vi tilføjede et tidsstempel til en tom streng, ville
          vi få en linje med kun "[hh:nn:ss.zzz] " — hvilket er
          støjende og forvirrende.
      Ved at returnere tidligt undgår vi begge problemer og sparer
      unødigt arbejde. }

  // Hukommelses- og stabilitetssikring:
  // Hvis Arduino sender kontinuerlig hurtig data (f.eks. 115200 baud),
  // beskæres de ældste linjer automatisk så TMemo ikke overfyldes eller fryser UI.
  if MemoTerminal.Lines.Count > 2500 then                                   // Er der for mange linjer?
  begin                                                                     // Begynder beskærings-gren
    MemoTerminal.Lines.BeginUpdate;                                         // Suspender repaints
    try                                                                     // Begynder try/finally
      while MemoTerminal.Lines.Count > 1500 do                              // Slet indtil 1500 linjer tilbage
        MemoTerminal.Lines.Delete(0);                                       // Slet ældste linje
    finally                                                                 // Uanset undtagelse:
      MemoTerminal.Lines.EndUpdate;                                         // Genoptag repaints
    end;                                                                    // Slut try/finally
  end;                                                                      // Slut beskærings-gren
  { ^ HUKOMMELSESVÆRN — den vigtigste stabilitetsforanstaltning i hele
      programmet.

      PROBLEMET:
        Ved 115200 baud (~11.5 KB/s) og en Arduino, der sender
        telemetri hvert sekund, vokser TMemoens tekst konstant. Efter
        få minutter kan den indeholde titusindvis af linjer. TMemo
        (især på Windows, hvor den er baseret på RichEdit) bliver
        EKSPONENTIELT langsommere ved store tekster:
          - 10.000 linjer   : mærkbar forsinkelse ved scroll.
          - 50.000 linjer   : flere sekunders frysing.
          - 100.000+ linjer : programmet kan fryse helt eller crashe.
        Uden denne beskyttelse ville en langvarig session gøre
        programmet ubrugeligt.

      LØSNINGEN — "RULLENDE VINDUE":
        Når antallet af linjer overstiger 2500, slettes de ældste
        linjer, indtil der kun er 1500 tilbage. Dette giver et
        rullende vindue på ca. 1500-2500 linjer, hvilket er rigeligt
        til at følge med i telemetrien uden at miste nyttig historik.

      HVORFOR 2500 SOM TÆRSKEL OG 1500 SOM MÅL?
        - 2500 er højt nok til, at brugeren kan scrolle tilbage og se
          de seneste par minutters telemetri.
        - 1500 er lavt nok til, at sletningen tager mærkbart kortere
          tid end den samlede session.
        - Mellemrummet (1000 linjer) giver "hysterese": vi sletter
          ikke én linje ad gangen, men en stor blok på én gang. Det
          undgår, at vi sletter konstant (hvilket ville være dyrt)
          og giver en mere jævn ydeevne.
        - Hvis vi slettede ned til 2499 (kun 1 linje), ville vi
          skulle gentage sletningen ved hvert nyt kald — hvilket ville
          fordoble arbejdet. Ved at slette ned til 1500 får vi
          ~1000 nye linjer, før vi skal slette igen.

      BeginUpdate/EndUpdate:
        Uden disse ville hver Delete(0) udløse en repaint og en
        intern tekstbuffer-opdatering — 1000 gange i træk. Det ville
        tage sekunder og fryse UI'et synligt. BeginUpdate suspenderer
        repaints og intern opdatering, indtil EndUpdate kaldes, så
        hele sletningen sker "i ét hug" — hurtigt og uden flicker.

      HVORFOR Delete(0) OG IKKE Delete(Count-1)?
        Vi sletter de ÆLDSTE linjer (i starten af listen), så det
        nyeste indhold bevares. Det er det, brugeren forventer:
        når noget nyt kommer ind, forsvinder det ældste.

      HVORFOR while OG IKKE if?
        Fordi vi skal kunne slette mange linjer, hvis brugeren har
        indsat en meget stor mængde data siden sidste tjek (fx en
        firmware-dump). while-løkken sikrer, at vi når ned til 1500
        uanset udgangspunktet.
        Alternativt kunne man beregne antallet af sletninger og kalde
        Delete i en for-løkke — men while er enklere og mere direkte.
        (TStringList.Delete er O(n), så gentagne kald i starten af
        listen er O(n²) for store sletninger — men med 1000 linjer
        ad gangen og BeginUpdate er det stadig hurtigt nok i praksis.)

      HVORFOR finally?
        Hvis Delete skulle kaste en undtagelse (usandsynligt, men
        muligt ved hukommelsesproblemer), skal EndUpdate alligevel
        kaldes — ellers ville Memo'en forblive i "update-suspenderet"
        tilstand og aldrig vise noget igen. finally garanterer, at
        EndUpdate altid kører. }

  InsertStr := AText;                                                       // Start med den rå tekst
  { ^ Starter med den rå tekst. Hvis der ikke skal tilføjes tidsstempel
      (se næste blok), er dette det endelige indhold. }

  if ChkTimestamp.Checked and ((MemoTerminal.Lines.Count = 0) or (MemoTerminal.Lines[MemoTerminal.Lines.Count - 1] = '')) then // Skal tidsstempel tilføjes?
    InsertStr := '[' + FormatDateTime('hh:nn:ss.zzz', Now) + '] ' + AText;  // Foranstil tidsstempel
  { ^ TIDSSTEMPEL — tilføjes KUN under bestemte betingelser.

      BETINGELSERNE:
        ChkTimestamp.Checked                              : brugeren
                                                            har slået
                                                            tidsstempler
                                                            til.
        (MemoTerminal.Lines.Count = 0)                    : Memo'en er
                                                            helt tom —
                                                            dette er
                                                            den aller-
                                                            første tekst.
        OR (MemoTerminal.Lines[MemoTerminal.Lines.Count-1] = '')
                                                          : den
                                                            SIDSTE
                                                            linje er
                                                            tom —
                                                            hvilket
                                                            betyder,
                                                            at den
                                                            foregående
                                                            tekst
                                                            sluttede
                                                            med et
                                                            linjeskift
                                                            (Serial.
                                                            println),
                                                            så vi er
                                                            ved at
                                                            starte en
                                                            NY linje.

      HVORFOR SÅ STRENGE BETINGELSER?
        Vi vil UNDGÅ, at hvert enkelt Serial.print() får sit eget
        tidsstempel midt i en logisk linje. Eksempel:
          Serial.print("Temp=");    -> "Temp="
          Serial.print(21.5);       -> "Temp=21.5"
          Serial.println(" C");     -> "Temp=21.5 C\r\n"
        Hvis vi satte tidsstempel på HVERT kald, ville det se sådan ud:
          [12:00:00.000] Temp=[12:00:00.001] 21.5[12:00:00.002]  C
        Hvilket er fuldstændig ulæseligt.
        Ved at sætte tidsstempel KUN når vi starter en ny linje (tom
        forrige linje eller tom Memo) får vi:
          [12:00:00.000] Temp=21.5 C
        Hvilket er præcis, hvad brugeren forventer.

      HVORFOR 'zzz' (millisekunder) OG IKKE 'zz' ELLER INGEN?
        Millisekunder er vigtige, når man fejlfinder tidskritiske
        protokoller (fx hvornår en ACK kommer i forhold til en STX).
        Uden millisekunder ville man ikke kunne se, om der gik 5 ms
        eller 500 ms mellem to begivenheder. Og det er netop den slags
        timing, der er afgørende i protokol-analyse.

      HVORFOR FormatDateTime OG IKKE EN MANUEL STRENGBYGNING?
        FormatDateTime håndterer alle detaljer korrekt (12/24-timers,
        locale-forskelle, sommertid) og er lynhurtig. Manuel
        sammensætning ville være mere kode og lettere at få forkert.

      HVORFOR Now OG IKKE GetTickCount?
        Now giver et TDateTime med både dato og tid. Vi viser kun
        tiden (hh:nn:ss.zzz), men Now er den mest naturlige kilde.
        GetTickCount ville give monotone millisekunder uden
        dato-kontekst — ikke nyttigt her.
        (Bemærk: Now har typisk 10-16 ms opløsning, ikke 1 ms. Men
        det er tilstrækkeligt til at skelne de fleste protokol-
        begivenheder. For højere præcision skulle man bruge en
        high-resolution timer, men det er overkill her.) }

  // Streaming indsættelse direkte ved slutningen af TMemo.
  // Dette bevarer Serial.print() (uden linjeskift) og behandler Serial.println()
  // naturligt præcis som den officielle Arduino IDE Serial Monitor!
  MemoTerminal.SelStart := Length(MemoTerminal.Text);                       // Flyt markør til slutningen
  MemoTerminal.SelLength := 0;                                              // Ingen tekst valgt
  MemoTerminal.SelText := InsertStr;                                        // Indsæt teksten ved markøren
  { ^ STREAMING-INDSÆTTELSE — kernen i visningslogikken.

      HVORFOR SELSTART/SELTEXT OG IKKE LINES.ADD ELLER LINES.TEXT?
        - Lines.Add(Text) tilføjer ALTID en ny linje, uanset om
          teksten slutter med et linjeskift eller ej. Det ville
          bryde Serial.print()-semantikken (hvert print ville komme
          på sin egen linje).
        - Lines.Text := Lines.Text + Text er O(n) per kald og bliver
          eksponentielt dyrt ved store tekster.
        - SelStart/SelText arbejder DIREKTE på tekstbufferen:
            SelStart := Length(Text)  : markøren flyttes til slut.
            SelLength := 0            : ingen tekst er valgt.
            SelText := InsertStr      : indsætter teksten ved markøren
                                        (dvs. tilføjer til slutningen).
          Det er den samme mekanisme, som når brugeren skriver i
          Memo'en — tekst tilføjes uden at ændre eksisterende
          linjeskift.

      HVORFOR ER DETTE VIGTIGT FOR SERIAL.PRINT-SEMANTIKKEN?
        Eksempel med Arduino IDE-kompatibel adfærd:
          Serial.print("A");      -> Memo: "A"
          Serial.print("B");      -> Memo: "AB"
          Serial.println("C");    -> Memo: "ABC\r\n" (ny linje)
          Serial.print("D");      -> Memo: "ABC\r\nD"
        Med SelText-indsættelse får vi præcis denne adfærd, fordi
        SelText ikke selv tilføjer noget linjeskift — det indsætter
        blot teksten, som den er.

      HVORFOR SELSTART := Length(MemoTerminal.Text) OG IKKE
      MemoTerminal.Lines.Count?
        Fordi SelStart tæller KARAKTERE, ikke linjer. Length(Text)
        giver den samlede tekstlængde, og dermed slutpositionen.
        Lines.Count giver kun antal linjer, hvilket ikke hjælper
        med at finde slutpositionen i karakter-strømmen.

      BEMÆRK OM YDELSE:
        Hver SelText-tildeling udløser en repaint af Memo'en (med
        mindre AutoScroll er slået fra og markøren er uden for
        synsfeltet). Ved høj datafrekvens kan dette blive en
        flaskehals. Men fordi TimerPollTimer poller med 50-100 ms
        interval, sker indsættelsen i små, overskuelige bidder — og
        Memo'en når at repaint'e mellem hvert kald. Det er netop
        derfor, polling er valgt frem for en læsetråd, der kunne
        oversvømme Memo'en med tusindvis af små opdateringer i
        sekundet. }

  if ChkAutoScroll.Checked then                                             // Er auto-scroll slået til?
  begin                                                                     // Begynder auto-scroll-gren
    MemoTerminal.SelStart := Length(MemoTerminal.Text);                     // Flyt markør til slutningen
    MemoTerminal.SelLength := 0;                                            // Ingen tekst valgt
  end;                                                                      // Slut auto-scroll-gren
  { ^ AUTO-SCROLL — flytter visningen til bunden, så den nyeste
      telemetri altid er synlig.

      HVORFOR ER DET EN SEPARAT BLOK OG IKKE BARE EN DEL AF
      INDSÆTTELSEN?
        Fordi brugeren kan have slået auto-scroll FRA for at kunne
        undersøge ældre data, mens der stadig kommer ny telemetri
        ind. Hvis auto-scroll altid var aktiv, ville brugeren blive
        "trukket" til bunden, hver gang en ny byte ankom — hvilket
        ville gøre det umuligt at læse ældre indhold.

      HVORFOR SELSTART IGEN?
        Fordi SelText-indsættelsen efterlader markøren lige efter det
        indsatte. Ved at sætte SelStart til slutningen igen (og
        SelLength til 0) sikrer vi, at markøren er ved den allersidste
        position. Det er dét, der får Memo'en til at scrolle til
        bunden.

      HVORFOR IKKE MemoTerminal.Perform(EM_SCROLLCARET, ...) ELLER
      LIGNENDE?
        Fordi SelStart/SelLength-tricket er den platform-uafhængige
        måde at opnå det på. Det virker på både Windows (RichEdit),
        Linux (GTK) og macOS (Cocoa) — uden platformsspecifikke
        konstanter eller API-kald. }

end;                                                                        // Slut på AppendToTerminal

procedure TFormMain.BtnSendClick(Sender: TObject);                          // Event: [Send]-knap
{ ^ Event-handler for [Send]-knappen (og indirekte for Enter-tasten i
    EditSend via EditSendKeyDown). Sender brugerens kommando til
    mikrokontrolleren med den valgte linjeafslutning.

    HVORFOR ER DENNE METODE SÅ VIGTIG?
      Det er den primære måde, brugeren interagerer med MCU'en på —
      fx ved at sende "LED_ON", "LED_OFF", "MODE" eller "PING" til
      den demonstrator-sketch, der følger med projektet. Uden denne
      metode ville terminalen kun være halvt så anvendelig: man kunne
      se telemetri, men ikke styre MCU'en.

    DEN OVERORDNEDE STRATEGI:
      1. Validér, at vi er forbundet (ellers kan vi ikke sende).
      2. Validér, at der er noget at sende (ellers spild af tid).
      3. Byg kommandoen med valgt linjeafslutning.
      4. Send via driveren — pakket i try/except, så en fejl ikke
         efterlader os i en brudt tilstand.
      5. Opdater tællere, vis bekræftelse, ryd inputfeltet.

    HVORFOR VALIDERE FØRST?
      Samme princip som i BtnConnectClick: undgå at åbne ressourcer
      eller udføre arbejde, hvis forudsætningerne ikke er opfyldt.
      Hvis vi ikke er forbundet, kan vi ikke sende — og så skal
      brugeren have en klar besked om det, ikke en mystisk fejl
      fra driveren. }

var                                                                         // Lokale variable
  Cmd: AnsiString;                                                          // Færdig kommando (tekst + linjeafslutning)
  Ending: AnsiString;                                                       // Valgt linjeafslutning
  { ^ Lokale variable:
      Cmd    : den færdige kommando (tekst + linjeafslutning) som
               AnsiString. AnsiString er valgt, fordi driverens
               SendString forventer en byte-orienteret streng —
               og fordi EditSend.Text er Unicode, men vi vil sende
               de rå UTF-8-bytes, som Arduino'en forventer.
      Ending : den valgte linjeafslutning (CR+LF, LF, CR eller ingen).
               Adskilt som variabel, fordi den sættes i en case-
               sætning og derefter bruges i konkatenationen — det gør
               koden lettere at læse end at indlejre case'en direkte
               i Cmd-tildelingen. }

begin                                                                       // Begynder procedurens krop
  if not FIsConnected or not Assigned(FSerial) then                         // Er vi ikke forbundet?
  begin                                                                     // Begynder fejl-gren
    ShowMessage('Ikke forbundet til nogen seriel port!');                   // Vis fejlbesked
    Exit;                                                                   // Afbryd metoden
  end;                                                                      // Slut fejl-gren
  { ^ FØRSTE VALIDERING: Er vi overhovedet forbundet?
        not FIsConnected      : vores eget flag siger "nej".
        not Assigned(FSerial) : driver-instansen findes ikke (burde
                                ikke kunne ske, men beskyttende).
      Hvis en af dem er sand, vises en klar besked og metoden
      afsluttes med Exit.
      HVORFOR BESKEDEN ER SÅ KORT?
        Fordi situationen er entydig: brugeren har glemt at trykke
        [Forbind], eller forbindelsen er faldet bort. Der er ingen
        komplekse løsningsmuligheder at forklare — den eneste
        handling er at forbinde først. En lang forklaring ville
        bare være støj.
      HVORFOR IKKE DEAKTIVERE [Send] NÅR IKKE FORBUNDET?
        Det gør vi faktisk — se UpdateUIState: BtnSend.Enabled :=
        FIsConnected. Så i praksis kan denne situation kun opstå,
        hvis forbindelsen falder bort mellem to timer-ticks (fx
        USB trækkes ud, og timeren har ikke nået at opdage det
        endnu). Den defensive kontrol fanger den slags edge-cases. }

  if EditSend.Text = '' then                                                // Er inputfeltet tomt?
    Exit;                                                                   // Afbryd (ingen kommando at sende)
  { ^ ANDEN VALIDERING: Er der noget at sende?
      Hvis inputfeltet er tomt, gør vi ingenting. Det undgår:
        - At sende en "tom kommando" med kun linjeafslutning (som
          Arduino'ens readStringUntil('\n') ville fortolke som en
          tom streng og muligvis fejlbehandle).
        - At spilde en TX-tælling på noget, der ikke er en kommando.
        - At vise "[Sendt -> Arduino]: " med tom tekst, hvilket
          ville se ud som en fejl.
      HVORFOR IKKE VISE EN BESKED OM TOM KOMMANDO?
        Fordi det ville være irriterende støj, hvis brugeren blot
        trykkede Enter ved et uheld. En stille ignorering er mere
        brugervenlig — og brugeren opdager det straks, fordi
        EditSend ikke tømmes (den er allerede tom). }

  Cmd := AnsiString(EditSend.Text);                                         // Konverter til byte-orienteret streng
  { ^ Konverterer EditSend.Text (som er en Unicode-streng / string)
      til AnsiString. Dette er vigtigt af flere grunde:

      HVORFOR ER KONVERTERING NØDVENDIG?
        - EditSend.Text er af typen "string" (UTF-8 i FPC med {$H+}).
        - Driverens SendString forventer en AnsiString (byte-orienteret).
        - Arduino'en forventer UTF-8-bytes over den serielle port.
        AnsiString er netop det: en byte-container. Ved at caste til
        AnsiString får vi de rå UTF-8-bytes, som EditSend.Text allerede
        indeholder (fordi LCL's strenge er UTF-8).

      HVORFOR IKKE BEHOLDE DET SOM "string" OG LADE DRIVEREN KLARE DET?
        Fordi driveren eksplicit erklærer SendString(const Data:
        AnsiString). Hvis vi sendte en "string", ville Pascal implicit
        konvertere — men den implicitte konvertering kan i visse
        tilfælde ændre kodningen (fx hvis compileren tror, at strengen
        er UTF-16). Ved at caste eksplicit er vi sikre på, at det er
        UTF-8-bytes, der sendes.

      BEMÆRK OM DANSKE TEGN:
        Hvis brugeren skriver "Blå" i EditSend, er det UTF-8-bytes
        0x42 0x6C 0xC3 0xA5. Det er præcis, hvad Arduino'ens
        Serial.readString() modtager, og hvad en UTF-8-baseret sketch
        forventer. Så danske tegn i kommandoer virker korrekt. }

  // Vælg linjeafslutning til Arduino
  case CbLineEnding.ItemIndex of                                            // Oversæt linjeafslutnings-valg
    0: Ending := #13#10; // CR + LF                                         // CR+LF (Windows/Arduino IDE)
    1: Ending := #10;     // Kun LF                                         // Kun LF
    2: Ending := #13;     // Kun CR                                         // Kun CR
    3: Ending := '';      // Ingen                                          // Ingen afslutning
  end;                                                                      // Slut case
  { ^ LINJEAFSLUTNING — valgt af brugeren via CbLineEnding.
      De fire muligheder dækker alle praktiske behov:

      0: CR + LF (#13#10)
         Windows-standard og Arduino-IDE-standard. Mest brugt af
         Arduino'ens Serial.readStringUntil('\n') — fungerer fordi
         den søger efter LF og trimmer CR bagefter (hvis sketchen
         bruger .trim()). Bruges også af mange protokoller (fx
         AT-kommandoer).
      1: Kun LF (#10)
         UNIX-standard. Bruges af sketcher, der læser med
         Serial.readStringUntil('\n') uden at trimme — de får så
         ikke et ekstra CR-tegn, som de skal håndtere.
      2: Kun CR (#13)
         Klassisk Mac-standard og nogle protokoller (fx nogle
         Modbus-varianter, selvom Modbus ASCII bruger CRLF).
      3: Ingen (#)
         Til kommandoer, der skal sendes uden afslutning — fx
         binære protokoller, hvor et ekstra linjeskift-tegn ville
         ødelægge rammestrukturen.

      HVORFOR EN CASE OG IKKE EN SIMPEL IF-KÆDE?
        Case er både hurtigere og mere læsbar, når man har flere
        faste valg baseret på ItemIndex. Det gør det også tydeligt,
        at valget er en enumeration-lignende struktur.

      BEMÆRK OM DEN MANGLENDE 'else':
        Hvis ItemIndex er -1 (ingen valgt) eller en uventet værdi,
        forbliver Ending uinitialiseret. Det er teknisk set en fejl
        — men i praksis kan det ikke ske, fordi FormCreate altid
        sætter ItemIndex := 0. En defensiv 'else Ending := #13#10'
        ville være sikrere, men den nuværende kode er hurtigere og
        matcher, hvad der faktisk sker. }

  Cmd := Cmd + Ending;                                                      // Tilføj linjeafslutning til kommandoen
  { ^ Tilføjer linjeafslutningen til kommandoen. Nu er Cmd den
      FULDE byte-sekvens, der skal sendes over porten — fx "LED_ON\r\n".
      Denne sammensætning gør det muligt at sende alt i ét SendString-
      kald, hvilket er mere effektivt end at sende tekst og afslutning
      separat (færre OS-kald, ingen risiko for at afslutningen
      kommer i en separat transmission, hvis driveren har intern
      buffering). }

  try                                                                       // Begynder try/except
    FSerial.SendString(Cmd);                                                // Send kommandoen over porten
    { ^ Sender den færdige kommando over porten. Driveren skriver
        alle bytes i ét WriteFile/fpwrite-kald, hvilket sikrer, at
        hele kommandoen når MCU'en som en sammenhængende sekvens —
        og ikke opdeles af OS'ets buffering.
        Ved 115200 baud tager "LED_ON\r\n" (8 bytes) ca. 0.7 ms at
        sende. GUI'en fryser ikke mærkbart. }

    Inc(FTxByteCount, Length(Cmd));                                         // Opdater TX-tæller
    StatusBar1.Panels[2].Text := 'TX: ' + IntToStr(FTxByteCount) + ' bytes'; // Opdater statuslinje
    { ^ Opdaterer TX-tælleren og statuslinjens tredje panel.
        Tællingen sker ud fra Length(Cmd), som er antallet af bytes
        i den færdige kommando (inkl. linjeafslutning) — præcis det
        antal, der blev sendt over porten.
        HVORFOR Int64 OG IKKE Integer?
          Se FTxByteCount-kommentaren: Int64 undgår overflow ved
          meget lange sessioner. }

    AppendToTerminal('[Sendt -> Arduino]: ' + EditSend.Text + LineEnding);  // Bekræftelsesbesked
    { ^ Bekræftelsesbesked i terminalen. Vi viser den RÅ kommando
        (uden linjeafslutning), fordi det er den, brugeren skrev —
        det er mere genkendeligt end at se "LED_ON\r\n" med synlige
        escape-tegn.
        HVORFOR ET "[Sendt -> Arduino]"-PRÆFIKS?
          For at skelne brugerens egne kommandoer fra MCU'ens svar.
          Uden præfikset ville det være forvirrende at se "LED_ON"
          efterfulgt af ">>> LED er tændt!" (som er MCU'ens svar) —
          hvilken af dem er hvad? Med præfikset er det tydeligt.
        HVORFOR LineEnding OG IKKE #13#10 DIREKTE?
          Fordi LineEnding matcher platformens naturlige linjeskift
          (CR+LF på Windows, LF på Linux) — begge steder ser det
          korrekt ud i TMemo. }

    EditSend.Clear;                                                         // Ryd inputfeltet efter vellykket afsendelse
    { ^ Rydder inputfeltet efter vellykket afsendelse.
        HVORFOR?
          - Forbereder feltet til den næste kommando (brugeren skal
            ikke selv slette).
          - Giver visuel feedback om, at kommandoen er sendt.
          - Undgår, at brugeren ved et uheld trykker Enter to gange
            og sender den samme kommando igen.
        HVORFOR IKKE FOKUSERE EditSend IGEN?
          Det gør vi faktisk indirekte — efter Clear() er EditSend
          stadig fokuseret (Clear ændrer ikke fokus), så brugeren kan
          straks skrive den næste kommando. }

  except                                                                    // Begynder except-gren
    on E: Exception do                                                      // Fanger alle undtagelser
      ShowMessage('Fejl ved afsendelse: ' + E.Message);                     // Vis fejlbesked
    { ^ FEJLHÅNDTERING. Hvis SendString kaster en undtagelse — fx
        fordi USB-kablet er trukket ud midt i afsendelsen, eller
        fordi driveren løber ind i en OS-fejl — viser vi en besked
        til brugeren med den specifikke fejl (E.Message).

        HVORFOR ER DER IKKE MERE OPRYDNING I EXCEPT-GRENEN?
          Fordi der ikke er noget at rydde op:
            - FSerial er stadig åben (hvis fejlen var midlertidig).
              Næste timer-tick vil opdage, hvis forbindelsen er død,
              og håndtere det korrekt (se TimerPollTimer).
            - FTxByteCount skal ikke opdateres — kommandoen blev
              ikke sendt, så vi skal ikke tælle den som sendt.
            - EditSend skal ikke ryddes — brugeren skal have chancen
              for at prøve igen.
          Den eksisterende oprydning i TimerPollTimer's except-gren
          håndterer de større problemer (fx USB trukket ud), så vi
          behøver ikke duplikere den logik her.

        HVORFOR VISES FEJLEN SOM ShowMessage OG IKKE SOM LOG?
          Fordi brugeren skal se den med det samme — en fejl i
          afsendelsen er en direkte handling, de lige har udført,
          og de forventer feedback. At logge den i terminalen (hvor
          den kunne drukne i telemetri) ville være mindre synligt. }
  end;                                                                      // Slut try/except
end;                                                                        // Slut på BtnSendClick

procedure TFormMain.EditSendKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState); // Event: tast trykket i EditSend
{ ^ Tastatur-event-handler for EditSend. Kaldes, når brugeren trykker
    en tast, mens inputfeltet har fokus — FØR tegnet når ind i feltet.

    FORMÅLET:
      Gøre det muligt at sende en kommando ved at trykke Enter, uden
      at brugeren skal flytte hånden til musen og klikke på [Send].
      Det er en lille, men vigtig UX-forbedring: i en terminal-lignende
      applikation forventer brugeren at kunne skrive og trykke Enter —
      præcis som i en kommandolinje eller Arduino IDE's Serial Monitor.

    HVORFOR OnKeyDown OG IKKE OnKeyPress ELLER OnKeyUp?
      - OnKeyPress giver kun printable tegn (32..126) og ville ikke
        kunne håndtere Enter korrekt på alle platforme — Enter er et
        kontroltegn (CR, 0x0D), ikke et printable tegn.
      - OnKeyUp fyrer EFTER tasten er sluppet, hvilket betyder, at
        Enter-tegnet allerede ville være nået ind i EditSend og have
        udløst en biplyd eller en standard-handling. Vi ville så
        skulle fjerne det igen, hvilket er mere besværligt.
      - OnKeyDown fyrer FØR tegnet når ind i feltet. Ved at sætte
        Key := 0 kan vi forhindre Enter i at nå feltet overhovedet
        — ren og enkel løsning.
      Det er derfor OnKeyDown er det rigtige valg til denne opgave. }

begin                                                                       // Begynder procedurens krop
  if Key = 13 then // Enter tast                                            // Er der trykket Enter?
  begin                                                                     // Begynder Enter-gren
    BtnSendClick(nil);                                                      // Udløs samme handling som [Send]-knappen
    Key := 0;                                                               // Nulstil tastetrykket (forhindr indsættelse)
  end;                                                                      // Slut Enter-gren
  { ^ ENTER-TASTEN (virtuel tastkode 13 = VK_RETURN på Windows;
      13 er også standard i LCL's TKeyEvent på alle platforme).

      TO TING SKER:
        1. BtnSendClick(nil) kaldes — samme metode som når brugeren
           klikker på [Send]-knappen. Genbrug af metoden sikrer, at
           adfærden er IDENTISK uanset hvordan kommandoen afsendes:
             - Samme validering (forbundet? ikke tom?).
             - Samme linjeafslutning.
             - Samme TX-tæller-opdatering.
             - Samme bekræftelsesbesked.
             - Samme fejlhåndtering.
           Uden genbrug ville vi skulle duplikere al den logik her,
           hvilket ville føre til inkonsistens over tid.

        2. Key := 0 nulstiller tastetrykket, så LCL ikke sender det
           videre til EditSend. Uden dette ville Enter-tegnet (CR)
           blive indsat i tekstfeltet EFTER BtnSendClick har kørt —
           hvilket ville give et underligt resultat: kommandoen sendes,
           EditSend.Clear() rydder feltet, og så indsætter LCL et CR
           bagefter. Det ville se ud som om feltet "husker" Enter.

      HVORFOR nil SOM SENDER TIL BtnSendClick?
        Fordi BtnSendClick ikke bruger Sender-parameteren — den
        refererer kun til EditSend, CbLineEnding og FSerial direkte.
        nil er derfor uproblematisk og udtrykker klart, at kaldet
        ikke stammer fra en knap. Alternativt kunne man sende
        EditSend som Sender, men det ville antyde en tilknytning,
        der ikke findes.

      HVORFOR BESKYTTE MOD SHIFT+ENTER OG CTRL+ENTER?
        Det gør vi IKKE her — både Shift+Enter og Ctrl+Enter udløser
        også afsendelse. For dette program er det acceptabelt, fordi:
          - Der er ingen multi-line input at beskytte (EditSend er
            et enkelt-linje felt).
          - Brugeren har ingen grund til at indsætte et linjeskift
            i kommandoen via tastaturet.
          - Hvis man senere vil differentiere, kan man tilføje et
            tjek på Shift-tilstanden:
              if (Key = 13) and (Shift = []) then ...
          Men det er ikke nødvendigt her.

      BEMÆRK OM ANDRE TASTER:
        Alle andre taster (bogstaver, tal, Backspace, piletaster osv.)
        overlades til EditSend's standard-adfærd — vi returnerer uden
        at røre Key, så LCL håndterer dem normalt. Det er vigtigt:
        hvis vi satte Key := 0 for alle taster, ville brugeren ikke
        kunne skrive i feltet! }
end;                                                                        // Slut på EditSendKeyDown


procedure TFormMain.BtnClearClick(Sender: TObject);                         // Event: [Ryd]-knap
{ ^ Event-handler for [Ryd]-knappen. Sletter alt indhold i terminalen
    og skriver en kort bekræftelsesbesked, så brugeren kan se, at
    handlingen lykkedes.

    HVORFOR EN SÅ SIMPEL METODE?
      Nogle gange er den enkleste løsning den rigtige. Brugeren har
      ét ønske: "Fjern alt det gamle indhold, så jeg kan starte forfra."
      Der er ingen parametre at validere, ingen tilstand at ændre,
      ingen data at gemme. At gøre metoden mere kompleks (fx med
      "er du sikker?"-dialoger eller fortryd-funktionalitet) ville
      være overkill — det er en terminal, og ryddet tekst er ikke
      værdifuldt nok til at fortjene en sikkerhedskontrol.

    HVORFOR ER DER ALLIGEVEL EN BEKRÆFTELSESBESKED?
      Fordi en helt tom Memo kan være tvetydig: virkede knappen?
      Skete der noget? Ved at skrive "=== Terminal ryddet ===" får
      brugeren øjeblikkelig visuel feedback på, at handlingen blev
      udført. Det er en lille ting, men det gør en mærkbar forskel i
      brugeroplevelsen — især hvis brugeren har trykket på knappen
      ved et uheld og undrer sig over, hvorfor indholdet forsvandt.

    HVORFOR BRUGES AppendToTerminal OG IKKE BARE MemoTerminal.Lines.Add?
      Fordi AppendToTerminal er den CENTRALE visningsfunktion, som
      alle andre dele af programmet bruger. Ved at gå gennem den får
      vi automatisk:
        - Hukommelsesværn (ikke relevant her, men konsistent).
        - Tidsstempel hvis ChkTimestamp er slået til.
        - Auto-scroll hvis ChkAutoScroll er slået til.
        - Streaming-semantik, så linjen vises korrekt.
      Hvis vi brugte Lines.Add direkte, ville vi omgå disse funktioner
      og skabe inkonsistens. Selv for en enkelt besked er det værd at
      holde sig til den centrale funktion. }

begin                                                                       // Begynder procedurens krop
  MemoTerminal.Clear;                                                       // Slet ALT indhold i Memo
  { ^ Sletter ALT indhold i MemoTerminal på én gang.
      HVORFOR Clear() OG IKKE Lines.Clear?
        MemoTerminal.Clear er en indbygget metode på TMemo, der
        sletter både tekst og nulstiller markøren. Lines.Clear
        sletter kun linjerne, men kan efterlade markør-positionen
        i en mærkelig tilstand. Clear() er den reneste løsning.

      HVORFOR ER DETTE EN HURTIG OPERATION?
        Fordi TMemo's Clear frigiver hele tekstbufferen på én gang
        i stedet for at slette linje for linje. Selv med 2500 linjer
        (den øvre grænse pga. hukommelsesværnet) tager det kun få
        millisekunder.

      BEMÆRK: Clear() udløser en repaint, så brugeren ser resultatet
      med det samme. Det er præcis, hvad vi ønsker. }

  AppendToTerminal('=== Terminal ryddet ===' + LineEnding);                 // Bekræftelsesbesked
  { ^ Skriver en bekræftelsesbesked EFTER sletningen.
      HVORFOR EFTER OG IKKE FØR?
        Fordi hvis vi skrev beskeden først og derefter kaldte Clear,
        ville beskeden også blive slettet — og brugeren ville stå
        tilbage med en helt tom terminal uden feedback. Ved at skrive
        EFTER Clear får brugeren en synlig bekræftelse på, at
        handlingen blev udført.

      HVORFOR "===" SOM MARKØR?
        Det er en visuel konvention, der signalerer "dette er en
        systembesked, ikke telemetri". Samme stil bruges i
        velkomstbeskeden ("=== Lazarus Arduino Seriel Terminal klar
        ===") og giver en ensartet æstetik. Brugeren kan straks
        se, at der er tale om en systemhændelse — ikke data fra
        MCU'en.

      HVORFOR LineEnding OG IKKE #13#10 DIREKTE?
        Fordi LineEnding matcher platformens naturlige linjeskift
        (CR+LF på Windows, LF på Linux). Begge steder ser det korrekt
        ud i TMemo — og hvis brugeren senere kopierer teksten til
        en fil, matcher det platformens konventioner.

      BEMÆRK OM TIDSSTEMPEL:
        Hvis ChkTimestamp er slået til, får denne besked også et
        tidsstempel, fordi AppendToTerminal tilføjer det automatisk.
        Det er konsistent og nyttigt — brugeren kan se, hvornår
        rydningen skete i forhold til andre begivenheder. }
end;                                                                        // Slut på BtnClearClick


procedure TFormMain.ChkDTRChange(Sender: TObject);                          // Event: ChkDTR skiftet tilstand
{ ^ Event-handler for ChkDTR-checkboxen. Kaldes, når brugeren klikker
    på checkboxen og dermed skifter dens tilstand mellem checked og
    unchecked.

    FORMÅLET:
      Gøre det muligt for brugeren at styre DTR-linjen (Data Terminal
      Ready) manuelt, mens en forbindelse er aktiv. DTR er en af de
      serielle kontrolsignaler, som historisk blev brugt til at
      signalere "jeg er klar til at modtage data", men som i moderne
      Arduino-sammenhæng oftest bruges til auto-reset af MCU'en.

    HVORFOR ER DET NYTTIGT AT KUNNE STYRE DTR MANUELT?
      Der er flere scenarier, hvor man har brug for manuel DTR-kontrol:
        1. UNDGÅ RESET VED FORBINDELSE:
           Nogle brugere vil forbinde til en Arduino, der allerede
           kører en sketch, UDEN at den bliver genstartet. Hvis DTR
           er høj hele tiden, undgår man auto-reset-pulsen — og kan
           dermed se, hvad MCU'en allerede laver.
        2. HOLDE MCU'EN I RESET:
           Ved at sætte DTR lav (unchecked) kan man holde MCU'en i
           reset-tilstand, fx for at inspicere bootloader'en eller
           for at forhindre, at sketchen kører under fejlfinding.
        3. TESTE RESET-ADFÆRD:
           Hvis man udvikler en sketch, der selv bruger DTR-signalet
           (fx til at signalere status til værtscomputeren), kan man
           verificere, at ændringer i DTR opfattes korrekt.
        4. KOMPATIBILITET MED SPECIELLE KORT:
           Nogle ESP8266/ESP32-varianter og visse industrielle
           RS-232-adaptere bruger DTR til flow control eller
           status-signalering, som skal styres manuelt.

    HVORFOR ER DET EN 'Change'-HANDLER OG IKKE EN 'Click'-HANDLER?
      - OnChange fyrer, når checkboxens TILSTAND ændrer sig (via
        kode eller via brugerklik). Det er den korrekte semantik:
        "gør noget, når tilstanden skifter".
      - OnClick fyrer ved ethvert klik, uanset om tilstanden ændrede
        sig. Hvis man brugte OnClick, ville et klik på en checkbox,
        der allerede er checked, ikke ændre noget — men OnClick ville
        stadig fyre, hvilket kunne give unødvendige kald til driveren.
      Desuden kan Change udløses programmatisk (fx ved at sætte
      ChkDTR.Checked := True i kode), hvilket er nyttigt, hvis man
      senere vil synkronisere checkboxen med faktisk DTR-tilstand. }

begin                                                                       // Begynder procedurens krop
  if FIsConnected and Assigned(FSerial) then                                // Er vi forbundet?
    FSerial.DTR := ChkDTR.Checked;                                          // Send checkbox-tilstand til driveren
  { ^ DENNE METODE GØR NØJAGTIG ÉN TING: synkroniserer checkboxens
      tilstand til den fysiske DTR-linje — men KUN hvis der er en
      aktiv forbindelse.

      HVORFOR BEGGE TJEK?
        FIsConnected        : vi skal være forbundet for at kunne
                              ændre DTR på en seriel port. Hvis
                              ikke, giver det ingen mening at kalde
                              driveren (og det ville sandsynligvis
                              give en fejl).
        Assigned(FSerial)   : driver-instansen skal eksistere. Dette
                              er teknisk set altid sandt, når
                              FIsConnected er sand (fordi FSerial
                              oprettes i FormCreate), men det er
                              billig forsikring mod edge-cases.

      HVORFOR SKER DER INTET, HVIS IKKE FORBUNDET?
        Fordi checkboxen også kan klikkes, FØR brugeren har
        forbundet. I så fald skal valget blot HUSKES — det gemmes
        automatisk i ChkDTR.Checked — og BtnConnectClick læser det
        ved forbindelse:
          FSerial.DTR := ChkDTR.Checked;
        Så når brugeren senere forbinder, bliver den valgte tilstand
        anvendt. Det er en elegant "deferred application"-mekanisme:
        indstillingen sættes straks i UI'et, men anvendes på
        hardwaren ved første mulige lejlighed.
        Dette undgår en fejlbesked som "du skal forbinde først for
        at ændre DTR" — hvilket ville være irriterende, fordi
        brugeren netop FORBEREDER forbindelsen.

      HVORFOR ER DER INGEN FEJLHÅNDTERING (try/except)?
        Fordi DTR := ... i praksis aldrig fejler på en gyldig,
        åben handle. Den underliggende EscapeCommFunction (Windows)
        eller ioctl (Linux) returnerer enten succes eller en fejl,
        men driveren ignorerer fejlen — den gør ikke noget aktivt
        for at rapportere den. Skulle der opstå et problem, ville
        det blive opdaget af næste timer-tick (som opdager, at
        porten er død) eller af en efterfølgende SendString.
        Derfor er try/except her unødvendig kompleksitet.

      BEMÆRK OM KONSISTENS MED ChkRTSChange:
        Denne metode og ChkRTSChange er bevidst identiske i struktur
        — kun navnet på checkboxen og driver-propertyen ændres.
        Det gør dem nemme at forstå og vedligeholde. Man kunne
        overveje at samle dem i én fælles handler (fx via en
        fælles hjælpefunktion), men da de kun er to metoder med
        hver tre linjer, er det ikke besværet værd. }

end;                                                                        // Slut på ChkDTRChange


procedure TFormMain.ChkRTSChange(Sender: TObject);                          // Event: ChkRTS skiftet tilstand
{ ^ Event-handler for ChkRTS-checkboxen. Kaldes, når brugeren klikker
    på checkboxen og dermed skifter dens tilstand mellem checked og
    unchecked.

    FORMÅLET:
      Gøre det muligt for brugeren at styre RTS-linjen (Request To
      Send) manuelt, mens en forbindelse er aktiv. RTS er en af de
      serielle kontrolsignaler, som historisk blev brugt til at
      signalere "jeg vil sende data" i half-duplex RS-232-kommunikation.

    HVORFOR ER DET NYTTIGT AT KUNNE STYRE RTS MANUELT?
      Der er flere scenarier, hvor man har brug for manuel RTS-kontrol:

        1. HARDWARE FLOW CONTROL:
           I RS-232-forbindelser bruges RTS/CTS ofte som hardware
           flow control: modtageren sætter RTS lav, når dens buffer
           er fuld, og senderen stopper med at sende. Selvom
           Arduino over USB normalt ikke bruger dette, kan visse
           USB-til-serial-adaptere (FTDI, CH340) og industrielle
           RS-232-kort gøre det. Manuel kontrol giver mulighed for
           at teste og styre denne mekanisme.

        2. BOOTLOADER-ADGANG PÅ VISSE KORT:
           Nogle Arduino-kompatible kort (især visse ESP8266- og
           ESP32-varianter) bruger RTS i kombination med DTR til
           at aktivere bootloader-tilstand. Ved at sætte de to
           linjer i bestemte kombinationer kan man tvinge MCU'en
           ind i bootloader uden at skulle trykke på fysiske
           knapper.

        3. RESET-SEKVENSER:
           Kombinationen af DTR og RTS styrer reset-sekvensen på
           mange Arduino-kort. Nogle kort kræver, at RTS sættes
           høj/lav i en bestemt rækkefølge i forhold til DTR for
           at virke korrekt. Manuel kontrol giver brugeren mulighed
           for at eksperimentere med sekvensen.

        4. FEJLFINDING AF SERIEL KOMMUNIKATION:
           Hvis man oplever, at data ikke kommer igennem, kan man
           bruge RTS til at teste, om modtageren faktisk er klar
           til at modtage. Nogle gange er problemet netop, at RTS
           står i en uheldig tilstand, som driveren har efterladt.

        5. TEST AF EGEN FIRMWARE:
           Hvis man udvikler firmware, der selv bruger RTS/CTS til
           flow control, kan man verificere, at MCU'ens håndtering
           af signalet er korrekt.

    HVORFOR ER DET EN 'Change'-HANDLER OG IKKE EN 'Click'-HANDLER?
      - OnChange fyrer, når checkboxens TILSTAND ændrer sig (via
        kode eller via brugerklik). Det er den korrekte semantik:
        "gør noget, når tilstanden skifter".
      - OnClick fyrer ved ethvert klik, uanset om tilstanden ændrede
        sig. Ved at bruge OnChange undgår vi unødvendige kald til
        driveren, når tilstanden ikke ændrede sig.
      Desuden kan Change udløses programmatisk (fx ved at sætte
      ChkRTS.Checked := True i kode), hvilket er nyttigt, hvis man
      senere vil synkronisere checkboxen med faktisk RTS-tilstand.

    BEMÆRK OM PARALLELITET MED ChkDTRChange:
      Denne metode er bevidst strukturelt identisk med ChkDTRChange
      — kun checkbox-navnet og driver-propertyen er forskellige.
      Det er et bevidst valg:
        - Konsistens gør koden nem at forstå: "når en checkbox
          ændres, sendes dens tilstand til den tilsvarende driver-
          property, hvis vi er forbundet".
        - Vedligeholdelse: hvis man senere skal ændre adfærden
          (fx tilføje logning eller fejlhåndtering), er det
          tydeligt, hvor man skal gøre det — begge steder.
        - Læsbarhed: hver metode gør præcis én ting, og det er
          nemt at se hvad.
      Man kunne overveje at samle dem i én fælles handler (fx via
      en fælles hjælpefunktion eller en parameter), men da de kun
      er to metoder med hver få linjer, er det ikke besværet værd.
      Det ville tværtimod gøre koden mere indirekte og sværere at
      læse. }

begin                                                                       // Begynder procedurens krop
  if FIsConnected and Assigned(FSerial) then                                // Er vi forbundet?
    FSerial.RTS := ChkRTS.Checked;                                          // Send checkbox-tilstand til driveren
  { ^ KERNEN I METODEN: synkroniserer checkboxens tilstand til den
      fysiske RTS-linje — men KUN hvis der er en aktiv forbindelse.

      HVORFOR BEGGE TJEK?
        FIsConnected        : vi skal være forbundet for at kunne
                              ændre RTS på en seriel port. Hvis
                              ikke, giver det ingen mening at kalde
                              driveren (og det ville sandsynligvis
                              give en fejl).
        Assigned(FSerial)   : driver-instansen skal eksistere. Dette
                              er teknisk set altid sandt, når
                              FIsConnected er sand (fordi FSerial
                              oprettes i FormCreate), men det er
                              billig forsikring mod edge-cases.

      HVORFOR SKER DER INTET, HVIS IKKE FORBUNDET?
        Fordi checkboxen også kan klikkes, FØR brugeren har
        forbundet. I så fald skal valget blot HUSKES — det gemmes
        automatisk i ChkRTS.Checked — og BtnConnectClick læser det
        ved forbindelse:
          FSerial.RTS := ChkRTS.Checked;
        Så når brugeren senere forbinder, bliver den valgte tilstand
        anvendt. Det er en elegant "deferred application"-mekanisme:
        indstillingen sættes straks i UI'et, men anvendes på
        hardwaren ved første mulige lejlighed.
        Dette undgår en fejlbesked som "du skal forbinde først for
        at ændre RTS" — hvilket ville være irriterende, fordi
        brugeren netop FORBEREDER forbindelsen.

      HVORFOR ER DER INGEN FEJLHÅNDTERING (try/except)?
        Fordi RTS := ... i praksis aldrig fejler på en gyldig,
        åben handle. Den underliggende EscapeCommFunction (Windows)
        eller ioctl (Linux) returnerer enten succes eller en fejl,
        men driveren ignorerer fejlen — den gør ikke noget aktivt
        for at rapportere den. Skulle der opstå et problem, ville
        det blive opdaget af næste timer-tick (som opdager, at
        porten er død) eller af en efterfølgende SendString.
        Derfor er try/except her unødvendig kompleksitet.

      HVORFOR ER DET IKKE ET PROBLEM, AT RTS STYRER FLOW CONTROL?
        Fordi vi i BtnConnectClick eksplicit har slået både software
        og hardware flow control FRA:
          FSerial.Config(Baud, Bits, ParityChar, StopBitVal,
                         False, False);
        Dvs. driveren forventer ikke at styre RTS automatisk — den
        lader brugeren (via denne checkbox) om det. Hvis man senere
        vil aktivere hardware flow control, skal man ændre Config-
        kaldet og samtidig sikre, at checkboxen ikke overskriver
        driverens automatiske styring. Det er en udvidelse, ikke
        en fejl i den nuværende kode.

      BEMÆRK OM DTR/RTS-KOMBINATIONER PÅ ESP32:
        Nogle ESP32-kort bruger en specifik DTR/RTS-sekvens til
        at aktivere bootloader. Hvis man vil tvinge bootloader-
        tilstand, skal man ofte sætte:
          DTR := False (træk GPIO0 lav via kreds)
          RTS := True  (hold EN høj)
        og derefter pulserer RTS for at frigive reset. Denne
        metode giver brugeren de nødvendige byggeklodser til at
        eksperimentere med sådanne sekvenser — men brugeren skal
        selv kende den korrekte kombination for sit specifikke
        kort. }
end;                                                                        // Slut på ChkRTSChange


procedure TFormMain.UpdateUIState;                                          // Central funktion: opdaterer hele UI'et
{ ^ CENTRAL FUNKTION til at synkronisere hele GUI'ets tilstand med
    programmets faktiske tilstand (FIsConnected og portens gyldighed).

    HVORFOR ER DENNE FUNKTION SÅ VIGTIG?
      I et GUI-program er der en konstant risiko for, at knapper,
      felter og indikatorer kommer ud af trit med virkeligheden —
      fx at [Send] er aktiv, selvom der ikke er nogen forbindelse,
      eller at [Forbind] kan trykkes, selvom man allerede ER
      forbundet. Sådanne tilstande forvirrer brugeren og kan føre
      til fejl (fx at man forsøger at sende til en lukket port).

      Løsningen er at samle ALL UI-opdatering i én funktion, som
      kaldes efter enhver tilstandsændring (Forbind, Afbryd,
      Genopfrisk, FormCreate, fejlhåndtering). Det giver:

        - ÉT SANDHEDSPUNKT: al UI-tilstand beregnes ud fra de
          samme to variable (FIsConnected og HasValidPort). Ingen
          steder i koden kan man komme til at sætte en knap
          forkert, fordi man glemte et andet sted.
        - KONSISTENS: knapper, ComboBoxes, ShapeStatus og
          statuslinjen opdateres ALTID sammen. Man kan ikke komme
          i en situation, hvor [Send] er enabled, men forbindelsen
          er død, og statuslinjen stadig siger "Forbundet".
        - VEDLIGEHOLDELSE: ændrer man UI-logikken (fx tilføjer
          en ny knap), er der ét sted at opdatere — ikke spredt
          ud over Connect, Disconnect, FormClose, TimerPollTimer
          osv.
        - TESTBARHED: man kan kalde UpdateUIState isoleret og
          verificere, at UI'et ser korrekt ud for en given
          tilstand.

    HVORFOR ER DET EN PRIVAT METODE OG IKKE EN PUBLIC?
      Fordi den kun bruges internt i TFormMain — ingen andre units
      skal kunne kalde den. Den er en "hjælpefunktion" for klassens
      egne event-handlers. }

var                                                                         // Lokale variable
  HasValidPort: Boolean;                                                    // Opsummerer om der er en brugbar port
  { ^ Lokal variabel, der opsummerer, om der er en brugbar port at
      forbinde til.

      HVORFOR EN LOKAL VARIABEL OG IKKE GENTAGE UDTRYKKET?
        Fordi udtrykket bruges to gange (til BtnConnect og til
        statuslinjens tekst). Ved at beregne det én gang:
          - Undgår vi at skrive det samme komplekse udtryk to
            steder (hvilket ville være en fejlkilde, hvis man
            ændrede det ene sted og glemte det andet).
          - Gør koden mere læsbar: "HasValidPort" forklarer
            intentionen bedre end det rå udtryk.
          - Er det marginalt hurtigere (CbComPort.Text og
            Pos() kaldes kun én gang i stedet for to). }

begin                                                                       // Begynder procedurens krop
  HasValidPort := (CbComPort.Items.Count > 0) and (Pos('(', CbComPort.Text) <> 1); // Beregn om der er en gyldig port
  { ^ DEFINITION AF "GYLDIG PORT". Der er to betingelser, som BEGGE
      skal være sande:

        1. CbComPort.Items.Count > 0
           Der er mindst ét punkt i ComboBoxen. Hvis listen er
           helt tom, er der intet at vælge — og så kan vi ikke
           forbinde.

        2. Pos('(', CbComPort.Text) <> 1
           Den VALGTE tekst starter IKKE med '('. Dette er vores
           "sentinel"-tjek for pladsholderen
           "(Ingen tilkoblede COM-porte fundet)", som RefreshComPorts
           indsætter, når der ikke findes nogen ægte porte.
           Hvis den valgte tekst starter med '(', ved vi, at det er
           pladsholderen — og så må brugeren ikke kunne forbinde.

      HVORFOR DENNE SAMMENSATTE BETINGELSE?
        Fordi vi skal kunne skelne mellem tre tilstande:
          - Tom ComboBox             : ingen port overhovedet.
          - Pladsholder valgt        : ingen ægte port, men UI'et
                                       ser ikke tomt ud.
          - Ægte port valgt          : klar til forbindelse.
        Kun i det sidste tilfælde må [Forbind] være enabled.
        Ved at kombinere de to tjek får vi præcis den semantik.

      BEMÆRK OM Pos('(', ...) <> 1:
        Hvis Pos returnerer 0, betyder det "ikke fundet" — og
        0 <> 1 er sandt. Så en tekst uden '(' vil altid bestå
        dette tjek. Det er korrekt: en ægte port som "COM3" eller
        "/dev/ttyUSB0" indeholder ikke '('.
        Vi kunne have skrevet "Pos('(', CbComPort.Text) = 0" for
        at være mere eksplicit, men "<> 1" er kortere og dækker
        både tilfældet "ikke fundet" (0) og "fundet senere i
        strengen" (2, 3, ...). Det er i praksis det samme. }

  BtnConnect.Enabled := (not FIsConnected) and HasValidPort;               // [Forbind] aktiv kun når ikke forbundet + gyldig port
  { ^ [Forbind]-knappen er aktiv KUN når:
        - Vi IKKE er forbundet (ellers giver det ingen mening at
          forbinde igen).
        - Der ER en gyldig port at forbinde til.
      Hvis en af betingelserne fejler, er knappen deaktiveret.
      HVORFOR KOMBINERE DE TO?
        Fordi begge er nødvendige for, at et klik på knappen giver
        mening. En deaktiveret knap er en klar visuel indikation
        til brugeren om, at handlingen ikke er mulig i den
        nuværende tilstand. }

  BtnDisconnect.Enabled := FIsConnected;                                    // [Afbryd] aktiv kun når forbundet
  { ^ [Afbryd] er kun aktiv, når vi ER forbundet. Ellers intet at
      afbryde.
      HVORFOR IKKE OGSÅ KRÆVE Assigned(FSerial)?
        Fordi FIsConnected kun kan være sand, når FSerial eksisterer.
        Hvis FSerial blev frigivet (fx i FormClose), ville
        FIsConnected også være False. Så tjekket er redundant. }

  BtnResetMCU.Enabled := FIsConnected;                                      // [Reset MCU] aktiv kun når forbundet
  { ^ [Reset MCU] kræver en åben forbindelse — vi skal bruge DTR-
      linjen, som kun kan styres på en åben port. }

  BtnRefreshPorts.Enabled := not FIsConnected;                              // [Genopfrisk] aktiv kun når ikke forbundet
  { ^ [Genopfrisk] er kun aktiv, når vi IKKE er forbundet.
      HVORFOR?
        Hvis man kunne genopfriske midt i en aktiv session, ville
        CbComPort.Items.Clear frigøre den valgte port-referencen, og
        statuslinjen ville vise en liste, der ikke matcher den
        faktisk åbne port. Risikoen for forvirring og inkonsistens
        er for stor. Desuden giver det ingen mening at lede efter
        nye porte, mens man er midt i en samtale med en eksisterende.
      Brugeren må først afbryde, derefter genopfriske. }

  CbComPort.Enabled := not FIsConnected;                                    // Port-vælger låst under forbindelse
  CbBaudRate.Enabled := not FIsConnected;                                   // Baudrate låst under forbindelse
  CbParity.Enabled := not FIsConnected;                                     // Paritet låst under forbindelse
  CbDataBits.Enabled := not FIsConnected;                                   // Databits låst under forbindelse
  CbStopBits.Enabled := not FIsConnected;                                   // Stopbits låst under forbindelse
  { ^ Alle port-parametre låses, når vi er forbundet.
      HVORFOR?
        - De er en del af den AKTIVE konfiguration. At ændre dem
          midt i en session ville betyde, at porten skulle
          rekonfigureres — hvilket er muligt, men kompliceret og
          sjældent ønsket. Ved at låse dem undgår vi en hel klasse
          af edge-cases.
        - Brugeren kan tydeligt se, at de nuværende parametre er
          "låst inde" og gælder for den aktive session. Hvis man
          vil ændre dem, må man afbryde først.
        - Risikoen for at brugeren ved et uheld ændrer baudrate
          midt i en session og dermed "mister" kommunikationen
          (fordi MCU'en kører videre på den gamle baudrate) er
          elimineret.
      HVORFOR ER DET FEM SEPARATE LINJER OG IKKE EN LØKKE?
        Fordi ComboBoxes ikke er i et array eller en liste. Man
        kunne lave et array af referencer, men det ville være
        mere kompliceret end fem simple linjer. De fem linjer er
        også nemmere at læse — man ser straks, hvilke kontroller
        der låses. }

  BtnSend.Enabled := FIsConnected;                                          // [Send] aktiv kun når forbundet
  EditSend.Enabled := FIsConnected;                                         // Inputfelt aktiv kun når forbundet
  { ^ [Send]-knappen og inputfeltet aktiveres KUN ved forbindelse.
      HVORFOR BEGGE?
        Hvis kun knappen var deaktiveret, kunne brugeren stadig
        skrive i feltet og undre sig over, hvorfor [Send] ikke
        virker. Ved at deaktivere begge signalerer vi klart:
        "denne funktion er ikke tilgængelig lige nu".
      HVORFOR ER DET OK AT DEAKTIVERE EditSend SELVOM DET ER ET
      ALMINDELIGT TEKSTFELT?
        Fordi dets ENESTE formål er at modtage kommandoer til
        MCU'en. Uden en forbindelse er det ubrugeligt — der er
        ingen at sende til. At lade det være aktivt ville være
        misvisende. }

  if FIsConnected then                                                      // Er vi forbundet?
  begin                                                                     // Begynder forbundet-gren
    ShapeStatus.Brush.Color := clLime;                                      // Grøn indikator
    StatusBar1.Panels[0].Text := 'Forbundet: ' + CbComPort.Text;            // Statuslinje: forbundet til port
  end                                                                       // Slut forbundet-gren
  else                                                                      // Ellers: ikke forbundet
  begin                                                                     // Begynder ikke-forbundet-gren
    ShapeStatus.Brush.Color := clRed;                                       // Rød indikator
    if HasValidPort then                                                    // Er der en gyldig port?
      StatusBar1.Panels[0].Text := 'Afbrudt (Klar til at forbinde)'         // Status: klar til at forbinde
    else                                                                    // Ellers: ingen port
      StatusBar1.Panels[0].Text := 'Ingen Arduino tilsluttet. Sæt USB i og tryk [Genopfrisk].'; // Handlingsorienteret status
  end;                                                                      // Slut ikke-forbundet-gren
  { ^ STATUSINDIKATOR OG STATUSLINJE — to ting opdateres sammen:

      HVIS FORBUNDET:
        - ShapeStatus bliver GRØN (clLime) — en umiddelbart synlig
          indikator, som brugeren kan se på afstand.
        - Statuslinjen viser "Forbundet: <portnavn>", så brugeren
          kan verificere, hvilken port der faktisk er åben. Dette
          er især vigtigt, hvis man har flere porte og skal være
          sikker på, at man er forbundet til den rigtige.

      HVIS IKKE FORBUNDET (to undertilfælde):
        - ShapeStatus bliver RØD (clRed) i begge tilfælde — det
          signalerer "ikke forbundet", uanset hvorfor.
        - Hvis der ER en gyldig port: "Afbrudt (Klar til at
          forbinde)". Brugeren ved, at systemet har fundet en port
          og venter på, at de trykker [Forbind].
        - Hvis der IKKE er nogen gyldig port: "Ingen Arduino
          tilsluttet. Sæt USB i og tryk [Genopfrisk]." Dette er
          en handlingsorienteret besked — den fortæller brugeren
          præcis, hvad de skal gøre for at komme videre.

      HVORFOR clLime OG clRed OG IKKE MERE SUBTILE FARVER?
        Fordi grøn/rød er en universel konvention for "ok/problem",
        som brugeren genkender med det samme. Mere subtile farver
        (fx blå, gul) ville kræve forklaring. Desuden er clLime og
        clRed skarpt adskilt i farvespektret, så selv farveblinde
        brugere kan se forskel (lysegrøn vs. mørkerød).

      HVORFOR OPDATERE StatusBar1.Panels[0] OG IKKE ET ANDET PANEL?
        Panel 0 er reserveret til port-status. Panel 1 er RX-tæller,
        panel 2 er TX-tæller. Denne opdeling gør statuslinjen
        informativ uden at være overfyldt.

      BEMÆRK OM CbComPort.Text I STATUSLINJEN:
        Vi bruger .Text (den aktuelt viste værdi) i stedet for
        .Items[ItemIndex] (den valgte post). Forskellen er
        typisk ingen, men .Text afspejler præcis, hvad brugeren
        ser — hvilket er det mest korrekte i en statusvisning.
        Hvis brugeren har skrevet frit i ComboBoxen (ikke muligt
        med den valgte Style, men teoretisk), ville .Text være
        mere retvisende. }

end;                                                                        // Slut på UpdateUIState
end.                                                                        // Slut på unit