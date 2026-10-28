program LeakWatchTests;

{$APPTYPE CONSOLE}

uses
  FastMM4 in '..\third_party\FastMM4\FastMM4.pas', // must stay the first unit
  SysUtils,
  TestFramework,
  TextTestRunner,
  GUITestRunner,
  JsonDataObjectsSmokeTests in 'JsonDataObjectsSmokeTests.pas';

begin
  if FindCmdLineSwitch('gui') then
    GUITestRunner.RunRegisteredTests
  else
    // rxbHaltOnFailures: the process exits with a non-zero code on failures
    TextTestRunner.RunRegisteredTests(rxbHaltOnFailures);
end.
