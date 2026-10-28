program LeakWatch;

uses
  FastMM4 in 'third_party\FastMM4\FastMM4.pas', // must stay the first unit
  Forms,
  fMain in 'src\fMain.pas';

begin
  Application.Initialize;
  Application.Title := 'LeakWatch';
  Application.CreateForm(TfrmMain, frmMain);
  Application.Run;
end.
