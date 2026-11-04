unit unitmain;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Forms, Controls, Graphics, Dialogs, StdCtrls, ExtCtrls,
  ComCtrls, synaser;

type
  // Understøttede tegnkodninger
  TSerialEncoding = (
    encUTF8,
    encASCII,
    encISO88591,
    encUnicodeUTF16LE,
    encUnicodeUTF16BE,
    encModbusASCII,
    encIBMBisync
  );

  { TFormMain }

  TFormMain = class(TForm)
    BtnConnect: TButton;
    BtnDisconnect: TButton;
    BtnResetMCU: TButton;
    BtnRefreshPorts: TButton;
    BtnClear: TButton;
    BtnSend: TButton;
    CbBaudRate: TComboBox;
    CbComPort: TComboBox;
    CbDataBits: TComboBox;
    CbEncoding: TComboBox;
    CbLineEnding: TComboBox;
    CbParity: TComboBox;
    CbStopBits: TComboBox;
    ChkAutoScroll: TCheckBox;
    ChkDTR: TCheckBox;
    ChkHexView: TCheckBox;
    ChkRTS: TCheckBox;
    ChkTimestamp: TCheckBox;
    EditSend: TEdit;
    GrpEncoding: TGroupBox;
    GrpPortSettings: TGroupBox;
    GrpTerminal: TGroupBox;
    LblBaud: TLabel;
    LblDataBits: TLabel;
    LblEncoding: TLabel;
    LblLineEnding: TLabel;
    LblParity: TLabel;
    LblPort: TLabel;
    LblStopBits: TLabel;
    MemoTerminal: TMemo;
    PanelBottom: TPanel;
    PanelControls: TPanel;
    PanelStatus: TPanel;
    ShapeStatus: TShape;
    StatusBar1: TStatusBar;
    TimerPoll: TTimer;
    procedure BtnClearClick(Sender: TObject);
    procedure BtnConnectClick(Sender: TObject);
    procedure BtnDisconnectClick(Sender: TObject);
    procedure BtnResetMCUClick(Sender: TObject);
    procedure BtnRefreshPortsClick(Sender: TObject);
    procedure BtnSendClick(Sender: TObject);
    procedure ChkDTRChange(Sender: TObject);
    procedure ChkRTSChange(Sender: TObject);
    procedure EditSendKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
    procedure FormClose(Sender: TObject; var {%H-}CloseAction: TCloseAction);
    procedure FormCreate(Sender: TObject);
    procedure GrpTerminalClick(Sender: TObject);
    procedure TimerPollTimer(Sender: TObject);
  private
    FSerial: TBlockSerial;
    FIsConnected: Boolean;
    FRxByteCount: Int64;
    FTxByteCount: Int64;
    FRxBuffer: AnsiString;

    procedure RefreshComPorts;
    procedure UpdateUIState;
    procedure AppendToTerminal(const AText: string);
    function DecodeIncomingData(const RawBytes: AnsiString; Encoding: TSerialEncoding): string;
    function DecodeModbusASCII(const Raw: AnsiString): string;
    function DecodeIBMBisync(const Raw: AnsiString): string;
    function BytesToHexString(const Raw: AnsiString): string;
  public
  end;

var
  FormMain: TFormMain;

implementation

{$R *.lfm}

{ Konverterer ISO-8859-1 (Latin-1) til UTF-8 for korrekt visning af æ, ø, å }
function Latin1ToUTF8(const S: AnsiString): string;
var
  i, j, Len: Integer;
  B: Byte;
begin
  Result := '';
  Len := Length(S);
  if Len = 0 then Exit;

  SetLength(Result, Len * 2);
  j := 1;
  for i := 1 to Len do
  begin
    B := Byte(S[i]);
    if B < $80 then
    begin
      Result[j] := Chr(B);
      Inc(j);
    end
    else
    begin
      Result[j] := Chr($C0 or (B shr 6));
      Result[j + 1] := Chr($80 or (B and $3F));
      Inc(j, 2);
    end;
  end;
  SetLength(Result, j - 1);
end;

{ TFormMain }

procedure TFormMain.FormCreate(Sender: TObject);
begin
  FSerial := TBlockSerial.Create;
  FIsConnected := False;
  FRxByteCount := 0;
  FTxByteCount := 0;
  FRxBuffer := '';

  // Initialiser lister
  RefreshComPorts;

  // Standardværdier optimeret til Arduino / ESP32
  if CbComPort.Items.Count > 0 then
    CbComPort.ItemIndex := 0;

  CbBaudRate.ItemIndex := CbBaudRate.Items.IndexOf('115200');
  if CbBaudRate.ItemIndex = -1 then
    CbBaudRate.ItemIndex := CbBaudRate.Items.IndexOf('9600');

  CbParity.ItemIndex := 0;   // Ingen (None - N)
  CbDataBits.ItemIndex := 3; // 8 bits
  CbStopBits.ItemIndex := 0; // 1 stop bit
  CbEncoding.ItemIndex := 0; // UTF-8
  CbLineEnding.ItemIndex := 0; // CR + LF (\r\n)

  UpdateUIState;
  AppendToTerminal('=== Lazarus Arduino Seriel Terminal klar. Vælg port og tryk [Forbind] ===' + LineEnding);
end;

procedure TFormMain.GrpTerminalClick(Sender: TObject);
begin

end;

procedure TFormMain.FormClose(Sender: TObject; var {%H-}CloseAction: TCloseAction);
begin
  if FIsConnected then
    BtnDisconnectClick(nil);

  if Assigned(FSerial) then
    FreeAndNil(FSerial);
end;

procedure TFormMain.RefreshComPorts;
var
  PortList: string;
  RawList: TStringList;
  i: Integer;
begin
  CbComPort.Items.Clear;

  // Henter udelukkende porte som rent faktisk er tilsluttet computeren!
  PortList := GetSerialPortNames;
  if PortList <> '' then
  begin
    RawList := TStringList.Create;
    try
      RawList.CommaText := PortList;
      for i := 0 to RawList.Count - 1 do
      begin
        if Trim(RawList[i]) <> '' then
          CbComPort.Items.Add(Trim(RawList[i]));
      end;
    finally
      RawList.Free;
    end;
  end;

  // Hvis ingen enhed er tilsluttet, tilføjes INGEN falske porte!
  if CbComPort.Items.Count > 0 then
  begin
    CbComPort.ItemIndex := 0;
    BtnConnect.Enabled := not FIsConnected;
    StatusBar1.Panels[0].Text := IntToStr(CbComPort.Items.Count) + ' tilkoblet port fundet. Klar.';
  end
  else
  begin
    CbComPort.Items.Add('(Ingen tilkoblede COM-porte fundet)');
    CbComPort.ItemIndex := 0;
    BtnConnect.Enabled := False;
    StatusBar1.Panels[0].Text := 'Ingen Arduino tilsluttet. Sæt USB i og tryk [Genopfrisk].';
  end;
end;

procedure TFormMain.BtnRefreshPortsClick(Sender: TObject);
begin
  RefreshComPorts;
  if (CbComPort.Items.Count > 0) and (Pos('(', CbComPort.Items[0]) <> 1) then
    AppendToTerminal('[System] Port-liste opdateret: ' + CbComPort.Items.CommaText + LineEnding)
  else
    AppendToTerminal('[System] Ingen tilkoblede COM-porte fundet. Kontrollér USB-forbindelse.' + LineEnding);
end;

procedure TFormMain.BtnConnectClick(Sender: TObject);
var
  RawPortStr: string;
  PortName: string;
  Baud: Integer;
  Bits: Integer;
  ParityChar: Char;
  StopBitVal: Integer;
  p: Integer;
begin
  if (CbComPort.Text = '') or (Pos('(', CbComPort.Text) = 1) then
  begin
    ShowMessage('Der er ingen tilkoblet COM-port valgt!' + LineEnding +
                'Tilslut din Arduino via USB-kabel og tryk derefter på [Genopfrisk].');
    Exit;
  end;

  // Ekstraher rent portnavn hvis der er ekstra tekst (f.eks. "COM3 (Arduino)")
  RawPortStr := Trim(CbComPort.Text);
  p := Pos(' ', RawPortStr);
  if p > 0 then
    PortName := Copy(RawPortStr, 1, p - 1)
  else
    PortName := RawPortStr;

  Baud := StrToIntDef(CbBaudRate.Text, 115200);
  Bits := StrToIntDef(CbDataBits.Text, 8);

  // Paritet: Ingen (N), Ulige (O), Lige (E), Mark (M), Space (S)
  case CbParity.ItemIndex of
    0: ParityChar := 'N';
    1: ParityChar := 'O';
    2: ParityChar := 'E';
    3: ParityChar := 'M';
    4: ParityChar := 'S';
    else ParityChar := 'N';
  end;

  // Stopbits: 0 = 1 bit (SB1), 1 = 1.5 bit (SB1andHalf), 2 = 2 bits (SB2)
  case CbStopBits.ItemIndex of
    0: StopBitVal := SB1;
    1: StopBitVal := SB1andHalf;
    2: StopBitVal := SB2;
    else StopBitVal := SB1;
  end;

  try
    FSerial.Connect(PortName);
    if FSerial.LastError <> 0 then
    begin
      ShowMessage('Kunne ikke åbne ' + PortName + '.' + LineEnding +
                  'Fejl: ' + FSerial.LastErrorDesc + LineEnding + LineEnding +
                  'Bemærk: Tjek at Arduino IDE Serial Monitor eller et andet program ikke er åbent.');
      Exit;
    end;

    // Konfigurer serieportens parametre
    FSerial.Config(Baud, Bits, ParityChar, StopBitVal, False, False);

    // Initialiser DTR og RTS (afgørende for ATmega328P og ESP32 serial reset)
    FSerial.DTR := ChkDTR.Checked;
    FSerial.RTS := ChkRTS.Checked;

    FIsConnected := True;
    TimerPoll.Enabled := True;
    UpdateUIState;

    AppendToTerminal(Format(LineEnding + '[System] Forbundet til %s ved %d baud (%d%s%d).' + LineEnding +
                            '[System] Venter på Arduino starttelemetri...' + LineEnding,
      [PortName, Baud, Bits, ParityChar, CbStopBits.ItemIndex + 1]));
  except
    on E: Exception do
    begin
      ShowMessage('Fejl ved forbindelse til ' + PortName + ': ' + E.Message);
      FIsConnected := False;
      UpdateUIState;
    end;
  end;
end;

procedure TFormMain.BtnDisconnectClick(Sender: TObject);
begin
  TimerPoll.Enabled := False;

  if Assigned(FSerial) and FIsConnected then
  begin
    try
      FSerial.CloseSocket;
    except
    end;
  end;

  FIsConnected := False;
  UpdateUIState;
  AppendToTerminal(LineEnding + '[System] Forbindelse afbrudt.' + LineEnding);
end;

procedure TFormMain.BtnResetMCUClick(Sender: TObject);
begin
  if not FIsConnected or not Assigned(FSerial) then
  begin
    ShowMessage('Forbind først til en Arduino for at kunne nulstille den.');
    Exit;
  end;

  AppendToTerminal(LineEnding + '[System] Sender hardware-reset puls (DTR) til Arduino...' + LineEnding);
  // Puls DTR for at genstarte mikrokontrolleren
  FSerial.DTR := False;
  Sleep(150);
  FSerial.DTR := True;
  AppendToTerminal('[System] Arduino genstartet. Venter på bootloader (~1.5 sek)...' + LineEnding);
end;

procedure TFormMain.TimerPollTimer(Sender: TObject);
var
  BytesWaiting: Integer;
  RawChunk: AnsiString;
  DecodedText: string;
  SelectedEnc: TSerialEncoding;
begin
  if not FIsConnected or not Assigned(FSerial) then
    Exit;

  try
    BytesWaiting := FSerial.WaitingData;
    if BytesWaiting > 0 then
    begin
      // Læs kun tilgængelige bytes (Timeout 0 = 100% non-blocking for GUI)
      RawChunk := FSerial.RecvBufferStr(BytesWaiting, 0);
      if Length(RawChunk) > 0 then
      begin
        Inc(FRxByteCount, Length(RawChunk));
        StatusBar1.Panels[1].Text := 'RX: ' + IntToStr(FRxByteCount) + ' bytes';

        if ChkHexView.Checked then
        begin
          AppendToTerminal(BytesToHexString(RawChunk) + ' ');
        end
        else
        begin
          SelectedEnc := TSerialEncoding(CbEncoding.ItemIndex);
          DecodedText := DecodeIncomingData(RawChunk, SelectedEnc);
          AppendToTerminal(DecodedText);
        end;
      end;
    end;
  except
    on E: Exception do
    begin
      // Hvis USB-kablet frakobles fysisk under kørsel
      TimerPoll.Enabled := False;
      FIsConnected := False;
      UpdateUIState;
      AppendToTerminal(LineEnding + '[System] USB-forbindelse tabt: ' + E.Message + LineEnding);
      RefreshComPorts;
    end;
  end;
end;

function TFormMain.DecodeIncomingData(const RawBytes: AnsiString; Encoding: TSerialEncoding): string;
var
  i: Integer;
  WStr: WideString;
  Len: Integer;
begin
  Result := '';
  WStr := '';
  case Encoding of
    encUTF8:
      // Arduino og ESP32 sender typisk UTF-8 som rå bytes
      Result := string(RawBytes);

    encASCII:
      // Standard 7-bit ASCII: behold tegn 32..126 samt CR, LF, TAB
      begin
        SetLength(Result, Length(RawBytes));
        for i := 1 to Length(RawBytes) do
        begin
          if (Ord(RawBytes[i]) >= 32) or (RawBytes[i] in [#10, #13, #9]) then
            Result[i] := RawBytes[i]
          else
            Result[i] := '.'; // Udskift ikke-printbare kontroltegn med prik
        end;
      end;

    encISO88591:
      // Latin-1 konvertering (æ=0xE6, ø=0xF8, å=0xE5, Æ=0xC6, Ø=0xD8, Å=0xC5)
      Result := Latin1ToUTF8(RawBytes);

    encUnicodeUTF16LE:
      // 16-bit Little Endian (Standard Windows Unicode)
      begin
        Len := Length(RawBytes) div 2;
        if Len > 0 then
        begin
          SetLength(WStr, Len);
          Move(RawBytes[1], WStr[1], Len * 2);
          Result := UTF8Encode(WStr);
        end;
      end;

    encUnicodeUTF16BE:
      // 16-bit Big Endian: byt bytes
      begin
        Len := Length(RawBytes) div 2;
        if Len > 0 then
        begin
          SetLength(WStr, Len);
          for i := 1 to Len do
            WStr[i] := WideChar((Ord(RawBytes[(i - 1) * 2 + 1]) shl 8) or Ord(RawBytes[(i - 1) * 2 + 2]));
          Result := UTF8Encode(WStr);
        end;
      end;

    encModbusASCII:
      Result := DecodeModbusASCII(RawBytes);

    encIBMBisync:
      Result := DecodeIBMBisync(RawBytes);
  end;
end;

{ Modbus ASCII: Start ':' (0x3A), 2 hex cifre pr byte, CR LF afslutning }
function TFormMain.DecodeModbusASCII(const Raw: AnsiString): string;
var
  i: Integer;
  Ch: Char;
begin
  Result := '';
  for i := 1 to Length(Raw) do
  begin
    Ch := Raw[i];
    if Ch = ':' then
      Result := Result + '[MODBUS START :]'
    else if (Ch = #13) and (i < Length(Raw)) and (Raw[i+1] = #10) then
      Result := Result + '[END CRLF]' + LineEnding
    else if not (Ch in [#10, #13]) then
      Result := Result + Ch;
  end;
end;

{ IBM Bisync (Binary Synchronous Communication): SYN, STX, ETX, DLE, ACK, NAK }
function TFormMain.DecodeIBMBisync(const Raw: AnsiString): string;
var
  i: Integer;
  B: Byte;
begin
  Result := '';
  for i := 1 to Length(Raw) do
  begin
    B := Byte(Raw[i]);
    case B of
      $16, $32: Result := Result + '<SYN>';
      $02:      Result := Result + '<STX>';
      $03:      Result := Result + '<ETX>' + LineEnding;
      $04:      Result := Result + '<EOT>' + LineEnding;
      $05:      Result := Result + '<ENQ>';
      $06:      Result := Result + '<ACK>';
      $15:      Result := Result + '<NAK>';
      $10:      Result := Result + '<DLE>';
      $17:      Result := Result + '<ETB>';
      else
        if (B >= 32) and (B <= 126) then
          Result := Result + Chr(B)
        else
          Result := Result + Format('[0x%02X]', [B]);
    end;
  end;
end;

function TFormMain.BytesToHexString(const Raw: AnsiString): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(Raw) do
    Result := Result + IntToHex(Ord(Raw[i]), 2) + ' ';
end;

procedure TFormMain.AppendToTerminal(const AText: string);
var
  InsertStr: string;
begin
  if AText = '' then Exit;

  // Hukommelses- og stabilitetssikring:
  // Hvis Arduino sender kontinuerlig hurtig data (f.eks. 115200 baud),
  // beskæres de ældste linjer automatisk så TMemo ikke overfyldes eller fryser UI.
  if MemoTerminal.Lines.Count > 2500 then
  begin
    MemoTerminal.Lines.BeginUpdate;
    try
      while MemoTerminal.Lines.Count > 1500 do
        MemoTerminal.Lines.Delete(0);
    finally
      MemoTerminal.Lines.EndUpdate;
    end;
  end;

  InsertStr := AText;
  if ChkTimestamp.Checked and ((MemoTerminal.Lines.Count = 0) or (MemoTerminal.Lines[MemoTerminal.Lines.Count - 1] = '')) then
    InsertStr := '[' + FormatDateTime('hh:nn:ss.zzz', Now) + '] ' + AText;

  // Streaming indsættelse direkte ved slutningen af TMemo.
  // Dette bevarer Serial.print() (uden linjeskift) og behandler Serial.println()
  // naturligt præcis som den officielle Arduino IDE Serial Monitor!
  MemoTerminal.SelStart := Length(MemoTerminal.Text);
  MemoTerminal.SelLength := 0;
  MemoTerminal.SelText := InsertStr;

  if ChkAutoScroll.Checked then
  begin
    MemoTerminal.SelStart := Length(MemoTerminal.Text);
    MemoTerminal.SelLength := 0;
  end;
end;

procedure TFormMain.BtnSendClick(Sender: TObject);
var
  Cmd: AnsiString;
  Ending: AnsiString;
begin
  if not FIsConnected or not Assigned(FSerial) then
  begin
    ShowMessage('Ikke forbundet til nogen seriel port!');
    Exit;
  end;

  if EditSend.Text = '' then
    Exit;

  Cmd := AnsiString(EditSend.Text);

  // Vælg linjeafslutning til Arduino
  case CbLineEnding.ItemIndex of
    0: Ending := #13#10; // CR + LF
    1: Ending := #10;     // Kun LF
    2: Ending := #13;     // Kun CR
    3: Ending := '';      // Ingen
  end;

  Cmd := Cmd + Ending;

  try
    FSerial.SendString(Cmd);
    Inc(FTxByteCount, Length(Cmd));
    StatusBar1.Panels[2].Text := 'TX: ' + IntToStr(FTxByteCount) + ' bytes';

    AppendToTerminal('[Sendt -> Arduino]: ' + EditSend.Text + LineEnding);
    EditSend.Clear;
  except
    on E: Exception do
      ShowMessage('Fejl ved afsendelse: ' + E.Message);
  end;
end;

procedure TFormMain.EditSendKeyDown(Sender: TObject; var Key: Word; Shift: TShiftState);
begin
  if Key = 13 then // Enter tast
  begin
    BtnSendClick(nil);
    Key := 0;
  end;
end;

procedure TFormMain.BtnClearClick(Sender: TObject);
begin
  MemoTerminal.Clear;
  AppendToTerminal('=== Terminal ryddet ===' + LineEnding);
end;

procedure TFormMain.ChkDTRChange(Sender: TObject);
begin
  if FIsConnected and Assigned(FSerial) then
    FSerial.DTR := ChkDTR.Checked;
end;

procedure TFormMain.ChkRTSChange(Sender: TObject);
begin
  if FIsConnected and Assigned(FSerial) then
    FSerial.RTS := ChkRTS.Checked;
end;

procedure TFormMain.UpdateUIState;
var
  HasValidPort: Boolean;
begin
  HasValidPort := (CbComPort.Items.Count > 0) and (Pos('(', CbComPort.Text) <> 1);

  BtnConnect.Enabled := (not FIsConnected) and HasValidPort;
  BtnDisconnect.Enabled := FIsConnected;
  BtnResetMCU.Enabled := FIsConnected;
  BtnRefreshPorts.Enabled := not FIsConnected;

  CbComPort.Enabled := not FIsConnected;
  CbBaudRate.Enabled := not FIsConnected;
  CbParity.Enabled := not FIsConnected;
  CbDataBits.Enabled := not FIsConnected;
  CbStopBits.Enabled := not FIsConnected;

  BtnSend.Enabled := FIsConnected;
  EditSend.Enabled := FIsConnected;

  if FIsConnected then
  begin
    ShapeStatus.Brush.Color := clLime;
    StatusBar1.Panels[0].Text := 'Forbundet: ' + CbComPort.Text;
  end
  else
  begin
    ShapeStatus.Brush.Color := clRed;
    if HasValidPort then
      StatusBar1.Panels[0].Text := 'Afbrudt (Klar til at forbinde)'
    else
      StatusBar1.Panels[0].Text := 'Ingen Arduino tilsluttet. Sæt USB i og tryk [Genopfrisk].';
  end;
end;

end.
