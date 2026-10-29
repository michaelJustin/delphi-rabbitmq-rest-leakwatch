unit fMain;

{ Main form, built in code (no .dfm).

  Top: broker settings, Connect/Disconnect, connection lamp.
  Left: leak generator. Center: known instances and the AllocatedBytes
  chart of the selected one. Bottom: warnings and log.

  The UI never does network I/O. Worker threads write into the shared
  state objects of uAppState and post a data-free wake-up message to a
  private window; the UI then reads what it needs. }

interface

uses
  Windows, Messages, SysUtils, Classes, Graphics, Controls, Forms, StdCtrls, ExtCtrls,
  ComCtrls, Grids,
  uSnapshot, uConfig, uAppState, uSnapshotStore, uSnapshotThread, uConsumerThread,
  uLeakThread, uEventLog;

const
  WM_LEAKWATCH_AUTOSTART = WM_APP + 2;

type
  TParamEdit = (peChurnMinInterval, peChurnMaxInterval, peChurnMaxObjects, peChurnMinSize,
    peChurnMaxSize, peChurnMinLifetime, peChurnMaxLifetime, peGrowthRate, peGrowthMinSize,
    peGrowthMaxSize, peReleaseAfterSeconds, peReleaseAfterObjects, pePermanentPercent);

  TfrmMain = class(TForm)
  private
    FConfig: TLeakWatchConfig;
    FStartedUtc: TDateTime;
    FStartTick: Cardinal;
    FNotifyWnd: HWND;
    FNotifier: TUiNotifier;
    FLog: TLogQueue;
    FWarnings: TWarningList;
    FStatus: TSharedStatus;
    FStore: TSnapshotStore;
    FEventLog: TDetectorEventLog;
    FGenerator: TLeakGenerator;
    FSnapshotThread: TSnapshotThread;
    FConsumerThread: TConsumerThread;
    FRetiring: TList;  // stopped threads not yet finished
    FLastWarningSeq: Integer;
    FSelectedInstance: string;
    FInstances: TInstanceInfoArray;
    FChartSamples: TSampleArray;
    FTrayLevel: TLeakLevel;
    FIcons: array[TLeakLevel] of TIcon;
    FShutDown: Boolean;
    FLoadingControls: Boolean;

    edHost, edPort, edUser, edPassword, edVHost: TEdit;
    btnConnect, btnDisconnect: TButton;
    shpLamp: TShape;
    lblConnection: TLabel;
    rgMode: TRadioGroup;
    edParams: array[TParamEdit] of TEdit;
    chkRelease: TCheckBox;
    btnStart, btnStop, btnReset: TButton;
    chkReportLeaks: TCheckBox;
    lblHeld: TLabel;
    grdInstances: TStringGrid;
    pbChart: TPaintBox;
    lvWarnings: TListView;
    memLog: TMemo;
    sbStatus: TStatusBar;
    tmrUi: TTimer;
    Tray: TTrayIcon;

    procedure BuildUi;
    function AddLabeledEdit(Parent: TWinControl; var Y: Integer; const Caption, Value: string;
      EditWidth: Integer = 70): TEdit;
    procedure LoadControls;
    procedure LogStartupInfo;

    procedure NotifyWndProc(var Msg: TMessage);
    procedure HandleNotify;
    procedure DrainLog;
    procedure UpdateWarnings;
    procedure UpdateGrid;
    procedure UpdateConnectionState;
    procedure UpdateGeneratorLabel;
    procedure UpdateStatusBar;
    procedure UpdateTray;
    procedure ReapRetiredThreads;

    procedure Connect;
    procedure Disconnect;
    procedure ShutDown;
    function ReadGeneratorSettings: TGeneratorSettings;

    procedure ConnectClick(Sender: TObject);
    procedure DisconnectClick(Sender: TObject);
    procedure StartClick(Sender: TObject);
    procedure StopClick(Sender: TObject);
    procedure ResetClick(Sender: TObject);
    procedure GeneratorChange(Sender: TObject);
    procedure TimerTick(Sender: TObject);
    procedure GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
    procedure GridDrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect; State: TGridDrawState);
    procedure ChartPaint(Sender: TObject);
    procedure FormClose(Sender: TObject; var Action: TCloseAction);
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

var
  frmMain: TfrmMain;

implementation

uses
  uTransport, uLeakDetector, uMemStats;

const
  LevelColors: array[TLeakLevel] of TColor = ($0050B000, $0000A5FF, $002020E0);
  ColAppId = 0;
  ColInstanceId = 1;
  ColLastSeen = 2;
  ColAllocated = 3;
  ColBlocks = 4;
  ColLevel = 5;
  ColState = 6;

function MakeLevelIcon(Color: TColor): TIcon;
var
  ColorBmp, MaskBmp: TBitmap;
  Info: TIconInfo;
begin
  ColorBmp := TBitmap.Create;
  MaskBmp := TBitmap.Create;
  try
    ColorBmp.Width := 16;
    ColorBmp.Height := 16;
    ColorBmp.Canvas.Brush.Color := clBlack;
    ColorBmp.Canvas.FillRect(Rect(0, 0, 16, 16));
    ColorBmp.Canvas.Brush.Color := Color;
    ColorBmp.Canvas.Pen.Color := clBlack;
    ColorBmp.Canvas.Ellipse(1, 1, 15, 15);
    MaskBmp.Monochrome := True;
    MaskBmp.Width := 16;
    MaskBmp.Height := 16;
    MaskBmp.Canvas.Brush.Color := clWhite;  // transparent
    MaskBmp.Canvas.FillRect(Rect(0, 0, 16, 16));
    MaskBmp.Canvas.Brush.Color := clBlack;  // opaque
    MaskBmp.Canvas.Pen.Color := clBlack;
    MaskBmp.Canvas.Ellipse(1, 1, 15, 15);
    Info.fIcon := True;
    Info.xHotspot := 0;
    Info.yHotspot := 0;
    Info.hbmMask := MaskBmp.Handle;
    Info.hbmColor := ColorBmp.Handle;
    Result := TIcon.Create;
    Result.Handle := CreateIconIndirect(Info);
  finally
    MaskBmp.Free;
    ColorBmp.Free;
  end;
end;

function UtcToLocalText(const Utc: TDateTime): string;
var
  StUtc, StLocal: TSystemTime;
begin
  DateTimeToSystemTime(Utc, StUtc);
  if SystemTimeToTzSpecificLocalTime(nil, StUtc, StLocal) then
    Result := FormatDateTime('hh:nn:ss', SystemTimeToDateTime(StLocal))
  else
    Result := FormatDateTime('hh:nn:ss', Utc) + ' UTC';
end;

{ TfrmMain }

constructor TfrmMain.Create(AOwner: TComponent);
var
  Args: TStringList;
  Level: TLeakLevel;
  Seed: Cardinal;
begin
  inherited CreateNew(AOwner);
  FStartedUtc := NowUtc;
  FStartTick := GetTickCount;

  FConfig := TLeakWatchConfig.Create;
  Args := TStringList.Create;
  try
    ParamsToStrings(Args);
    FConfig.Load(Args, ParamStr(0));
  finally
    Args.Free;
  end;

  FNotifyWnd := AllocateHWnd(NotifyWndProc);
  FNotifier := TUiNotifier.Create(FNotifyWnd);
  FLog := TLogQueue.Create(FNotifier);
  FWarnings := TWarningList.Create(FNotifier);
  FStatus := TSharedStatus.Create(FNotifier);
  // the store and the chart buffer are allocated now, during the start-up
  // phase the detector ignores
  FStore := TSnapshotStore.Create(FConfig.StoreCapacity);
  SetLength(FChartSamples, FConfig.StoreCapacity);
  FRetiring := TList.Create;
  if FConfig.HasSeed then
    Seed := FConfig.Seed
  else
    Seed := GetTickCount xor GetCurrentProcessId;
  FGenerator := TLeakGenerator.Create(Seed);
  FGenerator.SetSettings(FConfig.Generator);
  for Level := Low(TLeakLevel) to High(TLeakLevel) do
    FIcons[Level] := MakeLevelIcon(LevelColors[Level]);

  BuildUi;
  LoadControls;
  OnClose := FormClose;

  try
    FEventLog := TDetectorEventLog.Create(FConfig.EventLogFile, FConfig.AppId, FConfig.InstanceId);
  except
    on E: Exception do
    begin
      FEventLog := nil;
      FLog.Add('event log disabled: ' + E.Message);
    end;
  end;

  LogStartupInfo;
  UpdateConnectionState;
  UpdateTray;
  if FConfig.AutoStart then
    PostMessage(FNotifyWnd, WM_LEAKWATCH_AUTOSTART, 0, 0);
end;

destructor TfrmMain.Destroy;
var
  Level: TLeakLevel;
begin
  ShutDown;
  inherited Destroy;
  FGenerator.Free;
  FEventLog.Free;
  FRetiring.Free;
  FStore.Free;
  FStatus.Free;
  FWarnings.Free;
  FLog.Free;
  FNotifier.Free;
  if FNotifyWnd <> 0 then
    DeallocateHWnd(FNotifyWnd);
  for Level := Low(TLeakLevel) to High(TLeakLevel) do
    FIcons[Level].Free;
  FConfig.Free;
end;

function TfrmMain.AddLabeledEdit(Parent: TWinControl; var Y: Integer; const Caption, Value: string;
  EditWidth: Integer): TEdit;
var
  L: TLabel;
begin
  L := TLabel.Create(Self);
  L.Parent := Parent;
  L.Caption := Caption;
  L.Left := 8;
  L.Top := Y + 3;
  Result := TEdit.Create(Self);
  Result.Parent := Parent;
  Result.Left := Parent.ClientWidth - EditWidth - 8;
  Result.Top := Y;
  Result.Width := EditWidth;
  Result.Text := Value;
  Inc(Y, 24);
end;

procedure TfrmMain.BuildUi;
var
  pnlTop, pnlLeft, pnlMain, pnlBottom, pnlCenter: TPanel;
  gbA, gbB: TGroupBox;
  Split: TSplitter;
  X, Y: Integer;

  function TopEdit(const Caption: string; Width: Integer; Password: Boolean = False): TEdit;
  var
    L: TLabel;
  begin
    L := TLabel.Create(Self);
    L.Parent := pnlTop;
    L.Caption := Caption;
    L.Left := X;
    L.Top := 13;
    Inc(X, L.Width + 4);
    Result := TEdit.Create(Self);
    Result.Parent := pnlTop;
    Result.Left := X;
    Result.Top := 10;
    Result.Width := Width;
    if Password then
      Result.PasswordChar := '*';
    Inc(X, Width + 10);
  end;

  function Button(Parent: TWinControl; const Caption: string; Left, Top: Integer;
    OnClick: TNotifyEvent): TButton;
  begin
    Result := TButton.Create(Self);
    Result.Parent := Parent;
    Result.Caption := Caption;
    Result.SetBounds(Left, Top, 75, 25);
    Result.OnClick := OnClick;
  end;

  procedure AddColumn(const ACaption: string; AWidth: Integer);
  var
    Column: TListColumn;
  begin
    Column := lvWarnings.Columns.Add;
    Column.Caption := ACaption;
    Column.Width := AWidth;
  end;

begin
  Caption := 'LeakWatch';
  Width := 1180;
  Height := 820;
  Position := poScreenCenter;
  Font.Name := 'Tahoma';
  Font.Size := 8;
  Icon.Assign(FIcons[llNone]);
  Application.Icon.Assign(FIcons[llNone]);

  sbStatus := TStatusBar.Create(Self);
  sbStatus.Parent := Self;
  sbStatus.Panels.Add.Width := 300;
  sbStatus.Panels.Add.Width := 140;
  sbStatus.Panels.Add.Width := 200;
  sbStatus.Panels.Add.Width := 200;
  sbStatus.Panels.Add.Width := 300;

  // top: broker
  pnlTop := TPanel.Create(Self);
  pnlTop.Parent := Self;
  pnlTop.Align := alTop;
  pnlTop.Height := 44;
  pnlTop.BevelOuter := bvNone;
  X := 8;
  edHost := TopEdit('Host', 140);
  edPort := TopEdit('Port', 50);
  edUser := TopEdit('User', 90);
  edPassword := TopEdit('Password', 90, True);
  edVHost := TopEdit('VHost', 70);
  btnConnect := Button(pnlTop, 'Connect', X, 9, ConnectClick);
  btnDisconnect := Button(pnlTop, 'Disconnect', X + 80, 9, DisconnectClick);
  Inc(X, 170);
  shpLamp := TShape.Create(Self);
  shpLamp.Parent := pnlTop;
  shpLamp.Shape := stCircle;
  shpLamp.SetBounds(X, 12, 18, 18);
  lblConnection := TLabel.Create(Self);
  lblConnection.Parent := pnlTop;
  lblConnection.Left := X + 26;
  lblConnection.Top := 14;

  // left: generator
  pnlLeft := TPanel.Create(Self);
  pnlLeft.Parent := Self;
  pnlLeft.Align := alLeft;
  pnlLeft.Width := 280;
  pnlLeft.BevelOuter := bvNone;

  rgMode := TRadioGroup.Create(Self);
  rgMode.Parent := pnlLeft;
  rgMode.SetBounds(8, 4, 264, 60);
  rgMode.Caption := ' Leak generator mode ';
  rgMode.Items.Add('A - random churn (no leak)');
  rgMode.Items.Add('B - continuous growth (leak)');
  rgMode.OnClick := GeneratorChange;

  gbA := TGroupBox.Create(Self);
  gbA.Parent := pnlLeft;
  gbA.SetBounds(8, 70, 264, 196);
  gbA.Caption := ' Mode A ';
  Y := 18;
  edParams[peChurnMinInterval] := AddLabeledEdit(gbA, Y, 'Burst interval min (ms)', '');
  edParams[peChurnMaxInterval] := AddLabeledEdit(gbA, Y, 'Burst interval max (ms)', '');
  edParams[peChurnMaxObjects] := AddLabeledEdit(gbA, Y, 'Objects per burst (1..N)', '');
  edParams[peChurnMinSize] := AddLabeledEdit(gbA, Y, 'Object size min (bytes)', '');
  edParams[peChurnMaxSize] := AddLabeledEdit(gbA, Y, 'Object size max (bytes)', '');
  edParams[peChurnMinLifetime] := AddLabeledEdit(gbA, Y, 'Lifetime min (ms)', '');
  edParams[peChurnMaxLifetime] := AddLabeledEdit(gbA, Y, 'Lifetime max (ms)', '');

  gbB := TGroupBox.Create(Self);
  gbB.Parent := pnlLeft;
  gbB.SetBounds(8, 272, 264, 196);
  gbB.Caption := ' Mode B ';
  Y := 18;
  edParams[peGrowthRate] := AddLabeledEdit(gbB, Y, 'Rate (objects/s)', '');
  edParams[peGrowthMinSize] := AddLabeledEdit(gbB, Y, 'Object size min (bytes)', '');
  edParams[peGrowthMaxSize] := AddLabeledEdit(gbB, Y, 'Object size max (bytes)', '');
  chkRelease := TCheckBox.Create(Self);
  chkRelease.Parent := gbB;
  chkRelease.SetBounds(8, Y, 240, 17);
  chkRelease.Caption := 'Release phase (sawtooth)';
  chkRelease.OnClick := GeneratorChange;
  Inc(Y, 24);
  edParams[peReleaseAfterSeconds] := AddLabeledEdit(gbB, Y, 'Release after (s)', '');
  edParams[peReleaseAfterObjects] := AddLabeledEdit(gbB, Y, 'or after objects (0 = off)', '');
  edParams[pePermanentPercent] := AddLabeledEdit(gbB, Y, 'Permanent leak (%)', '');

  btnStart := Button(pnlLeft, 'Start', 8, 476, StartClick);
  btnStop := Button(pnlLeft, 'Stop', 96, 476, StopClick);
  btnReset := Button(pnlLeft, 'Reset', 184, 476, ResetClick);
  chkReportLeaks := TCheckBox.Create(Self);
  chkReportLeaks.Parent := pnlLeft;
  chkReportLeaks.SetBounds(8, 510, 264, 17);
  chkReportLeaks.Caption := 'Report leaks at exit';
  lblHeld := TLabel.Create(Self);
  lblHeld.Parent := pnlLeft;
  lblHeld.AutoSize := False;
  lblHeld.WordWrap := True;
  lblHeld.SetBounds(8, 536, 264, 40);

  // right of the generator: instances and chart, below them warnings and
  // log (inside pnlMain, so the generator panel keeps the full height)
  pnlMain := TPanel.Create(Self);
  pnlMain.Parent := Self;
  pnlMain.Align := alClient;
  pnlMain.BevelOuter := bvNone;

  pnlBottom := TPanel.Create(Self);
  pnlBottom.Parent := pnlMain;
  pnlBottom.Align := alBottom;
  pnlBottom.Height := 250;
  pnlBottom.BevelOuter := bvNone;
  Split := TSplitter.Create(Self);
  Split.Parent := pnlMain;
  Split.Align := alBottom;
  Split.Top := pnlBottom.Top - 1;

  lvWarnings := TListView.Create(Self);
  lvWarnings.Parent := pnlBottom;
  lvWarnings.Align := alTop;
  lvWarnings.Height := 110;
  lvWarnings.ViewStyle := vsReport;
  lvWarnings.ReadOnly := True;
  lvWarnings.RowSelect := True;
  AddColumn('Time', 70);
  AddColumn('AppId', 90);
  AddColumn('InstanceId', 130);
  AddColumn('Level', 70);
  AddColumn('Explanation', 700);

  memLog := TMemo.Create(Self);
  memLog.Parent := pnlBottom;
  memLog.Align := alClient;
  memLog.ReadOnly := True;
  memLog.ScrollBars := ssVertical;
  memLog.WordWrap := False;
  memLog.Font.Name := 'Courier New';

  // center: instances and chart
  pnlCenter := TPanel.Create(Self);
  pnlCenter.Parent := pnlMain;
  pnlCenter.Align := alClient;
  pnlCenter.BevelOuter := bvNone;

  grdInstances := TStringGrid.Create(Self);
  grdInstances.Parent := pnlCenter;
  grdInstances.Align := alTop;
  grdInstances.Height := 150;
  grdInstances.ColCount := 7;
  grdInstances.RowCount := 2;
  grdInstances.FixedCols := 0;
  grdInstances.FixedRows := 1;
  grdInstances.DefaultRowHeight := 18;
  grdInstances.Options := [goFixedVertLine, goFixedHorzLine, goVertLine, goHorzLine,
    goRowSelect, goColSizing];
  grdInstances.Cells[ColAppId, 0] := 'AppId';
  grdInstances.Cells[ColInstanceId, 0] := 'InstanceId';
  grdInstances.Cells[ColLastSeen, 0] := 'Last seen';
  grdInstances.Cells[ColAllocated, 0] := 'Allocated';
  grdInstances.Cells[ColBlocks, 0] := 'Blocks';
  grdInstances.Cells[ColLevel, 0] := 'Level';
  grdInstances.Cells[ColState, 0] := 'State';
  grdInstances.ColWidths[ColAppId] := 100;
  grdInstances.ColWidths[ColInstanceId] := 150;
  grdInstances.ColWidths[ColLastSeen] := 70;
  grdInstances.ColWidths[ColAllocated] := 80;
  grdInstances.ColWidths[ColBlocks] := 70;
  grdInstances.ColWidths[ColLevel] := 70;
  grdInstances.ColWidths[ColState] := 230;
  grdInstances.OnSelectCell := GridSelectCell;
  grdInstances.OnDrawCell := GridDrawCell;
  Split := TSplitter.Create(Self);
  Split.Parent := pnlCenter;
  Split.Align := alTop;
  Split.Top := grdInstances.Top + grdInstances.Height;

  pbChart := TPaintBox.Create(Self);
  pbChart.Parent := pnlCenter;
  pbChart.Align := alClient;
  pbChart.OnPaint := ChartPaint;

  sbStatus.Top := ClientHeight + 100;  // below everything else at the bottom

  tmrUi := TTimer.Create(Self);
  tmrUi.Interval := 1000;
  tmrUi.OnTimer := TimerTick;

  Tray := TTrayIcon.Create(Self);
  Tray.Icon.Assign(FIcons[llNone]);
  Tray.Visible := True;
end;

procedure TfrmMain.LoadControls;
var
  G: TGeneratorSettings;
begin
  FLoadingControls := True;
  try
    if FConfig.AppId <> FConfig.InstanceId then
      Caption := Format('LeakWatch [%s] (%s)', [FConfig.AppId, FConfig.InstanceId])
    else
      Caption := Format('LeakWatch [%s]', [FConfig.AppId]);
    edHost.Text := FConfig.Broker.Host;
    edPort.Text := IntToStr(FConfig.Broker.Port);
    edUser.Text := FConfig.Broker.User;
    edPassword.Text := FConfig.Broker.Password;
    edVHost.Text := FConfig.Broker.VHost;
    G := FConfig.Generator;
    rgMode.ItemIndex := Ord(G.Mode);
    edParams[peChurnMinInterval].Text := IntToStr(G.ChurnMinIntervalMs);
    edParams[peChurnMaxInterval].Text := IntToStr(G.ChurnMaxIntervalMs);
    edParams[peChurnMaxObjects].Text := IntToStr(G.ChurnMaxObjects);
    edParams[peChurnMinSize].Text := IntToStr(G.ChurnMinSize);
    edParams[peChurnMaxSize].Text := IntToStr(G.ChurnMaxSize);
    edParams[peChurnMinLifetime].Text := IntToStr(G.ChurnMinLifetimeMs);
    edParams[peChurnMaxLifetime].Text := IntToStr(G.ChurnMaxLifetimeMs);
    edParams[peGrowthRate].Text := IntToStr(G.GrowthRate);
    edParams[peGrowthMinSize].Text := IntToStr(G.GrowthMinSize);
    edParams[peGrowthMaxSize].Text := IntToStr(G.GrowthMaxSize);
    chkRelease.Checked := G.ReleaseEnabled;
    edParams[peReleaseAfterSeconds].Text := IntToStr(G.ReleaseAfterSeconds);
    edParams[peReleaseAfterObjects].Text := IntToStr(G.ReleaseAfterObjects);
    edParams[pePermanentPercent].Text := IntToStr(G.PermanentPercent);
    chkReportLeaks.Checked := FConfig.ReportLeaks;
  finally
    FLoadingControls := False;
  end;
  edParams[peChurnMinInterval].OnChange := GeneratorChange;
  edParams[peChurnMaxInterval].OnChange := GeneratorChange;
  edParams[peChurnMaxObjects].OnChange := GeneratorChange;
  edParams[peChurnMinSize].OnChange := GeneratorChange;
  edParams[peChurnMaxSize].OnChange := GeneratorChange;
  edParams[peChurnMinLifetime].OnChange := GeneratorChange;
  edParams[peChurnMaxLifetime].OnChange := GeneratorChange;
  edParams[peGrowthRate].OnChange := GeneratorChange;
  edParams[peGrowthMinSize].OnChange := GeneratorChange;
  edParams[peGrowthMaxSize].OnChange := GeneratorChange;
  edParams[peReleaseAfterSeconds].OnChange := GeneratorChange;
  edParams[peReleaseAfterObjects].OnChange := GeneratorChange;
  edParams[pePermanentPercent].OnChange := GeneratorChange;
end;

procedure TfrmMain.LogStartupInfo;
const
  Sources: array[TAppIdSource] of string = ('command line', 'INI file', 'generated');
var
  I: Integer;
begin
  FLog.Add(Format('LeakWatch started: app ''%s'' (AppId from %s), instance %s',
    [FConfig.AppId, Sources[FConfig.AppIdSource], FConfig.InstanceId]));
  FLog.Add('memory manager: ' + TMemStats.MemoryManagerName);
  FLog.Add('INI file: ' + FConfig.IniFileName);
  if Assigned(FEventLog) then
    FLog.Add('detector event log: ' + FConfig.EventLogFile);
  for I := 0 to FConfig.UnknownSwitches.Count - 1 do
    FLog.Add('ignored unknown switch: ' + FConfig.UnknownSwitches[I]);
  for I := 0 to FConfig.Warnings.Count - 1 do
    FLog.Add('configuration: ' + FConfig.Warnings[I]);
  if FConfig.RunForMinutes > 0 then
    FLog.Add(Format('will close after %s min', [FloatToStrInvariant(FConfig.RunForMinutes)]));
end;

function TfrmMain.ReadGeneratorSettings: TGeneratorSettings;

  function Value(P: TParamEdit; Default, Min: Integer): Integer;
  begin
    Result := StrToIntDef(Trim(edParams[P].Text), Default);
    if Result < Min then
      Result := Min;
  end;

  procedure Order(var Lo, Hi: Integer);
  var
    T: Integer;
  begin
    if Lo > Hi then
    begin
      T := Lo;
      Lo := Hi;
      Hi := T;
    end;
  end;

var
  Old: TGeneratorSettings;
begin
  Old := FGenerator.GetSettings;
  Result := Old;
  if rgMode.ItemIndex = 1 then
    Result.Mode := gmGrowth
  else
    Result.Mode := gmChurn;
  Result.ChurnMinIntervalMs := Value(peChurnMinInterval, Old.ChurnMinIntervalMs, 1);
  Result.ChurnMaxIntervalMs := Value(peChurnMaxInterval, Old.ChurnMaxIntervalMs, 1);
  Order(Result.ChurnMinIntervalMs, Result.ChurnMaxIntervalMs);
  Result.ChurnMaxObjects := Value(peChurnMaxObjects, Old.ChurnMaxObjects, 1);
  Result.ChurnMinSize := Value(peChurnMinSize, Old.ChurnMinSize, 1);
  Result.ChurnMaxSize := Value(peChurnMaxSize, Old.ChurnMaxSize, 1);
  Order(Result.ChurnMinSize, Result.ChurnMaxSize);
  Result.ChurnMinLifetimeMs := Value(peChurnMinLifetime, Old.ChurnMinLifetimeMs, 1);
  Result.ChurnMaxLifetimeMs := Value(peChurnMaxLifetime, Old.ChurnMaxLifetimeMs, 1);
  Order(Result.ChurnMinLifetimeMs, Result.ChurnMaxLifetimeMs);
  Result.GrowthRate := Value(peGrowthRate, Old.GrowthRate, 0);
  Result.GrowthMinSize := Value(peGrowthMinSize, Old.GrowthMinSize, 1);
  Result.GrowthMaxSize := Value(peGrowthMaxSize, Old.GrowthMaxSize, 1);
  Order(Result.GrowthMinSize, Result.GrowthMaxSize);
  Result.ReleaseEnabled := chkRelease.Checked;
  Result.ReleaseAfterSeconds := Value(peReleaseAfterSeconds, Old.ReleaseAfterSeconds, 1);
  Result.ReleaseAfterObjects := Value(peReleaseAfterObjects, Old.ReleaseAfterObjects, 0);
  Result.PermanentPercent := Value(pePermanentPercent, Old.PermanentPercent, 0);
  if Result.PermanentPercent > 100 then
    Result.PermanentPercent := 100;
end;

procedure TfrmMain.GeneratorChange(Sender: TObject);
begin
  if not FLoadingControls then
    FGenerator.SetSettings(ReadGeneratorSettings);
end;

procedure TfrmMain.StartClick(Sender: TObject);
begin
  FGenerator.SetSettings(ReadGeneratorSettings);
  FGenerator.Start;
  FLog.Add(Format('generator started (mode %s)', [ModeToStr(FGenerator.GetSettings.Mode)]));
  UpdateGeneratorLabel;
end;

procedure TfrmMain.StopClick(Sender: TObject);
begin
  FGenerator.Stop;
  FLog.Add('generator stopped (objects kept)');
  UpdateGeneratorLabel;
end;

procedure TfrmMain.ResetClick(Sender: TObject);
begin
  FGenerator.Reset;
  FLog.Add('generator reset (all objects freed)');
  UpdateGeneratorLabel;
end;

procedure TfrmMain.Connect;
var
  Pub: TSnapshotThreadSettings;
  Con: TConsumerThreadSettings;
  Broker: TBrokerSettings;
begin
  if Assigned(FSnapshotThread) or (FRetiring.Count > 0) then
    Exit;
  Broker := FConfig.Broker;
  Broker.Host := Trim(edHost.Text);
  Broker.Port := StrToIntDef(Trim(edPort.Text), Broker.Port);
  Broker.User := edUser.Text;
  Broker.Password := edPassword.Text;
  Broker.VHost := edVHost.Text;
  if (Broker.Host <> FConfig.Broker.Host) or (Broker.Port <> FConfig.Broker.Port)
    or (Broker.User <> FConfig.Broker.User) or (Broker.Password <> FConfig.Broker.Password)
    or (Broker.VHost <> FConfig.Broker.VHost) then
  begin
    FConfig.Broker := Broker;
    try
      FConfig.SaveBroker;
    except
      on E: Exception do
        FLog.Add('could not save the INI file: ' + E.Message);
    end;
  end;

  Pub.Broker := Broker;
  Pub.InstanceId := FConfig.InstanceId;
  Pub.AppId := FConfig.AppId;
  Pub.StartedUtc := FStartedUtc;
  Pub.IntervalMs := FConfig.IntervalMs;
  Con.Broker := Broker;
  Con.InstanceId := FConfig.InstanceId;
  Con.AppId := FConfig.AppId;
  Con.PollMs := FConfig.PollMs;
  Con.Detector := FConfig.Detector;
  FLog.Add(Format('connecting to http://%s:%d (vhost %s) as %s',
    [Broker.Host, Broker.Port, Broker.VHost, Broker.User]));
  FConsumerThread := TConsumerThread.Create(Con, FStore, FWarnings, FStatus, FLog, FNotifier, FEventLog);
  FSnapshotThread := TSnapshotThread.Create(Pub, FStatus, FLog);
  UpdateConnectionState;
end;

procedure TfrmMain.Disconnect;
begin
  // stop without waiting: a thread may be inside an HTTP call (up to the
  // timeout); the timer frees it once it has finished
  if Assigned(FSnapshotThread) then
  begin
    FSnapshotThread.Stop;
    FRetiring.Add(FSnapshotThread);
    FSnapshotThread := nil;
  end;
  if Assigned(FConsumerThread) then
  begin
    FConsumerThread.Stop;
    FRetiring.Add(FConsumerThread);
    FConsumerThread := nil;
  end;
  FLog.Add('disconnecting');
  UpdateConnectionState;
end;

procedure TfrmMain.ReapRetiredThreads;
var
  I: Integer;
begin
  for I := FRetiring.Count - 1 downto 0 do
    if TThread(FRetiring[I]).Finished then
    begin
      TThread(FRetiring[I]).Free;
      FRetiring.Delete(I);
    end;
end;

procedure TfrmMain.ConnectClick(Sender: TObject);
begin
  Connect;
end;

procedure TfrmMain.DisconnectClick(Sender: TObject);
begin
  Disconnect;
end;

procedure TfrmMain.ShutDown;
var
  I: Integer;
begin
  if FShutDown then
    Exit;
  FShutDown := True;
  tmrUi.Enabled := False;
  FNotifier.Detach;
  Disconnect;
  // waits for the threads; the consumer writes the FINAL lines now
  for I := 0 to FRetiring.Count - 1 do
    TThread(FRetiring[I]).Free;
  FRetiring.Clear;
  FGenerator.Stop;
  if chkReportLeaks.Checked then
  begin
    // leave the generator's objects allocated, so FastMM4 reports them
    ReportMemoryLeaksOnShutdown := True;
    FGenerator.AbandonAll;
  end
  else
  begin
    ReportMemoryLeaksOnShutdown := False;
    FGenerator.Reset;
  end;
  // scripted runs (-runfor) report whether the transport ever worked
  if (FConfig.RunForMinutes > 0) and not FStatus.Get.EverConnected then
    ExitCode := 1;
  Tray.Visible := False;
end;

procedure TfrmMain.FormClose(Sender: TObject; var Action: TCloseAction);
begin
  ShutDown;
end;

procedure TfrmMain.NotifyWndProc(var Msg: TMessage);
begin
  try
    case Msg.Msg of
      WM_LEAKWATCH_NOTIFY:
        if not FShutDown then
          HandleNotify;
      WM_LEAKWATCH_AUTOSTART:
        if not FShutDown then
        begin
          FLog.Add('autostart');
          Connect;
          StartClick(nil);
        end;
    else
      Msg.Result := DefWindowProc(FNotifyWnd, Msg.Msg, Msg.WParam, Msg.LParam);
    end;
  except
    Application.HandleException(Self);
  end;
end;

procedure TfrmMain.HandleNotify;
var
  Kinds: Integer;
begin
  Kinds := FNotifier.TakePending;
  if (Kinds and NotifyLog) <> 0 then
    DrainLog;
  if (Kinds and NotifyWarning) <> 0 then
    UpdateWarnings;
  if (Kinds and NotifyData) <> 0 then
  begin
    UpdateGrid;
    pbChart.Invalidate;
  end;
  if (Kinds and NotifyState) <> 0 then
    UpdateConnectionState;
end;

procedure TfrmMain.DrainLog;
var
  Lines: TStringList;
  I: Integer;
begin
  Lines := TStringList.Create;
  try
    FLog.Drain(Lines);
    if Lines.Count = 0 then
      Exit;
    memLog.Lines.BeginUpdate;
    try
      for I := 0 to Lines.Count - 1 do
        memLog.Lines.Add(Lines[I]);
      while memLog.Lines.Count > MaxLogLines do
        memLog.Lines.Delete(0);
    finally
      memLog.Lines.EndUpdate;
    end;
    SendMessage(memLog.Handle, EM_LINESCROLL, 0, memLog.Lines.Count);
  finally
    Lines.Free;
  end;
end;

procedure TfrmMain.UpdateWarnings;
var
  Entries: TWarningEntries;
  I: Integer;
  Item: TListItem;
begin
  Entries := FWarnings.GetSince(FLastWarningSeq);
  if Length(Entries) = 0 then
    Exit;
  lvWarnings.Items.BeginUpdate;
  try
    for I := 0 to High(Entries) do
    begin
      Item := lvWarnings.Items.Insert(0);  // newest first
      Item.Caption := UtcToLocalText(Entries[I].TimeUtc);
      Item.SubItems.Add(Entries[I].AppId);
      Item.SubItems.Add(Entries[I].InstanceId);
      Item.SubItems.Add(LeakLevelToStr(Entries[I].Level));
      Item.SubItems.Add(Entries[I].Text);
      FLastWarningSeq := Entries[I].Seq;
      if Entries[I].Level > llNone then
      begin
        Tray.BalloonTitle := 'LeakWatch';
        Tray.BalloonHint := Copy(Entries[I].Text, 1, 250);
        Tray.BalloonFlags := bfWarning;
        Tray.ShowBalloonHint;
      end;
    end;
    while lvWarnings.Items.Count > MaxWarnings do
      lvWarnings.Items.Delete(lvWarnings.Items.Count - 1);
  finally
    lvWarnings.Items.EndUpdate;
  end;
  UpdateGrid;
end;

procedure TfrmMain.UpdateGrid;
var
  I, Row, SelectedRow: Integer;
  Info: TInstanceInfo;
  State: string;
begin
  FInstances := FStore.GetInstances(NowUtc);
  if Length(FInstances) = 0 then
  begin
    grdInstances.RowCount := 2;
    for I := 0 to grdInstances.ColCount - 1 do
      grdInstances.Cells[I, 1] := '';
  end
  else
    grdInstances.RowCount := Length(FInstances) + 1;
  SelectedRow := -1;
  for I := 0 to High(FInstances) do
  begin
    Info := FInstances[I];
    Row := I + 1;
    grdInstances.Cells[ColAppId, Row] := Info.AppId;
    grdInstances.Cells[ColInstanceId, Row] := Info.InstanceId;
    grdInstances.Cells[ColLastSeen, Row] := UtcToLocalText(Info.LastSeenUtc);
    grdInstances.Cells[ColAllocated, Row] := FormatMegabytes(Info.Latest.Values.AllocatedBytes);
    grdInstances.Cells[ColBlocks, Row] := IntToStr(Info.Latest.Values.TotalAllocatedBlocks);
    grdInstances.Cells[ColLevel, Row] := LeakLevelToStr(Info.Level);
    if Info.Stale then
      State := 'STALE'
    else
      State := 'live';
    if Info.DuplicateAppId then
      State := State + ', duplicate AppId';
    if Info.InstanceId = FConfig.InstanceId then
      State := State + ', this instance';
    grdInstances.Cells[ColState, Row] := State;
    if Info.InstanceId = FSelectedInstance then
      SelectedRow := Row;
  end;
  if (FSelectedInstance = '') and (Length(FInstances) > 0) then
  begin
    FSelectedInstance := FInstances[0].InstanceId;
    SelectedRow := 1;
  end;
  if SelectedRow > 0 then
    grdInstances.Row := SelectedRow;
  UpdateTray;
end;

procedure TfrmMain.UpdateTray;
var
  I: Integer;
  Level: TLeakLevel;
  Hint: string;
begin
  Level := llNone;
  Hint := '';
  for I := 0 to High(FInstances) do
    if FInstances[I].Level > llNone then
    begin
      if FInstances[I].Level > Level then
        Level := FInstances[I].Level;
      if Hint <> '' then
        Hint := Hint + ', ';
      Hint := Hint + FInstances[I].AppId + ' ' + LeakLevelToStr(FInstances[I].Level);
    end;
  if Hint = '' then
    Hint := 'no leak suspected'
  else
    Hint := 'leaks: ' + Hint;
  Tray.Hint := Copy(Format('LeakWatch [%s]: %s', [FConfig.AppId, Hint]), 1, 127);
  if Level <> FTrayLevel then
  begin
    FTrayLevel := Level;
    Tray.Icon.Assign(FIcons[Level]);
    Icon.Assign(FIcons[Level]);
  end;
  sbStatus.Panels[4].Text := 'Leak status: ' + Hint;
end;

procedure TfrmMain.UpdateConnectionState;
var
  S: TStatusInfo;
  Connected: Boolean;
begin
  S := FStatus.Get;
  Connected := Assigned(FSnapshotThread);
  btnConnect.Enabled := not Connected and (FRetiring.Count = 0);
  btnDisconnect.Enabled := Connected;
  if not Connected then
  begin
    if FRetiring.Count > 0 then
    begin
      shpLamp.Brush.Color := clYellow;
      lblConnection.Caption := 'Disconnecting...';
    end
    else
    begin
      shpLamp.Brush.Color := clGray;
      lblConnection.Caption := 'Disconnected';
    end;
  end
  else if (S.PublishState = csError) or (S.ConsumeState = csError) then
  begin
    shpLamp.Brush.Color := clRed;
    if S.PublishError <> '' then
      lblConnection.Caption := 'Error: ' + S.PublishError
    else
      lblConnection.Caption := 'Error: ' + S.ConsumeError;
  end
  else if (S.PublishState = csConnected) and (S.ConsumeState = csConnected) then
  begin
    shpLamp.Brush.Color := clLime;
    lblConnection.Caption := 'Connected';
  end
  else
  begin
    shpLamp.Brush.Color := clYellow;
    lblConnection.Caption := 'Connecting...';
  end;
  lblConnection.Hint := lblConnection.Caption;
  lblConnection.ShowHint := True;
end;

procedure TfrmMain.UpdateGeneratorLabel;
var
  St: TGeneratorStats;
  Running: string;
begin
  St := FGenerator.Stats;
  if St.Running then
    Running := 'running'
  else
    Running := 'stopped';
  lblHeld.Caption := Format('Generator %s: %d objects held, %s (permanent: %d)',
    [Running, St.ObjectCount, FormatMegabytes(St.HeldBytes), St.PermanentCount]);
  btnStart.Enabled := not St.Running;
  btnStop.Enabled := St.Running;
end;

procedure TfrmMain.UpdateStatusBar;
var
  S: TStatusInfo;
begin
  S := FStatus.Get;
  sbStatus.Panels[0].Text := Format('App %s, instance %s', [FConfig.AppId, FConfig.InstanceId]);
  sbStatus.Panels[1].Text := Format('Capture %.2f ms', [S.LastCaptureMicros / 1000]);
  sbStatus.Panels[2].Text := 'Last publish: ' + S.LastPublish;
  sbStatus.Panels[3].Text := 'Last poll: ' + S.LastPoll;
end;

procedure TfrmMain.TimerTick(Sender: TObject);
begin
  ReapRetiredThreads;
  UpdateConnectionState;
  UpdateGrid;
  UpdateGeneratorLabel;
  UpdateStatusBar;
  if (FConfig.RunForMinutes > 0)
    and (GetTickCount - FStartTick >= Cardinal(Round(FConfig.RunForMinutes * 60000))) then
  begin
    FLog.Add('run time over, closing');
    tmrUi.Enabled := False;
    Close;
  end;
end;

procedure TfrmMain.GridSelectCell(Sender: TObject; ACol, ARow: Integer; var CanSelect: Boolean);
begin
  if (ARow >= 1) and (ARow <= Length(FInstances)) then
  begin
    FSelectedInstance := FInstances[ARow - 1].InstanceId;
    pbChart.Invalidate;
  end;
end;

procedure TfrmMain.GridDrawCell(Sender: TObject; ACol, ARow: Integer; Rect: TRect;
  State: TGridDrawState);
var
  Level: TLeakLevel;
  Text: string;
begin
  if (ARow < 1) or (ARow > Length(FInstances)) or (ACol <> ColLevel) then
    Exit;
  Level := FInstances[ARow - 1].Level;
  if Level = llNone then
    Exit;
  Text := grdInstances.Cells[ACol, ARow];
  grdInstances.Canvas.Brush.Color := LevelColors[Level];
  grdInstances.Canvas.Font.Color := clWhite;
  grdInstances.Canvas.FillRect(Rect);
  grdInstances.Canvas.TextOut(Rect.Left + 2, Rect.Top + 2, Text);
end;

procedure TfrmMain.ChartPaint(Sender: TObject);
const
  MarginLeft = 70;
  MarginRight = 12;
  MarginTop = 24;
  MarginBottom = 22;
var
  C: TCanvas;
  R, Plot: TRect;
  N, I, GridLine: Integer;
  StartedUtc: TDateTime;
  MinY, MaxY, Span, Seconds, Y: Double;
  Points: array of TPoint;
  Title: string;
  Info: TInstanceInfo;
begin
  C := pbChart.Canvas;
  R := pbChart.ClientRect;
  C.Brush.Color := clWhite;
  C.FillRect(R);
  C.Font.Color := clBlack;
  if FSelectedInstance = '' then
  begin
    C.TextOut(10, 10, 'No instance selected');
    Exit;
  end;
  N := FStore.CopySamples(FSelectedInstance, FChartSamples, Length(FChartSamples), StartedUtc);
  Title := FSelectedInstance;
  for I := 0 to High(FInstances) do
    if FInstances[I].InstanceId = FSelectedInstance then
    begin
      Info := FInstances[I];
      Title := Format('AllocatedBytes of app ''%s'' (%s) - %s', [Info.AppId, Info.InstanceId,
        LeakLevelToStr(Info.Level)]);
      if Info.LevelText <> '' then
        Title := Title + ': ' + Info.LevelText;
    end;
  C.TextOut(MarginLeft, 4, Title);
  if N < 2 then
  begin
    C.TextOut(MarginLeft, MarginTop + 10, 'Waiting for data...');
    Exit;
  end;

  MinY := FChartSamples[0].Values.AllocatedBytes;
  MaxY := MinY;
  for I := 1 to N - 1 do
  begin
    if FChartSamples[I].Values.AllocatedBytes < MinY then
      MinY := FChartSamples[I].Values.AllocatedBytes;
    if FChartSamples[I].Values.AllocatedBytes > MaxY then
      MaxY := FChartSamples[I].Values.AllocatedBytes;
  end;
  if MaxY - MinY < 1024 * 1024 then
  begin
    MinY := MinY - 512 * 1024;
    MaxY := MaxY + 512 * 1024;
  end;
  Seconds := SecondsBetweenUtc(FChartSamples[0].TimestampUtc, FChartSamples[N - 1].TimestampUtc);
  if Seconds <= 0 then
    Seconds := 1;

  Plot := Classes.Rect(R.Left + MarginLeft, R.Top + MarginTop, R.Right - MarginRight,
    R.Bottom - MarginBottom);
  if (Plot.Right <= Plot.Left) or (Plot.Bottom <= Plot.Top) then
    Exit;
  Span := MaxY - MinY;

  C.Pen.Color := $00E0E0E0;
  for GridLine := 0 to 4 do
  begin
    Y := Plot.Bottom - GridLine * (Plot.Bottom - Plot.Top) / 4;
    C.MoveTo(Plot.Left, Round(Y));
    C.LineTo(Plot.Right, Round(Y));
    C.TextOut(4, Round(Y) - 7, FormatMegabytes(MinY + GridLine * Span / 4));
  end;
  C.Pen.Color := clGray;
  C.Brush.Style := bsClear;
  C.Rectangle(Plot);
  C.TextOut(Plot.Left, Plot.Bottom + 4, Format('-%.1f min', [Seconds / 60]));
  C.TextOut(Plot.Right - C.TextWidth('now'), Plot.Bottom + 4, 'now');

  SetLength(Points, N);
  for I := 0 to N - 1 do
  begin
    Points[I].X := Plot.Left + Round((Plot.Right - Plot.Left)
      * SecondsBetweenUtc(FChartSamples[0].TimestampUtc, FChartSamples[I].TimestampUtc) / Seconds);
    Points[I].Y := Plot.Bottom - Round((Plot.Bottom - Plot.Top)
      * (FChartSamples[I].Values.AllocatedBytes - MinY) / Span);
  end;
  C.Pen.Color := clNavy;
  C.Pen.Width := 2;
  C.Polyline(Points);
  C.Pen.Width := 1;
  C.Brush.Style := bsSolid;
end;

end.
