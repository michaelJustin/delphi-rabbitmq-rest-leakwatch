unit uLeakDetector;

{ Leak detection over a sliding window of snapshots of one instance.

  Pure logic: no VCL, no Indy, no FastMM4. Four heuristics score the window
  (0..1 each), a noisy-OR combines them, and a hysteresis turns the combined
  score into a level (None / Suspected / Likely) that does not flicker.

  The x axis is always time in seconds, never the sample index, so gaps in
  the data do not distort slopes. }

interface

uses
  uSnapshot;

type
  TDetectorSettings = record
    { Sliding window: the newest N samples }
    WindowSamples: Integer;
    { Samples taken less than this after the process start are ignored
      (start-up allocations, generator ramp-up) }
    StartupIgnoreSeconds: Double;
    { No verdict until the remaining window spans at least this time }
    MinDataSeconds: Double;
    { Growth rates that count as a leak }
    SlopeThresholdBytesPerMin: Double;
    SlopeThresholdBlocksPerMin: Double;
    { Trend: minimum R² of the linear fit }
    MinR2: Double;
    { Monotonic growth: share of non-decreasing steps }
    MonotonicShare: Double;
    { Low-water mark: number of overlapping sub-windows }
    Segments: Integer;
    { No-release: minimum drop-free time, and what counts as a drop }
    NoReleaseMinutes: Double;
    DropPercent: Double;
    { Noisy-OR weights (0..1) }
    WeightTrend: Double;
    WeightMonotonic: Double;
    WeightLowWater: Double;
    WeightNoRelease: Double;
    { Hysteresis }
    SuspectedThreshold: Double;
    LikelyThreshold: Double;
    FallMargin: Double;
    RaiseCount: Integer;
    FallCount: Integer;
  end;

  TDoubleArray = array of Double;

  { The window as the heuristics see it: X in seconds since the first sample. }
  TDetectorWindow = record
    Count: Integer;
    X: TDoubleArray;
    Bytes: TDoubleArray;
    Blocks: TDoubleArray;
  end;

  THeuristicResult = record
    Name: string;
    Score: Double;  // 0..1
    Text: string;
  end;

  ILeakHeuristic = interface
    ['{7D3B8E21-5A4C-4F0B-9C6E-2B1F8A07D513}']
    function Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
  end;

  { 1. Linear regression of allocated bytes and blocks over time. }
  TTrendHeuristic = class(TInterfacedObject, ILeakHeuristic)
  public
    function Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
  end;

  { 2. Share of steps where allocation did not decrease. }
  TMonotonicHeuristic = class(TInterfacedObject, ILeakHeuristic)
  public
    function Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
  end;

  { 3. Low-water mark: the minimum of each of Segments overlapping
    sub-windows, each half the window long. A sub-window of half the window
    contains at least one trough of any release cycle shorter than that, so
    the minimums only rise when the floor itself rises. }
  TLowWaterMarkHeuristic = class(TInterfacedObject, ILeakHeuristic)
  public
    function Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
  end;

  { 4. No significant drop for a long time, with a net increase. }
  TNoReleaseHeuristic = class(TInterfacedObject, ILeakHeuristic)
  public
    function Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
  end;

  { Turns a score into a level that changes only after RaiseCount
    consecutive evaluations above a threshold, or FallCount consecutive
    evaluations below the threshold minus FallMargin. }
  THysteresis = class
  private
    FSettings: TDetectorSettings;
    FLevel: TLeakLevel;
    FUpCount: Integer;
    FUpLevel: TLeakLevel;
    FDownCount: Integer;
    FDownLevel: TLeakLevel;
  public
    constructor Create(const Settings: TDetectorSettings);
    function Update(Score: Double): TLeakLevel;
    procedure Reset;
    property Level: TLeakLevel read FLevel;
  end;

const
  HeuristicCount = 4;

type
  TDetectorResult = record
    Evaluated: Boolean;      // False during warm-up / with too little data
    Score: Double;
    Level: TLeakLevel;
    PreviousLevel: TLeakLevel;
    Changed: Boolean;
    SlopeBytesPerMin: Double;
    Details: array[0..HeuristicCount - 1] of THeuristicResult;
    Summary: string;         // for the warning text
    Hint: string;            // size-class attribution
  end;

  { Detector state of one instance. }
  TLeakDetector = class
  private
    FSettings: TDetectorSettings;
    FHeuristics: array[0..HeuristicCount - 1] of ILeakHeuristic;
    FHysteresis: THysteresis;
    FWindow: TDetectorWindow;
    FMaxLevel: TLeakLevel;
    FLastResult: TDetectorResult;
    function GetLevel: TLeakLevel;
  public
    constructor Create(const Settings: TDetectorSettings);
    destructor Destroy; override;
    { Samples[0..Count - 1], oldest first. }
    function Evaluate(const Samples: TSampleArray; Count: Integer;
      const StartedUtc: TDateTime): TDetectorResult;
    { Forget the history (instance restarted). MaxLevel is kept. }
    procedure Reset;
    property Level: TLeakLevel read GetLevel;
    property MaxLevel: TLeakLevel read FMaxLevel;
    property LastResult: TDetectorResult read FLastResult;
    property Settings: TDetectorSettings read FSettings;
  end;

function DefaultDetectorSettings: TDetectorSettings;

procedure LinearFit(const X, Y: TDoubleArray; Count: Integer; out Slope, R2: Double);

{ Small block classes that grew most between First and Last, plus the
  medium and large block totals. }
function SizeClassHint(const First, Last: TMemStatsValues; MaxClasses: Integer = 3): string;

{ "LEAK LIKELY – app 'WS-03' (PC1-4711): <summary>" }
function FormatLeakWarning(Level: TLeakLevel; const AppId, InstanceId, Summary: string): string;

function FormatMegabytes(Bytes: Double; Signed: Boolean = False): string;

implementation

uses
  SysUtils, Math;

const
  BytesPerMB = 1024.0 * 1024.0;

function DefaultDetectorSettings: TDetectorSettings;
begin
  Result.WindowSamples := 300;
  Result.StartupIgnoreSeconds := 120;
  Result.MinDataSeconds := 420;
  Result.SlopeThresholdBytesPerMin := 256 * 1024;
  Result.SlopeThresholdBlocksPerMin := 2000;
  Result.MinR2 := 0.8;
  Result.MonotonicShare := 0.9;
  Result.Segments := 8;
  Result.NoReleaseMinutes := 5;
  Result.DropPercent := 5;
  Result.WeightTrend := 0.8;
  Result.WeightMonotonic := 0.3;
  Result.WeightLowWater := 0.9;
  Result.WeightNoRelease := 0.6;
  Result.SuspectedThreshold := 0.4;
  Result.LikelyThreshold := 0.7;
  Result.FallMargin := 0.1;
  Result.RaiseCount := 3;
  Result.FallCount := 10;
end;

function Clamp01(Value: Double): Double;
begin
  if Value < 0 then
    Result := 0
  else if Value > 1 then
    Result := 1
  else
    Result := Value;
end;

{ 0 at half the threshold, 1 at the threshold }
function Ramp(Ratio: Double): Double;
begin
  Result := Clamp01((Ratio - 0.5) / 0.5);
end;

function FitFactor(R2, MinR2: Double): Double;
begin
  if MinR2 <= 0 then
    Result := 1
  else
    Result := Clamp01((R2 - MinR2 / 2) / (MinR2 / 2));
end;

{ Delphi's Format has no "+" flag }
function SignedCount(Value: Double): string;
begin
  if Value >= 0 then
    Result := Format('+%.0f', [Value])
  else
    Result := Format('%.0f', [Value]);
end;

function FormatMegabytes(Bytes: Double; Signed: Boolean): string;
begin
  if Signed and (Bytes >= 0) then
    Result := Format('+%.1f MB', [Bytes / BytesPerMB])
  else
    Result := Format('%.1f MB', [Bytes / BytesPerMB]);
end;

procedure LinearFit(const X, Y: TDoubleArray; Count: Integer; out Slope, R2: Double);
var
  I: Integer;
  MeanX, MeanY, Sxx, Sxy, Syy, DX, DY: Double;
begin
  Slope := 0;
  R2 := 0;
  if Count < 2 then
    Exit;
  MeanX := 0;
  MeanY := 0;
  for I := 0 to Count - 1 do
  begin
    MeanX := MeanX + X[I];
    MeanY := MeanY + Y[I];
  end;
  MeanX := MeanX / Count;
  MeanY := MeanY / Count;
  Sxx := 0;
  Sxy := 0;
  Syy := 0;
  for I := 0 to Count - 1 do
  begin
    DX := X[I] - MeanX;
    DY := Y[I] - MeanY;
    Sxx := Sxx + DX * DX;
    Sxy := Sxy + DX * DY;
    Syy := Syy + DY * DY;
  end;
  if Sxx > 0 then
    Slope := Sxy / Sxx;
  if (Sxx > 0) and (Syy > 0) then
    R2 := Sxy * Sxy / (Sxx * Syy);
end;

{ TTrendHeuristic }

function TTrendHeuristic.Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
var
  SlopeB, R2B, SlopeK, R2K, ScoreB, ScoreK: Double;
begin
  LinearFit(W.X, W.Bytes, W.Count, SlopeB, R2B);
  LinearFit(W.X, W.Blocks, W.Count, SlopeK, R2K);
  SlopeB := SlopeB * 60;  // per minute
  SlopeK := SlopeK * 60;
  ScoreB := 0;
  ScoreK := 0;
  if Settings.SlopeThresholdBytesPerMin > 0 then
    ScoreB := Ramp(SlopeB / Settings.SlopeThresholdBytesPerMin) * FitFactor(R2B, Settings.MinR2);
  if Settings.SlopeThresholdBlocksPerMin > 0 then
    ScoreK := Ramp(SlopeK / Settings.SlopeThresholdBlocksPerMin) * FitFactor(R2K, Settings.MinR2);
  Result.Name := 'Trend';
  Result.Score := Max(ScoreB, ScoreK);
  Result.Text := Format('%s/min (R2 %.2f), %s blocks/min (R2 %.2f)',
    [FormatMegabytes(SlopeB, True), R2B, SignedCount(SlopeK), R2K]);
end;

{ TMonotonicHeuristic }

function TMonotonicHeuristic.Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
var
  I, NotDecreasing: Integer;
  Share: Double;
begin
  Result.Name := 'Monotonic';
  Result.Score := 0;
  Result.Text := '';
  if W.Count < 2 then
    Exit;
  NotDecreasing := 0;
  for I := 1 to W.Count - 1 do
    if W.Bytes[I] >= W.Bytes[I - 1] then
      Inc(NotDecreasing);
  Share := NotDecreasing / (W.Count - 1);
  if (W.Bytes[W.Count - 1] > W.Bytes[0]) and (Settings.MonotonicShare > 0.5) then
    Result.Score := Clamp01((Share - 0.5) / (Settings.MonotonicShare - 0.5));
  Result.Text := Format('no decrease in %.0f %% of steps', [Share * 100]);
end;

{ TLowWaterMarkHeuristic }

function TLowWaterMarkHeuristic.Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
var
  Segments, K, I, Rising: Integer;
  Duration, SubLen, Step, Start, Rise, Expected, Eps: Double;
  Minimums: array of Double;
begin
  Result.Name := 'LowWaterMark';
  Result.Score := 0;
  Result.Text := '';
  Segments := Settings.Segments;
  if (W.Count < 4) or (Segments < 2) then
    Exit;
  Duration := W.X[W.Count - 1];
  if Duration <= 0 then
    Exit;
  SubLen := Duration / 2;
  Step := (Duration - SubLen) / (Segments - 1);
  SetLength(Minimums, Segments);
  for K := 0 to Segments - 1 do
  begin
    Start := K * Step;
    Minimums[K] := MaxDouble;
    for I := 0 to W.Count - 1 do
      if (W.X[I] >= Start) and (W.X[I] <= Start + SubLen) and (W.Bytes[I] < Minimums[K]) then
        Minimums[K] := W.Bytes[I];
    if Minimums[K] = MaxDouble then  // no sample in this sub-window (gap)
      if K > 0 then
        Minimums[K] := Minimums[K - 1]
      else
        Minimums[K] := W.Bytes[0];
  end;
  Expected := Settings.SlopeThresholdBytesPerMin / 60 * (Duration - SubLen);
  Eps := Expected / (Segments - 1) / 10;
  Rising := 0;
  for K := 1 to Segments - 1 do
    if Minimums[K] > Minimums[K - 1] + Eps then
      Inc(Rising);
  Rise := Minimums[Segments - 1] - Minimums[0];
  if Expected > 0 then
    Result.Score := Ramp(Rise / Expected);
  Result.Text := Format('low-water mark %s, rising in %d of %d steps',
    [FormatMegabytes(Rise, True), Rising, Segments - 1]);
end;

{ TNoReleaseHeuristic }

function TNoReleaseHeuristic.Evaluate(const W: TDetectorWindow; const Settings: TDetectorSettings): THeuristicResult;
var
  I, ResetIndex: Integer;
  Peak, MinSince, Period, Increase, Expected: Double;
begin
  Result.Name := 'NoRelease';
  Result.Score := 0;
  Result.Text := '';
  if W.Count < 2 then
    Exit;
  // find the last significant drop: a fall of more than DropPercent below
  // the peak since the previous drop
  Peak := W.Bytes[0];
  ResetIndex := 0;
  for I := 1 to W.Count - 1 do
    if W.Bytes[I] < Peak * (1 - Settings.DropPercent / 100) then
    begin
      ResetIndex := I;
      Peak := W.Bytes[I];
    end
    else if W.Bytes[I] > Peak then
      Peak := W.Bytes[I];
  MinSince := W.Bytes[ResetIndex];
  for I := ResetIndex + 1 to W.Count - 1 do
    if W.Bytes[I] < MinSince then
      MinSince := W.Bytes[I];
  Period := W.X[W.Count - 1] - W.X[ResetIndex];
  Increase := W.Bytes[W.Count - 1] - MinSince;
  Expected := Settings.SlopeThresholdBytesPerMin / 60 * Period;
  if (Period >= Settings.NoReleaseMinutes * 60) and (Expected > 0) then
    Result.Score := Ramp(Increase / Expected);
  Result.Text := Format('no release for %.1f min (%s)', [Period / 60, FormatMegabytes(Increase, True)]);
end;

{ THysteresis }

function LevelForScore(Score, Suspected, Likely: Double): TLeakLevel;
begin
  if Score >= Likely then
    Result := llLikely
  else if Score >= Suspected then
    Result := llSuspected
  else
    Result := llNone;
end;

constructor THysteresis.Create(const Settings: TDetectorSettings);
begin
  inherited Create;
  FSettings := Settings;
end;

procedure THysteresis.Reset;
begin
  FLevel := llNone;
  FUpCount := 0;
  FDownCount := 0;
end;

function THysteresis.Update(Score: Double): TLeakLevel;
var
  Up, Down: TLeakLevel;
begin
  Up := LevelForScore(Score, FSettings.SuspectedThreshold, FSettings.LikelyThreshold);
  Down := LevelForScore(Score, FSettings.SuspectedThreshold - FSettings.FallMargin,
    FSettings.LikelyThreshold - FSettings.FallMargin);
  if Up > FLevel then
  begin
    FDownCount := 0;
    // rise to the lowest level seen during the run
    if (FUpCount = 0) or (Up < FUpLevel) then
      FUpLevel := Up;
    Inc(FUpCount);
    if FUpCount >= FSettings.RaiseCount then
    begin
      FLevel := FUpLevel;
      FUpCount := 0;
    end;
  end
  else if Down < FLevel then
  begin
    FUpCount := 0;
    // fall to the highest level seen during the run
    if (FDownCount = 0) or (Down > FDownLevel) then
      FDownLevel := Down;
    Inc(FDownCount);
    if FDownCount >= FSettings.FallCount then
    begin
      FLevel := FDownLevel;
      FDownCount := 0;
    end;
  end
  else
  begin
    FUpCount := 0;
    FDownCount := 0;
  end;
  Result := FLevel;
end;

{ TLeakDetector }

constructor TLeakDetector.Create(const Settings: TDetectorSettings);
begin
  inherited Create;
  FSettings := Settings;
  FHeuristics[0] := TTrendHeuristic.Create;
  FHeuristics[1] := TMonotonicHeuristic.Create;
  FHeuristics[2] := TLowWaterMarkHeuristic.Create;
  FHeuristics[3] := TNoReleaseHeuristic.Create;
  FHysteresis := THysteresis.Create(Settings);
end;

destructor TLeakDetector.Destroy;
begin
  FHysteresis.Free;
  inherited Destroy;
end;

function TLeakDetector.GetLevel: TLeakLevel;
begin
  Result := FHysteresis.Level;
end;

procedure TLeakDetector.Reset;
begin
  FHysteresis.Reset;
end;

function TLeakDetector.Evaluate(const Samples: TSampleArray; Count: Integer;
  const StartedUtc: TDateTime): TDetectorResult;
var
  First, N, I: Integer;
  T0, Remaining, Slope, R2: Double;
  Weights: array[0..HeuristicCount - 1] of Double;
  Parts: string;
begin
  Result.Evaluated := False;
  Result.Score := 0;
  Result.PreviousLevel := FHysteresis.Level;
  Result.Level := FHysteresis.Level;
  Result.Changed := False;
  Result.SlopeBytesPerMin := 0;
  Result.Summary := '';
  Result.Hint := '';
  for I := 0 to HeuristicCount - 1 do
  begin
    Result.Details[I].Name := '';
    Result.Details[I].Score := 0;
    Result.Details[I].Text := '';
  end;

  First := 0;
  if Count > FSettings.WindowSamples then
    First := Count - FSettings.WindowSamples;
  while (First < Count)
    and (SecondsBetweenUtc(StartedUtc, Samples[First].TimestampUtc) < FSettings.StartupIgnoreSeconds) do
    Inc(First);
  N := Count - First;
  if N < 4 then
  begin
    FLastResult := Result;
    Exit;
  end;
  Remaining := SecondsBetweenUtc(Samples[First].TimestampUtc, Samples[Count - 1].TimestampUtc);
  // a full window is evaluated even if it spans less than MinDataSeconds
  // (short snapshot interval)
  if (Remaining < FSettings.MinDataSeconds) and (N < FSettings.WindowSamples) then
  begin
    FLastResult := Result;
    Exit;
  end;

  // allocated once at full window size, then reused
  if Length(FWindow.X) < N then
  begin
    SetLength(FWindow.X, Max(N, FSettings.WindowSamples));
    SetLength(FWindow.Bytes, Length(FWindow.X));
    SetLength(FWindow.Blocks, Length(FWindow.X));
  end;
  FWindow.Count := N;
  T0 := Samples[First].TimestampUtc;
  for I := 0 to N - 1 do
  begin
    FWindow.X[I] := SecondsBetweenUtc(T0, Samples[First + I].TimestampUtc);
    FWindow.Bytes[I] := Samples[First + I].Values.AllocatedBytes;
    FWindow.Blocks[I] := Samples[First + I].Values.TotalAllocatedBlocks;
  end;

  Weights[0] := FSettings.WeightTrend;
  Weights[1] := FSettings.WeightMonotonic;
  Weights[2] := FSettings.WeightLowWater;
  Weights[3] := FSettings.WeightNoRelease;
  Result.Score := 1;
  for I := 0 to HeuristicCount - 1 do
  begin
    Result.Details[I] := FHeuristics[I].Evaluate(FWindow, FSettings);
    Result.Score := Result.Score * (1 - Clamp01(Weights[I] * Result.Details[I].Score));
  end;
  Result.Score := 1 - Result.Score;
  Result.Evaluated := True;

  LinearFit(FWindow.X, FWindow.Bytes, N, Slope, R2);
  Result.SlopeBytesPerMin := Slope * 60;
  Parts := Format('%s/min', [FormatMegabytes(Result.SlopeBytesPerMin, True)]);
  Parts := Parts + ', ' + Result.Details[2].Text;
  if Result.Details[3].Score > 0 then
    Parts := Parts + ', ' + Result.Details[3].Text;
  Result.Summary := Parts;
  Result.Hint := SizeClassHint(Samples[First].Values, Samples[Count - 1].Values);

  Result.Level := FHysteresis.Update(Result.Score);
  Result.Changed := Result.Level <> Result.PreviousLevel;
  if Result.Level > FMaxLevel then
    FMaxLevel := Result.Level;
  FLastResult := Result;
end;

function SizeClassHint(const First, Last: TMemStatsValues; MaxClasses: Integer): string;
var
  Sizes: array[0..MaxSmallClasses - 1] of Integer;
  Growth: array[0..MaxSmallClasses - 1] of Int64;
  I, J, N, Best, TmpSize: Integer;
  Before, TmpGrowth: Int64;
  Parts: string;
begin
  N := 0;
  for I := 0 to Last.SmallCount - 1 do
  begin
    Before := 0;
    for J := 0 to First.SmallCount - 1 do
      if First.Small[J].BlockSize = Last.Small[I].BlockSize then
      begin
        Before := First.Small[J].Count;
        Break;
      end;
    if Last.Small[I].Count > Before then
    begin
      Sizes[N] := Last.Small[I].BlockSize;
      Growth[N] := Last.Small[I].Count - Before;
      Inc(N);
    end;
  end;
  // selection sort by grown bytes, descending (N <= 64)
  for I := 0 to N - 2 do
  begin
    Best := I;
    for J := I + 1 to N - 1 do
      if Growth[J] * Sizes[J] > Growth[Best] * Sizes[Best] then
        Best := J;
    TmpSize := Sizes[I]; Sizes[I] := Sizes[Best]; Sizes[Best] := TmpSize;
    TmpGrowth := Growth[I]; Growth[I] := Growth[Best]; Growth[Best] := TmpGrowth;
  end;
  Parts := '';
  for I := 0 to Min(N, MaxClasses) - 1 do
  begin
    if Parts <> '' then
      Parts := Parts + ', ';
    Parts := Parts + Format('%d B +%d', [Sizes[I], Growth[I]]);
  end;
  if Parts = '' then
    Parts := 'none';
  Result := Format('small classes growing: %s; medium %s blocks (%s); large %s blocks (%s)',
    [Parts,
     SignedCount(Last.MediumBlockCount - First.MediumBlockCount),
     FormatMegabytes(Last.MediumBlockBytes - First.MediumBlockBytes, True),
     SignedCount(Last.LargeBlockCount - First.LargeBlockCount),
     FormatMegabytes(Last.LargeBlockBytes - First.LargeBlockBytes, True)]);
end;

function FormatLeakWarning(Level: TLeakLevel; const AppId, InstanceId, Summary: string): string;
var
  Head: string;
begin
  case Level of
    llLikely: Head := 'LEAK LIKELY';
    llSuspected: Head := 'LEAK SUSPECTED';
  else
    Head := 'leak warning cleared';
  end;
  Result := Format('%s '#$2013' app ''%s'' (%s): %s', [Head, AppId, InstanceId, Summary]);
end;

end.
