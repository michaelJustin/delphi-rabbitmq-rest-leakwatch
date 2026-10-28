unit uMemStats;

{ The only unit that knows the memory manager. Everything else works with
  TMemStatsValues.

  Default: the memory manager built into the RTL (Delphi 2006 and later, a
  trimmed-down FastMM4), queried with System.GetMemoryManagerState.

  With the conditional define LEAKWATCH_FASTMM4, the project uses FastMM4
  from third_party/FastMM4 instead (first unit of the .dpr), and this unit
  queries FastMM4.GetMemoryManagerState. System declares the same names for
  the built-in manager, which is not in use then, so every name is
  qualified: calling System.GetMemoryManagerState with FastMM4 installed
  would report on the unused built-in manager. }

interface

uses
  uSnapshot;

type
  TMemStats = class
  public
    { Calls GetMemoryManagerState once and derives all figures from that one
      state, like FastMM4's GetMemoryManagerUsageSummary does. Does not
      allocate memory. }
    class function Capture: TMemStatsValues;
    { 'FastMM4 4.993' or 'built-in (RTL)' }
    class function MemoryManagerName: string;
  end;

implementation

uses
{$IFDEF LEAKWATCH_FASTMM4}
  FastMM4,
{$ENDIF}
  Windows;

{$IFDEF LEAKWATCH_FASTMM4}
type
  TManagerState = FastMM4.TMemoryManagerState;
const
  SmallBlockTypes = FastMM4.NumSmallBlockTypes;

procedure GetState(var State: TManagerState);
begin
  FastMM4.GetMemoryManagerState(State);
end;
{$ELSE}
type
  TManagerState = System.TMemoryManagerState;
const
  SmallBlockTypes = System.NumSmallBlockTypes;

procedure GetState(var State: TManagerState);
begin
  System.GetMemoryManagerState(State);
end;
{$ENDIF}

class function TMemStats.MemoryManagerName: string;
begin
{$IFDEF LEAKWATCH_FASTMM4}
  Result := 'FastMM4 ' + FastMM4.FastMMVersion;
{$ELSE}
  Result := 'built-in (RTL)';
{$ENDIF}
end;

class function TMemStats.Capture: TMemStatsValues;
var
  State: TManagerState;
  Frequency, Start, Stop, Reserved, Count: Int64;
  I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);

  QueryPerformanceFrequency(Frequency);
  QueryPerformanceCounter(Start);
  GetState(State);
  QueryPerformanceCounter(Stop);
  if Frequency > 0 then
    Result.CaptureMicros := (Stop - Start) * 1000000 div Frequency;

  Result.MediumBlockCount := State.AllocatedMediumBlockCount;
  Result.MediumBlockBytes := State.TotalAllocatedMediumBlockSize;
  Result.LargeBlockCount := State.AllocatedLargeBlockCount;
  Result.LargeBlockBytes := State.TotalAllocatedLargeBlockSize;

  Result.AllocatedBytes := Result.MediumBlockBytes + Result.LargeBlockBytes;
  Result.TotalAllocatedBlocks := Result.MediumBlockCount + Result.LargeBlockCount;
  Reserved := Int64(State.ReservedMediumBlockAddressSpace) + State.ReservedLargeBlockAddressSpace;
  for I := 0 to SmallBlockTypes - 1 do
  begin
    Count := State.SmallBlockTypeStates[I].AllocatedBlockCount;
    Inc(Result.AllocatedBytes, Int64(State.SmallBlockTypeStates[I].UseableBlockSize) * Count);
    Inc(Reserved, State.SmallBlockTypeStates[I].ReservedAddressSpace);
    Inc(Result.TotalAllocatedBlocks, Count);
    if (Count > 0) and (Result.SmallCount < MaxSmallClasses) then
    begin
      Result.Small[Result.SmallCount].BlockSize := State.SmallBlockTypeStates[I].UseableBlockSize;
      Result.Small[Result.SmallCount].Count := Count;
      Inc(Result.SmallCount);
    end;
  end;

  Result.OverheadBytes := Reserved - Result.AllocatedBytes;
  if Reserved > 0 then
    Result.Efficiency := Result.AllocatedBytes / Reserved * 100
  else
    Result.Efficiency := 100;
end;

end.
