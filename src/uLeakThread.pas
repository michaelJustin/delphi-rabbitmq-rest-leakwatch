unit uLeakThread;

{ Leak generator. TLeakGenerator holds the settings and the objects
  (thread-safe, TList + critical section); TLeakThread creates and frees
  objects according to the current settings, which may change while it
  runs.

  Mode A (random churn): bursts of objects with a random lifetime, no net
  growth after a warm-up of about the maximum lifetime.
  Mode B (continuous growth): objects at a fixed rate, kept until Reset;
  optionally a release phase frees all but a permanent share (sawtooth). }

interface

uses
  Classes, SyncObjs, uConfig, uWorkerThread;

type
  TGeneratorStats = record
    Running: Boolean;
    ObjectCount: Integer;
    HeldBytes: Int64;
    PermanentCount: Integer;
  end;

  TLeakThread = class;

  TLeakGenerator = class
  private
    FLock: TCriticalSection;
    FSettings: TGeneratorSettings;
    FChurn: TList;      // Mode A objects, each with an expiry time
    FGrowth: TList;     // Mode B objects of the current cycle
    FPermanent: TList;  // never freed by the release phase
    FHeldBytes: Int64;
    FThread: TLeakThread;
    FSeed: Cardinal;
    procedure FreeList(List: TList);
  public
    constructor Create(Seed: Cardinal);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
    { Frees all tracked objects (thread may keep running) }
    procedure Reset;
    { Forgets all objects without freeing them, so that FastMM4's shutdown
      report lists them as leaks. }
    procedure AbandonAll;
    procedure SetSettings(const Settings: TGeneratorSettings);
    function GetSettings: TGeneratorSettings;
    function Stats: TGeneratorStats;
  end;

  TLeakThread = class(TWorkerThread)
  private
    FGenerator: TLeakGenerator;
    FRandom: Cardinal;
    function Random(Lo, Hi: Integer): Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(Generator: TLeakGenerator; Seed: Cardinal);
  end;

implementation

uses
  Windows, SysUtils;

type
  TLeakObject = class
  public
    Data: string;
    Size: Integer;
    ExpiresTick: Cardinal;
    constructor Create(ASize: Integer);
  end;

constructor TLeakObject.Create(ASize: Integer);
begin
  inherited Create;
  Size := ASize;
  // a string of Size bytes (2 bytes per character), touched by StringOfChar
  Data := StringOfChar('x', (ASize + 1) div 2);
end;

{ TLeakGenerator }

constructor TLeakGenerator.Create(Seed: Cardinal);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FChurn := TList.Create;
  FGrowth := TList.Create;
  FPermanent := TList.Create;
  FSettings := DefaultGeneratorSettings;
  FSeed := Seed;
end;

destructor TLeakGenerator.Destroy;
begin
  Stop;
  Reset;
  FPermanent.Free;
  FGrowth.Free;
  FChurn.Free;
  FLock.Free;
  inherited Destroy;
end;

procedure TLeakGenerator.Start;
begin
  if FThread = nil then
  begin
    FThread := TLeakThread.Create(Self, FSeed);
    Inc(FSeed);  // a restart does not repeat the same sequence
  end;
end;

procedure TLeakGenerator.Stop;
begin
  FreeAndNil(FThread);  // stops and waits
end;

procedure TLeakGenerator.FreeList(List: TList);
var
  I: Integer;
begin
  for I := 0 to List.Count - 1 do
  begin
    Dec(FHeldBytes, TLeakObject(List[I]).Size);
    TLeakObject(List[I]).Free;
  end;
  List.Clear;
end;

procedure TLeakGenerator.Reset;
begin
  FLock.Enter;
  try
    FreeList(FChurn);
    FreeList(FGrowth);
    FreeList(FPermanent);
    FHeldBytes := 0;
  finally
    FLock.Leave;
  end;
end;

procedure TLeakGenerator.AbandonAll;
begin
  Stop;
  FLock.Enter;
  try
    FChurn.Clear;
    FGrowth.Clear;
    FPermanent.Clear;
    FHeldBytes := 0;
  finally
    FLock.Leave;
  end;
end;

procedure TLeakGenerator.SetSettings(const Settings: TGeneratorSettings);
begin
  FLock.Enter;
  try
    FSettings := Settings;
  finally
    FLock.Leave;
  end;
end;

function TLeakGenerator.GetSettings: TGeneratorSettings;
begin
  FLock.Enter;
  try
    Result := FSettings;
  finally
    FLock.Leave;
  end;
end;

function TLeakGenerator.Stats: TGeneratorStats;
begin
  FLock.Enter;
  try
    Result.Running := FThread <> nil;
    Result.ObjectCount := FChurn.Count + FGrowth.Count + FPermanent.Count;
    Result.HeldBytes := FHeldBytes;
    Result.PermanentCount := FPermanent.Count;
  finally
    FLock.Leave;
  end;
end;

{ TLeakThread }

constructor TLeakThread.Create(Generator: TLeakGenerator; Seed: Cardinal);
begin
  FGenerator := Generator;
  FRandom := Seed;
  if FRandom = 0 then
    FRandom := $9E3779B9;
  inherited Create;
end;

function TLeakThread.Random(Lo, Hi: Integer): Integer;
begin
  // xorshift32: own generator, System.Random is not thread-safe
  FRandom := FRandom xor (FRandom shl 13);
  FRandom := FRandom xor (FRandom shr 17);
  FRandom := FRandom xor (FRandom shl 5);
  if Hi <= Lo then
    Result := Lo
  else
    Result := Lo + Integer(FRandom mod Cardinal(Hi - Lo + 1));
end;

procedure TLeakThread.Execute;
const
  TickMs = 20;
var
  S: TGeneratorSettings;
  Tick, LastTick, CycleStart, NextBurst: Cardinal;
  Accumulated: Double;
  CycleCreated, I, N, Size: Integer;
  Obj: TLeakObject;
  G: TLeakGenerator;
begin
  G := FGenerator;
  LastTick := GetTickCount;
  CycleStart := LastTick;
  NextBurst := LastTick;
  Accumulated := 0;
  CycleCreated := 0;
  while not Terminated do
  begin
    S := G.GetSettings;
    Tick := GetTickCount;
    G.FLock.Enter;
    try
      // Mode A objects expire in both modes
      for I := G.FChurn.Count - 1 downto 0 do
      begin
        Obj := TLeakObject(G.FChurn[I]);
        if Integer(Tick - Obj.ExpiresTick) >= 0 then
        begin
          Dec(G.FHeldBytes, Obj.Size);
          Obj.Free;
          G.FChurn[I] := G.FChurn[G.FChurn.Count - 1];
          G.FChurn.Delete(G.FChurn.Count - 1);
        end;
      end;

      if S.Mode = gmChurn then
      begin
        Accumulated := 0;
        if Integer(Tick - NextBurst) >= 0 then
        begin
          N := Random(1, S.ChurnMaxObjects);
          for I := 1 to N do
          begin
            Size := Random(S.ChurnMinSize, S.ChurnMaxSize);
            Obj := TLeakObject.Create(Size);
            Obj.ExpiresTick := Tick + Cardinal(Random(S.ChurnMinLifetimeMs, S.ChurnMaxLifetimeMs));
            G.FChurn.Add(Obj);
            Inc(G.FHeldBytes, Size);
          end;
          NextBurst := Tick + Cardinal(Random(S.ChurnMinIntervalMs, S.ChurnMaxIntervalMs));
        end;
        CycleStart := Tick;
        CycleCreated := 0;
      end
      else
      begin
        NextBurst := Tick;
        Accumulated := Accumulated + S.GrowthRate * Integer(Tick - LastTick) / 1000;
        N := Trunc(Accumulated);
        Accumulated := Accumulated - N;
        for I := 1 to N do
        begin
          Size := Random(S.GrowthMinSize, S.GrowthMaxSize);
          G.FGrowth.Add(TLeakObject.Create(Size));
          Inc(G.FHeldBytes, Size);
        end;
        Inc(CycleCreated, N);
        if S.ReleaseEnabled
          and ((Integer(Tick - CycleStart) >= S.ReleaseAfterSeconds * 1000)
            or ((S.ReleaseAfterObjects > 0) and (CycleCreated >= S.ReleaseAfterObjects))) then
        begin
          // release phase: keep PermanentPercent of this cycle, free the rest
          for I := 0 to G.FGrowth.Count - 1 do
          begin
            Obj := TLeakObject(G.FGrowth[I]);
            if Random(0, 99) < S.PermanentPercent then
              G.FPermanent.Add(Obj)
            else
            begin
              Dec(G.FHeldBytes, Obj.Size);
              Obj.Free;
            end;
          end;
          G.FGrowth.Clear;
          CycleStart := Tick;
          CycleCreated := 0;
        end;
      end;
    finally
      G.FLock.Leave;
    end;
    LastTick := Tick;
    if Pause(TickMs) then
      Break;
  end;
end;

end.
