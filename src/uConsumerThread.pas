unit uConsumerThread;

{ Polls this instance's queue, stores the snapshots of all instances
  (fanout, including our own) and runs the leak detector per instance after
  each batch. Owns its own transport (and TIdHTTP). }

interface

uses
  Classes, uSnapshot, uTransport, uLeakDetector, uSnapshotStore, uAppState, uEventLog,
  uWorkerThread;

type
  TConsumerThreadSettings = record
    Broker: TBrokerSettings;
    InstanceId: string;
    AppId: string;
    PollMs: Integer;
    Detector: TDetectorSettings;
  end;

  TConsumerThread = class(TWorkerThread)
  private
    FSettings: TConsumerThreadSettings;
    FStore: TSnapshotStore;
    FWarnings: TWarningList;
    FStatus: TSharedStatus;
    FLog: TLogQueue;
    FNotifier: TUiNotifier;
    FEventLog: TDetectorEventLog;
    FDetectors: TStringList;  // sorted, InstanceId -> TDetectorEntry
    FWindow: TSampleArray;
    function Entry(const InstanceId, AppId: string): TObject;
    procedure HandlePayloads(Payloads, Changed: TStrings);
    procedure Evaluate(const InstanceId: string);
    procedure WriteFinal;
  protected
    procedure Execute; override;
  public
    { EventLog may be nil; it is not owned. }
    constructor Create(const Settings: TConsumerThreadSettings; Store: TSnapshotStore;
      Warnings: TWarningList; Status: TSharedStatus; Log: TLogQueue; Notifier: TUiNotifier;
      EventLog: TDetectorEventLog);
    destructor Destroy; override;
  end;

implementation

uses
  SysUtils, uSnapshotJson, uTransportRabbitMq;

const
  MaxMessagesPerPoll = 50;
  MinBackoffMs = 1000;
  MaxBackoffMs = 30000;

type
  TDetectorEntry = class
  public
    AppId: string;
    InstanceId: string;
    SampleCount: Integer;
    Detector: TLeakDetector;
    destructor Destroy; override;
  end;

destructor TDetectorEntry.Destroy;
begin
  Detector.Free;
  inherited Destroy;
end;

{ TConsumerThread }

constructor TConsumerThread.Create(const Settings: TConsumerThreadSettings; Store: TSnapshotStore;
  Warnings: TWarningList; Status: TSharedStatus; Log: TLogQueue; Notifier: TUiNotifier;
  EventLog: TDetectorEventLog);
begin
  FSettings := Settings;
  FStore := Store;
  FWarnings := Warnings;
  FStatus := Status;
  FLog := Log;
  FNotifier := Notifier;
  FEventLog := EventLog;
  FDetectors := TStringList.Create;
  FDetectors.Sorted := True;
  FDetectors.CaseSensitive := True;
  // the detector window is allocated once
  SetLength(FWindow, Settings.Detector.WindowSamples);
  inherited Create;
end;

destructor TConsumerThread.Destroy;
var
  I: Integer;
begin
  inherited Destroy;  // stops the thread first
  for I := 0 to FDetectors.Count - 1 do
    FDetectors.Objects[I].Free;
  FDetectors.Free;
end;

function TConsumerThread.Entry(const InstanceId, AppId: string): TObject;
var
  Index: Integer;
  E: TDetectorEntry;
begin
  if FDetectors.Find(InstanceId, Index) then
    E := TDetectorEntry(FDetectors.Objects[Index])
  else
  begin
    E := TDetectorEntry.Create;
    E.InstanceId := InstanceId;
    E.Detector := TLeakDetector.Create(FSettings.Detector);
    FDetectors.AddObject(InstanceId, E);
  end;
  if AppId <> '' then
    E.AppId := AppId;
  Result := E;
end;

procedure TConsumerThread.HandlePayloads(Payloads, Changed: TStrings);
var
  I: Integer;
  Snap: TMemSnapshot;
  Error: string;
  E: TDetectorEntry;
begin
  for I := 0 to Payloads.Count - 1 do
  begin
    if not TryJsonToSnapshot(Payloads[I], Snap, Error) then
    begin
      FLog.Add('skipped invalid snapshot: ' + Error);
      Continue;
    end;
    case FStore.Add(Snap, NowUtc) of
      arNewInstance:
        begin
          FLog.Add(Format('new instance: app ''%s'' (%s), interval %d ms',
            [Snap.AppId, Snap.InstanceId, Snap.IntervalMs]));
          if Assigned(FEventLog) then
            FEventLog.Seen(Snap.AppId, Snap.InstanceId);
          E := TDetectorEntry(Entry(Snap.InstanceId, Snap.AppId));
          E.Detector.Reset;
          Inc(E.SampleCount);
        end;
      arRestarted:
        begin
          FLog.Add(Format('instance restarted: app ''%s'' (%s), series cleared',
            [Snap.AppId, Snap.InstanceId]));
          E := TDetectorEntry(Entry(Snap.InstanceId, Snap.AppId));
          E.Detector.Reset;
          Inc(E.SampleCount);
        end;
      arAdded:
        Inc(TDetectorEntry(Entry(Snap.InstanceId, Snap.AppId)).SampleCount);
    else
      Continue;  // duplicate or too old
    end;
    if Changed.IndexOf(Snap.InstanceId) < 0 then
      Changed.Add(Snap.InstanceId);
  end;
end;

procedure TConsumerThread.Evaluate(const InstanceId: string);
var
  E: TDetectorEntry;
  Count: Integer;
  StartedUtc: TDateTime;
  R: TDetectorResult;
  Text: string;
begin
  E := TDetectorEntry(Entry(InstanceId, ''));
  Count := FStore.CopySamples(InstanceId, FWindow, FSettings.Detector.WindowSamples, StartedUtc);
  if Count = 0 then
    Exit;
  R := E.Detector.Evaluate(FWindow, Count, StartedUtc);
  if not R.Evaluated then
    Exit;
  FStore.SetLevel(InstanceId, R.Level, R.Summary);
  if R.Changed then
  begin
    Text := FormatLeakWarning(R.Level, E.AppId, InstanceId, R.Summary);
    FWarnings.Add(NowUtc, E.AppId, InstanceId, R.Level, Text);
    FLog.Add(Text);
    FLog.Add('  ' + R.Hint);
    if Assigned(FEventLog) then
      FEventLog.LevelChanged(E.AppId, InstanceId, R.PreviousLevel, R.Level, R.Summary);
  end;
end;

procedure TConsumerThread.WriteFinal;
var
  I: Integer;
  E: TDetectorEntry;
begin
  if not Assigned(FEventLog) then
    Exit;
  for I := 0 to FDetectors.Count - 1 do
  begin
    E := TDetectorEntry(FDetectors.Objects[I]);
    FEventLog.Final(E.AppId, E.InstanceId, E.SampleCount, E.Detector.Level, E.Detector.MaxLevel);
  end;
end;

procedure TConsumerThread.Execute;
var
  Transport: ISnapshotTransport;
  Payloads, Changed, Removed: TStringList;
  Declared, Fatal: Boolean;
  Backoff, WaitMs, I: Integer;
begin
  Payloads := TStringList.Create;
  Changed := TStringList.Create;
  Removed := TStringList.Create;
  try
    try
      Transport := TRabbitMqTransport.Create(FSettings.Broker, FSettings.InstanceId);
      Declared := False;
      Fatal := False;
      Backoff := MinBackoffMs;
      FStatus.SetConsumeState(csConnecting);
      while not Terminated do
      begin
        WaitMs := FSettings.PollMs;
        if not Fatal then
        try
          if not Declared then
          begin
            FStatus.SetConsumeState(csConnecting);
            Transport.Declare;
            Declared := True;
          end;
          Payloads.Clear;
          Changed.Clear;
          Transport.Poll(Payloads, MaxMessagesPerPoll);
          FStatus.SetConsumeState(csConnected);
          FStatus.SetLastPoll(Format('%d msg %s', [Payloads.Count, FormatDateTime('hh:nn:ss', Now)]));
          HandlePayloads(Payloads, Changed);
          for I := 0 to Changed.Count - 1 do
            Evaluate(Changed[I]);
          Removed.Clear;
          if FStore.Sweep(NowUtc, Removed) > 0 then
            for I := 0 to Removed.Count - 1 do
              FLog.Add('instance removed after 10 min without data: ' + Removed[I]);
          if ((Changed.Count > 0) or (Removed.Count > 0)) and Assigned(FNotifier) then
            FNotifier.Notify(NotifyData);
          // a full batch: more messages are probably waiting
          if Payloads.Count >= MaxMessagesPerPoll then
            WaitMs := 0;
          Backoff := MinBackoffMs;
        except
          on E: ETransportFatal do
          begin
            Fatal := True;
            FStatus.SetConsumeState(csError, E.Message);
            FLog.Add('consumer stopped: ' + E.Message
              + ' - fix the cause, then Disconnect and Connect again');
          end;
          on E: ETransportNotFound do
          begin
            // x-expires removed the queue (e.g. after a long disconnect)
            Declared := False;
            FLog.Add('queue not found, declaring it again');
            WaitMs := 0;
          end;
          on E: Exception do
          begin
            Declared := False;
            FStatus.SetConsumeState(csError, E.Message);
            FLog.Add(Format('poll failed: %s - retry in %d s', [E.Message, Backoff div 1000]));
            WaitMs := Backoff;
            Backoff := Backoff * 2;
            if Backoff > MaxBackoffMs then
              Backoff := MaxBackoffMs;
          end;
        end;
        if Pause(WaitMs) then
          Break;
      end;
      FStatus.SetConsumeState(csDisconnected);
    except
      on E: Exception do
        FLog.Add('consumer thread failed: ' + E.Message);
    end;
    WriteFinal;
  finally
    Removed.Free;
    Changed.Free;
    Payloads.Free;
  end;
end;

end.
