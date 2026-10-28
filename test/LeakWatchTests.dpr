program LeakWatchTests;

{$APPTYPE CONSOLE}

uses
  FastMM4 in '..\third_party\FastMM4\FastMM4.pas', // must stay the first unit
  SysUtils,
  TestFramework,
  TextTestRunner,
  GUITestRunner,
  uSnapshot in '..\src\uSnapshot.pas',
  uSnapshotJson in '..\src\uSnapshotJson.pas',
  uSnapshotStore in '..\src\uSnapshotStore.pas',
  uLeakDetector in '..\src\uLeakDetector.pas',
  JsonDataObjectsSmokeTests in 'JsonDataObjectsSmokeTests.pas',
  SnapshotJsonTests in 'SnapshotJsonTests.pas',
  SnapshotStoreTests in 'SnapshotStoreTests.pas',
  SyntheticSeries in 'SyntheticSeries.pas',
  LeakDetectorTests in 'LeakDetectorTests.pas';

begin
  if FindCmdLineSwitch('gui') then
    GUITestRunner.RunRegisteredTests
  else
    // rxbHaltOnFailures: the process exits with a non-zero code on failures
    TextTestRunner.RunRegisteredTests(rxbHaltOnFailures);
end.
