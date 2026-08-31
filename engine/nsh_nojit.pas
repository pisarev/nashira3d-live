{ A parser WITHOUT machine code generation - for WebAssembly.

  Why this exists and why it lives here rather than in the library.

  The library evaluates a formula through TJitParser: that one compiles it to
  machine code and therefore offers a batch call, ExecuteMany - one row of the
  mesh in a single pass. That is where its speed comes from, and touching it for
  the sake of a demo is out of the question.

  But there is no machine code in WebAssembly: there is no executable memory
  there at all, and the unit ParseJit.Memory does not build for it by design
  rather than by oversight. The parser itself does not go anywhere - it has an
  interpreter, the very TMathParser that TJitParser descends from.

  Exactly one missing method is written out for it here - the batch call - and
  written in the simplest way there is: a walk over the points. Slower than
  machine code, but computing THE SAME THING and by the same formula. Everything
  else - the mesh, the normals, the holes, the span of the height - stays with
  the real nsh_surface.

  The library neither sees nor builds this unit: it is picked up only by the
  build of the demo, under the definition NSH_NO_JIT.

  Hence the line the page states plainly: the formula is read and evaluated by
  the real parser, and machine code is what a desktop build adds on top of that,
  which a browser cannot give. }
unit nsh_nojit;

{$mode objfpc}{$H+}

interface

uses
  ParseTypes, Parser;

type
  TNoJitParser = class(TMathParser)
  private
    FText   : string;
    FScript : TScript;
    FHave   : Boolean;
    function GetZero: Int64;
  public
    { The same contract as TJitParser.ExecuteMany: Variable is the variable
      being walked over, Inputs are its values, Outputs are what came out.
      False means the formula did not parse. }
    function ExecuteMany(const Expr: string; var Variable: Double;
      const Inputs: array of Double; var Outputs: array of Double): Boolean;
    { The interpreter has no counters: it has nothing to compile. It answers
      with zeroes rather than inventing numbers - a zero here means "does not
      apply", and a check that asks about recompilation does not run on it. }
    property CompileCount: Int64 read GetZero;
    property HitCount: Int64 read GetZero;
    property MissCount: Int64 read GetZero;
  end;

implementation

uses
  SysUtils, ParseErrors, ValueUtils;

function TNoJitParser.GetZero: Int64;
begin
  Result := 0;
end;

{ The argument is named Expr and not Text: Text is a property of the ancestor,
  and an argument of the same name would shadow it in silence. }
function TNoJitParser.ExecuteMany(const Expr: string; var Variable: Double;
  const Inputs: array of Double; var Outputs: array of Double): Boolean;
var
  I : LongInt;
  E : TError;
begin
  Result := False;
  { The parse is kept between calls for the same reason as in the real parser:
    otherwise the price of parsing is paid on every row of the mesh. }
  if (not FHave) or (FText <> Expr) then
  begin
    StringToScript(Expr, FScript, E);
    if FScript = nil then
      Exit;
    FText := Expr;
    FHave := True;
  end;
  for I := 0 to High(Inputs) do
  begin
    if I > High(Outputs) then
      Break;
    Variable := Inputs[I];
    Outputs[I] := GetDouble(ExecuteScript(FScript)^);
  end;
  Result := True;
end;

end.
