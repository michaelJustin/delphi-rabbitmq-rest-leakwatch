unit uMemStats;

{ The only unit that uses FastMM4. Everything else works with
  TMemStatsValues and does not depend on the memory manager.

  System declares its own TMemoryManagerState and GetMemoryManagerState for
  the built-in RTL memory manager. Once FastMM4 is installed, those report
  on the unused built-in manager, so every FastMM4 name here is qualified. }

interface

uses
  uSnapshot;

type
  TMemStats = class
  public
    { Calls FastMM4.GetMemoryManagerState once and derives all figures from
      that one state, like FastMM4's GetMemoryManagerUsageSummary does.
      Does not allocate memory. }
    class function Capture: TMemStatsValues;
  end;

implementation

uses
  Windows, FastMM4;

class function TMemStats.Capture: TMemStatsValues;
var
  State: FastMM4.TMemoryManagerState;
  Frequency, Start, Stop, Reserved, Count: Int64;
  I: Integer;
begin
  FillChar(Result, SizeOf(Result), 0);

  QueryPerformanceFrequency(Frequency);
  QueryPerformanceCounter(Start);
  FastMM4.GetMemoryManagerState(State);
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
  for I := 0 to FastMM4.NumSmallBlockTypes - 1 do
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
