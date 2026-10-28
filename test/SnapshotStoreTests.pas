unit SnapshotStoreTests;

interface

uses
  TestFramework, uSnapshot, uSnapshotStore;

type
  TSnapshotStoreTest = class(TTestCase)
  private
    FStore: TSnapshotStore;
    FT0: TDateTime;
    function Snap(const InstanceId: string; Seq: Int64; const AppId: string = 'APP'): TMemSnapshot;
    function SeqList(const InstanceId: string; MaxCount: Integer = 1000): string;
    function AddSeqs(const InstanceId: string; const Seqs: array of Int64): TAddResult;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure FirstSampleIsNewInstance;
    procedure AppendsInOrder;
    procedure DropsDuplicates;
    procedure InsertsOutOfOrder;
    procedure WrapsAroundAtCapacity;
    procedure InsertsOutOfOrderWhenFull;
    procedure DropsTooOldWhenFull;
    procedure CopiesNewestMaxCount;
    procedure ClearsSeriesOnRestart;
    procedure StaleAfterThreeOwnIntervals;
    procedure SweepRemovesAfterTenMinutes;
    procedure MarksDuplicateAppIdOfLiveInstances;
    procedure KeepsLevel;
  end;

implementation

uses
  SysUtils;

const
  Capacity = 5;

procedure TSnapshotStoreTest.SetUp;
begin
  FStore := TSnapshotStore.Create(Capacity);
  FT0 := EncodeDate(2026, 10, 28);
end;

procedure TSnapshotStoreTest.TearDown;
begin
  FreeAndNil(FStore);
end;

function TSnapshotStoreTest.Snap(const InstanceId: string; Seq: Int64; const AppId: string): TMemSnapshot;
begin
  FillChar(Result.Values, SizeOf(Result.Values), 0);
  Result.InstanceId := InstanceId;
  Result.AppId := AppId;
  Result.StartedUtc := FT0;
  Result.Seq := Seq;
  Result.TimestampUtc := FT0 + Seq * 2 / SecsPerDay;
  Result.IntervalMs := 2000;
  Result.Values.AllocatedBytes := Seq * 1000;
end;

function TSnapshotStoreTest.AddSeqs(const InstanceId: string; const Seqs: array of Int64): TAddResult;
var
  I: Integer;
begin
  Result := arAdded;
  for I := 0 to High(Seqs) do
    Result := FStore.Add(Snap(InstanceId, Seqs[I]), FT0);
end;

function TSnapshotStoreTest.SeqList(const InstanceId: string; MaxCount: Integer): string;
var
  Buffer: TSampleArray;
  N, I: Integer;
  Started: TDateTime;
begin
  N := FStore.CopySamples(InstanceId, Buffer, MaxCount, Started);
  Result := '';
  for I := 0 to N - 1 do
  begin
    if Result <> '' then
      Result := Result + ',';
    Result := Result + IntToStr(Buffer[I].Seq);
  end;
end;

procedure TSnapshotStoreTest.FirstSampleIsNewInstance;
begin
  CheckTrue(FStore.Add(Snap('A', 1), FT0) = arNewInstance, 'first');
  CheckTrue(FStore.Add(Snap('A', 2), FT0) = arAdded, 'second');
  CheckEquals(1, FStore.InstanceCount);
end;

procedure TSnapshotStoreTest.AppendsInOrder;
begin
  AddSeqs('A', [1, 2, 3]);
  CheckEquals('1,2,3', SeqList('A'));
end;

procedure TSnapshotStoreTest.DropsDuplicates;
begin
  AddSeqs('A', [1, 2, 3]);
  CheckTrue(FStore.Add(Snap('A', 2), FT0) = arDuplicate, 'middle');
  CheckTrue(FStore.Add(Snap('A', 3), FT0) = arDuplicate, 'newest');
  CheckEquals('1,2,3', SeqList('A'));
end;

procedure TSnapshotStoreTest.InsertsOutOfOrder;
begin
  AddSeqs('A', [2, 4, 5]);
  CheckTrue(FStore.Add(Snap('A', 3), FT0) = arAdded, 'middle');
  CheckTrue(FStore.Add(Snap('A', 1), FT0) = arAdded, 'front');
  CheckEquals('1,2,3,4,5', SeqList('A'));
end;

procedure TSnapshotStoreTest.WrapsAroundAtCapacity;
begin
  AddSeqs('A', [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12]);
  CheckEquals('8,9,10,11,12', SeqList('A'));
end;

procedure TSnapshotStoreTest.InsertsOutOfOrderWhenFull;
begin
  AddSeqs('A', [1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12]);  // full: 7,8,9,11,12
  CheckEquals('7,8,9,11,12', SeqList('A'));
  CheckTrue(FStore.Add(Snap('A', 10), FT0) = arAdded);
  CheckEquals('8,9,10,11,12', SeqList('A'));
end;

procedure TSnapshotStoreTest.DropsTooOldWhenFull;
begin
  AddSeqs('A', [8, 9, 10, 11, 12]);
  CheckTrue(FStore.Add(Snap('A', 3), FT0) = arTooOld);
  CheckEquals('8,9,10,11,12', SeqList('A'));
end;

procedure TSnapshotStoreTest.CopiesNewestMaxCount;
begin
  AddSeqs('A', [1, 2, 3, 4, 5]);
  CheckEquals('3,4,5', SeqList('A', 3));
  CheckEquals('', SeqList('unknown'));
end;

procedure TSnapshotStoreTest.ClearsSeriesOnRestart;
var
  S: TMemSnapshot;
begin
  AddSeqs('A', [1, 2, 3]);
  FStore.SetLevel('A', llLikely, 'x');
  S := Snap('A', 1);
  S.StartedUtc := FT0 + 1 / 24;  // new process, same hostname-pid
  CheckTrue(FStore.Add(S, FT0) = arRestarted);
  CheckEquals('1', SeqList('A'));
  CheckTrue(FStore.GetInstances(FT0)[0].Level = llNone, 'level reset');
end;

procedure TSnapshotStoreTest.StaleAfterThreeOwnIntervals;
var
  Infos: TInstanceInfoArray;
begin
  AddSeqs('A', [1]);  // received at FT0, interval 2 s
  Infos := FStore.GetInstances(FT0 + 5 / SecsPerDay);
  CheckFalse(Infos[0].Stale, 'after 5 s');
  Infos := FStore.GetInstances(FT0 + 7 / SecsPerDay);
  CheckTrue(Infos[0].Stale, 'after 7 s');
end;

procedure TSnapshotStoreTest.SweepRemovesAfterTenMinutes;
begin
  AddSeqs('A', [1]);
  CheckEquals(0, FStore.Sweep(FT0 + 599 / SecsPerDay, nil), 'after 599 s');
  CheckEquals(1, FStore.Sweep(FT0 + 601 / SecsPerDay, nil), 'after 601 s');
  CheckEquals(0, FStore.InstanceCount);
end;

procedure TSnapshotStoreTest.MarksDuplicateAppIdOfLiveInstances;
var
  Infos: TInstanceInfoArray;
begin
  FStore.Add(Snap('A', 1, 'WS-01'), FT0);
  FStore.Add(Snap('B', 1, 'WS-01'), FT0 + 10 / SecsPerDay);
  FStore.Add(Snap('C', 1, 'WS-02'), FT0 + 10 / SecsPerDay);
  Infos := FStore.GetInstances(FT0 + 11 / SecsPerDay);  // A is stale now
  CheckEquals('A', Infos[0].InstanceId);
  CheckFalse(Infos[0].DuplicateAppId, 'A (stale)');
  CheckFalse(Infos[1].DuplicateAppId, 'B (other one is stale)');
  Infos := FStore.GetInstances(FT0 + 1 / SecsPerDay);
  CheckTrue(Infos[0].DuplicateAppId, 'A (both live)');
  CheckTrue(Infos[1].DuplicateAppId, 'B (both live)');
  CheckFalse(Infos[2].DuplicateAppId, 'C');
end;

procedure TSnapshotStoreTest.KeepsLevel;
var
  Infos: TInstanceInfoArray;
begin
  AddSeqs('A', [1]);
  FStore.SetLevel('A', llSuspected, 'because');
  Infos := FStore.GetInstances(FT0);
  CheckTrue(Infos[0].Level = llSuspected);
  CheckEquals('because', Infos[0].LevelText);
end;

initialization
  RegisterTest(TSnapshotStoreTest.Suite);

end.
