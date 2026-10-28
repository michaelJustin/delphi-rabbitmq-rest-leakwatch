unit LeakDetectorTests;

{ Detector tests with synthetic series (expected results from
  docs: PROMPT §7). All series use 2 s steps and default settings; the
  process start is one hour before the first sample unless a test says
  otherwise, so the start-up phase plays no role. }

interface

uses
  TestFramework, uSnapshot, uLeakDetector, SyntheticSeries;

type
  TLeakDetectorTest = class(TTestCase)
  private
    function Run(const Bytes: TDoubleArray): TRunResult;
    function LevelName(L: TLeakLevel): string;
  published
    procedure FlatNoiseIsNone;
    procedure RandomChurnIsNone;
    procedure SawtoothFullyReleasedIsNone;
    procedure SawtoothWithPermanentLeakIsLikely;
    procedure SteadyLeakIsLikely;
    procedure StepLeakIsFlaggedAndClearsAfterWindow;
    procedure SteadyLeakWithGapsIsLikely;
    procedure TooLittleDataIsNotEvaluated;
    procedure StartupRampIsIgnored;
  end;

  THysteresisTest = class(TTestCase)
  published
    procedure OscillationAroundThresholdDoesNotChangeLevel;
    procedure RisesAfterRaiseCountAndFallsAfterFallCount;
    procedure FallMarginKeepsLevel;
  end;

  TDetectorHelpersTest = class(TTestCase)
  published
    procedure LinearFitOfExactLine;
    procedure LinearFitOfConstantHasZeroR2;
    procedure SizeClassHintOrdersByGrownBytes;
    procedure WarningShowsAppIdAndInstanceId;
  end;

implementation

uses
  SysUtils;

{ TLeakDetectorTest }

function TLeakDetectorTest.Run(const Bytes: TDoubleArray): TRunResult;
begin
  Result := RunDetector(MakeSamples(Bytes, TestT0), TestT0 - 1 / 24, DefaultDetectorSettings);
end;

function TLeakDetectorTest.LevelName(L: TLeakLevel): string;
begin
  Result := LeakLevelToStr(L);
end;

procedure TLeakDetectorTest.FlatNoiseIsNone;
var
  R: TRunResult;
begin
  R := Run(FlatNoise(40, 50 * MB, 5, 1));
  CheckTrue(R.EvaluatedCount > 0, 'evaluated');
  CheckEquals('None', LevelName(R.MaxLevel), 'max level');
end;

procedure TLeakDetectorTest.RandomChurnIsNone;
var
  R: TRunResult;
begin
  R := Run(ModeAChurn(40, 10 * MB, 2));
  CheckTrue(R.EvaluatedCount > 0, 'evaluated');
  CheckEquals('None', LevelName(R.MaxLevel), 'max level');
end;

procedure TLeakDetectorTest.SawtoothFullyReleasedIsNone;
var
  R: TRunResult;
begin
  // 3-minute cycle, 10 MB/min ramp (30 MB peaks), everything released
  R := Run(Sawtooth(40, 20 * MB, 10 * MB, 180, 0, 100 * KB, 3));
  CheckEquals('None', LevelName(R.MaxLevel), 'max level');
end;

procedure TLeakDetectorTest.SawtoothWithPermanentLeakIsLikely;
var
  R: TRunResult;
begin
  // 10 % of each 30 MB cycle stays: +1 MB/min floor, 4x the threshold
  R := Run(Sawtooth(40, 20 * MB, 10 * MB, 180, 10, 100 * KB, 4));
  CheckEquals('Likely', LevelName(R.FinalLevel), 'final level');
end;

procedure TLeakDetectorTest.SteadyLeakIsLikely;
var
  R: TRunResult;
begin
  R := Run(SteadyLeak(30, 50 * MB, 2 * MB, 200 * KB, 5));
  CheckEquals('Likely', LevelName(R.FinalLevel), 'final level');
  // MinDataSeconds (7 min) plus a few evaluations
  CheckTrue((R.FirstLikelySec > 0) and (R.FirstLikelySec <= 10 * 60),
    Format('first Likely after %.0f s', [R.FirstLikelySec]));
end;

procedure TLeakDetectorTest.StepLeakIsFlaggedAndClearsAfterWindow;
var
  R: TRunResult;
begin
  // flat, +20 MB at minute 15, flat until minute 50
  R := Run(StepLeak(50, 50 * MB, 15, 20 * MB, 100 * KB, 6));
  CheckTrue(R.MaxLevel >= llSuspected, 'max level ' + LevelName(R.MaxLevel));
  CheckEquals('None', LevelName(R.FinalLevel), 'final level');
end;

procedure TLeakDetectorTest.SteadyLeakWithGapsIsLikely;
var
  Samples: TSampleArray;
  R: TRunResult;
begin
  Samples := MakeSamples(SteadyLeak(30, 50 * MB, 2 * MB, 200 * KB, 7), TestT0);
  Samples := RemoveRange(Samples, 12, 12.5);
  Samples := RemoveRange(Samples, 20, 22);
  R := RunDetector(Samples, TestT0 - 1 / 24, DefaultDetectorSettings);
  CheckEquals('Likely', LevelName(R.FinalLevel), 'final level');
end;

procedure TLeakDetectorTest.TooLittleDataIsNotEvaluated;
var
  R: TRunResult;
begin
  R := Run(SteadyLeak(6, 50 * MB, 2 * MB, 200 * KB, 8));
  CheckEquals(0, R.EvaluatedCount, 'evaluations');
  CheckEquals('None', LevelName(R.MaxLevel), 'max level');
end;

procedure TLeakDetectorTest.StartupRampIsIgnored;
var
  Bytes: TDoubleArray;
  I: Integer;
  R: TRunResult;
begin
  // the generator fills up in the first 30 s after the process start, then
  // the series is flat
  Bytes := FlatNoise(30, 20 * MB, 1, 9);
  for I := 0 to High(Bytes) do
    if I * StepSeconds >= 30 then
      Bytes[I] := Bytes[I] + 5 * MB
    else
      Bytes[I] := Bytes[I] + 5 * MB * I * StepSeconds / 30;
  R := RunDetector(MakeSamples(Bytes, TestT0), TestT0, DefaultDetectorSettings);
  CheckTrue(R.EvaluatedCount > 0, 'evaluated');
  CheckEquals('None', LevelName(R.MaxLevel), 'max level');
end;

{ THysteresisTest }

procedure THysteresisTest.OscillationAroundThresholdDoesNotChangeLevel;
var
  H: THysteresis;
  I: Integer;
begin
  H := THysteresis.Create(DefaultDetectorSettings);
  try
    for I := 1 to 50 do
    begin
      if Odd(I) then
        H.Update(0.45)
      else
        H.Update(0.35);
      CheckTrue(H.Level = llNone, Format('step %d', [I]));
    end;
  finally
    H.Free;
  end;
end;

procedure THysteresisTest.RisesAfterRaiseCountAndFallsAfterFallCount;
var
  H: THysteresis;
  I: Integer;
begin
  H := THysteresis.Create(DefaultDetectorSettings);
  try
    H.Update(0.75);
    H.Update(0.75);
    CheckTrue(H.Level = llNone, 'after 2');
    H.Update(0.75);
    CheckTrue(H.Level = llLikely, 'after 3');
    for I := 1 to 9 do
      H.Update(0.1);
    CheckTrue(H.Level = llLikely, 'after 9 low');
    H.Update(0.1);
    CheckTrue(H.Level = llNone, 'after 10 low');
  finally
    H.Free;
  end;
end;

procedure THysteresisTest.FallMarginKeepsLevel;
var
  H: THysteresis;
  I: Integer;
begin
  H := THysteresis.Create(DefaultDetectorSettings);
  try
    for I := 1 to 3 do
      H.Update(0.5);
    CheckTrue(H.Level = llSuspected, 'suspected');
    // 0.35 is below the threshold (0.4) but above threshold - margin (0.3)
    for I := 1 to 30 do
      H.Update(0.35);
    CheckTrue(H.Level = llSuspected, 'still suspected');
  finally
    H.Free;
  end;
end;

{ TDetectorHelpersTest }

procedure TDetectorHelpersTest.LinearFitOfExactLine;
var
  X, Y: TDoubleArray;
  I: Integer;
  Slope, R2: Double;
begin
  SetLength(X, 10);
  SetLength(Y, 10);
  for I := 0 to 9 do
  begin
    X[I] := I * 2;
    Y[I] := 100 + 3 * X[I];
  end;
  LinearFit(X, Y, 10, Slope, R2);
  CheckEquals(3, Slope, 1E-9, 'slope');
  CheckEquals(1, R2, 1E-9, 'R2');
end;

procedure TDetectorHelpersTest.LinearFitOfConstantHasZeroR2;
var
  X, Y: TDoubleArray;
  I: Integer;
  Slope, R2: Double;
begin
  SetLength(X, 5);
  SetLength(Y, 5);
  for I := 0 to 4 do
  begin
    X[I] := I;
    Y[I] := 7;
  end;
  LinearFit(X, Y, 5, Slope, R2);
  CheckEquals(0, Slope, 1E-12, 'slope');
  CheckEquals(0, R2, 1E-12, 'R2');
end;

procedure TDetectorHelpersTest.SizeClassHintOrdersByGrownBytes;
var
  A, B: TMemStatsValues;
  Hint: string;
begin
  FillChar(A, SizeOf(A), 0);
  FillChar(B, SizeOf(B), 0);
  A.SmallCount := 2;
  A.Small[0].BlockSize := 16;
  A.Small[0].Count := 100;
  A.Small[1].BlockSize := 1000;
  A.Small[1].Count := 10;
  B.SmallCount := 3;
  B.Small[0].BlockSize := 16;
  B.Small[0].Count := 300;    // +200 blocks = 3200 bytes
  B.Small[1].BlockSize := 1000;
  B.Small[1].Count := 20;     // +10 blocks = 10000 bytes
  B.Small[2].BlockSize := 48;
  B.Small[2].Count := 5;      // new class, +240 bytes
  B.MediumBlockCount := 3;
  Hint := SizeClassHint(A, B);
  CheckTrue(Pos('1000 B +10, 16 B +200, 48 B +5', Hint) > 0, Hint);
  CheckTrue(Pos('medium +3 blocks', Hint) > 0, Hint);
end;

procedure TDetectorHelpersTest.WarningShowsAppIdAndInstanceId;
var
  S: string;
begin
  S := FormatLeakWarning(llLikely, 'WS-03', 'PC1-4711', '+1.8 MB/min');
  CheckEquals('LEAK LIKELY '#$2013' app ''WS-03'' (PC1-4711): +1.8 MB/min', S);
end;

initialization
  RegisterTest(TLeakDetectorTest.Suite);
  RegisterTest(THysteresisTest.Suite);
  RegisterTest(TDetectorHelpersTest.Suite);

end.
