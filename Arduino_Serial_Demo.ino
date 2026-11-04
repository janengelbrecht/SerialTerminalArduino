/*
  Arduino / ESP32 / STM32 Seriel Test Sketch
  Til brug sammen med Lazarus / Free Pascal Serial Terminal

  Demonstrerer:
  1. Standard telemetri (Analog sensor, temperatur, tæller)
  2. Danske specialtegn (æ, ø, å) i UTF-8 og ISO-8859-1
  3. Modbus ASCII protokolrammer (:010300000002F4\r\n)
  4. IBM Bisync rammer med SYN, STX og ETX styretegn
  5. Modtagelse af kommandoer fra Lazarus terminalen (f.eks. 'LED_ON', 'LED_OFF', 'STATUS')
*/

const int LED_PIN = 13; // Indbygget LED på Uno/Nano (GPIO 2 på ESP32)
unsigned long lastSendTime = 0;
unsigned long counter = 0;
int mode = 0; // 0=Telemetri, 1=Modbus ASCII, 2=IBM Bisync

void setup() {
  pinMode(LED_PIN, OUTPUT);

  // Standard Arduino baud rate (kan ændres til 9600, 57600, 115200 osv.)
  Serial.begin(115200);

  // Vent på at serieporten er klar (vigtigt på Leonardo / STM32 / ESP32)
  delay(1000);

  Serial.println("==================================================");
  Serial.println("  Arduino Serial Test klar til Lazarus Terminal! ");
  Serial.println("  Kommandoer: LED_ON, LED_OFF, MODE, PING        ");
  Serial.println("==================================================");
}

void loop() {
  unsigned long currentMillis = millis();

  // Send periodiske data hvert 1000 ms
  if (currentMillis - lastSendTime >= 1000) {
    lastSendTime = currentMillis;
    counter++;

    // Skift mellem forskellige dataformater for at teste Lazarus afkoderen
    switch (mode) {
      case 0:
        // 1. Almindelig telemetri med sensorer og danske tegn
        {
          float simulatedTemp = 21.5 + (sin(counter * 0.1) * 3.5);
          int simulatedHum = 50 + (counter % 20);
          int analogVal = analogRead(A0);

          Serial.print("[#");
          Serial.print(counter);
          Serial.print("] Måling: Temp=");
          Serial.print(simulatedTemp, 1);
          Serial.print("°C | Fugtighed=");
          Serial.print(simulatedHum);
          Serial.print("% | A0=");
          Serial.print(analogVal);
          Serial.println(" | Danske tegn: æ, ø, å (Æ, Ø, Å)");
        }
        break;

      case 1:
        // 2. Modbus ASCII formateret frame
        // Kolon (':'), adresse, funktionskode, data, LRC checksum, CR LF
        {
          Serial.print(":010304"); // Slave 1, Func 03, 4 bytes
          Serial.print("01F4");   // Værdi 500 (Hex 01F4)
          Serial.print("002A");   // Værdi 42  (Hex 002A)
          Serial.println("DF");   // Beregnet LRC + CRLF
        }
        break;

      case 2:
        // 3. IBM Bisync format (SYN SYN STX <payload> ETX <BCC>)
        {
          // Send 2x SYN tegn (0x16 eller 0x32)
          Serial.write(0x16);
          Serial.write(0x16);
          // STX (Start of Text = 0x02)
          Serial.write(0x02);
          Serial.print("BISYNC_PAKKE_NR_");
          Serial.print(counter);
          // ETX (End of Text = 0x03)
          Serial.write(0x03);
          // Simpel Block Check Character (BCC)
          Serial.write(0x7F);
          Serial.println(); // Afsluttende linjeskift
        }
        break;
    }
  }

  // Læs kommandoer modtaget fra Lazarus programmet
  if (Serial.available() > 0) {
    String incomingCmd = Serial.readStringUntil('\n');
    incomingCmd.trim(); // Fjern whitespace og \r

    if (incomingCmd.length() > 0) {
      Serial.print(">>> [Arduino Modtog]: '");
      Serial.print(incomingCmd);
      Serial.println("'");

      if (incomingCmd.equalsIgnoreCase("LED_ON")) {
        digitalWrite(LED_PIN, HIGH);
        Serial.println(">>> LED er tændt!");
      }
      else if (incomingCmd.equalsIgnoreCase("LED_OFF")) {
        digitalWrite(LED_PIN, LOW);
        Serial.println(">>> LED er slukket!");
      }
      else if (incomingCmd.equalsIgnoreCase("MODE")) {
        mode = (mode + 1) % 3;
        Serial.print(">>> Skiftede test-mode til: ");
        if (mode == 0) Serial.println("Normal Telemetri + Danske tegn");
        if (mode == 1) Serial.println("Modbus ASCII rammer");
        if (mode == 2) Serial.println("IBM Bisync rammer");
      }
      else if (incomingCmd.equalsIgnoreCase("PING")) {
        Serial.println(">>> PONG! Arduino er vågen og online.");
      }
      else {
        Serial.println(">>> Ukendt kommando. Prøv: LED_ON, LED_OFF, MODE, PING");
      }
    }
  }
}
