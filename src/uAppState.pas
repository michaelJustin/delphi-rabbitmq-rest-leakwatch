unit uAppState;

{ State shared between the worker threads and the UI. Workers write into
  these thread-safe objects and wake the UI with a window message that
  carries no data; the UI then reads what it needs. Nothing leaks if the
  message arrives after the form is gone. All lists are bounded, because
  the application measures its own heap. }

interface

uses
  Windows, Messages, Classes, SyncObjs, uSnapshot;

const
  WM_LEAKWATCH_NOTIFY = WM_APP + 1;

  NotifyLog = 1;
  NotifyData = 2;
  NotifyState = 4;
  NotifyWarning = 8;

  MaxLogLines = 1000;
  MaxWarnings = 500;

type
  { Posts WM_LEAKWATCH_NOTIFY once per batch of changes. }
  TUiNotifier = class
  private
    FLock: TCriticalSection;
    FWnd: HWND;
    FPending: Integer;
  public
    constructor Create(Wnd: HWND);
    destructor Destroy; override;
    procedure Notify(Kinds: Integer);
    { UI thread: returns and clears the pending kinds }
    function TakePending: Integer;
    { UI thread: stop posting (window about to be destroyed) }
    procedure Detach;
  end;

  TLogQueue = class
  private
    FLock: TCriticalSection;
    FLines: TStringList;
    FNotifier: TUiNotifier;
    FDropped: Integer;
  public
    constructor Create(Notifier: TUiNotifier);
    destructor Destroy; override;
    procedure Add(const Msg: string);
    { UI thread: moves the queued lines to Target }
    procedure Drain(Target: TStrings);
  end;

  TWarningEntry = record
    Seq: Integer;
    TimeUtc: TDateTime;
    AppId: string;
    InstanceId: string;
    Level: TLeakLevel;
    Text: string;
  end;
  TWarningEntries = array of TWarningEntry;

  TWarningList = class
  private
    FLock: TCriticalSection;
    FItems: array[0..MaxWarnings - 1] of TWarningEntry;
    FCount: Integer;
    FNextSeq: Integer;
    FNotifier: TUiNotifier;
  public
    constructor Create(Notifier: TUiNotifier);
    destructor Destroy; override;
    procedure Add(const TimeUtc: TDateTime; const AppId, InstanceId: string;
      Level: TLeakLevel; const Text: string);
    { Entries with Seq > AfterSeq, oldest first (at most MaxWarnings) }
    function GetSince(AfterSeq: Integer): TWarningEntries;
  end;

  TConnState = (csDisconnected, csConnecting, csConnected, csError);

  TStatusInfo = record
    PublishState: TConnState;
    ConsumeState: TConnState;
    PublishError: string;
    ConsumeError: string;
    EverConnected: Boolean;   // publisher and consumer both reached Connected
    LastCaptureMicros: Int64;
    LastAllocatedBytes: Int64;
    LastPublish: string;
    LastPoll: string;
  end;

  TSharedStatus = class
  private
    FLock: TCriticalSection;
    FInfo: TStatusInfo;
    FPublishOk: Boolean;
    FConsumeOk: Boolean;
    FNotifier: TUiNotifier;
  public
    constructor Create(Notifier: TUiNotifier);
    destructor Destroy; override;
    procedure SetPublishState(State: TConnState; const Error: string = '');
    procedure SetConsumeState(State: TConnState; const Error: string = '');
    procedure SetCapture(Micros, AllocatedBytes: Int64);
    procedure SetLastPublish(const Text: string);
    procedure SetLastPoll(const Text: string);
    function Get: TStatusInfo;
  end;

function ConnStateToStr(State: TConnState): string;

implementation

uses
  SysUtils;

function ConnStateToStr(State: TConnState): string;
begin
  case State of
    csConnecting: Result := 'Connecting';
    csConnected: Result := 'Connected';
    csError: Result := 'Error';
  else
    Result := 'Disconnected';
  end;
end;

{ TUiNotifier }

constructor TUiNotifier.Create(Wnd: HWND);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FWnd := Wnd;
end;

destructor TUiNotifier.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TUiNotifier.Notify(Kinds: Integer);
var
  WasIdle: Boolean;
begin
  FLock.Enter;
  try
    WasIdle := FPending = 0;
    FPending := FPending or Kinds;
    if WasIdle and (FWnd <> 0) then
      PostMessage(FWnd, WM_LEAKWATCH_NOTIFY, 0, 0);
  finally
    FLock.Leave;
  end;
end;

function TUiNotifier.TakePending: Integer;
begin
  FLock.Enter;
  try
    Result := FPending;
    FPending := 0;
  finally
    FLock.Leave;
  end;
end;

procedure TUiNotifier.Detach;
begin
  FLock.Enter;
  try
    FWnd := 0;
  finally
    FLock.Leave;
  end;
end;

{ TLogQueue }

constructor TLogQueue.Create(Notifier: TUiNotifier);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FLines := TStringList.Create;
  FNotifier := Notifier;
end;

destructor TLogQueue.Destroy;
begin
  FLines.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLogQueue.Add(const Msg: string);
begin
  FLock.Enter;
  try
    if FLines.Count >= MaxLogLines then
    begin
      FLines.Delete(0);
      Inc(FDropped);
    end;
    FLines.Add(FormatDateTime('hh:nn:ss.zzz', Now) + '  ' + Msg);
  finally
    FLock.Leave;
  end;
  if Assigned(FNotifier) then
    FNotifier.Notify(NotifyLog);
end;

procedure TLogQueue.Drain(Target: TStrings);
begin
  FLock.Enter;
  try
    if FDropped > 0 then
    begin
      Target.Add(Format('(%d log lines dropped)', [FDropped]));
      FDropped := 0;
    end;
    Target.AddStrings(FLines);
    FLines.Clear;
  finally
    FLock.Leave;
  end;
end;

{ TWarningList }

constructor TWarningList.Create(Notifier: TUiNotifier);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FNotifier := Notifier;
end;

destructor TWarningList.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TWarningList.Add(const TimeUtc: TDateTime; const AppId, InstanceId: string;
  Level: TLeakLevel; const Text: string);
var
  Index: Integer;
begin
  FLock.Enter;
  try
    Inc(FNextSeq);
    Index := (FNextSeq - 1) mod MaxWarnings;
    FItems[Index].Seq := FNextSeq;
    FItems[Index].TimeUtc := TimeUtc;
    FItems[Index].AppId := AppId;
    FItems[Index].InstanceId := InstanceId;
    FItems[Index].Level := Level;
    FItems[Index].Text := Text;
    if FCount < MaxWarnings then
      Inc(FCount);
  finally
    FLock.Leave;
  end;
  if Assigned(FNotifier) then
    FNotifier.Notify(NotifyWarning);
end;

function TWarningList.GetSince(AfterSeq: Integer): TWarningEntries;
var
  FirstSeq, Seq, N: Integer;
begin
  FLock.Enter;
  try
    FirstSeq := FNextSeq - FCount + 1;
    if AfterSeq + 1 > FirstSeq then
      FirstSeq := AfterSeq + 1;
    N := FNextSeq - FirstSeq + 1;
    if N < 0 then
      N := 0;
    SetLength(Result, N);
    for Seq := FirstSeq to FNextSeq do
      Result[Seq - FirstSeq] := FItems[(Seq - 1) mod MaxWarnings];
  finally
    FLock.Leave;
  end;
end;

{ TSharedStatus }

constructor TSharedStatus.Create(Notifier: TUiNotifier);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FNotifier := Notifier;
end;

destructor TSharedStatus.Destroy;
begin
  FLock.Free;
  inherited Destroy;
end;

procedure TSharedStatus.SetPublishState(State: TConnState; const Error: string);
begin
  FLock.Enter;
  try
    FInfo.PublishState := State;
    FInfo.PublishError := Error;
    if State = csConnected then
      FPublishOk := True;
    FInfo.EverConnected := FPublishOk and FConsumeOk;
  finally
    FLock.Leave;
  end;
  if Assigned(FNotifier) then
    FNotifier.Notify(NotifyState);
end;

procedure TSharedStatus.SetConsumeState(State: TConnState; const Error: string);
begin
  FLock.Enter;
  try
    FInfo.ConsumeState := State;
    FInfo.ConsumeError := Error;
    if State = csConnected then
      FConsumeOk := True;
    FInfo.EverConnected := FPublishOk and FConsumeOk;
  finally
    FLock.Leave;
  end;
  if Assigned(FNotifier) then
    FNotifier.Notify(NotifyState);
end;

procedure TSharedStatus.SetCapture(Micros, AllocatedBytes: Int64);
begin
  FLock.Enter;
  try
    FInfo.LastCaptureMicros := Micros;
    FInfo.LastAllocatedBytes := AllocatedBytes;
  finally
    FLock.Leave;
  end;
end;

procedure TSharedStatus.SetLastPublish(const Text: string);
begin
  FLock.Enter;
  try
    FInfo.LastPublish := Text;
  finally
    FLock.Leave;
  end;
end;

procedure TSharedStatus.SetLastPoll(const Text: string);
begin
  FLock.Enter;
  try
    FInfo.LastPoll := Text;
  finally
    FLock.Leave;
  end;
end;

function TSharedStatus.Get: TStatusInfo;
begin
  FLock.Enter;
  try
    Result := FInfo;
  finally
    FLock.Leave;
  end;
end;

end.
