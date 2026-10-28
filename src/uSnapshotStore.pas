unit uSnapshotStore;

{ In-memory store of the snapshots received from all instances: one ring
  buffer per InstanceId, ordered by Seq. Thread-safe.

  Each ring buffer is allocated at full capacity when its instance first
  appears, so the store's memory does not grow while samples arrive (the
  application measures its own heap). }

interface

uses
  Classes, SyncObjs, uSnapshot;

const
  DefaultStoreCapacity = 600;
  { An instance is stale after this many of its own intervals without data }
  StaleIntervals = 3;
  { and is removed after this time without data }
  RemoveAfterSeconds = 10 * 60;

type
  TAddResult = (
    arAdded,        // appended or inserted in Seq order
    arNewInstance,  // first sample of an unknown instance
    arRestarted,    // known InstanceId with a different startedUtc: series cleared
    arDuplicate,    // Seq already stored, dropped
    arTooOld        // older than everything in a full buffer, dropped
  );

  TInstanceInfo = record
    InstanceId: string;
    AppId: string;
    StartedUtc: TDateTime;
    LastSeenUtc: TDateTime;  // receiver clock
    IntervalMs: Integer;
    SampleCount: Integer;
    Latest: TSample;
    Stale: Boolean;
    DuplicateAppId: Boolean;  // another live instance uses the same AppId
    Level: TLeakLevel;
    LevelText: string;
  end;
  TInstanceInfoArray = array of TInstanceInfo;

  TSnapshotStore = class
  private
    FLock: TCriticalSection;
    FCapacity: Integer;
    FSeries: TStringList;  // sorted, InstanceId -> TInstanceSeries
    function Find(const InstanceId: string): TObject;
  public
    constructor Create(Capacity: Integer = DefaultStoreCapacity);
    destructor Destroy; override;

    function Add(const S: TMemSnapshot; const ReceivedUtc: TDateTime): TAddResult;

    { Copies the newest MaxCount samples of an instance, oldest first, into
      Buffer (grown if too short). Returns the number of samples copied. }
    function CopySamples(const InstanceId: string; var Buffer: TSampleArray;
      MaxCount: Integer; out StartedUtc: TDateTime): Integer;

    function GetInstances(const NowUtc: TDateTime): TInstanceInfoArray;
    procedure SetLevel(const InstanceId: string; Level: TLeakLevel; const Text: string);

    { Removes instances without data for RemoveAfterSeconds; their ids are
      added to Removed (if assigned). Returns the number removed. }
    function Sweep(const NowUtc: TDateTime; Removed: TStrings): Integer;

    function InstanceCount: Integer;
    property Capacity: Integer read FCapacity;
  end;

function IsStale(const LastSeenUtc, NowUtc: TDateTime; IntervalMs: Integer): Boolean;

implementation

uses
  SysUtils;

type
  TInstanceSeries = class
  public
    InstanceId: string;
    AppId: string;
    StartedUtc: TDateTime;
    LastSeenUtc: TDateTime;
    IntervalMs: Integer;
    Level: TLeakLevel;
    LevelText: string;
    Items: TSampleArray;  // ring buffer, Length = capacity
    Head: Integer;        // physical index of the oldest sample
    Count: Integer;
    constructor Create(Capacity: Integer);
    function Phys(LogicalIndex: Integer): Integer;
    function Add(const Sample: TSample): TAddResult;
    procedure Clear;
  end;

function IsStale(const LastSeenUtc, NowUtc: TDateTime; IntervalMs: Integer): Boolean;
begin
  Result := SecondsBetweenUtc(LastSeenUtc, NowUtc) * 1000 > StaleIntervals * IntervalMs;
end;

{ TInstanceSeries }

constructor TInstanceSeries.Create(Capacity: Integer);
begin
  inherited Create;
  SetLength(Items, Capacity);
end;

function TInstanceSeries.Phys(LogicalIndex: Integer): Integer;
begin
  Result := (Head + LogicalIndex) mod Length(Items);
end;

procedure TInstanceSeries.Clear;
begin
  Head := 0;
  Count := 0;
end;

function TInstanceSeries.Add(const Sample: TSample): TAddResult;
var
  Cap, Pos, I: Integer;
begin
  Cap := Length(Items);
  // newest first: the usual case is an append
  if (Count = 0) or (Sample.Seq > Items[Phys(Count - 1)].Seq) then
  begin
    if Count < Cap then
    begin
      Items[Phys(Count)] := Sample;
      Inc(Count);
    end
    else
    begin
      Items[Head] := Sample;  // overwrite the oldest
      Head := (Head + 1) mod Cap;
    end;
    Result := arAdded;
    Exit;
  end;

  // out of order: find the insert position (first sample with a larger Seq)
  Pos := Count - 1;
  while (Pos >= 0) and (Items[Phys(Pos)].Seq > Sample.Seq) do
    Dec(Pos);
  if (Pos >= 0) and (Items[Phys(Pos)].Seq = Sample.Seq) then
  begin
    Result := arDuplicate;
    Exit;
  end;
  Inc(Pos);  // insert before the sample at Pos

  if Count < Cap then
  begin
    for I := Count downto Pos + 1 do
      Items[Phys(I)] := Items[Phys(I - 1)];
    Items[Phys(Pos)] := Sample;
    Inc(Count);
  end
  else
  begin
    if Pos = 0 then
    begin
      Result := arTooOld;  // would become the oldest and be dropped at once
      Exit;
    end;
    // drop the oldest, shift the older part down by one
    for I := 0 to Pos - 2 do
      Items[Phys(I)] := Items[Phys(I + 1)];
    Items[Phys(Pos - 1)] := Sample;
  end;
  Result := arAdded;
end;

{ TSnapshotStore }

constructor TSnapshotStore.Create(Capacity: Integer);
begin
  inherited Create;
  if Capacity < 2 then
    Capacity := 2;
  FCapacity := Capacity;
  FLock := TCriticalSection.Create;
  FSeries := TStringList.Create;
  FSeries.Sorted := True;
  FSeries.Duplicates := dupError;
  FSeries.CaseSensitive := True;
end;

destructor TSnapshotStore.Destroy;
var
  I: Integer;
begin
  if Assigned(FSeries) then
    for I := 0 to FSeries.Count - 1 do
      FSeries.Objects[I].Free;
  FSeries.Free;
  FLock.Free;
  inherited Destroy;
end;

function TSnapshotStore.Find(const InstanceId: string): TObject;
var
  Index: Integer;
begin
  if FSeries.Find(InstanceId, Index) then
    Result := FSeries.Objects[Index]
  else
    Result := nil;
end;

function TSnapshotStore.Add(const S: TMemSnapshot; const ReceivedUtc: TDateTime): TAddResult;
var
  Series: TInstanceSeries;
  IsNew, Restarted: Boolean;
begin
  FLock.Enter;
  try
    Series := TInstanceSeries(Find(S.InstanceId));
    IsNew := Series = nil;
    Restarted := False;
    if IsNew then
    begin
      Series := TInstanceSeries.Create(FCapacity);
      Series.InstanceId := S.InstanceId;
      Series.StartedUtc := S.StartedUtc;
      FSeries.AddObject(S.InstanceId, Series);
    end
    else if Abs(SecondsBetweenUtc(Series.StartedUtc, S.StartedUtc)) > 0.001 then
    begin
      // same InstanceId (hostname-pid), different process: pid was reused
      Series.Clear;
      Series.StartedUtc := S.StartedUtc;
      Series.Level := llNone;
      Series.LevelText := '';
      Restarted := True;
    end;

    Result := Series.Add(SampleFromSnapshot(S));
    if Result = arAdded then
    begin
      Series.AppId := S.AppId;
      Series.IntervalMs := S.IntervalMs;
      Series.LastSeenUtc := ReceivedUtc;
      if IsNew then
        Result := arNewInstance
      else if Restarted then
        Result := arRestarted;
    end;
  finally
    FLock.Leave;
  end;
end;

function TSnapshotStore.CopySamples(const InstanceId: string; var Buffer: TSampleArray;
  MaxCount: Integer; out StartedUtc: TDateTime): Integer;
var
  Series: TInstanceSeries;
  First, I: Integer;
begin
  Result := 0;
  StartedUtc := 0;
  FLock.Enter;
  try
    Series := TInstanceSeries(Find(InstanceId));
    if Series = nil then
      Exit;
    StartedUtc := Series.StartedUtc;
    Result := Series.Count;
    if Result > MaxCount then
      Result := MaxCount;
    if Length(Buffer) < Result then
      SetLength(Buffer, Result);
    First := Series.Count - Result;
    for I := 0 to Result - 1 do
      Buffer[I] := Series.Items[Series.Phys(First + I)];
  finally
    FLock.Leave;
  end;
end;

function TSnapshotStore.GetInstances(const NowUtc: TDateTime): TInstanceInfoArray;
var
  I, J: Integer;
  Series: TInstanceSeries;
begin
  FLock.Enter;
  try
    SetLength(Result, FSeries.Count);
    for I := 0 to FSeries.Count - 1 do
    begin
      Series := TInstanceSeries(FSeries.Objects[I]);
      Result[I].InstanceId := Series.InstanceId;
      Result[I].AppId := Series.AppId;
      Result[I].StartedUtc := Series.StartedUtc;
      Result[I].LastSeenUtc := Series.LastSeenUtc;
      Result[I].IntervalMs := Series.IntervalMs;
      Result[I].SampleCount := Series.Count;
      if Series.Count > 0 then
        Result[I].Latest := Series.Items[Series.Phys(Series.Count - 1)];
      Result[I].Stale := IsStale(Series.LastSeenUtc, NowUtc, Series.IntervalMs);
      Result[I].DuplicateAppId := False;
      Result[I].Level := Series.Level;
      Result[I].LevelText := Series.LevelText;
    end;
  finally
    FLock.Leave;
  end;
  for I := 0 to High(Result) do
    if not Result[I].Stale then
      for J := 0 to High(Result) do
        if (J <> I) and not Result[J].Stale and (Result[J].AppId = Result[I].AppId) then
          Result[I].DuplicateAppId := True;
end;

procedure TSnapshotStore.SetLevel(const InstanceId: string; Level: TLeakLevel; const Text: string);
var
  Series: TInstanceSeries;
begin
  FLock.Enter;
  try
    Series := TInstanceSeries(Find(InstanceId));
    if Series <> nil then
    begin
      Series.Level := Level;
      Series.LevelText := Text;
    end;
  finally
    FLock.Leave;
  end;
end;

function TSnapshotStore.Sweep(const NowUtc: TDateTime; Removed: TStrings): Integer;
var
  I: Integer;
  Series: TInstanceSeries;
begin
  Result := 0;
  FLock.Enter;
  try
    for I := FSeries.Count - 1 downto 0 do
    begin
      Series := TInstanceSeries(FSeries.Objects[I]);
      if SecondsBetweenUtc(Series.LastSeenUtc, NowUtc) > RemoveAfterSeconds then
      begin
        if Assigned(Removed) then
          Removed.Add(Series.InstanceId);
        Series.Free;
        FSeries.Delete(I);
        Inc(Result);
      end;
    end;
  finally
    FLock.Leave;
  end;
end;

function TSnapshotStore.InstanceCount: Integer;
begin
  FLock.Enter;
  try
    Result := FSeries.Count;
  finally
    FLock.Leave;
  end;
end;

end.
