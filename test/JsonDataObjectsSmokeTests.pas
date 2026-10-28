unit JsonDataObjectsSmokeTests;

{ Checks the JsonDataObjects behaviour LeakWatch relies on, with Delphi 2009. }

interface

uses
  TestFramework;

type
  TJsonDataObjectsSmokeTest = class(TTestCase)
  published
    procedure ParsesAndWritesObject;
    procedure KeepsInt64AboveInt32Range;
    procedure EscapesStrings;
    procedure WritesDotDecimalSeparatorUnderGermanLocale;
  end;

implementation

uses
  SysUtils, JsonDataObjects;

procedure TJsonDataObjectsSmokeTest.ParsesAndWritesObject;
var
  O: TJsonObject;
begin
  O := TJsonObject.Parse('{"a":1,"b":"x","c":[1,2],"d":{"routed":true}}') as TJsonObject;
  try
    CheckEquals(1, O.I['a']);
    CheckEquals('x', O.S['b']);
    CheckEquals(2, O.A['c'].Count);
    CheckTrue(O.O['d'].B['routed']);
  finally
    O.Free;
  end;
end;

procedure TJsonDataObjectsSmokeTest.KeepsInt64AboveInt32Range;
var
  O, P: TJsonObject;
  Big: Int64;
begin
  Big := Int64(5) * 1000 * 1000 * 1000;
  O := TJsonObject.Create;
  try
    O.L['big'] := Big;
    P := TJsonObject.Parse(O.ToJSON) as TJsonObject;
    try
      CheckEquals(Big, P.L['big']);
    finally
      P.Free;
    end;
  finally
    O.Free;
  end;
end;

procedure TJsonDataObjectsSmokeTest.EscapesStrings;
const
  Text = 'quote" backslash\ tab'#9' newline'#10' umlaut '#$00E4' euro '#$20AC;
var
  O, P: TJsonObject;
begin
  O := TJsonObject.Create;
  try
    O.S['t'] := Text;
    P := TJsonObject.Parse(O.ToJSON) as TJsonObject;
    try
      CheckEquals(Text, P.S['t']);
    finally
      P.Free;
    end;
  finally
    O.Free;
  end;
end;

procedure TJsonDataObjectsSmokeTest.WritesDotDecimalSeparatorUnderGermanLocale;
var
  O, P: TJsonObject;
  Saved: Char;
  Json: string;
begin
  Saved := DecimalSeparator;
  DecimalSeparator := ',';
  try
    O := TJsonObject.Create;
    try
      O.F['f'] := 97.25;
      Json := O.ToJSON;
      CheckTrue(Pos('97.25', Json) > 0, Json);
      P := TJsonObject.Parse(Json) as TJsonObject;
      try
        CheckEquals(97.25, P.F['f'], 1E-9);
      finally
        P.Free;
      end;
    finally
      O.Free;
    end;
  finally
    DecimalSeparator := Saved;
  end;
end;

initialization
  RegisterTest(TJsonDataObjectsSmokeTest.Suite);

end.
