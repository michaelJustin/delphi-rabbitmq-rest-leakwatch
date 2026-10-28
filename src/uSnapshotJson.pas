unit uSnapshotJson;

(* Converts TMemSnapshot to and from JSON (schema version 1).

  {"v":1,"instanceId":"PC1-4711","appId":"WS-03",
   "startedUtc":"2026-10-28T10:00:00.000Z","seq":42,
   "ts":"2026-10-28T10:01:24.000Z","intervalMs":2000,
   "allocatedBytes":123,"overheadBytes":45,"efficiency":73.2,
   "totalBlocks":1000,"medium":{"count":3,"bytes":9000},
   "large":{"count":1,"bytes":2000000},"captureMicros":150,
   "small":[[16,120],[24,80]]}

  "small" lists the non-zero small block classes as [blockSize, count]. *)

interface

uses
  uSnapshot;

function SnapshotToJson(const S: TMemSnapshot): string;

{ Returns False with a reason in Error if Json is not a valid snapshot. }
function TryJsonToSnapshot(const Json: string; out S: TMemSnapshot; out Error: string): Boolean;

implementation

uses
  SysUtils, JsonDataObjects;

function SnapshotToJson(const S: TMemSnapshot): string;
var
  O: TJsonObject;
  Small, Pair: TJsonArray;
  I: Integer;
begin
  O := TJsonObject.Create;
  try
    O.I['v'] := SnapshotSchemaVersion;
    O.S['instanceId'] := S.InstanceId;
    O.S['appId'] := S.AppId;
    O.S['startedUtc'] := DateTimeToIso8601(S.StartedUtc);
    O.L['seq'] := S.Seq;
    O.S['ts'] := DateTimeToIso8601(S.TimestampUtc);
    O.I['intervalMs'] := S.IntervalMs;
    O.L['allocatedBytes'] := S.Values.AllocatedBytes;
    O.L['overheadBytes'] := S.Values.OverheadBytes;
    O.F['efficiency'] := S.Values.Efficiency;
    O.L['totalBlocks'] := S.Values.TotalAllocatedBlocks;
    O.O['medium'].L['count'] := S.Values.MediumBlockCount;
    O.O['medium'].L['bytes'] := S.Values.MediumBlockBytes;
    O.O['large'].L['count'] := S.Values.LargeBlockCount;
    O.O['large'].L['bytes'] := S.Values.LargeBlockBytes;
    O.L['captureMicros'] := S.Values.CaptureMicros;
    Small := O.A['small'];
    for I := 0 to S.Values.SmallCount - 1 do
    begin
      Pair := Small.AddArray;
      Pair.Add(S.Values.Small[I].BlockSize);
      Pair.Add(S.Values.Small[I].Count);
    end;
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function TryJsonToSnapshot(const Json: string; out S: TMemSnapshot; out Error: string): Boolean;
var
  Base: TJsonBaseObject;
  O: TJsonObject;
  Small, Pair: TJsonArray;
  I: Integer;
begin
  Result := False;
  Error := '';
  Finalize(S);
  FillChar(S, SizeOf(S), 0);
  try
    Base := TJsonObject.Parse(Json);
  except
    on E: EJsonException do
    begin
      Error := 'invalid JSON: ' + E.Message;
      Exit;
    end;
  end;
  try
    if not (Base is TJsonObject) then
    begin
      Error := 'not a JSON object';
      Exit;
    end;
    O := TJsonObject(Base);
    if O.I['v'] <> SnapshotSchemaVersion then
    begin
      Error := Format('unknown schema version "%s"', [O.S['v']]);
      Exit;
    end;
    S.InstanceId := O.S['instanceId'];
    S.AppId := O.S['appId'];
    S.Seq := O.L['seq'];
    S.IntervalMs := O.I['intervalMs'];
    if S.InstanceId = '' then
    begin
      Error := 'missing instanceId';
      Exit;
    end;
    if S.Seq <= 0 then
    begin
      Error := 'missing or invalid seq';
      Exit;
    end;
    if S.IntervalMs <= 0 then
    begin
      Error := 'missing or invalid intervalMs';
      Exit;
    end;
    if not TryIso8601ToDateTime(O.S['ts'], S.TimestampUtc) then
    begin
      Error := 'invalid ts';
      Exit;
    end;
    if not TryIso8601ToDateTime(O.S['startedUtc'], S.StartedUtc) then
    begin
      Error := 'invalid startedUtc';
      Exit;
    end;
    if S.AppId = '' then
      S.AppId := S.InstanceId;
    S.Values.AllocatedBytes := O.L['allocatedBytes'];
    S.Values.OverheadBytes := O.L['overheadBytes'];
    S.Values.Efficiency := O.F['efficiency'];
    S.Values.TotalAllocatedBlocks := O.L['totalBlocks'];
    if O.Contains('medium') then
    begin
      S.Values.MediumBlockCount := O.O['medium'].L['count'];
      S.Values.MediumBlockBytes := O.O['medium'].L['bytes'];
    end;
    if O.Contains('large') then
    begin
      S.Values.LargeBlockCount := O.O['large'].L['count'];
      S.Values.LargeBlockBytes := O.O['large'].L['bytes'];
    end;
    S.Values.CaptureMicros := O.L['captureMicros'];
    if O.Contains('small') then
    begin
      Small := O.A['small'];
      if Small.Count > MaxSmallClasses then
      begin
        Error := Format('too many small block classes (%d)', [Small.Count]);
        Exit;
      end;
      for I := 0 to Small.Count - 1 do
      begin
        if Small.Types[I] <> jdtArray then
        begin
          Error := 'invalid small block class entry';
          Exit;
        end;
        Pair := Small.A[I];
        if Pair.Count <> 2 then
        begin
          Error := 'invalid small block class entry';
          Exit;
        end;
        S.Values.Small[I].BlockSize := Pair.I[0];
        S.Values.Small[I].Count := Pair.L[1];
      end;
      S.Values.SmallCount := Small.Count;
    end;
    Result := True;
  finally
    Base.Free;
  end;
end;

end.
