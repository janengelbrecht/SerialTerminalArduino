/*
  Arduino / ESP32 / STM32 Serial Test Sketch
  Til brug sammen med Lazarus / Free Pascal Serial Terminal

  Demonstrerer:
  1. Standard telemetri (Analog sensor, temperatur, tæller)
  2. Danske specialtegn (æ, ø, å) i UTF-8 og ISO-8859-1
  3. Modbus ASCII protokolrammer (:010300000002F4\r\n)
  4. IBM Bisync rammer med SYN, STX og ETX styretegn
  5. Modtagelse af kommandoer fra Lazarus terminalen (f.eks. 'LED_ON', 'LED_OFF', 'STATUS')

  Rettet version — se kommentarer markeret med [FIX].
*/

// [FIX #1] Platformafhængig LED-pin
#if defined(ARDUINO_ARCH_ESP32)
  const int LED_PIN = 2;
  const int ADC_PIN = 34;
#elif defined(ARDUINO_ARCH_STM32)
  const int LED_PIN = LED_BUILTIN;
  const int ADC_PIN = PA0;
#else
  const int LED_PIN = 13;
  const int ADC_PIN = A0;
#endif

unsigned long lastSendTime = 0;
unsigned long counter = 0;
int mode = 0;            // 0=Telemetri, 1=Modbus ASCII, 2=IBM Bisync
int pendingMode = -1;    // [FIX #8] Anvendes i loop() i stedet for direkte

// [FIX #3] Ikke-blokerende kommando-buffer
const size_t CMD_BUF_SIZE = 64;
char cmdBuffer[CMD_BUF_SIZE];
size_t cmdIndex = 0;

void setup() {
  pinMode(LED_PIN, OUTPUT);

  Serial.begin(115200);

  // [FIX #9] Kun nødvendigt på boards med native USB
#if defined(ARDUINO_ARCH_ESP32) || defined(ARDUINO_ARCH_STM32) || \
    defined(USBCON) || defined(ARDUINO_ARCH_SAMD)
  delay(1000);
#endif

  Serial.println("==================================================");
  Serial.println("  Arduino Serial Test klar til Lazarus Terminal! ");
  Serial.println("  Kommandoer: LED_ON, LED_OFF, MODE, PING        ");
  Serial.println("==================================================");
}

// [FIX #5] Beregn Modbus ASCII LRC dynamisk
static uint8_t modbusLRC(const uint8_t *data, size_t len) {
  uint8_t sum = 0;
  for (size_t i = 0; i < len; i++) sum += data[i];
  return (uint8_t)(-(int8_t)sum);
}

// [FIX #6] Beregn Bisync BCC som XOR af payload
static uint8_t bisyncBCC(const char *payload, size_t len) {
  uint8_t bcc = 0;
  for (size_t i = 0; i < len; i++) bcc ^= (uint8_t)payload[i];
  return bcc;
}

// [FIX #7] Send hex-byte med 2 cifre
static void printHexByte(uint8_t b) {
  const char *hex = "0123456789ABCDEF";
  Serial.write(hex[(b >> 4) & 0x0F]);
  Serial.write(hex[b & 0x0F]);
}

void loop() {
  unsigned long currentMillis = millis();

  // [FIX #8] Anvend pending mode-skift i loop-start
  if (pendingMode >= 0) {
    mode = pendingMode;
    pendingMode = -1;
    Serial.print(">>> Skiftede test-mode til: ");
    if (mode == 0) Serial.println("Normal Telemetri + Danske tegn");
    if (mode == 1) Serial.println("Modbus ASCII rammer");
    if (mode == 2) Serial.println("IBM Bisync rammer");
  }

  if (currentMillis - lastSendTime >= 1000) {
    lastSendTime = currentMillis;
    counter++;

    switch (mode) {
      case 0: {
        // [FIX #12] Modulo for at undgå præcisionstab
        float simulatedTemp = 21.5f + (sin((counter % 1000) * 0.1f) * 3.5f);
        int simulatedHum = 50 + (counter % 20);
        int analogVal = analogRead(ADC_PIN);

        Serial.print("[#");
        Serial.print(counter);
        Serial.print("] Måling: Temp=");
        Serial.print(simulatedTemp, 1);
        // [FIX #10] Send ISO-8859-1 gradtegn (0xB0) i stedet for UTF-8 °
        Serial.write(0xB0);
        Serial.print("C | Fugtighed=");
        Serial.print(simulatedHum);
        Serial.print("% | A0=");
        Serial.print(analogVal);
        Serial.println(" | Danske tegn: æ, ø, å (Æ, Ø, Å)");
        break;
      }

      case 1: {
        // [FIX #5, #13] Korrekt LRC beregnet dynamisk + eksplicit CRLF
        uint8_t frame[] = { 0x01, 0x03, 0x04, 0x01, 0xF4, 0x00, 0x2A };
        uint8_t lrc = modbusLRC(frame, sizeof(frame));

        Serial.print(':');
        for (size_t i = 0; i < sizeof(frame); i++) printHexByte(frame[i]);
        printHexByte(lrc);
        Serial.print("\r\n");
        break;
      }

      case 2: {
        // [FIX #6, #7] Korrekt BCC + ingen println efter BCC
        char payload[32];
        snprintf(payload, sizeof(payload), "BISYNC_PAKKE_NR_%lu", counter);
        size_t plen = strlen(payload);
        uint8_t bcc = bisyncBCC(payload, plen);

        Serial.write(0x16);          // SYN
        Serial.write(0x16);          // SYN
        Serial.write(0x02);          // STX
        Serial.write((const uint8_t *)payload, plen);
        Serial.write(0x03);          // ETX
        Serial.write(bcc);           // BCC
        // [FIX #7] Ingen println() — det ville korrumpere rammen
        break;
      }
    }
  }

  // [FIX #3, #4] Ikke-blokerende tegnvis kommando-læsning
  while (Serial.available() > 0) {
    char c = (char)Serial.read();
    if (c == '\n' || c == '\r') {
      if (cmdIndex > 0) {
        cmdBuffer[cmdIndex] = '\0';
        handleCommand(cmdBuffer);
        cmdIndex = 0;
      }
    } else if (cmdIndex < CMD_BUF_SIZE - 1) {
      cmdBuffer[cmdIndex++] = c;
    } else {
      // Buffer overløb — kassér
      cmdIndex = 0;
    }
  }
}

// [FIX #4] Sammenlign med strcasecmp i stedet for String::equalsIgnoreCase
static void handleCommand(char *cmd) {
  Serial.print(">>> [Arduino Modtog]: '");
  Serial.print(cmd);
  Serial.println("'");

  if (strcasecmp(cmd, "LED_ON") == 0) {
    digitalWrite(LED_PIN, HIGH);
    Serial.println(">>> LED er tændt!");
  } else if (strcasecmp(cmd, "LED_OFF") == 0) {
    digitalWrite(LED_PIN, LOW);
    Serial.println(">>> LED er slukket!");
  } else if (strcasecmp(cmd, "MODE") == 0) {
    // [FIX #8] Sæt flag — anvendes i loop()
    pendingMode = (mode + 1) % 3;
  } else if (strcasecmp(cmd, "PING") == 0) {
    Serial.println(">>> PONG! Arduino er vågen og online.");
  } else {
    Serial.println(">>> Ukendt kommando. Prøv: LED_ON, LED_OFF, MODE, PING");
  }
}