unit uTransportRabbitMq;

{ ISnapshotTransport over the RabbitMQ management HTTP API (port 15672),
  with one TIdHTTP per transport object. TIdHTTP is not thread-safe: each
  thread creates its own transport.

  Topology: a fanout exchange "leakwatch.snapshots" and one classic queue
  "leakwatch.<InstanceId>" per running instance, so every instance receives
  the snapshots of all instances. RabbitMQ documents HTTP publishing as
  inefficient and /get as a development and troubleshooting tool; at one
  snapshot every few seconds per instance this is acceptable here. }

interface

uses
  Classes, SysUtils, IdHTTP, uTransport;

const
  ExchangeName = 'leakwatch.snapshots';
  QueuePrefix = 'leakwatch.';
  QueueExpiresMs = 300000;     // unused queue is deleted after 5 min
  MessageTtlMs = 600000;
  QueueMaxLength = 5000;

type
  TRabbitMqTransport = class(TInterfacedObject, ISnapshotTransport)
  private
    FSettings: TBrokerSettings;
    FQueueName: string;
    FHttp: TIdHTTP;
    function BaseUrl: string;
    function Send(const Method, Path, Body, Context: string; IsDeclare: Boolean = False): string;
  public
    constructor Create(const Settings: TBrokerSettings; const InstanceId: string);
    destructor Destroy; override;
    { ISnapshotTransport }
    procedure Declare;
    function Publish(const SnapshotJson: string): Boolean;
    function Poll(Payloads: TStrings; MaxCount: Integer): Integer;
    { For tests and clean-up }
    procedure DeleteQueue;
    property QueueName: string read FQueueName;
  end;

{ Percent-encodes one URL path segment (UTF-8, everything but unreserved
  characters), so "/" becomes "%2F". }
function EncodePathSegment(const S: string): string;

function BuildExchangeBody: string;
function BuildQueueBody: string;
function BuildPublishBody(const Payload: string): string;
function BuildGetBody(MaxCount: Integer): string;
{ Value of "routed" in a publish response }
function ParseRouted(const Response: string): Boolean;
{ Adds the "payload" strings of a /get response to Payloads; returns the
  number of messages whose payload was not a string (skipped). }
function ParseGetResponse(const Response: string; Payloads: TStrings): Integer;

implementation

uses
  IdException, JsonDataObjects;

function EncodePathSegment(const S: string): string;
var
  Bytes: TBytes;
  I: Integer;
begin
  Result := '';
  Bytes := TEncoding.UTF8.GetBytes(S);
  for I := 0 to High(Bytes) do
    if AnsiChar(Bytes[I]) in ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'] then
      Result := Result + Char(Bytes[I])
    else
      Result := Result + '%' + IntToHex(Bytes[I], 2);
end;

function BuildExchangeBody: string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.S['type'] := 'fanout';
    O.B['durable'] := True;
    O.B['auto_delete'] := False;
    O.B['internal'] := False;
    O.O['arguments'].Clear;  // creates an empty object
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function BuildQueueBody: string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    // durable: non-durable non-exclusive queues are deprecated in
    // RabbitMQ 4.x; x-expires still removes the queue of a stopped instance
    O.B['durable'] := True;
    O.B['auto_delete'] := False;
    O.O['arguments'].S['x-queue-type'] := 'classic';
    O.O['arguments'].I['x-expires'] := QueueExpiresMs;
    O.O['arguments'].I['x-message-ttl'] := MessageTtlMs;
    O.O['arguments'].I['x-max-length'] := QueueMaxLength;
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function BuildPublishBody(const Payload: string): string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    // all four keys are mandatory
    O.O['properties'].Clear;  // creates an empty object
    O.S['routing_key'] := '';
    O.S['payload'] := Payload;
    O.S['payload_encoding'] := 'string';
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function BuildGetBody(MaxCount: Integer): string;
var
  O: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.I['count'] := MaxCount;
    O.S['ackmode'] := 'ack_requeue_false';
    O.S['encoding'] := 'auto';
    Result := O.ToJSON;
  finally
    O.Free;
  end;
end;

function ParseRouted(const Response: string): Boolean;
var
  Base: TJsonBaseObject;
begin
  Result := False;
  Base := TJsonObject.Parse(Response);
  try
    if not (Base is TJsonObject) then
      raise ETransportError.Create('unexpected publish response: ' + Response);
    Result := TJsonObject(Base).B['routed'];
  finally
    Base.Free;
  end;
end;

function ParseGetResponse(const Response: string; Payloads: TStrings): Integer;
var
  Base: TJsonBaseObject;
  Messages: TJsonArray;
  Msg: TJsonObject;
  I: Integer;
begin
  Result := 0;
  Base := TJsonObject.Parse(Response);
  try
    if not (Base is TJsonArray) then
      raise ETransportError.Create('unexpected /get response: ' + Copy(Response, 1, 200));
    Messages := TJsonArray(Base);
    for I := 0 to Messages.Count - 1 do
    begin
      if Messages.Types[I] <> jdtObject then
      begin
        Inc(Result);
        Continue;
      end;
      Msg := Messages.O[I];
      // "auto" returns base64 only for payloads that are not valid UTF-8,
      // which LeakWatch never publishes
      if Msg.S['payload_encoding'] = 'string' then
        Payloads.Add(Msg.S['payload'])
      else
        Inc(Result);
    end;
  finally
    Base.Free;
  end;
end;

function BytesToUtf8String(Stream: TMemoryStream): string;
var
  Bytes: TBytes;
begin
  SetLength(Bytes, Stream.Size);
  if Stream.Size > 0 then
  begin
    Stream.Position := 0;
    Stream.ReadBuffer(Bytes[0], Stream.Size);
  end;
  Result := TEncoding.UTF8.GetString(Bytes);
end;

{ TRabbitMqTransport }

constructor TRabbitMqTransport.Create(const Settings: TBrokerSettings; const InstanceId: string);
begin
  inherited Create;
  FSettings := Settings;
  FQueueName := QueuePrefix + InstanceId;
  FHttp := TIdHTTP.Create(nil);
  FHttp.ConnectTimeout := Settings.TimeoutMs;
  FHttp.ReadTimeout := Settings.TimeoutMs;
  FHttp.HandleRedirects := False;
  FHttp.Request.BasicAuthentication := True;
  FHttp.Request.Username := Settings.User;
  FHttp.Request.Password := Settings.Password;
  FHttp.Request.Accept := 'application/json';
  FHttp.Request.UserAgent := 'LeakWatch';
end;

destructor TRabbitMqTransport.Destroy;
begin
  FHttp.Free;
  inherited Destroy;
end;

function TRabbitMqTransport.BaseUrl: string;
begin
  Result := Format('http://%s:%d/api', [FSettings.Host, FSettings.Port]);
end;

function HttpError(const Context: string; Status: Integer; const Body: string;
  IsDeclare: Boolean): ETransportHttpError;
begin
  // a 4xx on a declare (including 404: unknown vhost) is a configuration
  // error; retrying it would only loop
  if (Status = 401) or (Status = 403) or (IsDeclare and (Status >= 400) and (Status < 500)) then
    Result := ETransportFatal.Create(Context, Status, Body)
  else if Status = 404 then
    Result := ETransportNotFound.Create(Context, Status, Body)
  else
    Result := ETransportHttpError.Create(Context, Status, Body);
end;

function TRabbitMqTransport.Send(const Method, Path, Body, Context: string; IsDeclare: Boolean): string;
var
  Source: TBytesStream;
  Response: TMemoryStream;
  Url: string;
begin
  Url := BaseUrl + Path;
  Source := TBytesStream.Create(TEncoding.UTF8.GetBytes(Body));
  Response := TMemoryStream.Create;
  try
    FHttp.Request.ContentType := 'application/json';
    FHttp.Request.CharSet := 'utf-8';
    try
      if Method = 'PUT' then
        FHttp.Put(Url, Source, Response)
      else if Method = 'DELETE' then
        FHttp.Delete(Url)
      else
        FHttp.Post(Url, Source, Response);
    except
      on E: EIdHTTPProtocolException do
        raise HttpError(Context, E.ErrorCode, E.ErrorMessage, IsDeclare);
      on E: EIdException do
      begin
        // the connection may be half-open now; start over next time
        try
          FHttp.Disconnect;
        except
          on EIdException do ;
        end;
        raise ETransportError.CreateFmt('%s: %s (%s)', [Context, E.Message, E.ClassName]);
      end;
    end;
    Result := BytesToUtf8String(Response);
    // Indy does not raise for every non-2xx answer: without hoInProcessAuth
    // (off by default) a 401 that it could answer with credentials is
    // returned as a normal response, so check the status here as well
    if (FHttp.ResponseCode < 200) or (FHttp.ResponseCode > 299) then
      raise HttpError(Context, FHttp.ResponseCode, Result, IsDeclare);
  finally
    Response.Free;
    Source.Free;
  end;
end;

procedure TRabbitMqTransport.Declare;
var
  VHost: string;
begin
  VHost := EncodePathSegment(FSettings.VHost);
  Send('PUT', '/exchanges/' + VHost + '/' + EncodePathSegment(ExchangeName),
    BuildExchangeBody, 'declare exchange', True);
  Send('PUT', '/queues/' + VHost + '/' + EncodePathSegment(FQueueName),
    BuildQueueBody, 'declare queue', True);
  Send('POST', '/bindings/' + VHost + '/e/' + EncodePathSegment(ExchangeName)
    + '/q/' + EncodePathSegment(FQueueName), '{"routing_key":""}', 'bind queue', True);
end;

function TRabbitMqTransport.Publish(const SnapshotJson: string): Boolean;
begin
  Result := ParseRouted(Send('POST', '/exchanges/' + EncodePathSegment(FSettings.VHost) + '/'
    + EncodePathSegment(ExchangeName) + '/publish', BuildPublishBody(SnapshotJson), 'publish'));
end;

function TRabbitMqTransport.Poll(Payloads: TStrings; MaxCount: Integer): Integer;
var
  Before: Integer;
begin
  Before := Payloads.Count;
  ParseGetResponse(Send('POST', '/queues/' + EncodePathSegment(FSettings.VHost) + '/'
    + EncodePathSegment(FQueueName) + '/get', BuildGetBody(MaxCount), 'poll'), Payloads);
  Result := Payloads.Count - Before;
end;

procedure TRabbitMqTransport.DeleteQueue;
begin
  Send('DELETE', '/queues/' + EncodePathSegment(FSettings.VHost) + '/'
    + EncodePathSegment(FQueueName), '', 'delete queue');
end;

end.
