unit MemStatsTests;

{ Run against the memory manager the test project is built with: the
  built-in one by default, FastMM4 with LEAKWATCH_FASTMM4. The Sees* tests
  fail if TMemStats queries a manager that is not in use. }

interface

uses
  TestFramework;

type
  TMemStatsTest = class(TTestCase)
  published
    procedure QueriesTheConfiguredMemoryManager;
{$IFDEF LEAKWATCH_FASTMM4}
    procedure MatchesFastMM4UsageSummary;
{$ENDIF}
    procedure BlockTotalsAddUp;
    procedure SeesLargeAllocation;
    procedure SeesSmallAllocations;
  end;

implementation

uses
{$IFDEF LEAKWATCH_FASTMM4}
  FastMM4,
{$ENDIF}
  SysUtils, uSnapshot, uMemStats;

procedure TMemStatsTest.QueriesTheConfiguredMemoryManager;
begin
{$IFDEF LEAKWATCH_FASTMM4}
  CheckTrue(IsMemoryManagerSet, 'FastMM4 installed');
  CheckTrue(Pos('FastMM4', TMemStats.MemoryManagerName) = 1, TMemStats.MemoryManagerName);
{$ELSE}
  CheckFalse(IsMemoryManagerSet, 'built-in memory manager in use');
  CheckEquals('built-in (RTL)', TMemStats.MemoryManagerName);
{$ENDIF}
end;

{$IFDEF LEAKWATCH_FASTMM4}
procedure TMemStatsTest.MatchesFastMM4UsageSummary;
var
  V: TMemStatsValues;
  U: FastMM4.TMemoryManagerUsageSummary;
begin
  // no allocation between the two calls: both see the same heap
  V := TMemStats.Capture;
  U := FastMM4.GetMemoryManagerUsageSummary;
  CheckEquals(Int64(U.AllocatedBytes), V.AllocatedBytes, 'AllocatedBytes');
  CheckEquals(Int64(U.OverheadBytes), V.OverheadBytes, 'OverheadBytes');
  CheckEquals(U.EfficiencyPercentage, V.Efficiency, 1E-9, 'Efficiency');
end;
{$ENDIF}

procedure TMemStatsTest.BlockTotalsAddUp;
var
  V: TMemStatsValues;
  I: Integer;
  Small, SmallBytes: Int64;
begin
  V := TMemStats.Capture;
  Small := 0;
  SmallBytes := 0;
  for I := 0 to V.SmallCount - 1 do
  begin
    CheckTrue(V.Small[I].Count > 0, 'only non-zero classes');
    Inc(Small, V.Small[I].Count);
    Inc(SmallBytes, V.Small[I].Count * V.Small[I].BlockSize);
  end;
  CheckTrue(V.SmallCount <= MaxSmallClasses, 'SmallCount');
  CheckEquals(V.TotalAllocatedBlocks, Small + V.MediumBlockCount + V.LargeBlockCount, 'blocks');
  CheckEquals(V.AllocatedBytes, SmallBytes + V.MediumBlockBytes + V.LargeBlockBytes, 'bytes');
end;

procedure TMemStatsTest.SeesLargeAllocation;
var
  Before, After: TMemStatsValues;
  P: Pointer;
begin
  Before := TMemStats.Capture;
  GetMem(P, 4 * 1024 * 1024);
  try
    After := TMemStats.Capture;
  finally
    FreeMem(P);
  end;
  CheckEquals(Before.LargeBlockCount + 1, After.LargeBlockCount, 'large blocks');
  CheckTrue(After.AllocatedBytes - Before.AllocatedBytes >= 4 * 1024 * 1024, 'bytes');
end;

procedure TMemStatsTest.SeesSmallAllocations;
const
  N = 1000;
var
  Before, After: TMemStatsValues;
  P: array[0..N - 1] of Pointer;
  I: Integer;
begin
  Before := TMemStats.Capture;
  for I := 0 to N - 1 do
    GetMem(P[I], 40);
  try
    After := TMemStats.Capture;
  finally
    for I := 0 to N - 1 do
      FreeMem(P[I]);
  end;
  CheckTrue(After.TotalAllocatedBlocks - Before.TotalAllocatedBlocks >= N, 'blocks');
  CheckTrue(After.AllocatedBytes - Before.AllocatedBytes >= N * 40, 'bytes');
end;

initialization
  RegisterTest(TMemStatsTest.Suite);

end.
