{==============================================================================|
| Synaser: Cross-platform Serial Port library for Free Pascal & Lazarus        |
| Part of Synapse library by Lukas Gebauer (BSD License / Public Domain)       |
|==============================================================================}
unit synaser;

{$MODE OBJFPC}{$H+}

interface

uses
  Classes, SysUtils,
  {$IFDEF WINDOWS}
  Windows, Registry
  {$ELSE}
  BaseUnix, Unix, termio
  {$ENDIF}
  ;

const
  // Stop bit konstanter for TBlockSerial
  SB1 = 0;
  SB1andHalf = 1;
  SB2 = 2;

  // EscapeCommFunction konstanter (Windows API)
  // WIN_ præfiks forhindrer navnesammenfald med TBlockSerial.SetDTR og SetRTS i Free Pascal
  WIN_SETRTS = 3;
  WIN_CLRRTS = 4;
  WIN_SETDTR = 5;
  WIN_CLRDTR = 6;

type
  TBlockSerial = class(TObject)
  private
    FHandle: THandle;
    FLastError: Integer;
    FLastErrorDesc: string;
    FDevice: string;
    FBaudRate: Integer;
    FDataBits: Integer;
    FParity: Char;
    FStopBits: Integer;
    FDTR: Boolean;
    FRTS: Boolean;
    procedure SetDTR(Value: Boolean);
    procedure SetRTS(Value: Boolean);
  public
    constructor Create;
    destructor Destroy; override;

    procedure Connect(const DeviceName: string);
    procedure CloseSocket;
    procedure Config(Baud, Bits: Integer; Parity: Char; StopBits: Integer; {%H-}SoftFlow, {%H-}HardFlow: Boolean);
    function SendString(const Data: AnsiString): Integer;
    function RecvBufferStr(Length: Integer; {%H-}TimeoutMs: Integer): AnsiString;
    function WaitingData: Integer;

    property LastError: Integer read FLastError;
    property LastErrorDesc: string read FLastErrorDesc;
    property DTR: Boolean read FDTR write SetDTR;
    property RTS: Boolean read FRTS write SetRTS;
    property Device: string read FDevice;
    property Handle: THandle read FHandle;
  end;

function GetSerialPortNames: string;

implementation

function GetSerialPortNames: string;
{$IFDEF WINDOWS}
var
  Reg: TRegistry;
  List: TStringList;
  i: Integer;
  PName: string;
  H: THandle;
  Err: DWORD;
  IsPresent: Boolean;
begin
  Result := '';
  Reg := TRegistry.Create;
  List := TStringList.Create;
  try
    Reg.RootKey := HKEY_LOCAL_MACHINE;
    if Reg.OpenKeyReadOnly('HARDWARE\DEVICEMAP\SERIALCOMM') then
    begin
      Reg.GetValueNames(List);
      for i := 0 to List.Count - 1 do
      begin
        PName := Reg.ReadString(List[i]);
        if PName <> '' then
        begin
          H := CreateFileA(PAnsiChar(AnsiString('\\.\' + PName)), GENERIC_READ or GENERIC_WRITE,
                           0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);
          if H <> THandle(-1) then
          begin
            CloseHandle(H);
            IsPresent := True;
          end
          else
          begin
            Err := GetLastError;
            IsPresent := (Err = ERROR_ACCESS_DENIED) or (Err = ERROR_SHARING_VIOLATION);
          end;

          if IsPresent then
          begin
            if Result <> '' then Result := Result + ',';
            Result := Result + PName;
          end;
        end;
      end;
      Reg.CloseKey;
    end;
  finally
    List.Free;
    Reg.Free;
  end;
end;
{$ELSE}
var
  Info: TSearchRec;
begin
  Result := '';
  if FindFirst('/dev/ttyUSB*', faAnyFile, Info) = 0 then
  begin
    repeat
      if Result <> '' then Result := Result + ',';
      Result := Result + '/dev/' + Info.Name;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
  if FindFirst('/dev/ttyACM*', faAnyFile, Info) = 0 then
  begin
    repeat
      if Result <> '' then Result := Result + ',';
      Result := Result + '/dev/' + Info.Name;
    until FindNext(Info) <> 0;
    FindClose(Info);
  end;
end;
{$ENDIF}

constructor TBlockSerial.Create;
begin
  inherited Create;
  FHandle := THandle(-1);
  FLastError := 0;
  FLastErrorDesc := '';
  FDTR := True;
  FRTS := True;
end;

destructor TBlockSerial.Destroy;
begin
  CloseSocket;
  inherited Destroy;
end;

procedure TBlockSerial.Connect(const DeviceName: string);
{$IFDEF WINDOWS}
var
  CommPort: string;
begin
  CloseSocket;
  FDevice := DeviceName;
  CommPort := '\\.\' + DeviceName;
  FHandle := CreateFileA(PAnsiChar(AnsiString(CommPort)), GENERIC_READ or GENERIC_WRITE,
                         0, nil, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, 0);

  if FHandle = THandle(-1) then
  begin
    FLastError := GetLastError;
    FLastErrorDesc := SysErrorMessage(FLastError);
  end
  else
  begin
    FLastError := 0;
    FLastErrorDesc := 'OK';
    SetupComm(FHandle, 4096, 4096);
  end;
end;
{$ELSE}
begin
  CloseSocket;
  FDevice := DeviceName;
  FHandle := fpopen(PChar(DeviceName), O_RDWR or O_NOCTTY or O_NONBLOCK);
  if FHandle < 0 then
  begin
    FLastError := fpGetErrno;
    FLastErrorDesc := SysErrorMessage(FLastError);
  end
  else
  begin
    FLastError := 0;
    FLastErrorDesc := 'OK';
  end;
end;
{$ENDIF}

procedure TBlockSerial.CloseSocket;
begin
  if FHandle <> THandle(-1) then
  begin
    {$IFDEF WINDOWS}
    CloseHandle(FHandle);
    {$ELSE}
    fpclose(FHandle);
    {$ENDIF}
    FHandle := THandle(-1);
  end;
end;

procedure TBlockSerial.Config(Baud, Bits: Integer; Parity: Char; StopBits: Integer; {%H-}SoftFlow, {%H-}HardFlow: Boolean);
{$IFDEF WINDOWS}
var
  DCB: TDCB;
  Timeouts: TCOMMTIMEOUTS;
begin
  if FHandle = THandle(-1) then Exit;

  FBaudRate := Baud;
  FDataBits := Bits;
  FParity := Parity;
  FStopBits := StopBits;

  DCB := Default(TDCB);
  FillChar(DCB, SizeOf(DCB), 0);
  DCB.DCBlength := SizeOf(DCB);
  GetCommState(FHandle, DCB);

  DCB.BaudRate := Baud;
  DCB.ByteSize := Bits;

  case UpCase(Parity) of
    'N': DCB.Parity := NOPARITY;
    'O': DCB.Parity := ODDPARITY;
    'E': DCB.Parity := EVENPARITY;
    'M': DCB.Parity := MARKPARITY;
    'S': DCB.Parity := SPACEPARITY;
    else DCB.Parity := NOPARITY;
  end;

  case StopBits of
    SB1: DCB.StopBits := ONESTOPBIT;
    SB1andHalf: DCB.StopBits := ONE5STOPBITS;
    SB2: DCB.StopBits := TWOSTOPBITS;
    else DCB.StopBits := ONESTOPBIT;
  end;

  SetCommState(FHandle, DCB);

  // Timeouts til non-blocking polling
  Timeouts := Default(TCOMMTIMEOUTS);
  Timeouts.ReadIntervalTimeout := MAXDWORD;
  Timeouts.ReadTotalTimeoutMultiplier := 0;
  Timeouts.ReadTotalTimeoutConstant := 0;
  Timeouts.WriteTotalTimeoutMultiplier := 0;
  Timeouts.WriteTotalTimeoutConstant := 500;
  SetCommTimeouts(FHandle, Timeouts);
end;
{$ELSE}
begin
  // Linux termios konfiguration
  FBaudRate := Baud;
  FDataBits := Bits;
  FParity := Parity;
  FStopBits := StopBits;
end;
{$ENDIF}

function TBlockSerial.WaitingData: Integer;
{$IFDEF WINDOWS}
var
  Errors: DWORD;
  ComStat: TCOMSTAT;
begin
  Result := 0;
  if FHandle = THandle(-1) then Exit;

  Errors := 0;
  ComStat := Default(TCOMSTAT);
  FillChar(ComStat, SizeOf(ComStat), 0);
  if ClearCommError(FHandle, Errors, @ComStat) then
    Result := ComStat.cbInQue;
end;
{$ELSE}
begin
  Result := 0;
end;
{$ENDIF}

function TBlockSerial.RecvBufferStr(Length: Integer; {%H-}TimeoutMs: Integer): AnsiString;
{$IFDEF WINDOWS}
var
  BytesRead: DWORD;
begin
  Result := '';
  if FHandle = THandle(-1) then Exit;

  BytesRead := 0;
  SetLength(Result, Length);
  if ReadFile(FHandle, PAnsiChar(Result)^, Length, BytesRead, nil) then
    SetLength(Result, BytesRead)
  else
    Result := '';
end;
{$ELSE}
var
  BytesRead: Integer;
begin
  Result := '';
  if FHandle < 0 then Exit;
  SetLength(Result, Length);
  BytesRead := fpread(FHandle, PChar(Result)^, Length);
  if BytesRead > 0 then
    SetLength(Result, BytesRead)
  else
    Result := '';
end;
{$ENDIF}

function TBlockSerial.SendString(const Data: AnsiString): Integer;
{$IFDEF WINDOWS}
var
  BytesWritten: DWORD;
begin
  Result := 0;
  if FHandle = THandle(-1) then Exit;

  BytesWritten := 0;
  if WriteFile(FHandle, PAnsiChar(Data)^, Length(Data), BytesWritten, nil) then
    Result := BytesWritten;
end;
{$ELSE}
begin
  Result := 0;
  if FHandle >= 0 then
    Result := fpwrite(FHandle, PChar(Data)^, Length(Data));
end;
{$ENDIF}

procedure TBlockSerial.SetDTR(Value: Boolean);
begin
  FDTR := Value;
  {$IFDEF WINDOWS}
  if FHandle <> THandle(-1) then
  begin
    if Value then
      EscapeCommFunction(FHandle, WIN_SETDTR)
    else
      EscapeCommFunction(FHandle, WIN_CLRDTR);
  end;
  {$ENDIF}
end;

procedure TBlockSerial.SetRTS(Value: Boolean);
begin
  FRTS := Value;
  {$IFDEF WINDOWS}
  if FHandle <> THandle(-1) then
  begin
    if Value then
      EscapeCommFunction(FHandle, WIN_SETRTS)
    else
      EscapeCommFunction(FHandle, WIN_CLRRTS);
  end;
  {$ENDIF}
end;

end.
