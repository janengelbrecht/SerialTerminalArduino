/* ============================================================================
 *  FIL:        Arduino_Serial_Demo.ino
 *  FORMÅL:     Demonstrationsprogram til seriel kommunikation mellem en
 *              mikrocontroller (Arduino/ESP32/ESP8266/STM32) og en PC der
 *              kører Lazarus / Free Pascal Serial Terminal.
 *
 *  HVAD PROGRAMMET GØR (overordnet):
 *  ---------------------------------------------------------------------------
 *  Programmet gør tre ting i en uendelig løkke (loop()):
 *
 *    1) HVERT SEKUND sender det en linje data ud på den serielle port.
 *       Hvilken slags linje der sendes afhænger af en "mode"-variabel:
 *         Mode 0 = Almindelig telemetri (målinger, temperatur, fugtighed)
 *                  med danske specialtegn (æ, ø, å, Æ, Ø, Å).
 *         Mode 1 = En frame formateret som Modbus ASCII (industriprotokol).
 *         Mode 2 = En frame formateret som IBM Bisync (ældre IBM-protokol).
 *
 *    2) HELE TIDEN lytter det efter kommandoer FRA PC'en. Hvis PC'en
 *       sender f.eks. "LED_ON\n", så tænder programmet den indbyggede LED
 *       og svarer tilbage med en bekræftelse.
 *
 *    3) Kommandoen "MODE" skifter mellem de tre sendetilstande, så man
 *       kan teste, om Lazarus-programmet kan afkode alle tre formater.
 *
 *  UNDERSTØTTET HARDWARE OG SÆRLIGE FORHOLD:
 *  ---------------------------------------------------------------------------
 *  Programmet kan kompileres til mange forskellige boards, men der er
 *  vigtige forskelle man SKAL være opmærksom på:
 *
 *  ARDUINO UNO / NANO (ATmega328P):
 *    - Har KUN ÉN seriel port (Serial = USB-porten). Den bruges både til
 *      at sende data til PC'en OG til at modtage kommandoer.
 *    - Analog input hedder A0 og giver værdier fra 0 til 1023 (10 bit).
 *    - Den indbyggede LED sidder på digital pin 13 og er AKTIV HIGH.
 *    - Upload sker via en separat USB-serial-chip (ATmega16U2 eller CH340),
 *      så der er INGEN grund til at vente på at USB-porten "åbner".
 *    - Baudrate 115200 virker fint på originale boards, men nogle billige
 *      CH340-kopier kan have problemer. Denne kode bruger derfor 57600
 *      som default på AVR for maksimal kompatibilitet.
 *    - 2 KB RAM og 32 KB flash: Vi undgår String og bruger fast buffer.
 *
 *  ARDUINO MEGA 2560 (ATmega2560):
 *    - Har FLERE serielle porte: Serial, Serial1, Serial2, Serial3.
 *      "Serial" er stadig USB-porten til PC'en.
 *    - Analog input A0 giver 0..1023 (10 bit), ligesom Uno.
 *    - Indbygget LED på pin 13, AKTIV HIGH.
 *
 *  ESP32 (Espressif, f.eks. ESP32-WROOM-32):
 *    - Har 3 serielle porte. "Serial" er USB/COM-porten (via UART0).
 *    - GPIO 2 er boot-strap pin — vi bruger derfor GPIO 4 som ekstern LED.
 *    - Analog input: GPIO 34 (ADC1-kanal 6), 0..4095 (12 bit).
 *    - ADC2 (GPIO 25/26/27) kan IKKE bruges sammen med WiFi.
 *    - GPIO 34-39 er KUN input (ingen pull-up).
 *
 *  ESP8266 (f.eks. NodeMCU, Wemos D1 mini):
 *    - Har kun ÉN hardware-UART (Serial).
 *    - GPIO 2 SKAL være HIGH ved boot — vi bruger derfor GPIO 5 som LED.
 *    - Analog input: A0, 0..1023 (10 bit), typisk 0..1.0 V.
 *
 *  STM32 (f.eks. Blue Pill, Black Pill, Nucleo-boards):
 *    - Har typisk flere USART'er. "Serial" maps til den UART, som
 *      Arduino-kernen vælger. PÅ NOGLE CORES FINDES "Serial" IKKE
 *      AUTOMATISK — se kommentar i koden.
 *    - LED_BUILTIN er ofte PC13 på Blue Pill — AKTIV LOW.
 *    - Analog input: PA0 (ADC1-kanal 0), 0..4095 (12 bit).
 *
 *  FÆLLES FOR ALLE BOARDS:
 *    - Programmet bruger IKKE String-klassen (undgår heap-fragmentering).
 *    - Kommandoer skal afsluttes med '\n' eller '\r'.
 *    - Halve kommandoer kasseres efter 500 ms (CMD_TIMEOUT_MS).
 *
 *
 *  SÅDAN BRUGES PROGRAMMET:
 *    - Åbn en seriel terminal med BAUD_RATE, 8N1.
 *    - Skriv "PING" + Enter     -> boardet svarer "PONG".
 *    - Skriv "LED_ON" + Enter   -> LED tændes.
 *    - Skriv "LED_OFF" + Enter  -> LED slukkes.
 *    - Skriv "MODE" + Enter     -> skifter mellem de tre sendetilstande.
 *
 * ============================================================================
 */

/* ----------------------------------------------------------------------------
 *  SEKTION 0: INKLUDER NØDVENDIGE HEADERS
 *  ----------------------------------------------------------------------------
 *  [R13] Eksplicit inkludering af de headers, vi bruger funktioner fra.
 * -------------------------------------------------------------------------- */
#include <Arduino.h>        // pinMode, digitalWrite, Serial, millis, delay, osv.
#include <math.h>           // sin() — bruges til simuleret temperatur
#include <string.h>         // strlen, memcpy, strcpy, strcat — strengfunktioner
#include <stdint.h>         // uint8_t, uint16_t, uint32_t — faste heltalstyper
#ifndef DISABLE_SNPRINTF
  #include <stdio.h>        // snprintf — bruges til at bygge payload-streng
#endif


/* ----------------------------------------------------------------------------
 *  SEKTION 1: PLATFORMAFHÆNGIGE KONSTANTER OG MAKROER
 *  ----------------------------------------------------------------------------
 *  Forskellige boards har forskellige pin-navne, ADC-skalaer, baudrater og
 *  LED-polariteter. Vi bruger preprocessor-makroer til at vælge de rigtige
 *  værdier for den platform, koden kompileres til.
 * -------------------------------------------------------------------------- */

/* --- Standard-baudrate. Kan overskrives med en #define før inkludering. --- */
#ifndef BAUD_RATE                                         // Er BAUD_RATE ikke allerede defineret?
  #if defined(__AVR__)                                    // Er vi på en AVR (Uno/Nano/Mega)?
    #define BAUD_RATE 57600                               // AVR: 57600 er robust over for CH340
  #else                                                   // Ellers (ESP32/ESP8266/STM32)
    #define BAUD_RATE 115200                              // Ikke-AVR: 115200 er standard
  #endif                                                  // Slut på AVR-tjek
#endif                                                    // Slut på BAUD_RATE-tjek

/* --- Timeout for halve kommandoer (millisekunder) --- */
#define CMD_TIMEOUT_MS 500                                // Kassér halv kommando efter 500 ms

/* --- Maksimal længde på en kommando (inkl. null-terminator) --- */
#define CMD_BUF_SIZE 64                                   // 64 tegn er rigeligt til kommandoer

/* ----------------------------------------------------------------------------
 *  [R4] KØ TIL MODE-SKIFT
 *  ----------------------------------------------------------------------------
 *  Cirkulær kø med plads til 8 ventende mode-skift. Undgår race condition.
 * -------------------------------------------------------------------------- */
#define MODE_QUEUE_SIZE 8                                 // Plads til 8 ventende skift
int  modeQueue[MODE_QUEUE_SIZE];                          // Ring-buffer med ventende modes
int  modeQueueHead  = 0;                                  // Indeks hvor næste skift læses
int  modeQueueTail  = 0;                                  // Indeks hvor næste skift skrives
int  modeQueueCount = 0;                                  // Antal elementer i køen

/* Hjælpefunktion: læg et mode-skift i køen. Returnerer true ved succes. */
static bool enqueueMode(int newMode) {                    // Funktion: læg mode i køen
  if (modeQueueCount >= MODE_QUEUE_SIZE) {                // Er køen fuld?
    return false;                                         // Ja — returnér fejl
  }                                                       // Slut på fuld-tjek
  modeQueue[modeQueueTail] = newMode;                     // Skriv mode på tail-position
  modeQueueTail = (modeQueueTail + 1) % MODE_QUEUE_SIZE;  // Flyt tail (wrap ved ende)
  modeQueueCount++;                                       // Én mere i køen
  return true;                                            // Succes
}                                                         // Slut på enqueueMode

/* Hjælpefunktion: tag næste mode-skift fra køen. Returnerer -1 hvis tom. */
static int dequeueMode() {                                // Funktion: tag mode fra køen
  if (modeQueueCount <= 0) {                              // Er køen tom?
    return -1;                                            // Ja — signalér tom
  }                                                       // Slut på tom-tjek
  int v = modeQueue[modeQueueHead];                       // Læs mode fra head-position
  modeQueueHead = (modeQueueHead + 1) % MODE_QUEUE_SIZE;  // Flyt head (wrap ved ende)
  modeQueueCount--;                                       // Én mindre i køen
  return v;                                               // Returnér den læste mode
}                                                         // Slut på dequeueMode


/* ----------------------------------------------------------------------------
 *  SEKTION 2: PLATFORMVALG AF LED OG ADC
 *  ----------------------------------------------------------------------------
 *  [R1]  LED_ACTIVE_LOW : styrer om HIGH tænder eller slukker LED'en
 *  [R9]  LED_PIN valgt   : undgår boot-strap pins på ESP8266/ESP32
 *  [R10] ADC_PIN valgt   : undgår ADC2 på ESP32 (WiFi-konflikt)
 *  [R14] ADC_MAX_VAL     : ADC-skala pr. platform (10 vs 12 bit)
 * -------------------------------------------------------------------------- */

#if defined(ARDUINO_ARCH_ESP32)                           // Er vi på ESP32?
  #define LED_PIN         4                               // GPIO 4 = ekstern LED (sikker pin)
  #define LED_ACTIVE_LOW  false                           // GPIO 4 er aktiv HIGH
  #define ADC_PIN         34                              // GPIO 34 = ADC1-kanal 6
  #define ADC_MAX_VAL     4095                            // 12-bit ADC (0..4095)
  #define PLATFORM_NAME   "ESP32"                         // Navn til velkomstbanner

#elif defined(ARDUINO_ARCH_ESP8266)                       // Er vi på ESP8266?
  #define LED_PIN         5                               // GPIO 5 / D1 = ekstern LED (sikker)
  #define LED_ACTIVE_LOW  false                           // GPIO 5 er aktiv HIGH
  #define ADC_PIN         A0                              // A0 = eneste ADC-pin
  #define ADC_MAX_VAL     1023                            // 10-bit ADC (0..1023)
  #define PLATFORM_NAME   "ESP8266"                       // Navn til velkomstbanner

#elif defined(ARDUINO_ARCH_STM32)                         // Er vi på STM32?
  #define LED_PIN         LED_BUILTIN                     // Boardets indbyggede LED (ofte PC13)
  #define LED_ACTIVE_LOW  true                            // PC13 på Blue Pill er aktiv LOW
  #define ADC_PIN         PA0                             // PA0 = ADC1-kanal 0
  #define ADC_MAX_VAL     4095                            // 12-bit ADC (0..4095)
  #define PLATFORM_NAME   "STM32"                         // Navn til velkomstbanner

#else                                                     // Ellers: AVR (Uno/Nano/Mega)
  #define LED_PIN         13                              // Pin 13 = indbygget LED
  #define LED_ACTIVE_LOW  false                           // Pin 13 er aktiv HIGH
  #define ADC_PIN         A0                              // A0 = analog indgang
  #define ADC_MAX_VAL     1023                            // 10-bit ADC (0..1023)
  #define PLATFORM_NAME   "AVR (Uno/Nano/Mega)"           // Navn til velkomstbanner
#endif                                                    // Slut på platformvalg


/* ----------------------------------------------------------------------------
 *  SEKTION 3: GLOBALE VARIABLE
 *  ----------------------------------------------------------------------------
 *  Disse variable lever hele programmets levetid og husker tilstand mellem
 *  hver gennemløb af loop().
 * -------------------------------------------------------------------------- */

/* lastSendTime: Tidspunkt (ms siden opstart) for sidste telemetri-linje. */
unsigned long lastSendTime = 0;                           // Starter ved 0 ms

/* counter: Tæller der øges med 1 for hver telemetri-linje. */
unsigned long counter = 0;                                // Starter ved 0

/* mode: Hvilken sendetilstand vi er i lige nu (0, 1 eller 2). */
int mode = 0;                                             // Start i telemetri-mode

/* Kommando-buffer: her samles tegnene fra PC'en, indtil '\n' eller '\r'. */
char          cmdBuffer[CMD_BUF_SIZE];                    // Fast char-buffer (ingen String)
size_t        cmdIndex    = 0;                            // Antal tegn samlet indtil videre
unsigned long cmdLastRxMs = 0;                            // Tidspunkt for seneste modtagne tegn


/* ----------------------------------------------------------------------------
 *  SEKTION 4: HJÆLPEFUNKTIONER
 *  ----------------------------------------------------------------------------
 *  Små funktioner, der hver især løser én opgave. Gør loop() mere læsbar.
 * -------------------------------------------------------------------------- */

/* ----------------------------------------------------------------------------
 *  [R2] EGEN strcasecmp-IMPLEMENTATION
 *  ----------------------------------------------------------------------------
 *  Standard-C's strcasecmp er POSIX, ikke ISO C. På nogle indlejrede
 *  platforme findes den ikke i <string.h>. Derfor implementerer vi den selv.
 *
 *  Sammenligner to null-terminerede strenge uden at skelne mellem store og
 *  små bogstaver. Returnerer 0 hvis ens, <0 hvis a<b, >0 hvis a>b.
 * -------------------------------------------------------------------------- */
static int my_strcasecmp(const char *a, const char *b) {  // Funktion: case-insensitiv sammenligning
  while (*a != '\0' && *b != '\0') {                      // Så længe begge strenge har tegn tilbage
    unsigned char ca = (unsigned char)*a;                 // Læs tegn fra a som unsigned
    unsigned char cb = (unsigned char)*b;                 // Læs tegn fra b som unsigned
    if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca + ('a' - 'A'));  // a: A-Z -> a-z
    if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb + ('a' - 'A'));  // b: A-Z -> a-z
    if (ca != cb) {                                       // Er tegnene forskellige?
      return (int)ca - (int)cb;                           // Ja — returnér differensen
    }                                                     // Slut på forskel-tjek
    a++;                                                  // Gå til næste tegn i a
    b++;                                                  // Gå til næste tegn i b
  }                                                       // Slut på while-løkke
  unsigned char ca = (unsigned char)*a;                   // Læs resterende tegn fra a
  unsigned char cb = (unsigned char)*b;                   // Læs resterende tegn fra b
  if (ca >= 'A' && ca <= 'Z') ca = (unsigned char)(ca + ('a' - 'A'));  // Normalisér a
  if (cb >= 'A' && cb <= 'Z') cb = (unsigned char)(cb + ('a' - 'A'));  // Normalisér b
  return (int)ca - (int)cb;                               // Returnér differens (0 hvis begge slut)
}                                                         // Slut på my_strcasecmp


/* ----------------------------------------------------------------------------
 *  MODBUS ASCII LRC
 *  ----------------------------------------------------------------------------
 *  Summen af alle bytes, derefter to's komplement. Resultatet er én byte.
 *  Eksempel: {0x01,0x03,0x04,0x01,0xF4,0x00,0x2A} -> 0xD9
 * -------------------------------------------------------------------------- */
static uint8_t modbusLRC(const uint8_t *data, size_t len) {  // Funktion: beregn Modbus LRC
  uint8_t sum = 0;                                        // Start sum ved 0
  for (size_t i = 0; i < len; i++) {                      // Løb gennem alle bytes
    sum += data[i];                                       // Læg byte til sum (mod 256)
  }                                                       // Slut på for-løkke
  return (uint8_t)(-(int8_t)sum);                         // To's komplement af summen
}                                                         // Slut på modbusLRC


/* ----------------------------------------------------------------------------
 *  IBM BISYNC BCC
 *  ----------------------------------------------------------------------------
 *  [R6] FORENKLET BCC-variant: simpel XOR af payload. Rigtig IBM Bisync
 *  kan bruge CRC-16 eller LRC. Denne variant er kun kompatibel med en
 *  modtager, der bruger PRÆCIS samme variant.
 * -------------------------------------------------------------------------- */
static uint8_t bisyncBCC(const char *payload, size_t len) {  // Funktion: beregn Bisync BCC
  uint8_t bcc = 0;                                        // Start BCC ved 0
  for (size_t i = 0; i < len; i++) {                      // Løb gennem alle tegn
    bcc ^= (uint8_t)payload[i];                           // XOR tegn ind i BCC
  }                                                       // Slut på for-løkke
  return bcc;                                             // Returnér færdig BCC
}                                                         // Slut på bisyncBCC


/* ----------------------------------------------------------------------------
 *  HEX-BYTE UDSKRIVNING
 *  ----------------------------------------------------------------------------
 *  Skriver en byte som to hex-cifre (f.eks. 0x1F -> "1F"). Bruges i Modbus.
 * -------------------------------------------------------------------------- */
static void printHexByte(uint8_t b) {                     // Funktion: skriv byte som hex
  static const char hex[] = "0123456789ABCDEF";           // Hex-tabel (A-F med stort)
  Serial.write(hex[(b >> 4) & 0x0F]);                     // Høje nibble som hex-ciffer
  Serial.write(hex[b & 0x0F]);                            // Lave nibble som hex-ciffer
}                                                         // Slut på printHexByte


/* ----------------------------------------------------------------------------
 *  [R1] LED-HJÆLPEFUNKTIONER
 *  ----------------------------------------------------------------------------
 *  Håndterer LED-polaritet, så resten af koden kalder ledOn()/ledOff()
 *  uden at bekymre sig om aktiv HIGH/LOW.
 * -------------------------------------------------------------------------- */
static void ledOn() {                                     // Funktion: tænd LED
#if LED_ACTIVE_LOW                                        // Er LED'en aktiv LOW?
  digitalWrite(LED_PIN, LOW);                             // Ja — LOW tænder
#else                                                     // Ellers (aktiv HIGH)
  digitalWrite(LED_PIN, HIGH);                            // HIGH tænder
#endif                                                    // Slut på polaritetsvalg
}                                                         // Slut på ledOn

static void ledOff() {                                    // Funktion: sluk LED
#if LED_ACTIVE_LOW                                        // Er LED'en aktiv LOW?
  digitalWrite(LED_PIN, HIGH);                            // Ja — HIGH slukker
#else                                                     // Ellers (aktiv HIGH)
  digitalWrite(LED_PIN, LOW);                             // LOW slukker
#endif                                                    // Slut på polaritetsvalg
}                                                         // Slut på ledOff


/* ----------------------------------------------------------------------------
 *  FORWARDS-DEKLARATION
 *  ----------------------------------------------------------------------------
 *  handleCommand() bruges i loop() længere nede, men defineres efter loop().
 *  Derfor erklærer vi den her, så compileren kender signaturen.
 * -------------------------------------------------------------------------- */
static void handleCommand(char *cmd);                     // Prototype på handleCommand


/* ----------------------------------------------------------------------------
 *  SEKTION 5: setup() — KØRES ÉN GANG VED OPSTART
 *  ----------------------------------------------------------------------------
 *  Her initialiseres hardware og seriel kommunikation. Kører færdig før loop().
 * -------------------------------------------------------------------------- */
void setup() {                                            // setup() kaldes én gang ved opstart
  pinMode(LED_PIN, OUTPUT);                               // Sæt LED-pin til OUTPUT
  ledOff();                                               // Sluk LED straks (uanset polaritet)

  Serial.begin(BAUD_RATE);                                // Start seriel port med BAUD_RATE

#if defined(ARDUINO_ARCH_ESP32) || defined(ARDUINO_ARCH_STM32) || \
    defined(USBCON) || defined(ARDUINO_ARCH_SAMD)         // Har boardet native USB?
  delay(1000);                                            // Ja — vent 1 s på at USB-host åbner porten
#endif                                                    // Slut på native-USB-tjek

  Serial.println("==================================================");  // Overlinje i banner
  Serial.print  ("  Arduino Serial Test klar til Lazarus Terminal! ");  // Banner-tekst
  Serial.print  ("[");                                    // Start på platform-navn
  Serial.print  (PLATFORM_NAME);                          // Platform-navn (fx "ESP32")
  Serial.println("]");                                    // Afslut platform + ny linje
  Serial.print  ("  Baudrate: ");                         // Fast tekst
  Serial.println(BAUD_RATE);                              // Vis faktisk baudrate
  Serial.println("  Kommandoer: LED_ON, LED_OFF, MODE, PING");  // Liste over kommandoer
  Serial.println("==================================================");  // Underlinje i banner
}                                                         // Slut på setup


/* ----------------------------------------------------------------------------
 *  SEKTION 6: loop() — KØRES I EN UENDELIG LØKKE
 *  ----------------------------------------------------------------------------
 *  1) Anvend ventende mode-skift fra køen
 *  2) Hvert 1000 ms: send en linje i den aktuelle mode
 *  3) Hele tiden: læs kommandoer fra PC'en uden at blokere
 *  4) Tjek for timeout på halve kommandoer
 * -------------------------------------------------------------------------- */
void loop() {                                             // loop() kaldes i det uendelige
  unsigned long currentMillis = millis();                 // Aktuel tid i ms siden opstart

  int newMode;                                            // Midlertidig variabel til dequeue
  while ((newMode = dequeueMode()) >= 0) {                // Tøm køen: tag næste mode
    mode = newMode;                                       // Anvend det nye mode
    Serial.print(">>> Skiftede test-mode til: ");         // Fast tekst
    if (mode == 0) Serial.println("Normal Telemetri + Danske tegn");  // Mode 0: telemetri
    if (mode == 1) Serial.println("Modbus ASCII rammer"); // Mode 1: Modbus
    if (mode == 2) Serial.println("IBM Bisync rammer");   // Mode 2: Bisync
  }                                                       // Slut på kø-tømning

  if (currentMillis - lastSendTime >= 1000) {             // Er der gået 1000 ms?
    lastSendTime = currentMillis;                         // Ja — husk tidspunktet
    counter++;                                            // Tæl en ny måling

    switch (mode) {                                       // Vælg format ud fra mode

      case 0: {                                           // MODE 0: Almindelig telemetri
        float simulatedTemp = 21.5f + (sin((counter % 10000) * 0.1f) * 3.5f);  // Simuleret temp
        int   simulatedHum  = 50 + (int)(counter % 20);   // Simuleret fugtighed 50..69 %
        int   analogVal     = analogRead(ADC_PIN);        // Læs analog indgang

        Serial.print("[#");                               // Start på målingsnummer
        Serial.print(counter);                            // Målingsnummer
        Serial.print("] Måling: Temp=");                  // Fast tekst
        Serial.print(simulatedTemp, 1);                   // Temperatur med 1 decimal
        Serial.write(0xB0);                               // '°' i ISO-8859-1
        Serial.print("C | Fugtighed=");                   // Fast tekst
        Serial.print(simulatedHum);                       // Fugtighed i %
        Serial.print("% | A0=");                          // Fast tekst
        Serial.print(analogVal);                          // Analog værdi
        Serial.print("/");                                // Skilletegn
        Serial.print(ADC_MAX_VAL);                        // ADC-skala (1023 eller 4095)
        Serial.println(" | Danske tegn: æ, ø, å (Æ, Ø, Å)");  // Danske tegn + ny linje
        break;                                            // Forlad switch
      }

      case 1: {                                           // MODE 1: Modbus ASCII frame
        uint8_t frame[] = { 0x01, 0x03, 0x04, 0x01, 0xF4, 0x00, 0x2A };  // Frame-indhold
        uint8_t lrc = modbusLRC(frame, sizeof(frame));    // Beregn LRC dynamisk

        Serial.print(':');                                // Start-tegn ':'
        for (size_t i = 0; i < sizeof(frame); i++) {      // Løb gennem alle frame-bytes
          printHexByte(frame[i]);                         // Send byte som 2 hex-cifre
        }                                                 // Slut på for-løkke
        printHexByte(lrc);                                // Send LRC som 2 hex-cifre
        Serial.print("\r\n");                             // Afslut med CR LF (eksplicit)
        break;                                            // Forlad switch
      }

      case 2: {                                           // MODE 2: IBM Bisync frame
#ifndef DISABLE_SNPRINTF                                  // Er snprintf slået til?
        char payload[40];                                 // Buffer til payload-tekst
        snprintf(payload, sizeof(payload), "BISYNC_PAKKE_NR_%lu", counter);  // Byg payload
#else                                                     // Ellers (spar flash på AVR)
        char payload[40];                                 // Buffer til payload-tekst
        strcpy(payload, "BISYNC_PAKKE_NR_");              // Kopiér fast prefix
        char numbuf[12];                                  // Buffer til tal
        ultoa(counter, numbuf, 10);                       // Konvertér counter til tekst
        strcat(payload, numbuf);                          // Tilføj tal til payload
#endif                                                    // Slut på snprintf-valg
        size_t plen = strlen(payload);                    // Længde af payload
        uint8_t bcc = bisyncBCC(payload, plen);           // Beregn BCC (forenklet XOR)

        Serial.write(0x16);                               // SYN (1. synkroniseringstegn)
        Serial.write(0x16);                               // SYN (2. synkroniseringstegn)
        Serial.write(0x02);                               // STX (start of text)
        Serial.write((const uint8_t *)payload, plen);     // Payload som rå bytes
        Serial.write(0x03);                               // ETX (end of text)
        Serial.write(bcc);                                // BCC (block check character)
        break;                                            // Forlad switch (intet linjeskift!)
      }
    }                                                     // Slut på switch
  }                                                       // Slut på 1000-ms-tjek

  while (Serial.available() > 0) {                        // Er der tegn at læse?
    char c = (char)Serial.read();                         // Læs ét tegn
    cmdLastRxMs = currentMillis;                          // Husk seneste modtagelsestidspunkt

    if (c == '\n' || c == '\r') {                         // Er det et linjeskift?
      if (cmdIndex > 0) {                                 // Ja — er der noget i bufferen?
        cmdBuffer[cmdIndex] = '\0';                       // Afslut strengen med null
        char localCmd[CMD_BUF_SIZE];                      // Lokal kopi af kommandoen
        memcpy(localCmd, cmdBuffer, cmdIndex + 1);        // Kopiér inkl. null-terminator
        handleCommand(localCmd);                          // Behandl den lokale kopi
        cmdIndex = 0;                                     // Nulstil buffer til næste kommando
      }                                                   // Slut på tom-buffer-tjek
    } else if (cmdIndex < CMD_BUF_SIZE - 1) {             // Ellers — er der plads i bufferen?
      cmdBuffer[cmdIndex++] = c;                          // Gem tegnet og øg indeks
    } else {                                              // Ellers — buffer overløb
      cmdIndex = 0;                                       // Kassér hele kommandoen
    }                                                     // Slut på buffer-håndtering
  }                                                       // Slut på Serial.available-løkke

  if (cmdIndex > 0 && (currentMillis - cmdLastRxMs) > CMD_TIMEOUT_MS) {  // Halv kommando for gammel?
    Serial.println(">>> [Timeout] Halv kommando kasseret.");  // Informér brugeren
    cmdIndex = 0;                                         // Kassér den halve kommando
  }                                                       // Slut på timeout-tjek
}                                                         // Slut på loop


/* ----------------------------------------------------------------------------
 *  SEKTION 7: handleCommand() — BEHANDLER EN MODTAGET KOMMANDO
 *  ----------------------------------------------------------------------------
 *  Tager en null-termineret streng og sammenligner med de kendte kommandoer.
 *  Sammenligningen er case-insensitiv via vores egen my_strcasecmp.
 * -------------------------------------------------------------------------- */
static void handleCommand(char *cmd) {                    // Funktion: behandl én kommando
  Serial.print(">>> [Arduino Modtog]: '");                // Fast tekst
  Serial.print(cmd);                                      // Selve kommandoen
  Serial.println("'");                                    // Afsluttende apostrof + ny linje

  if (my_strcasecmp(cmd, "LED_ON") == 0) {                // Er kommandoen LED_ON?
    ledOn();                                              // Ja — tænd LED
    Serial.println(">>> LED er tændt!");                  // Bekræft til brugeren

  } else if (my_strcasecmp(cmd, "LED_OFF") == 0) {        // Er kommandoen LED_OFF?
    ledOff();                                             // Ja — sluk LED
    Serial.println(">>> LED er slukket!");                // Bekræft til brugeren

  } else if (my_strcasecmp(cmd, "MODE") == 0) {           // Er kommandoen MODE?
    int nextMode = (mode + 1) % 3;                        // Beregn næste mode (0->1->2->0)
    if (modeQueueCount > 0) {                             // Er der allerede ventende skift?
      int lastQueued = modeQueue[modeQueueTail - 1 < 0 ? MODE_QUEUE_SIZE - 1 : modeQueueTail - 1];  // Læs sidste i kø
      nextMode = (lastQueued + 1) % 3;                    // Basér næste på sidste i kø (ikke nuværende)
    }                                                     // Slut på kø-tjek
    if (enqueueMode(nextMode)) {                          // Læg skiftet i køen
      Serial.print(">>> Mode-skift sat i kø (kø-længde: ");  // Fast tekst
      Serial.print(modeQueueCount);                       // Vis kø-længde
      Serial.println(")");                                // Afslut parentes + ny linje
    } else {                                              // Køen er fuld
      Serial.println(">>> Fejl: Mode-køen er fuld, skift ignoreret.");  // Fejlbesked
    }                                                     // Slut på enqueue-tjek

  } else if (my_strcasecmp(cmd, "PING") == 0) {           // Er kommandoen PING?
    Serial.println(">>> PONG! Arduino er vågen og online.");  // Ja — svar PONG

  } else {                                                // Ukendt kommando
    Serial.println(">>> Ukendt kommando. Prøv: LED_ON, LED_OFF, MODE, PING");  // Hjælpebesked
  }                                                       // Slut på kommando-kæde
}                                                         // Slut på handleCommand