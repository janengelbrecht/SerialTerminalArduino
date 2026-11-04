{===============================================================================
DOKUMENTATION AF SYNASE — SERIEL DRIVER
  ===============================================================================
  Fil:      synaser.pas
  Sprog:    Free Pascal / Lazarus ({$mode objfpc}{$H+})
  Formål:   Letvægts, selvstændig seriel driver til SerialTerminal-projektet.
            Understøtter Windows (CreateFileA/DCB/COMMTIMEOUTS) og UNIX
            (fpopen/termios) via betinget kompilering.
  Oprindelse: Baseret på Synapse-bibliotekets synaser (Lukas Gebauer,
            BSD/Public Domain), men reduceret og tilpasset.
  ===============================================================================

  INDHOLDSFORTEGNELSE
  -------------------
  1.  Overordnet arkitektur og ansvar
  2.  Interface-sektionen
      2.1  Stop bit-konstanter (SB1, SB1andHalf, SB2)
      2.2  EscapeCommFunction-konstanter (WIN_*)
      2.3  TBlockSerial — offentligt API
      2.4  GetSerialPortNames — fri funktion
  3.  Implementation — portdetektering
      3.1  GetSerialPortNames (Windows)
      3.2  GetSerialPortNames (UNIX)
  4.  TBlockSerial — livscyklus
      4.1  Create/Destroy
      4.2  Connect
      4.3  CloseSocket
  5.  TBlockSerial — konfiguration og I/O
      5.1  Config
      5.2  WaitingData
      5.3  RecvBufferStr
      5.4  SendString
  6.  TBlockSerial — kontrolsignaler
      6.1  SetDTR
      6.2  SetRTS
  7.  Designvalg og begrundelser (opsummering)

  ===============================================================================
  1. OVERORDNET ARKITEKTUR OG ANSVAR
  ===============================================================================

  synaser.pas er en TYND driver — den oversætter et lille, platform-uafhængigt
  API (TBlockSerial) til de underliggende OS-kald. Alt, hvad der handler om
  brugergrænseflade, kodning og protokolafkodning, ligger i unitmain.pas.

  DATAFLOW:

      [unitmain.TFormMain]
            |
            |  TBlockSerial.Create / Connect / Config / SendString
            |  RecvBufferStr / WaitingData / DTR / RTS / CloseSocket
            v
      [TBlockSerial]  --- betinget kompilering --->  [Windows API]
                                                     [POSIX API]

  BETINGET KOMPILERING:
  Hele filen er opdelt i {$IFDEF WINDOWS}- og {$ELSE}-grene. Det betyder,
  at kun den ene gren kompileres ind i executablen på hver platform. Det
  giver:
    - Ingen unødvendige afhængigheder (Windows-grenen trækker ikke POSIX-
      units ind, og omvendt).
    - Ingen risiko for navnekollisioner mellem Windows- og POSIX-typer.
    - Klar adskillelse af platformspecifik kode (NFR-002).

  HVORFOR EN EGEN DRIVER OG IKKE EN EKSTERN AFHÆNGIGHED?
    - Nul eksterne afhængigheder ud over FPC/Lazarus-økosystemet.
    - Fuld kontrol over non-blocking timeouts og portdetektering.
    - Kan tilpasses præcist til projektets behov uden at skulle vente på
      opstrøms ændringer.

  ===============================================================================
  2. INTERFACE-SEKTIONEN
  ===============================================================================

  2.1 Stop bit-konstanter (SB1, SB1andHalf, SB2)
  ----------------------------------------------
  Abstraherer OS'ets stopbit-værdier. På Windows bruges ONESTOPBIT,
  ONE5STOPBITS, TWOSTOPBITS; på POSIX bruges CSTOPB og tilsvarende.
  Ved at bruge fælles konstanter kan unitmain.pas arbejde platform-uafhængigt.

  HVORFOR IKKE BRUGE OS'ETS KONSTANTER DIREKTE I unitmain?
    Fordi unitmain ikke skal kende til Windows- eller POSIX-detaljer.
    Abstraktionen gør det også muligt at ændre den interne repræsentation
    uden at ændre kaldende kode.

  2.2 EscapeCommFunction-konstanter (WIN_*)
  -----------------------------------------
  Windows' EscapeCommFunction bruger numeriske koder (3, 4, 5, 6) til at
  sætte/cleare RTS og DTR. Disse er ikke eksporteret som navngivne
  konstanter i FPC's Windows-unit, så vi definerer dem selv.

  HVORFOR WIN_-PRÆFIKS?
    TBlockSerial har metoderne SetDTR og SetRTS. Uden præfiks ville
    konstanterne SETDTR/CLRDTR/SETRTS/CLRRTS kollidere med metodenavnene
    i samme scope — og compileren ville ikke kunne skelne. WIN_-præfikset
    gør det eksplicit, at der er tale om Windows API-koder.

  2.3 TBlockSerial — offentligt API
  ---------------------------------
  Klassen er bevidst lille og fokuseret:
    - Connect/CloseSocket    : livscyklus for porten.
    - Config                 : baud, bits, paritet, stopbits, timeouts.
    - SendString/RecvBufferStr: byte-orienteret I/O.
    - WaitingData            : polling-hjælper.
    - DTR/RTS                : kontrolsignaler.
    - LastError/LastErrorDesc: fejlrapportering.
    - Device/Handle          : inspektion.

  HVORFOR ER API'ET SÅ SMALT?
    Jo mindre overflade, jo nemmere er det at vedligeholde og teste.
    Alt, hvad der ikke er strengt nødvendigt for SerialTerminal, er
    udeladt — fx flow control-konfiguration, break-signaler og
    modem-status-linjer (DSR, CTS, RI, DCD).

  HVORFOR ER LastError/LastErrorDesc PROPERTIES OG IKKE UNDTAGELSER?
    Fordi OS-fejl i seriel kommunikation ofte er "forventede" (port
    optaget, USB trukket ud) og skal håndteres kontrolleret af GUI'et
    — ikke kastes op gennem call-stacken. Ved at gemme fejlen i felter
    kan kalderen tjekke efter hvert kald og vise en passende besked.
    Metoder som Connect kaster derfor ikke undtagelser ved normale
    fejl; kun uventede fejl (fx hukommelsesmangel) propagerer.

  2.4 GetSerialPortNames — fri funktion
  -------------------------------------
  Returnerer en kommasepareret liste af fysisk tilstedeværende porte.
  Er en fri funktion (ikke en klassemetode), fordi den ikke har brug
  for TBlockSerial-instansens tilstand — den er ren OS-introspection.

  ===============================================================================
  3. IMPLEMENTATION — PORTDETEKTERING
  ===============================================================================

  3.1 GetSerialPortNames (Windows)
  ---------------------------------
  Læser HKEY_LOCAL_MACHINE\HARDWARE\DEVICEMAP\SERIALCOMM, som Windows
  opdaterer øjeblikkeligt, når en COM-port tilsluttes eller fjernes.
  Hver kandidat verificeres med CreateFileA for at sikre, at porten
  faktisk kan åbnes (eller er optaget af en anden proces).

  HVORFOR DOBBELTVERIFIKATION (registry + CreateFileA)?
    Registreringsdatabasen kan i sjældne tilfælde indeholde forældede
    poster (fx efter et crash, hvor driveren ikke nåede at rydde op).
    Åbningstesten giver et endeligt svar på, om porten reelt eksisterer.

  HVORFOR MEDTAGE ERROR_ACCESS_DENIED OG ERROR_SHARING_VIOLATION?
    Det betyder, at porten FINDES, men er optaget af en anden proces
    (fx Arduino IDE's Serial Monitor). Brugeren skal kunne se porten i
    listen for at forstå, hvorfor forbindelsen fejler — og for at vide,
    at de skal lukke det andet program først. Dette opfylder FR-003.

  HVORFOR UDELADE ERROR_FILE_NOT_FOUND?
    Det betyder, at porten ikke eksisterer (endnu). At vise den ville
    føre til "phantom-porte", som brugeren ikke kan forbinde til.
    Dette opfylder FR-004.

  3.2 GetSerialPortNames (UNIX)
  -----------------------------
  Scanner /dev/ttyUSB* (FTDI/CH340-baserede Arduino-kort) og
  /dev/ttyACM* (native USB CDC, fx Uno R3, ESP32-S3).

  HVORFOR KUN DISSE TO MØNSTRE?
    De dækker langt størstedelen af Arduino/ESP32-kort på Linux.
    macOS bruger /dev/tty.usbmodem* og /dev/tty.usbserial*, som ikke
    scannes her — en kendt begrænsning i denne forenklede udgave
    (se den separate analyse).

  ===============================================================================
  4. TBlockSerial — LIVSCYKLUS
  ===============================================================================

  4.1 Create/Destroy
  ------------------
  Create initialiserer FHandle til THandle(-1) (ugyldig), nulstiller
  fejlfelter og sætter DTR/RTS til True (standard for de fleste MCU'er).

  Destroy kalder CloseSocket for sikker oprydning. Dette er vigtigt,
  fordi TBlockSerial IKKE er ejet af LCL-komponenthierarkiet — den
  skal frigives eksplicit af unitmain.pas (FreeAndNil i FormClose).

  HVORFOR THandle(-1) OG IKKE 0 SOM "UGYLDIG"?
    Fordi 0 er en gyldig handle på nogle platforme (stdin). Windows'
    CreateFileA returnerer specifikt INVALID_HANDLE_VALUE = THandle(-1)
    ved fejl, og POSIX' fpopen returnerer -1. Ved at bruge samme
    sentinel-værdi i hele koden undgår vi forvirring.

  4.2 Connect
  -----------
  Windows: åbner '\\.\COMx' med CreateFileA (GENERIC_READ|GENERIC_WRITE,
  share-mode 0 = eksklusiv adgang). Kalder SetupComm for at sætte
  buffere til 4 KB.

  UNIX: fpopen med O_RDWR|O_NOCTTY|O_NONBLOCK.

  HVORFOR SHARE-MODE 0 PÅ WINDOWS?
    Det giver eksklusiv adgang — ingen andre processer kan åbne porten,
    mens vi har den. Det forhindrer, at to terminal-programmer skriver
    til den samme MCU samtidigt og skaber kaos. Dette opfylder FR-006.

  HVORFOR O_NOCTTY PÅ POSIX?
    Uden O_NOCTTY ville den serielle port blive vores controlling
    terminal, hvilket kunne føre til uventede signaler (fx SIGHUP),
    hvis forbindelsen falder bort. O_NOCTTY forhindrer dette.

  HVORFOR O_NONBLOCK PÅ POSIX?
    Så fpopen ikke blokerer, hvis porten ikke er klar. Selve læsningen
    bliver også non-blocking (se RecvBufferStr), hvilket matcher
    Windows' non-blocking timeouts.

  HVORFOR GEM MES FDevice OG IKKE BARE HANDLE?
    FDevice bruges til fejlmeddelelser og statusvisning. Handle er
    en implementeringsdetalje, som kalderen sjældent har brug for.

  4.3 CloseSocket
  ---------------
  Lukker handle og nulstiller den til THandle(-1). Idempotent — kan
  kaldes flere gange uden skade.

  HVORFOR IDEMPOTENS?
    Fordi CloseSocket kaldes fra flere steder: BtnDisconnectClick,
    FormClose, destructor, og potentielt fra fejlhåndtering. Hvis den
    ikke var idempotent, ville det andet kald forsøge at lukke en
    allerede lukket handle — hvilket i bedste fald er harmløst, i
    værste fald giver en fejl. Dette opfylder NFR-008.

  ===============================================================================
  5. TBlockSerial — KONFIGURATION OG I/O
  ===============================================================================

  5.1 Config
  ----------
  Windows: udfylder DCB (BaudRate, ByteSize, Parity, StopBits), kalder
  SetCommState, og sætter derefter COMMTIMEOUTS til non-blocking læsning
  og 500 ms skrive-timeout.

  UNIX: gemmer parametrene (termios-konfiguration er IKKE implementeret
  i denne forenklede udgave — en kendt begrænsning).

  HVORFOR ReadIntervalTimeout = MAXDWORD OG ReadTotalTimeoutConstant = 0?
    Denne kombination giver "non-blocking" adfærd: ReadFile returnerer
    øjeblikkeligt med de bytes, der er tilgængelige (kan være 0). Det
    matcher POSIX' O_NONBLOCK og gør polling-modellen ens på begge
    platforme. Dette opfylder FR-008.

  HVORFOR WriteTotalTimeoutConstant = 500 ms?
    For at undgå, at WriteFile blokerer uendeligt, hvis TX-bufferen er
    fuld (fx fordi MCU'en ikke læser). 500 ms er rigeligt til de fleste
    kommandoer og giver en kontrolleret fejl i stedet for en fastlåst
    GUI. Dette opfylder FR-009.

  HVORFOR KALDES GetCommState FØR DCB UDFYLDES?
    Fordi DCB indeholder mange felter, som vi ikke selv sætter (fx
    flow control-konfiguration, XON/XOFF-tegn). Ved at læse den
    nuværende DCB først og kun ændre de felter, vi interesserer os
    for, bevarer vi OS'ets standardindstillinger for resten.

  HVORFOR IGNORERES SoftFlow/HardFlow?
    Fordi Arduino/ESP32 normalt ikke bruger flow control på USB-CDC.
    Parametrene er med i signaturen for API-kompatibilitet, men
    implementeres ikke. En fremtidig udvidelse kunne sætte
    DCB.fOutxCtsFlow, fRtsControl osv.

  5.2 WaitingData
  ---------------
  Windows: ClearCommError -> COMSTAT.cbInQue = antal bytes i OS-buffer.

  UNIX: returnerer 0 i denne forenklede udgave.

  HVORFOR ClearCommError OG IKKE EN ANDEN METODE?
    ClearCommError er den officielle Windows-måde at få COMSTAT, som
    indeholder cbInQue (antal bytes i input-bufferen). Den rydder
    samtidig eventuelle fejlflag, hvilket er nyttigt.

  HVORFOR RETURNERER UNIX-GRENEN 0?
    Fordi denne forenklede udgave ikke implementerer fpioctl(FIONREAD).
    Det betyder, at GUI'ets gating på WaitingData > 0 aldrig bliver
    sand på POSIX — en kendt begrænsning, som gør RX død på Linux.
    En korrekt implementering ville kalde fpioctl(FHandle, FIONREAD, @n).

  5.3 RecvBufferStr
  -----------------
  Læser op til Length bytes. Windows: ReadFile med de konfigurerede
  timeouts. UNIX: fpread. Returnerer faktisk læste bytes.

  HVORFOR SetLength(Result, Length) FØR ReadFile?
    Fordi ReadFile skriver direkte ind i Result's buffer. Strengen skal
    have den korrekte længde, FØR man kan indeksere den — ellers får
    man en range-check-fejl (i debug) eller stille hukommelseskorruption
    (i release).

  HVORFOR SetLength(Result, BytesRead) EFTER ReadFile?
    Fordi ReadFile kan læse færre bytes end den anmodede længde (fx
    hvis der kun er 3 bytes i bufferen, men vi bad om 10). Vi trimmer
    Result til det faktisk læste antal, så kalderen ikke får
    null-bytes med i sin videre behandling.

  HVORFOR RETURNERER ReadFile-FEJL EN TOM STRENG?
    Fordi vi ikke kan gøre noget fornuftigt med en delvis læsning ved
    fejl. Kalderen (TimerPollTimer) tjekker Length(RawChunk) > 0 og
    springer tomme resultater over. En fremtidig forbedring kunne
    sætte FLastError og lade kalderen reagere — det er nødvendigt for
    korrekt USB-frakoblingsdetektion (FR-015).

  5.4 SendString
  --------------
  Skriver hele strengen. Windows: WriteFile. UNIX: fpwrite. Returnerer
  antal skrevne bytes (kan bruges til fejltælling).

  HVORFOR RETURNERES ANTAL SKREVNE BYTES OG IKKE EN BOOLEAN?
    Fordi WriteFile/fpwrite kan skrive FÆRRE bytes end anmodet (delvis
    skrivning). Kalderen kan så afgøre, om hele kommandoen blev sendt,
    eller om der skal forsøges igen. I den nuværende unitmain.pas
    ignoreres returværdien — en kendt fejl (FR-029), som bør rettes.

  ===============================================================================
  6. TBlockSerial — KONTROLSIGNALER
  ===============================================================================

  6.1 SetDTR
  ----------
  Windows: EscapeCommFunction med WIN_SETDTR eller WIN_CLRDTR.
  UNIX: gemmer blot tilstanden (ingen ioctl-implementering).

  HVORFOR GEM MES FDTR SELV OM WINDOWS-KALDET FEJLER?
    Fordi FDTR er den ønskede tilstand. Hvis EscapeCommFunction fejler
    (fx fordi porten er lukket), er det stadig nyttigt at vide, hvad
    brugeren forsøgte at sætte — fx til fejlfindingslogning. Og næste
    vellykkede kald vil sætte den korrekte tilstand.

  HVORFOR ER DER INGEN FEJLRAPPORTERING?
    Fordi EscapeCommFunction i praksis sjældent fejler på en gyldig,
    åben handle. Hvis den gør, opdages det ved næste I/O-operation
    (fx ReadFile returnerer False). At rapportere fejlen her ville
    kræve, at kalderen tjekkede efter hvert DTR/RTS-skift — hvilket
    ville gøre API'et mere besværligt uden en tilsvarende gevinst.

  6.2 SetRTS
  ----------
  Samme mønster som SetDTR, men for RTS-linjen.

  HVORFOR ER DER IKKE EN FÆLLES HJÆLPEFUNKTION?
    Fordi de to metoder er små og strukturelt identiske. En fælles
    hjælpefunktion ville kræve en parameter for, hvilken linje der
    styres — hvilket ville gøre koden mere indirekte uden at spare
    nævneværdig kode. To små, ens metoder er lettere at læse.

  ===============================================================================
  7. DESIGNVALG OG BEGRUNDELSER (OPSUMMERING)
  ===============================================================================

  - Betinget kompilering: én fil, to platforme, nul unødvendige
    afhængigheder.
  - Smalt API: kun det, SerialTerminal har brug for.
  - LastError/LastErrorDesc i stedet for undtagelser: OS-fejl er
    forventede og skal håndteres kontrolleret af GUI'et.
  - Idempotent CloseSocket: sikker at kalde fra flere steder.
  - THandle(-1) som sentinel: matcher OS'ets egne konventioner.
  - Non-blocking timeouts: matcher POSIX' O_NONBLOCK og giver ens
    polling-model på begge platforme.
  - Kommasepareret portliste: simpelt format, nemt at parse i GUI'et.

  KENDTE BEGRÆNSNINGER (ikke rettet i denne version):
    - UNIX: WaitingData returnerer altid 0 (RX død på Linux/macOS).
    - UNIX: termios-konfiguration er ikke implementeret.
    - UNIX: DTR/RTS er no-ops.
    - UNIX: FHandle-sammenligninger bruger < 0 / >= 0 på en usigneret
      THandle — bør være THandle(-1).
    - macOS: /dev/tty.usbmodem* og /dev/tty.usbserial* scannes ikke.
    - Windows: GetCommState/SetCommState/SetCommTimeouts returværdier
      ignoreres.
    - Windows: USB-frakobling detekteres ikke (ReadFile-fejl ignoreres).
  =============================================================================== }

unit synaser;                                                               // Deklarerer unit'ens navn; skal matche filnavnet synaser.pas
{ ^ Unit-erklæring. Filen skal hede synaser.pas, og unit-navnet skal
    stemme overens med filnavnet (Lazarus-krav). "synaser" er en
    forkortelse for "Synapse Serial" — det oprindelige bibliotek, som
    denne driver er baseret på. }

{$MODE OBJFPC}{$H+}                                                         // Compiler-direktiv: Object Pascal + AnsiString som standard
{ ^ To compiler-direktiver:
      {$MODE OBJFPC} : Sætter FPC i Object Pascal-tilstand (Delphi-
                       kompatibel dialekt) med class, properties,
                       virtuelle metoder og AnsiString som standard-
                       strengtype.
      {$H+}          : Gør "string" til AnsiString (dynamisk,
                       reference-talt, automatisk hukommelsesstyring)
                       i stedet for ShortString (max 255 tegn).
                       Nødvendigt fordi vi håndterer vilkårligt store
                       datamængder fra serieporten. }

interface                                                                   // Begynder den offentlige del, som andre units kan se
{ ^ Her begynder unit'ens offentlige overflade. Alt mellem "interface"
    og "implementation" er synligt for andre units, der bruger/"uses"-er
    denne unit. Opdelingen giver hurtigere kompilering og informations-
    skjul. }

uses                                                                        // Begynder afhængighedslisten
  Classes, SysUtils,                                                        // Kerne-units (TStringList, Format, SysErrorMessage)
  {$IFDEF WINDOWS}
  Windows, Registry                                                         // Windows API + registry-adgang
  {$ELSE}
  BaseUnix, Unix, termio                                                    // POSIX API + termios
  {$ENDIF}
  ;
{ ^ Betinget afhængighedsliste:
      Classes    : TStringList (bruges af GetSerialPortNames).
      SysUtils   : Format, SysErrorMessage, IntToHex m.fl.
      Windows    : CreateFileA, ReadFile, WriteFile, DCB, COMMTIMEOUTS,
                   EscapeCommFunction, ClearCommError m.fl.
      Registry   : TRegistry til at læse SERIALCOMM-nøglen.
      BaseUnix   : fpopen, fpclose, fpread, fpwrite, fpGetErrno.
      Unix       : O_RDWR, O_NOCTTY, O_NONBLOCK.
      termio     : termios-typer (ikke brugt i denne version, men
                   inkluderet for fremtidig udvidelse).
    HVORFOR BETINGET?
      Windows-grenen må ikke trække POSIX-units ind (de findes ikke
      på Windows), og omvendt. Betinget kompilering sikrer, at kun
      de relevante units kompileres ind på hver platform. }

const                                                                       // Begynder konstantdeklarationer
  // Stop bit konstanter for TBlockSerial
  SB1 = 0;                                                                  // 1 stopbit
  SB1andHalf = 1;                                                           // 1.5 stopbits
  SB2 = 2;                                                                  // 2 stopbits
{ ^ Abstrakte stopbit-konstanter, der bruges af unitmain.pas i stedet
    for platformsspecifikke OS-konstanter. På Windows mapper de til
    ONESTOPBIT/ONE5STOPBITS/TWOSTOPBITS i DCB; på POSIX ville de
    (i en fuld implementering) mappe til CSTOPB og tilsvarende.
    HVORFOR ABSTRAKTION?
      unitmain.pas skal ikke kende til Windows- eller POSIX-detaljer.
      Ved at bruge fælles konstanter kan GUI-koden arbejde platform-
      uafhængigt. }

  // EscapeCommFunction konstanter (Windows API)
  // WIN_ præfiks forhindrer navnesammenfald med TBlockSerial.SetDTR og SetRTS i Free Pascal
  WIN_SETRTS = 3;                                                           // EscapeCommFunction: sæt RTS høj
  WIN_CLRRTS = 4;                                                           // EscapeCommFunction: sæt RTS lav
  WIN_SETDTR = 5;                                                           // EscapeCommFunction: sæt DTR høj
  WIN_CLRDTR = 6;                                                           // EscapeCommFunction: sæt DTR lav
{ ^ Windows' EscapeCommFunction bruger numeriske koder til at styre
    RTS og DTR. Disse er ikke eksporteret som navngivne konstanter i
    FPC's Windows-unit, så vi definerer dem selv.
    HVORFOR WIN_-PRÆFIKS?
      TBlockSerial har metoderne SetDTR og SetRTS. Uden præfiks ville
      konstanterne SETDTR/CLRDTR/SETRTS/CLRRTS kollidere med metode-
      navnene i samme scope. WIN_-præfikset gør det eksplicit, at der
      er tale om Windows API-koder. }

type                                                                        // Begynder typetilkendegivelser
  TBlockSerial = class(TObject)                                             // Seriel driver-klasse, arver fra TObject
{ ^ KLASSEERKLÆRING for den serielle driver. Arver direkte fra TObject
    (ikke TComponent), fordi den ikke skal være en del af LCL's
    komponenthierarki. Det betyder, at den skal frigives eksplicit
    med FreeAndNil i unitmain.pas — LCL's automatiske oprydning
    rører den ikke.
    SEKTIONER:
      - private: intern tilstand og hjælpeprocedurer.
      - public: det offentlige API, som unitmain.pas bruger. }

  private                                                                   // Private medlemmer, usynlige udefra
{ ^ Her begynder de private medlemmer — usynlige for andre units.
    Formålet er informationsskjul: kun TBlockSerial's egne metoder
    må rode med den interne tilstand. }

    FHandle: THandle;                                                       // OS-handle for den åbne port
{ ^ OS-handle for den åbne port. På Windows er det en HANDLE
    (pointer-størrelse); på POSIX er det en file descriptor pakket
    ind i THandle. THandle(-1) betyder "ikke åben".
    HVORFOR THandle OG IKKE EN PLATFORMSSPECIFIK TYPE?
      THandle er defineret i både Windows- og BaseUnix-units og har
      samme størrelse som en pointer. Ved at bruge den fælles type
      kan resten af koden arbejde platform-uafhængigt. }

    FLastError: Integer;                                                    // Seneste OS-fejlkode
    FLastErrorDesc: string;                                                 // Menneske-læsbar beskrivelse af fejlen
{ ^ Fejlrapportering. Når en operation fejler, gemmes OS'ets fejlkode
    (GetLastError på Windows, fpGetErrno på POSIX) og en beskrivelse
    (SysErrorMessage) her. Kalderen kan så vise en meningsfuld besked
    til brugeren.
    HVORFOR IKKE UNDTAGELSER?
      Fordi OS-fejl i seriel kommunikation ofte er "forventede" (port
      optaget, USB trukket ud) og skal håndteres kontrolleret af GUI'et.
      Ved at gemme fejlen i felter kan kalderen tjekke efter hvert kald
      og vise en passende besked — uden at skulle pakke alt ind i
      try/except. }

    FDevice: string;                                                        // Enhedsnavn (fx "COM3" eller "/dev/ttyUSB0")
{ ^ Enhedsnavnet som det blev givet til Connect. Gemmes til
    fejlmeddelelser og statusvisning. }

    FBaudRate: Integer;                                                     // Gemt baudrate
    FDataBits: Integer;                                                     // Gemt antal databits
    FParity: Char;                                                          // Gemt paritet (N/O/E/M/S)
    FStopBits: Integer;                                                     // Gemt stopbits (SB1/SB1andHalf/SB2)
{ ^ De konfigurerede port-parametre. Gemmes for at kunne inspiceres
    og for at bevare tilstanden mellem Config-kald. }

    FDTR: Boolean;                                                          // Ønsket DTR-tilstand
    FRTS: Boolean;                                                          // Ønsket RTS-tilstand
{ ^ De ønskede tilstande for DTR og RTS. Gemmes, fordi vi vil kunne
    rapportere tilbage, hvad brugeren har valgt — også selv om det
    fysiske signal ikke kunne sættes (fx fordi porten er lukket). }

    procedure SetDTR(Value: Boolean);                                       // Property-setter for DTR
    procedure SetRTS(Value: Boolean);                                       // Property-setter for RTS
{ ^ Property-setters. De erklæres i private, fordi de kun skal kaldes
    via property-syntaksen (FSerial.DTR := True), ikke direkte. }

  public                                                                    // Offentlig sektion
{ ^ Her begynder det offentlige API — det, som unitmain.pas bruger. }

    constructor Create;                                                     // Opretter driver-instansen
    destructor Destroy; override;                                           // Frigiver driver-instansen

    procedure Connect(const DeviceName: string);                            // Åbner porten
    procedure CloseSocket;                                                  // Lukker porten (idempotent)
    procedure Config(Baud, Bits: Integer; Parity: Char; StopBits: Integer; {%H-}SoftFlow, {%H-}HardFlow: Boolean); // Konfigurerer porten
{ ^ Livscyklus og konfiguration:
      Create       : initialiserer felter.
      Destroy      : kalder CloseSocket og frigiver.
      Connect      : åbner porten (CreateFileA / fpopen).
      CloseSocket  : lukker porten (idempotent).
      Config       : sætter baud, bits, paritet, stopbits og timeouts.
    {%H-} foran SoftFlow/HardFlow undertrykker en compiler-hint om,
    at parametrene ikke bruges i denne version (de er med for
    API-kompatibilitet og fremtidig udvidelse). }

    function SendString(const Data: AnsiString): Integer;                   // Skriver bytes til porten
    function RecvBufferStr(Length: Integer; {%H-}TimeoutMs: Integer): AnsiString; // Læser bytes fra porten
    function WaitingData: Integer;                                          // Antal bytes i OS-buffer
{ ^ Byte-orienteret I/O:
      SendString    : skriver en byte-sekvens, returnerer antal skrevne.
      RecvBufferStr : læser op til Length bytes, returnerer faktisk læste.
      WaitingData   : spørger OS-bufferen, hvor mange bytes der er klar.
    TimeoutMs ignoreres i denne version (timeouts er sat globalt via
    Config). Parameteren er med for API-kompatibilitet. }

    property LastError: Integer read FLastError;                            // Seneste OS-fejlkode
    property LastErrorDesc: string read FLastErrorDesc;                     // Fejlbeskrivelse
    property DTR: Boolean read FDTR write SetDTR;                           // DTR-tilstand (læs/skriv)
    property RTS: Boolean read FRTS write SetRTS;                           // RTS-tilstand (læs/skriv)
    property Device: string read FDevice;                                   // Enhedsnavn (read-only)
    property Handle: THandle read FHandle;                                  // OS-handle (read-only, til inspektion)
{ ^ Offentlige properties:
      LastError/LastErrorDesc : fejlrapportering efter hvert kald.
      DTR/RTS                 : kontrolsignaler (skrivning kalder
                                SetDTR/SetRTS, som sender til OS).
      Device/Handle           : read-only inspektion.
    HVORFOR ER DTR/RTS PROPERTIES OG IKKE METODER?
      Syntaksen FSerial.DTR := True er mere naturlig end
      FSerial.SetDTR(True). Det matcher også Delphi/Lazarus-konventionen
      for simple tilstandsfelter med bivirkninger. }
  end;                                                                      // Slut på TBlockSerial-klassen

function GetSerialPortNames: string;                                        // Fri funktion: returnerer komma-separeret portliste
{ ^ Returnerer en kommasepareret liste af fysisk tilstedeværende porte.
    Er en fri funktion (ikke en klassemetode), fordi den ikke har brug
    for TBlockSerial-instansens tilstand — den er ren OS-introspection.
    HVORFOR KOMMASEPARERET?
      Det er et simpelt format, som nemt kan parses med TStringList.
      CommaText i unitmain.pas. Alternativer (TStringList som returværdi,
      array) ville kræve hukommelsesstyring og mere kompleks kode. }

implementation                                                              // Begynder implementationsdelen
{ ^ Her begynder implementation-sektionen. Alt, der erklæres her, er
    KUN synligt inde i denne unit — andre units kan ikke se eller
    kalde disse procedurer og funktioner. Det giver fuld indkapsling
    af den interne arbejdsgang. }

function GetSerialPortNames: string;                                        // Portdetektering (platformsbetinget)
{$IFDEF WINDOWS}
var                                                                         // Windows-grenens lokale variable
  Reg: TRegistry;                                                           // Registry-adgang
  List: TStringList;                                                        // Liste over værdinavne i SERIALCOMM
  i: Integer;                                                               // Løkkeindeks
  PName: string;                                                            // Portnavn (fx "COM3")
  H: THandle;                                                               // Midlertidig handle fra CreateFileA
  Err: DWORD;                                                               // GetLastError-resultat
  IsPresent: Boolean;                                                       // Er porten fysisk til stede?
begin                                                                       // Begynder Windows-implementeringen
  Result := '';                                                             // Initialiserer resultatet som tom streng
  Reg := TRegistry.Create;                                                  // Opretter registry-objekt
  List := TStringList.Create;                                               // Opretter liste til værdinavne
  try                                                                       // Begynder try/finally for oprydning
    Reg.RootKey := HKEY_LOCAL_MACHINE;                                      // Sætter rodnøgle til HKLM
    { ^ SERIALCOMM ligger under HKEY_LOCAL_MACHINE, ikke HKEY_CURRENT_USER.
        Det er en system-global nøgle, som alle brugere kan læse. }

    if Reg.OpenKeyReadOnly('HARDWARE\DEVICEMAP\SERIALCOMM') then            // Åbner SERIALCOMM-nøglen
    { ^ Åbner nøglen, hvor Windows registrerer alle aktive COM-porte.
        Nøglen opdateres øjeblikkeligt, når en USB-serial-adapter
        tilsluttes eller fjernes.
        HVORFOR OpenKeyReadOnly OG IKKE OpenKey?
          Vi skal kun LÆSE listen — ikke skrive til den. ReadOnly er
          sikrere og undgår unødvendige rettighedskrav.
        BEMÆRK: Stien SKAL have backslashes. 'HARDWARE\DEVICEMAP\SERIALCOMM'
        er den korrekte sti (FR-001). }

    begin                                                                   // Begynder succes-gren
      Reg.GetValueNames(List);                                              // Henter alle værdinavne i nøglen
      { ^ Hver COM-port registreres som en værdi i nøglen. Værdinavnet
          er typisk "Device" eller "COM3" (afhængigt af driveren), og
          værdien er selve portnavnet (fx "COM3").
          Vi itererer over værdinavnene og læser hver værdi. }

      for i := 0 to List.Count - 1 do                                       // Itererer over hver registreret port
      begin                                                                 // Begynder løkkekrop
        PName := Reg.ReadString(List[i]);                                   // Læser portnavnet (fx "COM3")
        if PName <> '' then                                                 // Springer tomme værdier over
        begin                                                               // Begynder ikke-tom-gren
          // Sikkerhedstjek: Verificer om porten fysisk eksisterer
          H := CreateFileA(PAnsiChar(AnsiString('\\.\' + PName)), GENERIC_READ or GENERIC_WRITE,
                           0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
          { ^ Verifikationsåbning. Vi forsøger at åbne porten med
              eksklusiv adgang (share-mode 0). Hvis det lykkes, findes
              porten og er fri. Hvis det fejler med specifikke
              fejlkoder, kan vi stadig medtage den (se nedenfor).
              BEMÆRK STIEN: '\\.\' + PName er den korrekte enhedssti
              på Windows. '\.' + PName ville være ugyldig (FR-001). }

          if H <> THandle(-1) then                                          // Lykkedes åbningen?
          begin                                                             // Begynder succes-gren
            CloseHandle(H);                                                 // Luk straks igen — vi skulle kun verificere
            IsPresent := True;                                              // Porten findes og er fri
            { ^ Porten findes og er fri. Vi lukker den straks igen,
                fordi vi kun skulle verificere. Den faktiske åbning
                sker senere via TBlockSerial.Connect. }
          end                                                               // Slut succes-gren
          else                                                              // Ellers: åbningen fejlede
          begin                                                             // Begynder fejl-gren
            Err := GetLastError;                                            // Hent OS-fejlkoden
            // ERROR_ACCESS_DENIED (5) betyder at porten rent faktisk ER tilsluttet,
            // men pt. er optaget af et andet program (f.eks. Arduino IDE).
            // ERROR_FILE_NOT_FOUND (2) betyder at porten IKKE eksisterer.
            IsPresent := (Err = ERROR_ACCESS_DENIED) or (Err = ERROR_SHARING_VIOLATION);
            { ^ To fejlkoder indikerer, at porten FINDES, men er optaget:
                  ERROR_ACCESS_DENIED (5)     : en anden proces har
                                                allerede åbnet porten
                                                eksklusivt (fx Arduino
                                                IDE's Serial Monitor).
                  ERROR_SHARING_VIOLATION (32): en anden proces har
                                                åbnet porten med en
                                                delt share-mode, som
                                                ikke er kompatibel
                                                med vores eksklusive.
                I begge tilfælde skal porten vises i listen, så
                brugeren kan diagnosticere (FR-003).
                ERROR_FILE_NOT_FOUND (2) betyder derimod, at porten
                ikke eksisterer — så udelades den (FR-004). }
          end;                                                              // Slut fejl-gren

          if IsPresent then                                                 // Skal porten medtages?
          begin                                                             // Begynder medtag-gren
            if Result <> '' then Result := Result + ',';                    // Tilføj komma-separator hvis ikke første
            Result := Result + PName;                                       // Tilføj portnavnet
            { ^ Tilføjer portnavnet til den kommaseparerede liste.
                Komma tilføjes kun mellem elementer — ikke før det
                første, og ikke efter det sidste. Det giver et rent
                format som "COM3,COM5". }
          end;                                                              // Slut medtag-gren
        end;                                                                // Slut ikke-tom-gren
      end;                                                                  // Slut løkke
      Reg.CloseKey;                                                         // Lukker registry-nøglen
      { ^ Lukker nøglen, så Windows frigiver ressourcen. Selv om
          TRegistry's destructor også ville lukke den, er eksplicit
          CloseKey god praksis — det frigiver håndtaget med det samme
          i stedet for at vente på, at objektet frigives. }
    end;                                                                    // Slut succes-gren
  finally                                                                   // Uanset undtagelse:
    List.Free;                                                              // Frigiv listen
    Reg.Free;                                                               // Frigiv registry-objektet
    { ^ finally sikrer, at både List og Reg frigives, uanset om
        CreateFileA eller ReadString skulle kaste en undtagelse.
        Uden finally ville en fejl føre til hukommelseslæk. }
  end;                                                                      // Slut try/finally
end;                                                                        // Slut Windows-implementering
{$ELSE}
var                                                                         // UNIX-grenens lokale variable
  Info: TSearchRec;                                                         // FindFirst/FindNext-resultat
begin                                                                       // Begynder UNIX-implementeringen
  Result := '';                                                             // Initialiserer resultatet som tom streng
  if FindFirst('/dev/ttyUSB*', faAnyFile, Info) = 0 then                    // Søger efter FTDI/CH340-baserede kort
  begin                                                                     // Begynder ttyUSB-gren
    repeat                                                                  // Løkke over alle matches
      if Result <> '' then Result := Result + ',';                          // Tilføj komma hvis ikke første
      Result := Result + '/dev/' + Info.Name;                               // Tilføj det fulde enhedsnavn
    until FindNext(Info) <> 0;                                              // Gentag indtil ingen flere
    FindClose(Info);                                                        // Luk søgehåndtaget
    { ^ /dev/ttyUSB* dækker FTDI-, CH340- og CP210x-baserede
        Arduino-kort — de mest udbredte USB-serial-adaptere på Linux.
        FindFirst/FindNext er den idiomatiske måde at scanne et
        filsystem på i Pascal. }
  end;                                                                      // Slut ttyUSB-gren
  if FindFirst('/dev/ttyACM*', faAnyFile, Info) = 0 then                    // Søger efter native USB CDC-kort
  begin                                                                     // Begynder ttyACM-gren
    repeat                                                                  // Løkke over alle matches
      if Result <> '' then Result := Result + ',';                          // Tilføj komma hvis ikke første
      Result := Result + '/dev/' + Info.Name;                               // Tilføj det fulde enhedsnavn
    until FindNext(Info) <> 0;                                              // Gentag indtil ingen flere
    FindClose(Info);                                                        // Luk søgehåndtaget
    { ^ /dev/ttyACM* dækker native USB CDC-enheder som Arduino Uno
        R3, Leonardo og ESP32-S3. De kræver ingen ekstern USB-
        serial-adapter — MCU'en taler USB direkte.
        BEMÆRK: macOS bruger /dev/tty.usbmodem* og
        /dev/tty.usbserial*, som IKKE scannes her — en kendt
        begrænsning i denne forenklede udgave (FR-002). }
  end;                                                                      // Slut ttyACM-gren
end;                                                                        // Slut UNIX-implementering
{$ENDIF}

constructor TBlockSerial.Create;                                            // Opretter driver-instansen
{ ^ Initialiserer driver-instansen. Kaldes fra unitmain.FormCreate.
    Sætter alle felter til deres udgangsværdier. }
begin                                                                       // Begynder konstruktøren
  inherited Create;                                                         // Kalder TObject.Create
  FHandle := THandle(-1);                                                   // Ingen åben port endnu
  { ^ THandle(-1) er sentinel for "ikke åben". Det matcher både
      Windows' INVALID_HANDLE_VALUE og POSIX' fpopen-returværdi -1.
      Ved at bruge samme værdi i hele koden undgår vi forvirring. }

  FLastError := 0;                                                          // Ingen fejl endnu
  FLastErrorDesc := '';                                                     // Ingen fejlbeskrivelse
  FDTR := True;                                                             // Standard: DTR høj
  FRTS := True;                                                             // Standard: RTS høj
  { ^ DTR/RTS sættes til True som standard. Det matcher de fleste
      Arduino/ESP32-kort, hvor DTR høj betyder "MCU'en kører" (ikke
      i reset). Brugeren kan ændre det via checkboxes i GUI'et. }
end;                                                                        // Slut på Create

destructor TBlockSerial.Destroy;                                            // Frigiver driver-instansen
{ ^ Kaldes når instansen frigives (via FreeAndNil i unitmain.FormClose).
    Lukker porten for sikker oprydning, så vi ikke efterlader en låst
    COM-port. }
begin                                                                       // Begynder destructoren
  CloseSocket;                                                              // Luk porten hvis åben (idempotent)
  inherited Destroy;                                                        // Kalder TObject.Destroy
  { ^ CloseSocket er idempotent — den tjekker selv, om FHandle er
      gyldig. Så vi behøver ikke tjekke her. }
end;                                                                        // Slut på Destroy

procedure TBlockSerial.Connect(const DeviceName: string);                   // Åbner porten
{ ^ Åbner den serielle port med eksklusiv adgang (FR-006).
    Gemmer enhedsnavnet i FDevice og sætter FHandle.
    Ved fejl gemmes OS-fejlkoden i FLastError og en beskrivelse i
    FLastErrorDesc — kalderen tjekker FLastError efter kaldet. }
{$IFDEF WINDOWS}
var                                                                         // Windows-grenens lokale variable
  CommPort: string;                                                         // Fuld enhedssti (fx '\\.\COM3')
begin                                                                       // Begynder Windows-implementeringen
  CloseSocket;                                                              // Luk eventuel tidligere åben port
  { ^ Sikrer, at vi ikke lækker en tidligere handle, hvis Connect
      kaldes to gange uden CloseSocket imellem. CloseSocket er
      idempotent, så det er harmløst, hvis der ikke er noget at lukke. }

  FDevice := DeviceName;                                                    // Gem enhedsnavnet
  CommPort := '\\.\' + DeviceName;                                          // Byg fuld Windows-enhedssti
  { ^ Windows kræver '\\.\'-præfiks for at åbne COM-porte over COM9
      og for at undgå navnekollisioner med filnavne. Selv for COM1-9
      er det god praksis at bruge præfikset — det er den officielt
      anbefalede form. }

  FHandle := CreateFileA(PAnsiChar(AnsiString(CommPort)), GENERIC_READ or GENERIC_WRITE,
                         0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
  { ^ Åbner porten med:
        GENERIC_READ or GENERIC_WRITE : læse- og skriveadgang.
        0 (share-mode)                : EKSKLUSIV adgang — ingen
                                        andre processer kan åbne
                                        porten, mens vi har den.
                                        Dette opfylder FR-006.
        OPEN_EXISTING                 : porten skal allerede
                                        eksistere (vi opretter ikke
                                        en ny).
        FILE_ATTRIBUTE_NORMAL         : ingen specielle attributter.
      Ved fejl returnerer CreateFileA INVALID_HANDLE_VALUE (=
      THandle(-1)), og GetLastError giver den specifikke årsag. }

  if FHandle = THandle(-1) then                                             // Gik åbningen galt?
  begin                                                                     // Begynder fejl-gren
    FLastError := GetLastError;                                             // Gem OS-fejlkoden
    FLastErrorDesc := SysErrorMessage(FLastError);                          // Gem menneske-læsbar beskrivelse
    { ^ Typiske fejlkoder:
          ERROR_ACCESS_DENIED (5)      : porten er optaget af en
                                         anden proces (fx Arduino IDE).
          ERROR_FILE_NOT_FOUND (2)     : porten eksisterer ikke.
          ERROR_SHARING_VIOLATION (32) : porten er åbnet med en
                                         inkompatibel share-mode.
        SysErrorMessage giver en lokaliseret tekst, som kan vises
        direkte til brugeren. }
  end                                                                       // Slut fejl-gren
  else                                                                      // Ellers: åbningen lykkedes
  begin                                                                     // Begynder succes-gren
    FLastError := 0;                                                        // Nulstil fejlkode
    FLastErrorDesc := 'OK';                                                 // Sæt beskrivelse til "OK"
    SetupComm(FHandle, 4096, 4096);                                         // Sæt RX/TX-buffere til 4 KB
    { ^ SetupComm fortæller driveren, hvor store interne buffere
        den skal bruge. 4 KB er rigeligt til polling ved 115200 baud
        (~11.5 KB/s) med 50-100 ms interval — driveren kan rumme
        op til ~350 ms data, hvis GUI'en er langsom.
        HVORFOR 4 KB OG IKKE MERE?
          Større buffere giver ikke mening her, fordi vi poller
          hyppigt. 4 KB er en god balance mellem hukommelsesforbrug
          og robusthed over for korte GUI-pauser.
        BEMÆRK: Returværdien ignoreres. Hvis SetupComm fejler,
        bruger driveren sine standard-buffere — hvilket er
        acceptabelt. }
  end;                                                                      // Slut succes-gren
end;                                                                        // Slut Windows-implementering
{$ELSE}
begin                                                                       // Begynder UNIX-implementeringen
  CloseSocket;                                                              // Luk eventuel tidligere åben port
  FDevice := DeviceName;                                                    // Gem enhedsnavnet
  FHandle := fpopen(PChar(DeviceName), O_RDWR or O_NOCTTY or O_NONBLOCK);   // Åbn porten med non-blocking adgang
  { ^ fpopen åbner enheden med:
        O_RDWR     : læse- og skriveadgang.
        O_NOCTTY   : porten bliver IKKE vores controlling terminal
                     (forhindrer SIGHUP, hvis forbindelsen falder bort).
        O_NONBLOCK : åbningen blokerer ikke, selv om porten ikke er
                     klar. Selve læsningen bliver også non-blocking.
      Ved fejl returnerer fpopen -1, og fpGetErrno giver årsagen.
      BEMÆRK: FHandle er THandle (usigneret), så sammenligningen
      "FHandle < 0" nedenfor er teknisk set forkert — den bør være
      "FHandle = THandle(-1)". Dette er en kendt fejl i denne version. }

  if FHandle < 0 then                                                       // Gik åbningen galt?
  { ^ BEMÆRK: Dette tjek er teknisk set forkert på POSIX, fordi
      THandle er usigneret. THandle(-1) wrapper til en meget stor
      positiv værdi, og "FHandle < 0" evaluerer derfor False, selv
      når fpopen fejlede. Resultatet er, at en fejlet åbning
      rapporteres som "OK". Korrekt: "if FHandle = THandle(-1) then".
      Dette er en kendt fejl i denne version. }
  begin                                                                     // Begynder fejl-gren
    FLastError := fpGetErrno;                                               // Gem POSIX-fejlkoden
    FLastErrorDesc := SysErrorMessage(FLastError);                          // Gem menneske-læsbar beskrivelse
  end                                                                       // Slut fejl-gren
  else                                                                      // Ellers: åbningen lykkedes
  begin                                                                     // Begynder succes-gren
    FLastError := 0;                                                        // Nulstil fejlkode
    FLastErrorDesc := 'OK';                                                 // Sæt beskrivelse til "OK"
  end;                                                                      // Slut succes-gren
end;                                                                        // Slut UNIX-implementering
{$ENDIF}

procedure TBlockSerial.CloseSocket;                                         // Lukker porten
{ ^ Lukker den serielle port og nulstiller FHandle til THandle(-1).
    Idempotent — kan kaldes flere gange uden skade (NFR-008). }
begin                                                                       // Begynder procedurens krop
  if FHandle <> THandle(-1) then                                            // Er der en åben handle?
  { ^ Idempotens-tjek. Hvis FHandle allerede er THandle(-1), er der
      intet at lukke — vi springer over. Det gør det sikkert at
      kalde CloseSocket fra flere steder (BtnDisconnectClick,
      FormClose, destructor). }
  begin                                                                     // Begynder lukke-gren
    {$IFDEF WINDOWS}
    CloseHandle(FHandle);                                                   // Luk Windows-handle
    {$ELSE}
    fpclose(FHandle);                                                       // Luk POSIX-filbeskrivelse
    {$ENDIF}
    { ^ Platformsspecifik lukning. Begge frigiver OS-ressourcen.
        Returværdien ignoreres — hvis lukningen fejler, er der
        typisk fordi porten allerede er væk (fx USB trukket ud),
        og så er der intet at gøre. }

    FHandle := THandle(-1);                                                 // Markér som lukket
    { ^ Sætter handle til sentinel-værdien, så efterfølgende kald
        af CloseSocket ser, at der ikke er noget at lukke. Dette er
        kernen i idempotensen. }
  end;                                                                      // Slut lukke-gren
end;                                                                        // Slut på CloseSocket

procedure TBlockSerial.Config(Baud, Bits: Integer; Parity: Char; StopBits: Integer; {%H-}SoftFlow, {%H-}HardFlow: Boolean);
{ ^ Konfigurerer porten med baud, bits, paritet, stopbits og timeouts.
    Windows: DCB + COMMTIMEOUTS.
    UNIX: gemmer blot parametrene (termios ikke implementeret). }
{$IFDEF WINDOWS}
var                                                                         // Windows-grenens lokale variable
  DCB: TDCB;                                                                // Device Control Block
  Timeouts: TCOMMTIMEOUTS;                                                  // Timeout-konfiguration
begin                                                                       // Begynder Windows-implementeringen
  if FHandle = THandle(-1) then Exit;                                       // Kan ikke konfigurere en lukket port
  { ^ Defensivt tjek. Hvis porten ikke er åben, giver det ingen mening
      at forsøge at konfigurere den — SetCommState ville fejle. }

  FBaudRate := Baud;                                                        // Gem baudrate
  FDataBits := Bits;                                                        // Gem databits
  FParity := Parity;                                                        // Gem paritet
  FStopBits := StopBits;                                                    // Gem stopbits
  { ^ Gemmer parametrene i felterne, så de kan inspiceres senere
      (fx via properties, hvis vi tilføjer dem). }

  DCB := Default(TDCB);                                                     // Nulstil DCB-struktur
  FillChar(DCB, SizeOf(DCB), 0);                                            // Sikr alle bytes er 0
  DCB.DCBlength := SizeOf(DCB);                                             // Sæt strukturens størrelse
  { ^ DCB skal være nulstillet og have DCBlength sat, FØR GetCommState
      kaldes. Ellers kan GetCommState returnere uforudsigelige værdier
      for de felter, vi ikke selv sætter. }

  GetCommState(FHandle, DCB);                                               // Læs nuværende konfiguration
  { ^ Læser den nuværende DCB, så vi bevarer OS'ets standardindstillinger
      for de felter, vi ikke selv ændrer (fx flow control, XON/XOFF-
      tegn). BEMÆRK: Returværdien ignoreres — en kendt fejl (NFR-010). }

  DCB.BaudRate := Baud;                                                     // Sæt baudrate
  DCB.ByteSize := Bits;                                                     // Sæt databits

  case UpCase(Parity) of                                                    // Oversæt paritet til DCB-konstant
    'N': DCB.Parity := NOPARITY;                                            // N: ingen paritet
    'O': DCB.Parity := ODDPARITY;                                           // O: ulige paritet
    'E': DCB.Parity := EVENPARITY;                                          // E: lige paritet
    'M': DCB.Parity := MARKPARITY;                                          // M: mark-paritet (altid 1)
    'S': DCB.Parity := SPACEPARITY;                                         // S: space-paritet (altid 0)
    else DCB.Parity := NOPARITY;                                            // Ukendt: fallback til N
  end;                                                                      // Slut case
  { ^ Mapper den enkelt-bogstavs paritet-kode (N/O/E/M/S) til Windows'
      DCB-konstanter. UpCase gør det robust over for små bogstaver.
      Den defensive else-gren dækker ugyldige værdier. }

  case StopBits of                                                          // Oversæt stopbits til DCB-konstant
    SB1: DCB.StopBits := ONESTOPBIT;                                        // 1 stopbit
    SB1andHalf: DCB.StopBits := ONE5STOPBITS;                               // 1.5 stopbits
    SB2: DCB.StopBits := TWOSTOPBITS;                                       // 2 stopbits
    else DCB.StopBits := ONESTOPBIT;                                        // Ukendt: fallback til 1
  end;                                                                      // Slut case
  { ^ Mapper vores abstrakte SB1/SB1andHalf/SB2-konstanter til Windows'
      DCB-konstanter. }

  SetCommState(FHandle, DCB);                                               // Anvend DCB på porten
  { ^ Sender den konfigurerede DCB til driveren. Returværdien ignoreres
      — en kendt fejl (NFR-010). Hvis SetCommState fejler (fx på grund
      af ugyldige parametre), fortsætter vi uden at vide det. }

  // Timeouts til non-blocking polling
  Timeouts := Default(TCOMMTIMEOUTS);                                       // Nulstil timeouts
  Timeouts.ReadIntervalTimeout := MAXDWORD;                                 // Non-blocking læsning
  Timeouts.ReadTotalTimeoutMultiplier := 0;                                 // Ingen multiplikator
  Timeouts.ReadTotalTimeoutConstant := 0;                                   // Ingen konstant timeout
  Timeouts.WriteTotalTimeoutMultiplier := 0;                                // Ingen multiplikator
  Timeouts.WriteTotalTimeoutConstant := 500;                                // 500 ms skrive-timeout
  SetCommTimeouts(FHandle, Timeouts);                                       // Anvend timeouts
  { ^ Timeout-konfigurationen er kritisk for non-blocking adfærd:
        ReadIntervalTimeout = MAXDWORD OG
        ReadTotalTimeoutConstant = 0    : ReadFile returnerer
                                          ØJEBLIKKELIGT med de bytes,
                                          der er tilgængelige (kan
                                          være 0). Dette opfylder
                                          FR-008.
        WriteTotalTimeoutConstant = 500 : WriteFile blokerer i op
                                          til 500 ms, hvis TX-
                                          bufferen er fuld. Undgår
                                          uendelig blokering.
                                          Dette opfylder FR-009.
      BEMÆRK: Returværdien af SetCommTimeouts ignoreres — en kendt
      fejl (NFR-010). }
end;                                                                        // Slut Windows-implementering
{$ELSE}
begin                                                                       // Begynder UNIX-implementeringen
  // Linux termios konfiguration
  FBaudRate := Baud;                                                        // Gem baudrate
  FDataBits := Bits;                                                        // Gem databits
  FParity := Parity;                                                        // Gem paritet
  FStopBits := StopBits;                                                    // Gem stopbits
  { ^ Denne forenklede udgave gemmer blot parametrene — den anvender
      dem IKKE via tcsetattr. Det betyder, at porten kører med
      OS'ets nuværende termios-indstillinger, hvilket sjældent er
      det, brugeren ønsker. Dette er en kendt begrænsning (CON-02).
      En korrekt implementering ville kalde:
        tcgetattr(FHandle, @tio);
        cfsetispeed(@tio, BaudConstant);
        cfsetospeed(@tio, BaudConstant);
        tio.c_cflag := (tio.c_cflag and not CSIZE) or CS8;
        ... (paritet, stopbits, flow control)
        tcsetattr(FHandle, TCSANOW, @tio);
      men det er uden for denne versions omfang. }
end;                                                                        // Slut UNIX-implementering
{$ENDIF}

function TBlockSerial.WaitingData: Integer;                                 // Antal bytes i OS-buffer
{ ^ Returnerer antallet af bytes, som OS-bufferen aktuelt indeholder.
    Bruges af unitmain.TimerPollTimer til at afgøre, om der er data
    at læse — og i så fald hvor mange. }
{$IFDEF WINDOWS}
var                                                                         // Windows-grenens lokale variable
  Errors: DWORD;                                                            // Fejlflag fra ClearCommError
  ComStat: TCOMSTAT;                                                        // Kommunikationsstatus
begin                                                                       // Begynder Windows-implementeringen
  Result := 0;                                                              // Standard: ingen bytes
  if FHandle = THandle(-1) then Exit;                                       // Lukket port? Ingen data
  { ^ Defensivt tjek. En lukket port har ingen data, og ClearCommError
      ville fejle. }

  Errors := 0;                                                              // Nulstil fejlflag
  ComStat := Default(TCOMSTAT);                                             // Nulstil COMSTAT
  FillChar(ComStat, SizeOf(ComStat), 0);                                    // Sikr alle bytes er 0
  if ClearCommError(FHandle, Errors, @ComStat) then                         // Hent COMSTAT
    Result := ComStat.cbInQue;                                              // cbInQue = antal bytes i input-buffer
  { ^ ClearCommError er den officielle Windows-måde at få COMSTAT,
      som indeholder cbInQue (antal bytes i input-bufferen). Den
      rydder samtidig eventuelle fejlflag.
      HVORFOR ClearCommError OG IKKE EN ANDEN METODE?
        Der er ingen anden lige så direkte måde at få cbInQue på.
        Alternativet (PeekNamedPipe) virker ikke på COM-porte.
      BEMÆRK: Hvis ClearCommError fejler (fx pga. USB-frakobling),
      forbliver Result = 0. Kalderen (TimerPollTimer) ser så ingen
      data og gør intet — hvilket betyder, at USB-frakobling ikke
      opdages her. En kendt begrænsning (FR-015). }
end;                                                                        // Slut Windows-implementering
{$ELSE}
begin                                                                       // Begynder UNIX-implementeringen
  Result := 0;                                                              // Forenklet: altid 0
  { ^ Denne forenklede udgave returnerer altid 0 på POSIX. Det betyder,
      at unitmain.TimerPollTimer's gating "if BytesWaiting > 0" aldrig
      bliver sand, og RecvBufferStr aldrig kaldes. Resultatet er, at
      RX er død på Linux/macOS — en kendt, blokerende fejl (FR-012,
      FR-013).
      En korrekt implementering ville kalde:
        var n: cint;
        if fpioctl(FHandle, FIONREAD, @n) = 0 then Result := n;
      men det er uden for denne versions omfang. }
end;                                                                        // Slut UNIX-implementering
{$ENDIF}

function TBlockSerial.RecvBufferStr(Length: Integer; {%H-}TimeoutMs: Integer): AnsiString;
{ ^ Læser op til Length bytes fra porten og returnerer dem som en
    AnsiString. Returnerer en tom streng ved fejl eller ingen data. }
{$IFDEF WINDOWS}
var                                                                         // Windows-grenens lokale variable
  BytesRead: DWORD;                                                         // Antal faktisk læste bytes
begin                                                                       // Begynder Windows-implementeringen
  Result := '';                                                             // Standard: tom streng
  if FHandle = THandle(-1) then Exit;                                       // Lukket port? Ingen data
  { ^ Defensivt tjek. En lukket port kan ikke læses fra. }

  BytesRead := 0;                                                           // Nulstil tæller
  SetLength(Result, Length);                                                // Alloker plads til Length bytes
  { ^ Strengen skal have den korrekte længde, FØR ReadFile kan skrive
      ind i den. Uden SetLength ville vi skrive til en tom streng og
      få en range-check-fejl (debug) eller hukommelseskorruption
      (release). }

  if ReadFile(FHandle, PAnsiChar(Result)^, Length, BytesRead, nil) then     // Læs bytes
    SetLength(Result, BytesRead)                                            // Trim til faktisk læst antal
  else                                                                      // Ellers: fejl
    Result := '';                                                           // Returner tom streng
  { ^ ReadFile kan læse FÆRRE bytes end anmodet (fx hvis der kun er
      3 bytes i bufferen, men vi bad om 10). Vi trimmer Result til
      det faktisk læste antal, så kalderen ikke får null-bytes med.
      HVORFOR nil SOM OVERLAPPED?
        Vi har åbnet porten UDEN FILE_FLAG_OVERLAPPED, så ReadFile
        er synkron — men med non-blocking timeouts returnerer den
        straks med de tilgængelige bytes. nil er korrekt her.
      BEMÆRK: Ved fejl (fx USB-frakobling) returneres tom streng.
      Kalderen (TimerPollTimer) ser Length(RawChunk) = 0 og gør
      intet — hvilket betyder, at USB-frakobling ikke opdages.
      En kendt begrænsning (FR-015). }
end;                                                                        // Slut Windows-implementering
{$ELSE}
var                                                                         // UNIX-grenens lokale variable
  BytesRead: Integer;                                                       // Antal faktisk læste bytes
begin                                                                       // Begynder UNIX-implementeringen
  Result := '';                                                             // Standard: tom streng
  if FHandle < 0 then Exit;                                                 // Lukket port? Ingen data
  { ^ BEMÆRK: Samme usignerede-THandle-problem som i Connect. Dette
      tjek evaluerer altid False på POSIX, fordi THandle er usigneret.
      Korrekt: "if FHandle = THandle(-1) then". En kendt fejl. }

  SetLength(Result, Length);                                                // Alloker plads
  BytesRead := fpread(FHandle, PChar(Result)^, Length);                     // Læs bytes
  if BytesRead > 0 then                                                     // Lykkedes læsningen?
    SetLength(Result, BytesRead)                                            // Trim til faktisk læst antal
  else                                                                      // Ellers: ingen data eller fejl
    Result := '';                                                           // Returner tom streng
  { ^ fpread returnerer antal læste bytes, 0 ved ingen data (pga.
      O_NONBLOCK), eller -1 ved fejl. Vi behandler 0 og -1 ens
      (tom streng) — kalderen skelner ikke.
      BEMÆRK: Denne kode nås ALDRIG i praksis, fordi TimerPollTimer
      gater på WaitingData > 0, og WaitingData returnerer 0 på POSIX.
      En kendt, blokerende fejl (FR-012, FR-013). }
end;                                                                        // Slut UNIX-implementering
{$ENDIF}

function TBlockSerial.SendString(const Data: AnsiString): Integer;          // Skriver bytes til porten
{ ^ Skriver hele Data til porten og returnerer antal skrevne bytes.
    Ved delvis skrivning returneres det faktiske antal — kalderen
    bør tjekke, om alle bytes blev sendt. }
{$IFDEF WINDOWS}
var                                                                         // Windows-grenens lokale variable
  BytesWritten: DWORD;                                                      // Antal faktisk skrevne bytes
begin                                                                       // Begynder Windows-implementeringen
  Result := 0;                                                              // Standard: 0 bytes skrevet
  if FHandle = THandle(-1) then Exit;                                       // Lukket port? Intet at skrive til
  { ^ Defensivt tjek. En lukket port kan ikke skrives til. }

  BytesWritten := 0;                                                        // Nulstil tæller
  if WriteFile(FHandle, PAnsiChar(Data)^, Length(Data), BytesWritten, nil) then // Skriv bytes
    Result := BytesWritten;                                                 // Returner antal skrevne
  { ^ WriteFile kan skrive FÆRRE bytes end anmodet (delvis skrivning),
      hvis TX-bufferen er næsten fuld. Ved at returnere det faktiske
      antal kan kalderen afgøre, om hele kommandoen blev sendt.
      BEMÆRK: unitmain.BtnSendClick ignorerer returværdien — en
      kendt fejl (FR-029). }
end;                                                                        // Slut Windows-implementering
{$ELSE}
begin                                                                       // Begynder UNIX-implementeringen
  Result := 0;                                                              // Standard: 0 bytes skrevet
  if FHandle >= 0 then                                                      // Er porten åben?
  { ^ BEMÆRK: Samme usignerede-THandle-problem. "FHandle >= 0" er
      altid sandt på POSIX, også for THandle(-1). Korrekt:
      "if FHandle <> THandle(-1) then". En kendt fejl. }
    Result := fpwrite(FHandle, PChar(Data)^, Length(Data));                 // Skriv bytes
  { ^ fpwrite returnerer antal skrevne bytes, eller -1 ved fejl.
      Ved fejl returnerer vi -1 til kalderen — hvilket er teknisk
      set forkert (funktionen lover at returnere antal skrevne
      bytes, ikke fejlkoder). En kendt begrænsning. }
end;                                                                        // Slut UNIX-implementering
{$ENDIF}

procedure TBlockSerial.SetDTR(Value: Boolean);                              // Sætter DTR-linjen
{ ^ Sætter DTR-linjen til Value. Gemmer den ønskede tilstand i FDTR,
    uanset om det fysiske signal kunne sættes. }
begin                                                                       // Begynder procedurens krop
  FDTR := Value;                                                            // Gem ønsket tilstand
  { ^ Gemmer den ønskede tilstand. Selv om det fysiske signal ikke
      kunne sættes (fx fordi porten er lukket), er det nyttigt at
      vide, hvad brugeren forsøgte — fx til fejlfindingslogning. }

  {$IFDEF WINDOWS}
  if FHandle <> THandle(-1) then                                            // Er porten åben?
  begin                                                                     // Begynder Windows-gren
    if Value then                                                           // Skal DTR sættes høj?
      EscapeCommFunction(FHandle, WIN_SETDTR)                               // Sæt DTR høj
    else                                                                    // Ellers: sæt lav
      EscapeCommFunction(FHandle, WIN_CLRDTR);                              // Sæt DTR lav
    { ^ EscapeCommFunction er Windows' officielle måde at styre
        kontrolsignaler på. Returværdien ignoreres — hvis den fejler,
        opdages det ved næste I/O-operation. En kendt begrænsning
        (NFR-010), men acceptabel her. }
  end;                                                                      // Slut Windows-gren
  {$ENDIF}
  { ^ På POSIX gør denne metode intet ud over at gemme FDTR — en
      kendt begrænsning (FR-031, FR-034). En korrekt implementering
      ville kalde ioctl(FHandle, TIOCMBIS, TIOCM_DTR) for at sætte
      og ioctl(FHandle, TIOCMBIC, TIOCM_DTR) for at cleare. }
end;                                                                        // Slut på SetDTR

procedure TBlockSerial.SetRTS(Value: Boolean);                              // Sætter RTS-linjen
{ ^ Sætter RTS-linjen til Value. Samme mønster som SetDTR. }
begin                                                                       // Begynder procedurens krop
  FRTS := Value;                                                            // Gem ønsket tilstand

  {$IFDEF WINDOWS}
  if FHandle <> THandle(-1) then                                            // Er porten åben?
  begin                                                                     // Begynder Windows-gren
    if Value then                                                           // Skal RTS sættes høj?
      EscapeCommFunction(FHandle, WIN_SETRTS)                               // Sæt RTS høj
    else                                                                    // Ellers: sæt lav
      EscapeCommFunction(FHandle, WIN_CLRRTS);                              // Sæt RTS lav
  end;                                                                      // Slut Windows-gren
  {$ENDIF}
  { ^ Samme som SetDTR — på POSIX er dette en no-op ud over at gemme
      FRTS. En kendt begrænsning (FR-034). En korrekt implementering
      ville bruge ioctl(TIOCMBIS/TIOCMBIC, TIOCM_RTS). }
end;                                                                        // Slut på SetRTS

end.                                                                        // Slut på unit