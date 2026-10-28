program LeakWatchTests;

{$APPTYPE CONSOLE}

uses
{$IFDEF LEAKWATCH_FASTMM4}
  FastMM4 in '..\third_party\FastMM4\FastMM4.pas', // must stay the first unit
{$ENDIF}
  SysUtils,
  TestFramework,
  TextTestRunner,
  GUITestRunner,
  uSnapshot in '..\src\uSnapshot.pas',
  uSnapshotJson in '..\src\uSnapshotJson.pas',
  uSnapshotStore in '..\src\uSnapshotStore.pas',
  uLeakDetector in '..\src\uLeakDetector.pas',
  uMemStats in '..\src\uMemStats.pas',
  uTransport in '..\src\uTransport.pas',
  uTransportRabbitMq in '..\src\uTransportRabbitMq.pas',
  uConfig in '..\src\uConfig.pas',
  uAppState in '..\src\uAppState.pas',
  uEventLog in '..\src\uEventLog.pas',
  uWorkerThread in '..\src\uWorkerThread.pas',
  uSnapshotThread in '..\src\uSnapshotThread.pas',
  uConsumerThread in '..\src\uConsumerThread.pas',
  uLeakThread in '..\src\uLeakThread.pas',
  JsonDataObjectsSmokeTests in 'JsonDataObjectsSmokeTests.pas',
  SnapshotJsonTests in 'SnapshotJsonTests.pas',
  SnapshotStoreTests in 'SnapshotStoreTests.pas',
  SyntheticSeries in 'SyntheticSeries.pas',
  LeakDetectorTests in 'LeakDetectorTests.pas',
  MemStatsTests in 'MemStatsTests.pas',
  TransportTests in 'TransportTests.pas',
  AppTests in 'AppTests.pas';

begin
  if FindCmdLineSwitch('gui') then
    GUITestRunner.RunRegisteredTests
  else
    // rxbHaltOnFailures: the process exits with a non-zero code on failures
    TextTestRunner.RunRegisteredTests(rxbHaltOnFailures);
end.
