unit fMain;

interface

uses
  Classes, Forms;

type
  TfrmMain = class(TForm)
  public
    constructor Create(AOwner: TComponent); override;
  end;

var
  frmMain: TfrmMain;

implementation

constructor TfrmMain.Create(AOwner: TComponent);
begin
  inherited CreateNew(AOwner);
  Caption := 'LeakWatch';
end;

end.
