program LeakWatch;

uses
  FastMM4 in 'third_party\FastMM4\FastMM4.pas', // must stay the first unit
  Forms,
  uSnapshot in 'src\uSnapshot.pas',
  uSnapshotJson in 'src\uSnapshotJson.pas',
  uSnapshotStore in 'src\uSnapshotStore.pas',
  uLeakDetector in 'src\uLeakDetector.pas',
  uMemStats in 'src\uMemStats.pas',
  uTransport in 'src\uTransport.pas',
  uTransportRabbitMq in 'src\uTransportRabbitMq.pas',
  uConfig in 'src\uConfig.pas',
  uAppState in 'src\uAppState.pas',
  uEventLog in 'src\uEventLog.pas',
  uWorkerThread in 'src\uWorkerThread.pas',
  uSnapshotThread in 'src\uSnapshotThread.pas',
  uConsumerThread in 'src\uConsumerThread.pas',
  uLeakThread in 'src\uLeakThread.pas',
  fMain in 'src\fMain.pas';

begin
  Application.Initialize;
  Application.Title := 'LeakWatch';
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
