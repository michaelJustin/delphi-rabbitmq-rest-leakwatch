unit uConfig;

{ Configuration from the INI file and the command line (the command line
  wins), and the identity of this process.

  Command line switches (-name=value or /name=value, names not case
  sensitive):
    -id=<AppId>          display label of this instance
    -mode=A|B            leak generator mode
    -autostart           connect and start the generator after start-up
    -runfor=<minutes>    close normally after that time
    -seed=<n>            random seed of the generator
    -eventlog=<path>     detector event log (default: next to the exe)
    -ini=<path>          INI file (default: LeakWatch.ini next to the exe)
    -reportleaks         FastMM4 leak report at exit (= the checkbox) }

interface

uses
  Classes, IniFiles, uTransport, uLeakDetector;

const
  MinIntervalMs = 500;

type
  TGeneratorMode = (gmChurn, gmGrowth);  // Mode A, Mode B

  TGeneratorSettings = record
    Mode: TGeneratorMode;
    { Mode A, random churn }
    ChurnMinIntervalMs: Integer;
    ChurnMaxIntervalMs: Integer;
    ChurnMaxObjects: Integer;
    ChurnMinSize: Integer;
    ChurnMaxSize: Integer;
    ChurnMinLifetimeMs: Integer;
    ChurnMaxLifetimeMs: Integer;
    { Mode B, continuous growth }
    GrowthRate: Integer;  // objects per second
    GrowthMinSize: Integer;
    GrowthMaxSize: Integer;
    ReleaseEnabled: Boolean;
    ReleaseAfterSeconds: Integer;
    ReleaseAfterObjects: Integer;  // 0 = no object limit
    PermanentPercent: Integer;
  end;

  TAppIdSource = (aisCommandLine, aisIni, aisGenerated);

  TLeakWatchConfig = class
  private
    FUnknownSwitches: TStringList;
    FWarnings: TStringList;
    procedure ApplySwitch(const Name, Value: string; HasValue: Boolean);
  public
    IniFileName: string;
    Broker: TBrokerSettings;
    InstanceId: string;
    AppId: string;
    AppIdSource: TAppIdSource;
    IntervalMs: Integer;
    PollMs: Integer;
    StoreCapacity: Integer;
    Detector: TDetectorSettings;
    Generator: TGeneratorSettings;
    { command line only }
    AutoStart: Boolean;
    RunForMinutes: Double;  // 0 = run until closed
    HasSeed: Boolean;
    Seed: Cardinal;
    EventLogFile: string;
    ReportLeaks: Boolean;

    constructor Create;
    destructor Destroy; override;
    { Sets defaults, then reads the INI file named by -ini (or the default)
      and applies the switches. Args holds the command line arguments
      without the program name. }
    procedure Load(Args: TStrings; const ExeName: string);
    procedure LoadIni(const FileName: string);
    procedure SaveBroker;
    property UnknownSwitches: TStringList read FUnknownSwitches;
    property Warnings: TStringList read FWarnings;
  end;

function DefaultGeneratorSettings: TGeneratorSettings;
function ModeToStr(Mode: TGeneratorMode): string;
function HostName: string;
function DefaultInstanceId: string;
{ Parses "1.5" (also "1,5"), independent of the Windows locale }
function TryStrToFloatInvariant(const S: string; out Value: Double): Boolean;
function FloatToStrInvariant(Value: Double): string;
procedure ParamsToStrings(Target: TStrings);

implementation

uses
  Windows, SysUtils;

var
  InvariantFormat: TFormatSettings;

function DefaultGeneratorSettings: TGeneratorSettings;
begin
  Result.Mode := gmChurn;
  Result.ChurnMinIntervalMs := 50;
  Result.ChurnMaxIntervalMs := 200;
  Result.ChurnMaxObjects := 10;
  Result.ChurnMinSize := 64;
  Result.ChurnMaxSize := 16384;
  Result.ChurnMinLifetimeMs := 1000;
  Result.ChurnMaxLifetimeMs := 30000;
  // about 20 * 4.6 KB = 92 KB/s, 5.4 MB/min
  Result.GrowthRate := 20;
  Result.GrowthMinSize := 1024;
  Result.GrowthMaxSize := 8192;
  Result.ReleaseEnabled := False;
  Result.ReleaseAfterSeconds := 180;
  Result.ReleaseAfterObjects := 0;
  Result.PermanentPercent := 10;
end;

function ModeToStr(Mode: TGeneratorMode): string;
begin
  if Mode = gmGrowth then
    Result := 'B'
  else
    Result := 'A';
end;

function HostName: string;
var
  Buffer: array[0..MAX_COMPUTERNAME_LENGTH] of Char;
  Size: DWORD;
begin
  Size := Length(Buffer);
  if GetComputerName(Buffer, Size) then
    SetString(Result, Buffer, Size)
  else
    Result := 'unknown';
end;

function DefaultInstanceId: string;
begin
  Result := HostName + '-' + IntToStr(GetCurrentProcessId);
end;

function TryStrToFloatInvariant(const S: string; out Value: Double): Boolean;
begin
  Result := TryStrToFloat(StringReplace(Trim(S), ',', '.', []), Value, InvariantFormat);
end;

function FloatToStrInvariant(Value: Double): string;
begin
  Result := FloatToStr(Value, InvariantFormat);
end;

procedure ParamsToStrings(Target: TStrings);
var
  I: Integer;
begin
  for I := 1 to ParamCount do
    Target.Add(ParamStr(I));
end;

function SafeFileNamePart(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if CharInSet(Result[I], ['\', '/', ':', '*', '?', '"', '<', '>', '|']) or (Result[I] < ' ') then
      Result[I] := '_';
end;

function ReadFloat(Ini: TCustomIniFile; const Section, Key: string; Default: Double): Double;
begin
  if not TryStrToFloatInvariant(Ini.ReadString(Section, Key, ''), Result) then
    Result := Default;
end;

{ TLeakWatchConfig }

constructor TLeakWatchConfig.Create;
begin
  inherited Create;
  FUnknownSwitches := TStringList.Create;
  FWarnings := TStringList.Create;
end;

destructor TLeakWatchConfig.Destroy;
begin
  FWarnings.Free;
  FUnknownSwitches.Free;
  inherited Destroy;
end;

procedure TLeakWatchConfig.LoadIni(const FileName: string);
var
  Ini: TMemIniFile;
  D: TDetectorSettings;
  G: TGeneratorSettings;
  Value: string;
begin
  IniFileName := FileName;
  Ini := TMemIniFile.Create(FileName, TEncoding.UTF8);
  try
    Broker.Host := Ini.ReadString('Broker', 'Host', Broker.Host);
    Broker.Port := Ini.ReadInteger('Broker', 'Port', Broker.Port);
    Broker.User := Ini.ReadString('Broker', 'User', Broker.User);
    Broker.Password := Ini.ReadString('Broker', 'Password', Broker.Password);
    Broker.VHost := Ini.ReadString('Broker', 'VHost', Broker.VHost);
    Broker.TimeoutMs := Ini.ReadInteger('Broker', 'TimeoutMs', Broker.TimeoutMs);

    Value := Trim(Ini.ReadString('App', 'AppId', ''));
    if Value <> '' then
    begin
      AppId := Value;
      AppIdSource := aisIni;
    end;
    IntervalMs := Ini.ReadInteger('App', 'IntervalMs', IntervalMs);
    PollMs := Ini.ReadInteger('App', 'PollMs', PollMs);
    StoreCapacity := Ini.ReadInteger('App', 'StoreCapacity', StoreCapacity);

    D := Detector;
    D.WindowSamples := Ini.ReadInteger('Detector', 'WindowSamples', D.WindowSamples);
    D.StartupIgnoreSeconds := ReadFloat(Ini, 'Detector', 'StartupIgnoreSeconds', D.StartupIgnoreSeconds);
    D.MinDataSeconds := ReadFloat(Ini, 'Detector', 'MinDataSeconds', D.MinDataSeconds);
    D.SlopeThresholdBytesPerMin := 1024 * ReadFloat(Ini, 'Detector', 'SlopeThresholdKBPerMin',
      D.SlopeThresholdBytesPerMin / 1024);
    D.SlopeThresholdBlocksPerMin := ReadFloat(Ini, 'Detector', 'SlopeThresholdBlocksPerMin',
      D.SlopeThresholdBlocksPerMin);
    D.MinR2 := ReadFloat(Ini, 'Detector', 'MinR2', D.MinR2);
    D.MonotonicShare := ReadFloat(Ini, 'Detector', 'MonotonicShare', D.MonotonicShare);
    D.Segments := Ini.ReadInteger('Detector', 'Segments', D.Segments);
    D.NoReleaseMinutes := ReadFloat(Ini, 'Detector', 'NoReleaseMinutes', D.NoReleaseMinutes);
    D.DropPercent := ReadFloat(Ini, 'Detector', 'DropPercent', D.DropPercent);
    D.WeightTrend := ReadFloat(Ini, 'Detector', 'WeightTrend', D.WeightTrend);
    D.WeightMonotonic := ReadFloat(Ini, 'Detector', 'WeightMonotonic', D.WeightMonotonic);
    D.WeightLowWater := ReadFloat(Ini, 'Detector', 'WeightLowWater', D.WeightLowWater);
    D.WeightNoRelease := ReadFloat(Ini, 'Detector', 'WeightNoRelease', D.WeightNoRelease);
    D.SuspectedThreshold := ReadFloat(Ini, 'Detector', 'SuspectedThreshold', D.SuspectedThreshold);
    D.LikelyThreshold := ReadFloat(Ini, 'Detector', 'LikelyThreshold', D.LikelyThreshold);
    D.FallMargin := ReadFloat(Ini, 'Detector', 'FallMargin', D.FallMargin);
    D.RaiseCount := Ini.ReadInteger('Detector', 'RaiseCount', D.RaiseCount);
    D.FallCount := Ini.ReadInteger('Detector', 'FallCount', D.FallCount);
    Detector := D;

    G := Generator;
    if SameText(Ini.ReadString('Generator', 'Mode', ModeToStr(G.Mode)), 'B') then
      G.Mode := gmGrowth
    else
      G.Mode := gmChurn;
    G.ChurnMinIntervalMs := Ini.ReadInteger('Generator', 'ChurnMinIntervalMs', G.ChurnMinIntervalMs);
    G.ChurnMaxIntervalMs := Ini.ReadInteger('Generator', 'ChurnMaxIntervalMs', G.ChurnMaxIntervalMs);
    G.ChurnMaxObjects := Ini.ReadInteger('Generator', 'ChurnMaxObjects', G.ChurnMaxObjects);
    G.ChurnMinSize := Ini.ReadInteger('Generator', 'ChurnMinSize', G.ChurnMinSize);
    G.ChurnMaxSize := Ini.ReadInteger('Generator', 'ChurnMaxSize', G.ChurnMaxSize);
    G.ChurnMinLifetimeMs := Ini.ReadInteger('Generator', 'ChurnMinLifetimeMs', G.ChurnMinLifetimeMs);
    G.ChurnMaxLifetimeMs := Ini.ReadInteger('Generator', 'ChurnMaxLifetimeMs', G.ChurnMaxLifetimeMs);
    G.GrowthRate := Ini.ReadInteger('Generator', 'GrowthRate', G.GrowthRate);
    G.GrowthMinSize := Ini.ReadInteger('Generator', 'GrowthMinSize', G.GrowthMinSize);
    G.GrowthMaxSize := Ini.ReadInteger('Generator', 'GrowthMaxSize', G.GrowthMaxSize);
    G.ReleaseEnabled := Ini.ReadBool('Generator', 'ReleaseEnabled', G.ReleaseEnabled);
    G.ReleaseAfterSeconds := Ini.ReadInteger('Generator', 'ReleaseAfterSeconds', G.ReleaseAfterSeconds);
    G.ReleaseAfterObjects := Ini.ReadInteger('Generator', 'ReleaseAfterObjects', G.ReleaseAfterObjects);
    G.PermanentPercent := Ini.ReadInteger('Generator', 'PermanentPercent', G.PermanentPercent);
    Generator := G;
  finally
    Ini.Free;
  end;
end;

procedure TLeakWatchConfig.SaveBroker;
var
  Ini: TMemIniFile;
begin
  Ini := TMemIniFile.Create(IniFileName, TEncoding.UTF8);
  try
    Ini.WriteString('Broker', 'Host', Broker.Host);
    Ini.WriteInteger('Broker', 'Port', Broker.Port);
    Ini.WriteString('Broker', 'User', Broker.User);
    Ini.WriteString('Broker', 'Password', Broker.Password);  // plain text, see README
    Ini.WriteString('Broker', 'VHost', Broker.VHost);
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

procedure TLeakWatchConfig.ApplySwitch(const Name, Value: string; HasValue: Boolean);
var
  N: Integer;
  F: Double;
begin
  if SameText(Name, 'id') and HasValue and (Trim(Value) <> '') then
  begin
    AppId := Trim(Value);
    AppIdSource := aisCommandLine;
  end
  else if SameText(Name, 'mode') and HasValue then
  begin
    if SameText(Value, 'A') then
      Generator.Mode := gmChurn
    else if SameText(Value, 'B') then
      Generator.Mode := gmGrowth
    else
      FWarnings.Add(Format('-mode=%s: expected A or B', [Value]));
  end
  else if SameText(Name, 'autostart') then
    AutoStart := True
  else if SameText(Name, 'runfor') and HasValue then
  begin
    if TryStrToFloatInvariant(Value, F) and (F > 0) then
      RunForMinutes := F
    else
      FWarnings.Add(Format('-runfor=%s: expected minutes > 0', [Value]));
  end
  else if SameText(Name, 'seed') and HasValue then
  begin
    if TryStrToInt(Value, N) then
    begin
      HasSeed := True;
      Seed := Cardinal(N);
    end
    else
      FWarnings.Add(Format('-seed=%s: expected an integer', [Value]));
  end
  else if SameText(Name, 'eventlog') and HasValue then
    EventLogFile := Value
  else if SameText(Name, 'ini') and HasValue then
    // handled in Load before the INI file is read
  else if SameText(Name, 'reportleaks') then
    ReportLeaks := True
  else if HasValue then
    FUnknownSwitches.Add('-' + Name + '=' + Value)
  else
    FUnknownSwitches.Add('-' + Name);
end;

function SplitSwitch(const Arg: string; out Name, Value: string; out HasValue: Boolean): Boolean;
var
  P: Integer;
  S: string;
begin
  Result := (Length(Arg) > 1) and ((Arg[1] = '-') or (Arg[1] = '/'));
  if not Result then
    Exit;
  S := Copy(Arg, 2, MaxInt);
  P := Pos('=', S);
  HasValue := P > 0;
  if HasValue then
  begin
    Name := Copy(S, 1, P - 1);
    Value := Copy(S, P + 1, MaxInt);
  end
  else
  begin
    Name := S;
    Value := '';
  end;
end;

procedure TLeakWatchConfig.Load(Args: TStrings; const ExeName: string);
var
  I: Integer;
  Name, Value, Ini: string;
  HasValue: Boolean;
begin
  FUnknownSwitches.Clear;
  FWarnings.Clear;
  Broker := DefaultBrokerSettings;
  InstanceId := DefaultInstanceId;
  AppId := InstanceId;
  AppIdSource := aisGenerated;
  IntervalMs := 2000;
  PollMs := 1000;
  StoreCapacity := 600;
  Detector := DefaultDetectorSettings;
  Generator := DefaultGeneratorSettings;
  AutoStart := False;
  RunForMinutes := 0;
  HasSeed := False;
  Seed := 0;
  ReportLeaks := False;

  Ini := ChangeFileExt(ExeName, '.ini');
  for I := 0 to Args.Count - 1 do
    if SplitSwitch(Args[I], Name, Value, HasValue) and SameText(Name, 'ini') and HasValue then
      Ini := Value;
  LoadIni(Ini);

  for I := 0 to Args.Count - 1 do
    if SplitSwitch(Args[I], Name, Value, HasValue) then
      ApplySwitch(Name, Value, HasValue)
    else
      FUnknownSwitches.Add(Args[I]);

  if IntervalMs < MinIntervalMs then
  begin
    FWarnings.Add(Format('IntervalMs=%d is below the minimum, using %d', [IntervalMs, MinIntervalMs]));
    IntervalMs := MinIntervalMs;
  end;
  if PollMs < 100 then
    PollMs := 100;
  if StoreCapacity < Detector.WindowSamples then
  begin
    FWarnings.Add(Format('StoreCapacity=%d is smaller than WindowSamples, using %d',
      [StoreCapacity, Detector.WindowSamples]));
    StoreCapacity := Detector.WindowSamples;
  end;
  if EventLogFile = '' then
    EventLogFile := ExtractFilePath(ExeName) + 'LeakWatch-' + SafeFileNamePart(AppId) + '-events.log';
end;

initialization
  GetLocaleFormatSettings(LOCALE_SYSTEM_DEFAULT, InvariantFormat);
  InvariantFormat.DecimalSeparator := '.';
  InvariantFormat.ThousandSeparator := ',';

end.
