unit SyntheticSeries;

{ Deterministic synthetic memory series for the detector tests, and a helper
  that feeds them through a TLeakDetector sample by sample, the way the
  consumer thread does. }

interface

uses
  uSnapshot, uLeakDetector;

const
  StepSeconds = 2;
  MB = 1024.0 * 1024.0;
  KB = 1024.0;

type
  { Linear congruential generator: same numbers on every run and compiler }
  TLcg = record
    State: Cardinal;
    procedure Init(Seed: Cardinal);
    function Next: Double;  // [0, 1)
    function Range(Lo, Hi: Double): Double;
  end;

  TRunResult = record
    MaxLevel: TLeakLevel;
    FinalLevel: TLeakLevel;
    EvaluatedCount: Integer;
    FirstSuspectedSec: Double;  // -1 if never
    FirstLikelySec: Double;     // -1 if never
    LevelChanges: Integer;
  end;

function SampleCountFor(Minutes: Double): Integer;

function FlatNoise(Minutes, Base, NoisePercent: Double; Seed: Cardinal): TDoubleArray;

{ Simulation of the Mode A generator defaults: bursts of 1..10 objects every
  50..200 ms, 64..16384 bytes each, living 1..30 s. Recording starts after a
  60 s warm-up (twice the maximum lifetime), when the churn is stationary. }
function ModeAChurn(Minutes, Base: Double; Seed: Cardinal): TDoubleArray;

function Sawtooth(Minutes, Base, RampPerMin, CycleSeconds, PermanentPercent,
  NoiseBytes: Double; Seed: Cardinal): TDoubleArray;

function SteadyLeak(Minutes, Base, PerMin, NoiseBytes: Double; Seed: Cardinal): TDoubleArray;

function StepLeak(Minutes, Base, StepAtMinute, StepBytes, NoiseBytes: Double;
  Seed: Cardinal): TDoubleArray;

{ Samples every StepSeconds starting at T0; blocks = bytes / 4096 }
function MakeSamples(const Bytes: TDoubleArray; const T0: TDateTime): TSampleArray;

{ Removes the samples between FromMinute and ToMinute (relative to the first) }
function RemoveRange(const Samples: TSampleArray; FromMinute, ToMinute: Double): TSampleArray;

function RunDetector(const Samples: TSampleArray; const StartedUtc: TDateTime;
  const Settings: TDetectorSettings): TRunResult;

function TestT0: TDateTime;

implementation

{$Q-}{$R-}

uses
  SysUtils;

{ TLcg }

procedure TLcg.Init(Seed: Cardinal);
begin
  State := Seed;
end;

function TLcg.Next: Double;
begin
  State := State * 1664525 + 1013904223;  // overflow intended ($Q- above)
  Result := (State shr 8) / 16777216.0;
end;

function TLcg.Range(Lo, Hi: Double): Double;
begin
  Result := Lo + (Hi - Lo) * Next;
end;

function TestT0: TDateTime;
begin
  Result := EncodeDate(2026, 1, 1);
end;

function SampleCountFor(Minutes: Double): Integer;
begin
  Result := Round(Minutes * 60 / StepSeconds);
end;

function FlatNoise(Minutes, Base, NoisePercent: Double; Seed: Cardinal): TDoubleArray;
var
  R: TLcg;
  I: Integer;
begin
  R.Init(Seed);
  SetLength(Result, SampleCountFor(Minutes));
  for I := 0 to High(Result) do
    Result[I] := Base * (1 + R.Range(-NoisePercent, NoisePercent) / 100);
end;

function ModeAChurn(Minutes, Base: Double; Seed: Cardinal): TDoubleArray;
const
  WarmupSeconds = 60;
var
  R: TLcg;
  Expiry, Size: array of Double;
  Alive, I, J, K, Burst: Integer;
  T, NextBurst, Sum: Double;
begin
  R.Init(Seed);
  SetLength(Result, SampleCountFor(Minutes));
  SetLength(Expiry, 4096);
  SetLength(Size, 4096);
  Alive := 0;
  NextBurst := 0;
  for K := 0 to High(Result) do
  begin
    T := WarmupSeconds + K * StepSeconds;
    while NextBurst <= T do
    begin
      Burst := 1 + Trunc(R.Next * 10);
      for I := 1 to Burst do
      begin
        if Alive = Length(Expiry) then
        begin
          SetLength(Expiry, Alive * 2);
          SetLength(Size, Alive * 2);
        end;
        Size[Alive] := R.Range(64, 16384);
        Expiry[Alive] := NextBurst + R.Range(1, 30);
        Inc(Alive);
      end;
      NextBurst := NextBurst + R.Range(0.05, 0.2);
    end;
    J := 0;
    Sum := 0;
    for I := 0 to Alive - 1 do
      if Expiry[I] > T then
      begin
        Expiry[J] := Expiry[I];
        Size[J] := Size[I];
        Sum := Sum + Size[J];
        Inc(J);
      end;
    Alive := J;
    Result[K] := Base + Sum;
  end;
end;

function Sawtooth(Minutes, Base, RampPerMin, CycleSeconds, PermanentPercent,
  NoiseBytes: Double; Seed: Cardinal): TDoubleArray;
var
  R: TLcg;
  I: Integer;
  T, InCycle, Permanent: Double;
  Cycle, LastCycle: Integer;
begin
  R.Init(Seed);
  SetLength(Result, SampleCountFor(Minutes));
  Permanent := 0;
  LastCycle := 0;
  for I := 0 to High(Result) do
  begin
    T := I * StepSeconds;
    Cycle := Trunc(T / CycleSeconds);
    while LastCycle < Cycle do
    begin
      // end of a cycle: everything is freed except the permanent share
      Permanent := Permanent + RampPerMin * CycleSeconds / 60 * PermanentPercent / 100;
      Inc(LastCycle);
    end;
    InCycle := T - Cycle * CycleSeconds;
    Result[I] := Base + Permanent + RampPerMin * InCycle / 60 + R.Range(-NoiseBytes, NoiseBytes);
  end;
end;

function SteadyLeak(Minutes, Base, PerMin, NoiseBytes: Double; Seed: Cardinal): TDoubleArray;
var
  R: TLcg;
  I: Integer;
begin
  R.Init(Seed);
  SetLength(Result, SampleCountFor(Minutes));
  for I := 0 to High(Result) do
    Result[I] := Base + PerMin * I * StepSeconds / 60 + R.Range(-NoiseBytes, NoiseBytes);
end;

function StepLeak(Minutes, Base, StepAtMinute, StepBytes, NoiseBytes: Double;
  Seed: Cardinal): TDoubleArray;
var
  R: TLcg;
  I: Integer;
begin
  R.Init(Seed);
  SetLength(Result, SampleCountFor(Minutes));
  for I := 0 to High(Result) do
  begin
    Result[I] := Base + R.Range(-NoiseBytes, NoiseBytes);
    if I * StepSeconds >= StepAtMinute * 60 then
      Result[I] := Result[I] + StepBytes;
  end;
end;

function MakeSamples(const Bytes: TDoubleArray; const T0: TDateTime): TSampleArray;
var
  I: Integer;
begin
  SetLength(Result, Length(Bytes));
  for I := 0 to High(Bytes) do
  begin
    FillChar(Result[I], SizeOf(Result[I]), 0);
    Result[I].Seq := I + 1;
    Result[I].TimestampUtc := T0 + I * StepSeconds / SecsPerDay;
    Result[I].Values.AllocatedBytes := Round(Bytes[I]);
    Result[I].Values.TotalAllocatedBlocks := Round(Bytes[I] / 4096);
  end;
end;

function RemoveRange(const Samples: TSampleArray; FromMinute, ToMinute: Double): TSampleArray;
var
  I, N: Integer;
  Minute: Double;
begin
  SetLength(Result, Length(Samples));
  N := 0;
  for I := 0 to High(Samples) do
  begin
    Minute := SecondsBetweenUtc(Samples[0].TimestampUtc, Samples[I].TimestampUtc) / 60;
    if (Minute < FromMinute) or (Minute >= ToMinute) then
    begin
      Result[N] := Samples[I];
      Inc(N);
    end;
  end;
  SetLength(Result, N);
end;

function RunDetector(const Samples: TSampleArray; const StartedUtc: TDateTime;
  const Settings: TDetectorSettings): TRunResult;
var
  Detector: TLeakDetector;
  Window: TSampleArray;
  I, J, First, Count: Integer;
  R: TDetectorResult;
  Elapsed: Double;
begin
  Result.MaxLevel := llNone;
  Result.FinalLevel := llNone;
  Result.EvaluatedCount := 0;
  Result.FirstSuspectedSec := -1;
  Result.FirstLikelySec := -1;
  Result.LevelChanges := 0;
  SetLength(Window, Settings.WindowSamples);
  Detector := TLeakDetector.Create(Settings);
  try
    for I := 0 to High(Samples) do
    begin
      First := I - Settings.WindowSamples + 1;
      if First < 0 then
        First := 0;
      Count := I - First + 1;
      for J := 0 to Count - 1 do
        Window[J] := Samples[First + J];
      R := Detector.Evaluate(Window, Count, StartedUtc);
      if R.Evaluated then
        Inc(Result.EvaluatedCount);
      if R.Changed then
        Inc(Result.LevelChanges);
      Elapsed := SecondsBetweenUtc(Samples[0].TimestampUtc, Samples[I].TimestampUtc);
      if (R.Level >= llSuspected) and (Result.FirstSuspectedSec < 0) then
        Result.FirstSuspectedSec := Elapsed;
      if (R.Level = llLikely) and (Result.FirstLikelySec < 0) then
        Result.FirstLikelySec := Elapsed;
      Result.FinalLevel := R.Level;
    end;
    Result.MaxLevel := Detector.MaxLevel;
  finally
    Detector.Free;
  end;
end;

end.
