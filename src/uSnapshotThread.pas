unit uSnapshotThread;

{ Captures a memory snapshot every IntervalMs and publishes it. Owns its
  own transport (and TIdHTTP). }

interface

uses
  uSnapshot, uTransport, uAppState, uWorkerThread;

type
  TSnapshotThreadSettings = record
    Broker: TBrokerSettings;
    InstanceId: string;
    AppId: string;
    StartedUtc: TDateTime;
    IntervalMs: Integer;
  end;

  TSnapshotThread = class(TWorkerThread)
  private
    FSettings: TSnapshotThreadSettings;
    FStatus: TSharedStatus;
    FLog: TLogQueue;
  protected
    procedure Execute; override;
  public
    constructor Create(const Settings: TSnapshotThreadSettings; Status: TSharedStatus; Log: TLogQueue);
  end;

const
  { Capture durations above this are logged }
  CaptureLogThresholdMicros = 5000;

implementation

uses
  Windows, SysUtils, uMemStats, uSnapshotJson, uTransportRabbitMq;

const
  MinBackoffMs = 1000;
  MaxBackoffMs = 30000;

constructor TSnapshotThread.Create(const Settings: TSnapshotThreadSettings; Status: TSharedStatus;
  Log: TLogQueue);
begin
  FSettings := Settings;
  FStatus := Status;
  FLog := Log;
  inherited Create;
end;

procedure TSnapshotThread.Execute;
var
  Transport: ISnapshotTransport;
  Snap: TMemSnapshot;
  Seq: Int64;
  Declared, Fatal, Routed, LastRouted: Boolean;
  Backoff, WaitMs: Integer;
  Started: Cardinal;
begin
  try
    Transport := TRabbitMqTransport.Create(FSettings.Broker, FSettings.InstanceId);
    Snap.InstanceId := FSettings.InstanceId;
    Snap.AppId := FSettings.AppId;
    Snap.StartedUtc := FSettings.StartedUtc;
    Snap.IntervalMs := FSettings.IntervalMs;
    Seq := 0;
    Declared := False;
    Fatal := False;
    LastRouted := True;
    Backoff := MinBackoffMs;
    FStatus.SetPublishState(csConnecting);
    while not Terminated do
    begin
      Started := GetTickCount;
      WaitMs := FSettings.IntervalMs;

      Inc(Seq);
      Snap.Seq := Seq;
      Snap.TimestampUtc := NowUtc;
      Snap.Values := TMemStats.Capture;
      FStatus.SetCapture(Snap.Values.CaptureMicros, Snap.Values.AllocatedBytes);
      if Snap.Values.CaptureMicros > CaptureLogThresholdMicros then
        FLog.Add(Format('snapshot capture took %.1f ms', [Snap.Values.CaptureMicros / 1000]));

      if not Fatal then
      try
        if not Declared then
        begin
          FStatus.SetPublishState(csConnecting);
          Transport.Declare;
          Declared := True;
          FLog.Add(Format('publisher: exchange %s and queue %s%s declared',
            [ExchangeName, QueuePrefix, FSettings.InstanceId]));
        end;
        Routed := Transport.Publish(SnapshotToJson(Snap));
        FStatus.SetPublishState(csConnected);
        FStatus.SetLastPublish(Format('#%d %s', [Seq, FormatDateTime('hh:nn:ss', Now)]));
        if Routed <> LastRouted then
        begin
          if Routed then
            FLog.Add('publish: routed again')
          else
            FLog.Add('WARNING publish: not routed (no queue bound to ' + ExchangeName + ')');
          LastRouted := Routed;
        end;
        Backoff := MinBackoffMs;
      except
        on E: ETransportFatal do
        begin
          Fatal := True;
          FStatus.SetPublishState(csError, E.Message);
          FLog.Add('publisher stopped: ' + E.Message
            + ' - fix the cause, then Disconnect and Connect again');
        end;
        on E: Exception do
        begin
          Declared := False;  // the queue or exchange may be gone
          FStatus.SetPublishState(csError, E.Message);
          FLog.Add(Format('publish failed: %s - retry in %d s', [E.Message, Backoff div 1000]));
          WaitMs := Backoff;
          Backoff := Backoff * 2;
          if Backoff > MaxBackoffMs then
            Backoff := MaxBackoffMs;
        end;
      end;

      if WaitMs = FSettings.IntervalMs then
        Dec(WaitMs, Integer(GetTickCount - Started));
      if Pause(WaitMs) then
        Break;
    end;
    FStatus.SetPublishState(csDisconnected);
  except
    on E: Exception do
      FLog.Add('publisher thread failed: ' + E.Message);
  end;
end;

end.
