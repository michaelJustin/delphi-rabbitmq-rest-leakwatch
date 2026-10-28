unit uSnapshot;

{ Snapshot types shared by all LeakWatch units, and UTC/ISO 8601 helpers.
  No dependencies on FastMM4, Indy or the VCL. }

interface

const
  { FastMM4 4.993 has 56 small block types (46 with Align16Bytes). }
  MaxSmallClasses = 64;
  SnapshotSchemaVersion = 1;

type
  TSizeClassCount = record
    BlockSize: Integer;
    Count: Int64;
  end;

  { Memory manager figures of one snapshot. Contains no managed types, so
    copying it never allocates memory. }
  TMemStatsValues = record
    AllocatedBytes: Int64;
    OverheadBytes: Int64;
    Efficiency: Double;
    TotalAllocatedBlocks: Int64;
    MediumBlockCount: Int64;
    MediumBlockBytes: Int64;
    LargeBlockCount: Int64;
    LargeBlockBytes: Int64;
    CaptureMicros: Int64;
    { Non-zero small block classes only, in Small[0..SmallCount - 1] }
    SmallCount: Integer;
    Small: array[0..MaxSmallClasses - 1] of TSizeClassCount;
  end;

  { What one instance publishes. }
  TMemSnapshot = record
    InstanceId: string;
    AppId: string;
    StartedUtc: TDateTime;
    Seq: Int64;
    TimestampUtc: TDateTime;
    IntervalMs: Integer;
    Values: TMemStatsValues;
  end;

  { What the store keeps per sample (the identity is kept once per series). }
  TSample = record
    Seq: Int64;
    TimestampUtc: TDateTime;
    Values: TMemStatsValues;
  end;
  TSampleArray = array of TSample;

  TLeakLevel = (llNone, llSuspected, llLikely);

function NowUtc: TDateTime;

{ Formats as yyyy-mm-ddThh:nn:ss.zzzZ }
function DateTimeToIso8601(const Value: TDateTime): string;

{ Accepts yyyy-mm-ddThh:nn:ss[.zzz]Z }
function TryIso8601ToDateTime(const Text: string; out Value: TDateTime): Boolean;

function LeakLevelToStr(Level: TLeakLevel): string;

function SampleFromSnapshot(const S: TMemSnapshot): TSample;

{ Seconds from A to B }
function SecondsBetweenUtc(const A, B: TDateTime): Double;

implementation

uses
  Windows, SysUtils, DateUtils;

function NowUtc: TDateTime;
var
  ST: TSystemTime;
begin
  GetSystemTime(ST);
  Result := SystemTimeToDateTime(ST);
end;

function DateTimeToIso8601(const Value: TDateTime): string;
var
  Y, Mo, D, H, Mi, S, Ms: Word;
begin
  DecodeDateTime(Value, Y, Mo, D, H, Mi, S, Ms);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.3dZ', [Y, Mo, D, H, Mi, S, Ms]);
end;

function TryIso8601ToDateTime(const Text: string; out Value: TDateTime): Boolean;

  function Num(Start, Len: Integer; out N: Integer): Boolean;
  var
    I: Integer;
  begin
    N := 0;
    for I := Start to Start + Len - 1 do
    begin
      if (I > Length(Text)) or not CharInSet(Text[I], ['0'..'9']) then
      begin
        Result := False;
        Exit;
      end;
      N := N * 10 + Ord(Text[I]) - Ord('0');
    end;
    Result := True;
  end;

var
  Y, Mo, D, H, Mi, S, Ms: Integer;
  ZPos: Integer;
  DatePart, TimePart: TDateTime;
begin
  Result := False;
  Value := 0;
  if (Length(Text) < 20) or (Text[5] <> '-') or (Text[8] <> '-') or (Text[11] <> 'T')
    or (Text[14] <> ':') or (Text[17] <> ':') then
    Exit;
  if not (Num(1, 4, Y) and Num(6, 2, Mo) and Num(9, 2, D) and Num(12, 2, H)
    and Num(15, 2, Mi) and Num(18, 2, S)) then
    Exit;
  Ms := 0;
  ZPos := 20;
  if Text[20] = '.' then
  begin
    if not Num(21, 3, Ms) then
      Exit;
    ZPos := 24;
  end;
  if (Length(Text) <> ZPos) or (Text[ZPos] <> 'Z') then
    Exit;
  if not TryEncodeDate(Y, Mo, D, DatePart) then
    Exit;
  if not TryEncodeTime(H, Mi, S, Ms, TimePart) then
    Exit;
  Value := DatePart + TimePart;
  Result := True;
end;

function LeakLevelToStr(Level: TLeakLevel): string;
begin
  case Level of
    llSuspected: Result := 'Suspected';
    llLikely: Result := 'Likely';
  else
    Result := 'None';
  end;
end;

function SampleFromSnapshot(const S: TMemSnapshot): TSample;
begin
  Result.Seq := S.Seq;
  Result.TimestampUtc := S.TimestampUtc;
  Result.Values := S.Values;
end;

function SecondsBetweenUtc(const A, B: TDateTime): Double;
begin
  Result := (B - A) * SecsPerDay;
end;

end.
