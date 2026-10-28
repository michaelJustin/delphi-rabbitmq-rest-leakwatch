unit SnapshotJsonTests;

interface

uses
  TestFramework, uSnapshot;

type
  TIso8601Test = class(TTestCase)
  published
    procedure RoundTripKeepsMilliseconds;
    procedure AcceptsWithoutMilliseconds;
    procedure RejectsInvalidText;
  end;

  TSnapshotJsonTest = class(TTestCase)
  private
    function Sample: TMemSnapshot;
  published
    procedure RoundTrip;
    procedure EscapesQuotesBackslashControlAndNonAscii;
    procedure KeepsInt64AboveInt32Range;
    procedure UsesDotUnderGermanLocale;
    procedure RejectsNonObject;
    procedure RejectsGarbage;
    procedure RejectsUnknownVersion;
    procedure RejectsMissingFields;
    procedure RejectsTooManySmallClasses;
  end;

implementation

uses
  SysUtils, uSnapshotJson;

{ TIso8601Test }

procedure TIso8601Test.RoundTripKeepsMilliseconds;
var
  T, Back: TDateTime;
begin
  T := EncodeDate(2026, 10, 28) + EncodeTime(13, 4, 5, 678);
  CheckEquals('2026-10-28T13:04:05.678Z', DateTimeToIso8601(T));
  CheckTrue(TryIso8601ToDateTime(DateTimeToIso8601(T), Back));
  CheckEquals(0, SecondsBetweenUtc(T, Back), 0.0005);
end;

procedure TIso8601Test.AcceptsWithoutMilliseconds;
var
  Back: TDateTime;
begin
  CheckTrue(TryIso8601ToDateTime('2026-10-28T13:04:05Z', Back));
  CheckEquals(0, SecondsBetweenUtc(EncodeDate(2026, 10, 28) + EncodeTime(13, 4, 5, 0), Back), 0.0005);
end;

procedure TIso8601Test.RejectsInvalidText;
var
  Back: TDateTime;
begin
  CheckFalse(TryIso8601ToDateTime('', Back), 'empty');
  CheckFalse(TryIso8601ToDateTime('2026-10-28 13:04:05Z', Back), 'space');
  CheckFalse(TryIso8601ToDateTime('2026-10-28T13:04:05', Back), 'no Z');
  CheckFalse(TryIso8601ToDateTime('2026-13-28T13:04:05Z', Back), 'month 13');
  CheckFalse(TryIso8601ToDateTime('2026-10-28T25:04:05Z', Back), 'hour 25');
  CheckFalse(TryIso8601ToDateTime('2026-10-28T13:04:05.6Z', Back), 'one digit ms');
  CheckFalse(TryIso8601ToDateTime('2026-10-28T13:04:05.678Z ', Back), 'trailing space');
end;

{ TSnapshotJsonTest }

function TSnapshotJsonTest.Sample: TMemSnapshot;
begin
  FillChar(Result.Values, SizeOf(Result.Values), 0);
  Result.InstanceId := 'PC1-4711';
  Result.AppId := 'WS-03';
  Result.StartedUtc := EncodeDate(2026, 10, 28) + EncodeTime(10, 0, 0, 0);
  Result.Seq := 42;
  Result.TimestampUtc := EncodeDate(2026, 10, 28) + EncodeTime(10, 1, 24, 500);
  Result.IntervalMs := 2000;
  Result.Values.AllocatedBytes := 12345678;
  Result.Values.OverheadBytes := 2345678;
  Result.Values.Efficiency := 84.03;
  Result.Values.TotalAllocatedBlocks := 9876;
  Result.Values.MediumBlockCount := 12;
  Result.Values.MediumBlockBytes := 345678;
  Result.Values.LargeBlockCount := 2;
  Result.Values.LargeBlockBytes := 2000000;
  Result.Values.CaptureMicros := 321;
  Result.Values.SmallCount := 2;
  Result.Values.Small[0].BlockSize := 16;
  Result.Values.Small[0].Count := 500;
  Result.Values.Small[1].BlockSize := 2592;
  Result.Values.Small[1].Count := 7;
end;

procedure TSnapshotJsonTest.RoundTrip;
var
  A, B: TMemSnapshot;
  Error: string;
begin
  A := Sample;
  CheckTrue(TryJsonToSnapshot(SnapshotToJson(A), B, Error), Error);
  CheckEquals(A.InstanceId, B.InstanceId, 'InstanceId');
  CheckEquals(A.AppId, B.AppId, 'AppId');
  CheckEquals(0, SecondsBetweenUtc(A.StartedUtc, B.StartedUtc), 0.0005, 'StartedUtc');
  CheckEquals(A.Seq, B.Seq, 'Seq');
  CheckEquals(0, SecondsBetweenUtc(A.TimestampUtc, B.TimestampUtc), 0.0005, 'TimestampUtc');
  CheckEquals(A.IntervalMs, B.IntervalMs, 'IntervalMs');
  CheckEquals(A.Values.AllocatedBytes, B.Values.AllocatedBytes, 'AllocatedBytes');
  CheckEquals(A.Values.OverheadBytes, B.Values.OverheadBytes, 'OverheadBytes');
  CheckEquals(A.Values.Efficiency, B.Values.Efficiency, 1E-9, 'Efficiency');
  CheckEquals(A.Values.TotalAllocatedBlocks, B.Values.TotalAllocatedBlocks, 'TotalAllocatedBlocks');
  CheckEquals(A.Values.MediumBlockCount, B.Values.MediumBlockCount, 'MediumBlockCount');
  CheckEquals(A.Values.MediumBlockBytes, B.Values.MediumBlockBytes, 'MediumBlockBytes');
  CheckEquals(A.Values.LargeBlockCount, B.Values.LargeBlockCount, 'LargeBlockCount');
  CheckEquals(A.Values.LargeBlockBytes, B.Values.LargeBlockBytes, 'LargeBlockBytes');
  CheckEquals(A.Values.CaptureMicros, B.Values.CaptureMicros, 'CaptureMicros');
  CheckEquals(2, B.Values.SmallCount, 'SmallCount');
  CheckEquals(2592, B.Values.Small[1].BlockSize, 'Small[1].BlockSize');
  CheckEquals(Int64(7), B.Values.Small[1].Count, 'Small[1].Count');
end;

procedure TSnapshotJsonTest.EscapesQuotesBackslashControlAndNonAscii;
const
  Id = 'W"S\03'#9'-'#$00E4#$20AC;
var
  A, B: TMemSnapshot;
  Error: string;
begin
  A := Sample;
  A.AppId := Id;
  CheckTrue(TryJsonToSnapshot(SnapshotToJson(A), B, Error), Error);
  CheckEquals(Id, B.AppId);
end;

procedure TSnapshotJsonTest.KeepsInt64AboveInt32Range;
var
  A, B: TMemSnapshot;
  Error: string;
begin
  A := Sample;
  A.Values.AllocatedBytes := Int64(5) * 1000 * 1000 * 1000;
  A.Seq := Int64(3) * 1000 * 1000 * 1000;
  CheckTrue(TryJsonToSnapshot(SnapshotToJson(A), B, Error), Error);
  CheckEquals(A.Values.AllocatedBytes, B.Values.AllocatedBytes);
  CheckEquals(A.Seq, B.Seq);
end;

procedure TSnapshotJsonTest.UsesDotUnderGermanLocale;
var
  A, B: TMemSnapshot;
  Json, Error: string;
  Saved: Char;
begin
  Saved := DecimalSeparator;
  DecimalSeparator := ',';
  try
    A := Sample;
    Json := SnapshotToJson(A);
    CheckTrue(Pos('"efficiency":84.03', Json) > 0, Json);
    CheckTrue(TryJsonToSnapshot(Json, B, Error), Error);
    CheckEquals(84.03, B.Values.Efficiency, 1E-9);
  finally
    DecimalSeparator := Saved;
  end;
end;

procedure TSnapshotJsonTest.RejectsNonObject;
var
  B: TMemSnapshot;
  Error: string;
begin
  CheckFalse(TryJsonToSnapshot('[1,2]', B, Error));
  CheckNotEquals('', Error);
end;

procedure TSnapshotJsonTest.RejectsGarbage;
var
  B: TMemSnapshot;
  Error: string;
begin
  CheckFalse(TryJsonToSnapshot('{"v":1,', B, Error), 'truncated');
  CheckFalse(TryJsonToSnapshot('hello', B, Error), 'text');
  CheckFalse(TryJsonToSnapshot('', B, Error), 'empty');
end;

procedure TSnapshotJsonTest.RejectsUnknownVersion;
var
  B: TMemSnapshot;
  Error: string;
begin
  CheckFalse(TryJsonToSnapshot(StringReplace(SnapshotToJson(Sample), '"v":1', '"v":2', []), B, Error));
  CheckTrue(Pos('version', Error) > 0, Error);
end;

procedure TSnapshotJsonTest.RejectsMissingFields;
var
  B: TMemSnapshot;
  Error: string;
  Json: string;
begin
  Json := SnapshotToJson(Sample);
  CheckFalse(TryJsonToSnapshot(StringReplace(Json, '"instanceId"', '"x"', []), B, Error), 'instanceId');
  CheckFalse(TryJsonToSnapshot(StringReplace(Json, '"seq"', '"x"', []), B, Error), 'seq');
  CheckFalse(TryJsonToSnapshot(StringReplace(Json, '"ts"', '"x"', []), B, Error), 'ts');
  CheckFalse(TryJsonToSnapshot(StringReplace(Json, '"intervalMs"', '"x"', []), B, Error), 'intervalMs');
end;

procedure TSnapshotJsonTest.RejectsTooManySmallClasses;
var
  B: TMemSnapshot;
  Error, Small: string;
  I: Integer;
begin
  Small := '';
  for I := 1 to MaxSmallClasses + 1 do
  begin
    if Small <> '' then
      Small := Small + ',';
    Small := Small + Format('[%d,1]', [I * 8]);
  end;
  CheckFalse(TryJsonToSnapshot(StringReplace(SnapshotToJson(Sample),
    '"small":[[16,500],[2592,7]]', '"small":[' + Small + ']', []), B, Error));
  CheckTrue(Pos('too many', Error) > 0, Error);
end;

initialization
  RegisterTest(TIso8601Test.Suite);
  RegisterTest(TSnapshotJsonTest.Suite);

end.
