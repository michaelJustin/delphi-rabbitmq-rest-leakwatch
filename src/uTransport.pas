unit uTransport;

{ Broker-independent transport interface for snapshots, so the RabbitMQ
  management API client can be replaced by an AMQP or stream-protocol
  client later. }

interface

uses
  Classes, SysUtils;

type
  TBrokerSettings = record
    Host: string;
    Port: Integer;
    User: string;
    Password: string;
    VHost: string;
    TimeoutMs: Integer;
  end;

  { Network or server error; the caller retries with back-off. }
  ETransportError = class(Exception);

  ETransportHttpError = class(ETransportError)
  private
    FStatusCode: Integer;
    FBody: string;
  public
    constructor Create(const Context: string; StatusCode: Integer; const Body: string);
    property StatusCode: Integer read FStatusCode;
    property Body: string read FBody;
  end;

  { The exchange or queue does not exist (any more): declare again. }
  ETransportNotFound = class(ETransportHttpError);

  { Retrying will not help (bad credentials, missing permissions, a
    conflicting declaration). The caller stops until reconnected. }
  ETransportFatal = class(ETransportHttpError);

  ISnapshotTransport = interface
    ['{2F7A8C14-91D3-4B6E-A5F0-6C3E9D2B184A}']
    { Creates exchange, queue and binding if they don't exist. Idempotent. }
    procedure Declare;
    { Returns False if the broker accepted the message but routed it nowhere. }
    function Publish(const SnapshotJson: string): Boolean;
    { Adds up to MaxCount received snapshot JSON strings to Payloads;
      returns the number added. }
    function Poll(Payloads: TStrings; MaxCount: Integer): Integer;
  end;

function DefaultBrokerSettings: TBrokerSettings;

implementation

function DefaultBrokerSettings: TBrokerSettings;
begin
  Result.Host := 'localhost';
  Result.Port := 15672;
  Result.User := 'guest';
  Result.Password := 'guest';
  Result.VHost := '/';
  Result.TimeoutMs := 5000;
end;

{ ETransportHttpError }

constructor ETransportHttpError.Create(const Context: string; StatusCode: Integer; const Body: string);
begin
  inherited CreateFmt('%s: HTTP %d %s', [Context, StatusCode, Body]);
  FStatusCode := StatusCode;
  FBody := Body;
end;

end.
