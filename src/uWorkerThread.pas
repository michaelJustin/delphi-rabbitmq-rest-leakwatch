unit uWorkerThread;

{ Base class for the worker threads: cooperative stop through an event, so
  a thread waiting between two iterations wakes up at once. }

interface

uses
  Classes, SyncObjs;

type
  TWorkerThread = class(TThread)
  private
    FStopEvent: TEvent;
  protected
    { Waits up to Ms milliseconds; returns True if the thread should stop. }
    function Pause(Ms: Integer): Boolean;
  public
    { The thread starts running after the constructor of the descendant
      has completed (TThread.AfterConstruction). }
    constructor Create;
    { Stops the thread and waits for it }
    destructor Destroy; override;
    { Asks the thread to stop, without waiting }
    procedure Stop;
  end;

implementation

constructor TWorkerThread.Create;
begin
  FStopEvent := TEvent.Create(nil, True, False, '');
  inherited Create(False);
end;

destructor TWorkerThread.Destroy;
begin
  Stop;
  inherited Destroy;  // waits for Execute to return
  FStopEvent.Free;
end;

procedure TWorkerThread.Stop;
begin
  Terminate;
  FStopEvent.SetEvent;
end;

function TWorkerThread.Pause(Ms: Integer): Boolean;
begin
  if Ms > 0 then
    FStopEvent.WaitFor(Ms);
  Result := Terminated;
end;

end.
