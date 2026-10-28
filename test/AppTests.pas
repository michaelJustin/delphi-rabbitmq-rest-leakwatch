unit AppTests;

{ Configuration, event log, shared state, leak generator; and (with
  -integration) the snapshot and consumer threads against a local broker. }

interface

uses
  TestFramework;

type
  TConfigTest = class(TTestCase)
  private
    FDir: string;
    FConfig: TObject;
    procedure LoadWith(const Args: array of string; const IniText: string = '');
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DefaultsWithoutIniAndSwitches;
    procedure ParsesAllSwitches;
    procedure CommandLineIdWinsOverIni;
    procedure IniIdWinsOverGenerated;
    procedure ReadsFloatsWithDotUnderGermanLocale;
    procedure ReportsUnknownSwitchesAndBadValues;
    procedure ClampsIntervalToMinimum;
    procedure IniSwitchSelectsIniFile;
    procedure EventLogNameIsSafe;
  end;

  TEventLogTest = class(TTestCase)
  published
    procedure WritesTabSeparatedUtf8Lines;
  end;

  TAppStateTest = class(TTestCase)
  published
    procedure LogQueueIsBounded;
    procedure WarningListKeepsNewest;
  end;

  TLeakGeneratorTest = class(TTestCase)
  published
    procedure ChurnCreatesAndFreesObjects;
    procedure GrowthReleasePhaseKeepsPermanentShare;
  end;

  TThreadsIntegrationTest = class(TTestCase)
  published
    procedure ConsumerReceivesOwnSnapshots;
  end;

implementation

uses
  Windows, Classes, SysUtils, uSnapshot, uConfig, uEventLog, uAppState, uLeakThread,
  uSnapshotStore, uSnapshotThread, uConsumerThread, uTransport, uTransportRabbitMq,
  uLeakDetector;

function TempDir: string;
var
  Buffer: array[0..MAX_PATH] of Char;
begin
  GetTempPath(MAX_PATH, Buffer);
  Result := IncludeTrailingPathDelimiter(Buffer) + Format('leakwatch-test-%d-%d',
    [GetCurrentProcessId, GetTickCount]);
  ForceDirectories(Result);
end;

procedure DeleteDir(const Dir: string);
var
  SR: TSearchRec;
begin
  if FindFirst(IncludeTrailingPathDelimiter(Dir) + '*', faAnyFile, SR) = 0 then
  begin
    repeat
      if (SR.Attr and faDirectory) = 0 then
        DeleteFile(IncludeTrailingPathDelimiter(Dir) + SR.Name);
    until FindNext(SR) <> 0;
    FindClose(SR);
  end;
  RemoveDir(Dir);
end;

{ TConfigTest }

procedure TConfigTest.SetUp;
begin
  FDir := TempDir;
  FConfig := TLeakWatchConfig.Create;
end;

procedure TConfigTest.TearDown;
begin
  FreeAndNil(FConfig);
  DeleteDir(FDir);
end;

procedure TConfigTest.LoadWith(const Args: array of string; const IniText: string);
var
  L: TStringList;
  I: Integer;
begin
  if IniText <> '' then
  begin
    L := TStringList.Create;
    try
      L.Text := IniText;
      L.SaveToFile(FDir + '\LeakWatch.ini', TEncoding.UTF8);
    finally
      L.Free;
    end;
  end;
  L := TStringList.Create;
  try
    for I := 0 to High(Args) do
      L.Add(Args[I]);
    TLeakWatchConfig(FConfig).Load(L, FDir + '\LeakWatch.exe');
  finally
    L.Free;
  end;
end;

procedure TConfigTest.DefaultsWithoutIniAndSwitches;
var
  C: TLeakWatchConfig;
begin
  LoadWith([]);
  C := TLeakWatchConfig(FConfig);
  CheckEquals(DefaultInstanceId, C.InstanceId, 'InstanceId');
  CheckEquals(C.InstanceId, C.AppId, 'AppId');
  CheckTrue(C.AppIdSource = aisGenerated, 'source');
  CheckEquals('localhost', C.Broker.Host);
  CheckEquals(15672, C.Broker.Port);
  CheckEquals('/', C.Broker.VHost);
  CheckEquals(2000, C.IntervalMs);
  CheckTrue(C.Generator.Mode = gmChurn, 'mode');
  CheckFalse(C.AutoStart, 'autostart');
  CheckEquals(FDir + '\LeakWatch.ini', C.IniFileName);
end;

procedure TConfigTest.ParsesAllSwitches;
var
  C: TLeakWatchConfig;
begin
  LoadWith(['-id=WS-03', '/MODE=b', '-autostart', '-runfor=1.5', '-seed=42',
    '-eventlog=C:\x\y.log', '-reportleaks']);
  C := TLeakWatchConfig(FConfig);
  CheckEquals('WS-03', C.AppId);
  CheckTrue(C.AppIdSource = aisCommandLine, 'source');
  CheckTrue(C.Generator.Mode = gmGrowth, 'mode');
  CheckTrue(C.AutoStart, 'autostart');
  CheckEquals(1.5, C.RunForMinutes, 1E-9, 'runfor');
  CheckTrue(C.HasSeed, 'seed set');
  CheckEquals(42, Integer(C.Seed), 'seed');
  CheckEquals('C:\x\y.log', C.EventLogFile);
  CheckTrue(C.ReportLeaks, 'reportleaks');
  CheckEquals(0, C.UnknownSwitches.Count, C.UnknownSwitches.Text);
  CheckEquals(0, C.Warnings.Count, C.Warnings.Text);
end;

procedure TConfigTest.CommandLineIdWinsOverIni;
begin
  LoadWith(['-id=FromCmd'], '[App]'#13#10'AppId=FromIni');
  CheckEquals('FromCmd', TLeakWatchConfig(FConfig).AppId);
end;

procedure TConfigTest.IniIdWinsOverGenerated;
begin
  LoadWith([], '[App]'#13#10'AppId=FromIni');
  CheckEquals('FromIni', TLeakWatchConfig(FConfig).AppId);
  CheckTrue(TLeakWatchConfig(FConfig).AppIdSource = aisIni);
  // the queue name never depends on the AppId
  CheckEquals(DefaultInstanceId, TLeakWatchConfig(FConfig).InstanceId);
end;

procedure TConfigTest.ReadsFloatsWithDotUnderGermanLocale;
var
  Saved: Char;
begin
  Saved := DecimalSeparator;
  DecimalSeparator := ',';
  try
    LoadWith([], '[Detector]'#13#10'MinR2=0.65'#13#10'SlopeThresholdKBPerMin=512');
    CheckEquals(0.65, TLeakWatchConfig(FConfig).Detector.MinR2, 1E-9, 'MinR2');
    CheckEquals(512 * 1024, TLeakWatchConfig(FConfig).Detector.SlopeThresholdBytesPerMin, 1E-6);
  finally
    DecimalSeparator := Saved;
  end;
end;

procedure TConfigTest.ReportsUnknownSwitchesAndBadValues;
var
  C: TLeakWatchConfig;
begin
  LoadWith(['-foo', '-bar=1', 'plain', '-mode=C', '-runfor=x', '-seed=y']);
  C := TLeakWatchConfig(FConfig);
  CheckEquals(3, C.UnknownSwitches.Count, C.UnknownSwitches.Text);
  CheckEquals(3, C.Warnings.Count, C.Warnings.Text);
  CheckTrue(C.Generator.Mode = gmChurn, 'mode unchanged');
end;

procedure TConfigTest.ClampsIntervalToMinimum;
begin
  LoadWith([], '[App]'#13#10'IntervalMs=100');
  CheckEquals(MinIntervalMs, TLeakWatchConfig(FConfig).IntervalMs);
  CheckEquals(1, TLeakWatchConfig(FConfig).Warnings.Count);
end;

procedure TConfigTest.IniSwitchSelectsIniFile;
var
  L: TStringList;
begin
  L := TStringList.Create;
  try
    L.Text := '[Broker]'#13#10'Host=broker.example';
    L.SaveToFile(FDir + '\other.ini');
  finally
    L.Free;
  end;
  LoadWith(['-ini=' + FDir + '\other.ini']);
  CheckEquals('broker.example', TLeakWatchConfig(FConfig).Broker.Host);
end;

procedure TConfigTest.EventLogNameIsSafe;
begin
  LoadWith(['-id=a/b:c']);
  CheckEquals(FDir + '\LeakWatch-a_b_c-events.log', TLeakWatchConfig(FConfig).EventLogFile);
end;

{ TEventLogTest }

procedure TEventLogTest.WritesTabSeparatedUtf8Lines;
var
  Dir, FileName: string;
  Log: TDetectorEventLog;
  L, F: TStringList;
begin
  Dir := TempDir;
  FileName := Dir + '\events.log';
  Log := TDetectorEventLog.Create(FileName, 'WS-01', 'PC-1');
  try
    Log.Seen('WS-02', 'PC-2');
    Log.LevelChanged('WS-02', 'PC-2', llNone, llLikely, 'tab'#9'and'#10'newline '#$20AC);
    Log.Final('WS-02', 'PC-2', 123, llLikely, llLikely);
  finally
    Log.Free;
  end;
  L := TStringList.Create;
  F := TStringList.Create;
  try
    L.LoadFromFile(FileName, TEncoding.UTF8);
    CheckEquals(3, L.Count, L.Text);
    F.Delimiter := #9;
    F.StrictDelimiter := True;
    F.DelimitedText := L[0];
    CheckEquals('SEEN', F[0]);
    CheckEquals('WS-01', F[2]);
    CheckEquals('PC-1', F[3]);
    CheckEquals('WS-02', F[4]);
    CheckEquals('PC-2', F[5]);
    F.DelimitedText := L[1];
    CheckEquals(9, F.Count, 'LEVEL fields');
    CheckEquals('None', F[6]);
    CheckEquals('Likely', F[7]);
    CheckEquals('tab and newline '#$20AC, F[8]);
    F.DelimitedText := L[2];
    CheckEquals('FINAL', F[0]);
    CheckEquals('123', F[6]);
    CheckEquals('Likely', F[8]);
  finally
    F.Free;
    L.Free;
    DeleteDir(Dir);
  end;
end;

{ TAppStateTest }

procedure TAppStateTest.LogQueueIsBounded;
var
  Q: TLogQueue;
  L: TStringList;
  I: Integer;
begin
  Q := TLogQueue.Create(nil);
  L := TStringList.Create;
  try
    for I := 1 to MaxLogLines + 10 do
      Q.Add(IntToStr(I));
    Q.Drain(L);
    CheckEquals(MaxLogLines + 1, L.Count, 'lines + dropped note');
    CheckTrue(Pos('10 log lines dropped', L[0]) > 0, L[0]);
    CheckTrue(Pos('  11', L[1]) > 0, L[1]);
    L.Clear;
    Q.Drain(L);
    CheckEquals(0, L.Count, 'drained');
  finally
    L.Free;
    Q.Free;
  end;
end;

procedure TAppStateTest.WarningListKeepsNewest;
var
  W: TWarningList;
  E: TWarningEntries;
  I: Integer;
begin
  W := TWarningList.Create(nil);
  try
    for I := 1 to MaxWarnings + 20 do
      W.Add(0, 'A', 'I', llLikely, IntToStr(I));
    E := W.GetSince(0);
    CheckEquals(MaxWarnings, Length(E), 'count');
    CheckEquals('21', E[0].Text, 'oldest kept');
    CheckEquals(IntToStr(MaxWarnings + 20), E[High(E)].Text, 'newest');
    E := W.GetSince(MaxWarnings + 18);
    CheckEquals(2, Length(E), 'since');
    CheckEquals(0, Length(W.GetSince(MaxWarnings + 20)), 'nothing new');
  finally
    W.Free;
  end;
end;

{ TLeakGeneratorTest }

procedure TLeakGeneratorTest.ChurnCreatesAndFreesObjects;
var
  G: TLeakGenerator;
  S: TGeneratorSettings;
  I, Peak: Integer;
begin
  G := TLeakGenerator.Create(1);
  try
    S := DefaultGeneratorSettings;
    S.ChurnMinIntervalMs := 5;
    S.ChurnMaxIntervalMs := 10;
    S.ChurnMinLifetimeMs := 50;
    S.ChurnMaxLifetimeMs := 100;
    G.SetSettings(S);
    G.Start;
    Peak := 0;
    for I := 1 to 30 do
    begin
      Sleep(20);
      if G.Stats.ObjectCount > Peak then
        Peak := G.Stats.ObjectCount;
    end;
    CheckTrue(Peak > 0, 'objects created');
    // stop creating, let the remaining objects expire
    S.ChurnMinIntervalMs := 100000;
    S.ChurnMaxIntervalMs := 100000;
    G.SetSettings(S);
    Sleep(400);
    CheckEquals(0, G.Stats.ObjectCount, 'all expired');
    CheckEquals(Int64(0), G.Stats.HeldBytes, 'bytes');
  finally
    G.Free;
  end;
end;

procedure TLeakGeneratorTest.GrowthReleasePhaseKeepsPermanentShare;
var
  G: TLeakGenerator;
  S: TGeneratorSettings;
  St: TGeneratorStats;
begin
  G := TLeakGenerator.Create(2);
  try
    S := DefaultGeneratorSettings;
    S.Mode := gmGrowth;
    S.GrowthRate := 1000;
    S.ReleaseEnabled := True;
    S.ReleaseAfterSeconds := 1000;
    S.ReleaseAfterObjects := 200;
    S.PermanentPercent := 50;
    G.SetSettings(S);
    G.Start;
    Sleep(500);
    G.Stop;
    St := G.Stats;
    CheckTrue(St.PermanentCount > 0, 'permanent objects kept');
    CheckTrue(St.ObjectCount - St.PermanentCount < 200, 'current cycle below the release limit');
    CheckTrue(St.HeldBytes > 0, 'bytes');
    G.Reset;
    CheckEquals(0, G.Stats.ObjectCount, 'reset');
    CheckEquals(Int64(0), G.Stats.HeldBytes, 'reset bytes');
  finally
    G.Free;
  end;
end;

{ TThreadsIntegrationTest }

procedure TThreadsIntegrationTest.ConsumerReceivesOwnSnapshots;
var
  Store: TSnapshotStore;
  Log: TLogQueue;
  Warnings: TWarningList;
  Status: TSharedStatus;
  PubSettings: TSnapshotThreadSettings;
  ConSettings: TConsumerThreadSettings;
  Pub: TSnapshotThread;
  Con: TConsumerThread;
  InstanceId: string;
  I: Integer;
  Infos: TInstanceInfoArray;
  Found: Boolean;
  Transport: TRabbitMqTransport;
begin
  InstanceId := Format('test-threads-%d-%d', [GetCurrentProcessId, GetTickCount]);
  Store := TSnapshotStore.Create(50);
  Log := TLogQueue.Create(nil);
  Warnings := TWarningList.Create(nil);
  Status := TSharedStatus.Create(nil);
  try
    PubSettings.Broker := DefaultBrokerSettings;
    PubSettings.InstanceId := InstanceId;
    PubSettings.AppId := 'threads-test';
    PubSettings.StartedUtc := NowUtc;
    PubSettings.IntervalMs := 500;
    ConSettings.Broker := DefaultBrokerSettings;
    ConSettings.InstanceId := InstanceId;
    ConSettings.AppId := 'threads-test';
    ConSettings.PollMs := 200;
    ConSettings.Detector := DefaultDetectorSettings;
    Pub := TSnapshotThread.Create(PubSettings, Status, Log);
    Con := TConsumerThread.Create(ConSettings, Store, Warnings, Status, Log, nil, nil);
    try
      Found := False;
      for I := 1 to 50 do
      begin
        Sleep(100);
        Infos := Store.GetInstances(NowUtc);
        if (Length(Infos) > 0) and (Infos[0].SampleCount >= 3) then
        begin
          Found := True;
          Break;
        end;
      end;
    finally
      Con.Free;
      Pub.Free;
    end;
    CheckTrue(Found, 'three own snapshots received');
    CheckTrue(Status.Get.EverConnected, 'connected');
    CheckEquals('threads-test', Infos[0].AppId);
  finally
    Transport := TRabbitMqTransport.Create(DefaultBrokerSettings, InstanceId);
    try
      try
        Transport.DeleteQueue;
      except
        on ETransportError do ;
      end;
    finally
      Transport.Free;
    end;
    Status.Free;
    Warnings.Free;
    Log.Free;
    Store.Free;
  end;
end;

initialization
  RegisterTest(TConfigTest.Suite);
  RegisterTest(TEventLogTest.Suite);
  RegisterTest(TAppStateTest.Suite);
  RegisterTest(TLeakGeneratorTest.Suite);
  if FindCmdLineSwitch('integration') then
    RegisterTest(TThreadsIntegrationTest.Suite);

end.
