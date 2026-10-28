unit TransportTests;

{ TransportTests: request bodies and response parsing, no broker needed.

  TransportIntegrationTests: against a running RabbitMQ with the management
  plugin on localhost:15672 (guest/guest). Registered only when the test
  runner is started with -integration. }

interface

uses
  TestFramework, uTransport;

type
  TTransportTest = class(TTestCase)
  published
    procedure EncodesDefaultVHost;
    procedure EncodesNonAsciiAsUtf8;
    procedure KeepsUnreservedCharacters;
    procedure PublishBodyHasAllMandatoryKeys;
    procedure QueueBodyIsDurableClassicWithExpiry;
    procedure ParsesRouted;
    procedure ParsesGetResponse;
    procedure RejectsUnexpectedGetResponse;
  end;

  TTransportIntegrationTest = class(TTestCase)
  private
    FInstanceId: string;
    function Settings: TBrokerSettings;
  protected
    procedure SetUp; override;
    procedure TearDown; override;
  published
    procedure DeclareIsIdempotent;
    procedure PublishedSnapshotIsRoutedAndPolled;
    procedure PollOfMissingQueueRaisesNotFound;
    procedure WrongPasswordIsFatal;
  end;

implementation

uses
  Windows, Classes, SysUtils, JsonDataObjects, uTransportRabbitMq;

{ TTransportTest }

procedure TTransportTest.EncodesDefaultVHost;
begin
  CheckEquals('%2F', EncodePathSegment('/'));
end;

procedure TTransportTest.EncodesNonAsciiAsUtf8;
begin
  CheckEquals('W%C3%A4rme%20%E2%82%AC', EncodePathSegment('W'#$00E4'rme '#$20AC));
end;

procedure TTransportTest.KeepsUnreservedCharacters;
begin
  CheckEquals('leakwatch.PC1-4711_a~', EncodePathSegment('leakwatch.PC1-4711_a~'));
end;

procedure TTransportTest.PublishBodyHasAllMandatoryKeys;
var
  O: TJsonObject;
begin
  O := TJsonObject.Parse(BuildPublishBody('{"v":1,"appId":"a\"b"}')) as TJsonObject;
  try
    CheckTrue(O.Contains('properties'), 'properties');
    CheckTrue(O.Types['properties'] = jdtObject, 'properties is an object');
    CheckTrue(O.Contains('routing_key'), 'routing_key');
    CheckEquals('string', O.S['payload_encoding']);
    CheckEquals('{"v":1,"appId":"a\"b"}', O.S['payload']);
  finally
    O.Free;
  end;
end;

procedure TTransportTest.QueueBodyIsDurableClassicWithExpiry;
var
  O: TJsonObject;
begin
  O := TJsonObject.Parse(BuildQueueBody) as TJsonObject;
  try
    CheckTrue(O.B['durable'], 'durable');
    CheckFalse(O.B['auto_delete'], 'auto_delete');
    CheckEquals('classic', O.O['arguments'].S['x-queue-type']);
    CheckEquals(300000, O.O['arguments'].I['x-expires']);
    CheckEquals(600000, O.O['arguments'].I['x-message-ttl']);
    CheckEquals(5000, O.O['arguments'].I['x-max-length']);
  finally
    O.Free;
  end;
end;

procedure TTransportTest.ParsesRouted;
begin
  CheckTrue(ParseRouted('{"routed":true}'));
  CheckFalse(ParseRouted('{"routed":false}'));
end;

procedure TTransportTest.ParsesGetResponse;
var
  Payloads: TStringList;
  Skipped: Integer;
begin
  Payloads := TStringList.Create;
  try
    Skipped := ParseGetResponse(
      '[{"payload_bytes":9,"redelivered":false,"exchange":"leakwatch.snapshots",' +
      '"routing_key":"","message_count":1,"properties":[],' +
      '"payload":"{\"v\":1}","payload_encoding":"string"},' +
      '{"payload":"AAEC","payload_encoding":"base64"}]', Payloads);
    CheckEquals(1, Payloads.Count, 'payloads');
    CheckEquals('{"v":1}', Payloads[0]);
    CheckEquals(1, Skipped, 'skipped');
    CheckEquals(0, ParseGetResponse('[]', Payloads), 'empty');
  finally
    Payloads.Free;
  end;
end;

procedure TTransportTest.RejectsUnexpectedGetResponse;
var
  Payloads: TStringList;
begin
  Payloads := TStringList.Create;
  try
    try
      ParseGetResponse('{"error":"x"}', Payloads);
      Fail('no exception');
    except
      on ETransportError do ;
    end;
  finally
    Payloads.Free;
  end;
end;

{ TTransportIntegrationTest }

function TTransportIntegrationTest.Settings: TBrokerSettings;
begin
  Result := DefaultBrokerSettings;
end;

procedure TTransportIntegrationTest.SetUp;
begin
  FInstanceId := Format('test-%d-%d', [GetCurrentProcessId, GetTickCount]);
end;

procedure TTransportIntegrationTest.TearDown;
var
  T: TRabbitMqTransport;
begin
  T := TRabbitMqTransport.Create(Settings, FInstanceId);
  try
    try
      T.DeleteQueue;
    except
      on ETransportError do ;  // not declared by this test
    end;
  finally
    T.Free;
  end;
end;

procedure TTransportIntegrationTest.DeclareIsIdempotent;
var
  T: ISnapshotTransport;
begin
  T := TRabbitMqTransport.Create(Settings, FInstanceId);
  T.Declare;
  T.Declare;
end;

procedure TTransportIntegrationTest.PublishedSnapshotIsRoutedAndPolled;
const
  Payload = '{"v":1,"appId":"W'#$00E4'rme '#$20AC'","note":"quote\" and \\backslash"}';
var
  T: ISnapshotTransport;
  Payloads: TStringList;
  I: Integer;
begin
  T := TRabbitMqTransport.Create(Settings, FInstanceId);
  T.Declare;
  CheckTrue(T.Publish(Payload), 'routed');
  Payloads := TStringList.Create;
  try
    // other LeakWatch instances may publish to the same fanout exchange
    for I := 1 to 20 do
    begin
      T.Poll(Payloads, 50);
      if Payloads.IndexOf(Payload) >= 0 then
        Break;
      Sleep(100);
    end;
    CheckTrue(Payloads.IndexOf(Payload) >= 0, 'received: ' + Payloads.Text);
  finally
    Payloads.Free;
  end;
end;

procedure TTransportIntegrationTest.PollOfMissingQueueRaisesNotFound;
var
  T: ISnapshotTransport;
  Payloads: TStringList;
begin
  T := TRabbitMqTransport.Create(Settings, FInstanceId);
  Payloads := TStringList.Create;
  try
    try
      T.Poll(Payloads, 10);
      Fail('no exception');
    except
      on E: ETransportNotFound do
        CheckEquals(404, E.StatusCode);
    end;
  finally
    Payloads.Free;
  end;
end;

procedure TTransportIntegrationTest.WrongPasswordIsFatal;
var
  S: TBrokerSettings;
  T: ISnapshotTransport;
begin
  S := Settings;
  S.Password := 'wrong-password';
  T := TRabbitMqTransport.Create(S, FInstanceId);
  try
    T.Declare;
    Fail('no exception');
  except
    on E: ETransportFatal do
      CheckEquals(401, E.StatusCode);
  end;
end;

initialization
  RegisterTest(TTransportTest.Suite);
  if FindCmdLineSwitch('integration') then
    RegisterTest(TTransportIntegrationTest.Suite);

end.
