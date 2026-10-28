unit uEventLog;

{ Detector event log for scripted runs (test\acceptance.ps1). UTF-8 text,
  one tab-separated line per event, written through to the file at once:

    SEEN   <utc> <observer AppId> <observer InstanceId> <subject AppId> <subject InstanceId>
    LEVEL  <utc> <observer...> <subject...> <old level> <new level> <explanation>
    FINAL  <utc> <observer...> <subject...> <sample count> <final level> <max level> }

interface

uses
  Classes, SyncObjs, uSnapshot;

type
  TDetectorEventLog = class
  private
    FLock: TCriticalSection;
    FStream: TFileStream;
    FObserverAppId: string;
    FObserverInstanceId: string;
    procedure WriteFields(const Kind: string; const Fields: array of string);
  public
    constructor Create(const FileName, ObserverAppId, ObserverInstanceId: string);
    destructor Destroy; override;
    procedure Seen(const AppId, InstanceId: string);
    procedure LevelChanged(const AppId, InstanceId: string; OldLevel, NewLevel: TLeakLevel;
      const Explanation: string);
    procedure Final(const AppId, InstanceId: string; SampleCount: Integer;
      FinalLevel, MaxLevel: TLeakLevel);
  end;

implementation

uses
  SysUtils;

function Clean(const S: string): string;
var
  I: Integer;
begin
  Result := S;
  for I := 1 to Length(Result) do
    if (Result[I] = #9) or (Result[I] = #10) or (Result[I] = #13) then
      Result[I] := ' ';
end;

constructor TDetectorEventLog.Create(const FileName, ObserverAppId, ObserverInstanceId: string);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FObserverAppId := ObserverAppId;
  FObserverInstanceId := ObserverInstanceId;
  FStream := TFileStream.Create(FileName, fmCreate);
end;

destructor TDetectorEventLog.Destroy;
begin
  FStream.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TDetectorEventLog.WriteFields(const Kind: string; const Fields: array of string);
var
  Line: string;
  Bytes: TBytes;
  I: Integer;
begin
  Line := Kind + #9 + DateTimeToIso8601(NowUtc) + #9 + Clean(FObserverAppId) + #9
    + Clean(FObserverInstanceId);
  for I := 0 to High(Fields) do
    Line := Line + #9 + Clean(Fields[I]);
  Bytes := TEncoding.UTF8.GetBytes(Line + #13#10);
  FLock.Enter;
  try
    // TFileStream writes straight to the file (no buffering)
    if Length(Bytes) > 0 then
      FStream.WriteBuffer(Bytes[0], Length(Bytes));
  finally
    FLock.Leave;
  end;
end;

procedure TDetectorEventLog.Seen(const AppId, InstanceId: string);
begin
  WriteFields('SEEN', [AppId, InstanceId]);
end;

procedure TDetectorEventLog.LevelChanged(const AppId, InstanceId: string; OldLevel,
  NewLevel: TLeakLevel; const Explanation: string);
begin
  WriteFields('LEVEL', [AppId, InstanceId, LeakLevelToStr(OldLevel), LeakLevelToStr(NewLevel),
    Explanation]);
end;

procedure TDetectorEventLog.Final(const AppId, InstanceId: string; SampleCount: Integer;
  FinalLevel, MaxLevel: TLeakLevel);
begin
  WriteFields('FINAL', [AppId, InstanceId, IntToStr(SampleCount), LeakLevelToStr(FinalLevel),
    LeakLevelToStr(MaxLevel)]);
end;

end.
