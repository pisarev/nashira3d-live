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

  SINCE THEN a second back end has been added beside the walk: nsh_fasteval
  turns the SAME decoded formula into a short postfix program over doubles. It
  is not a second parser - the reading and the decoding are the parser's own -
  and it is not trusted blindly: points scattered over the surface are computed
  both ways as it goes, and one disagreement retires it for that formula. What a
  browser still cannot give is machine code; what it turns out not to need is
  the boxing of a value at every node. }
unit nsh_nojit;

{$mode objfpc}{$H+}

interface

uses
  ParseTypes, Parser, nsh_fasteval;

type
  TNoJitParser = class(TMathParser)
  private
    FText   : string;
    FScript : TScript;
    FHave   : Boolean;
    FFast   : TFastProgram;
    FFastOk : Boolean;
    FSeen   : Boolean;
    FFastRows: Int64;
    FFastOff: Boolean;
    FRow    : LongInt;
    function GetZero: Int64;
  public
    { The same contract as TJitParser.ExecuteMany: Variable is the variable
      being walked over, Inputs are its values, Outputs are what came out.
      False means the formula did not parse. }
    { THE SWITCH IS FOR PROVING, not for tuning. With the fast back end off the
      module computes exactly as it did before it existed, so a check can put
      the two side by side and answer in numbers whether the pictures moved. }
    property FastOff: Boolean read FFastOff write FFastOff;
    { HOW MANY ROWS WENT THE FAST WAY. Without this a check cannot tell a
      fast path that agrees from one that quietly retired itself and left
      the interpreter to agree with itself. }
    property FastRows: Int64 read FFastRows;
    destructor Destroy; override;
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
  SysUtils, Math, ParseErrors, ValueUtils;

{ EQUAL ENOUGH TO BE THE SAME NUMBER. Plain equality says nothing about two
  NaNs, and a hole in the surface is a NaN: without the second half of this the
  first hole would retire the fast program. }
function Same(const A, B: Double): Boolean;
begin
  Result := (A = B) or (IsNan(A) and IsNan(B));
end;

function TNoJitParser.GetZero: Int64;
begin
  Result := 0;
end;

destructor TNoJitParser.Destroy;
begin
  FFast.Free;
  inherited Destroy;
end;

{ The argument is named Expr and not Text: Text is a property of the ancestor,
  and an argument of the same name would shadow it in silence. }
function TNoJitParser.ExecuteMany(const Expr: string; var Variable: Double;
  const Inputs: array of Double; var Outputs: array of Double): Boolean;
var
  I, J, Last    : LongInt;
  Y             : Double;
  E             : TError;
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
    { A new formula, a new program. Compiling is attempted once and its refusal
      is remembered: a formula this back end has not been taught must not be
      offered to it again on every row. }
    if FFast = nil then
      FFast := TFastProgram.Create;
    FFastOk := (not FFastOff) and FFast.Compile(Self, Expr);
    FSeen := False;
    FRow := 0;
  end;
  Last := High(Inputs);
  if Last > High(Outputs) then
    Last := High(Outputs);
  if Last < 0 then
    Exit(True);

  if FFastOk then
  begin
    { y does not change along a row, so it is read once rather than at every
      node - through the place the decoder named while compiling. }
    Y := 0;
    if FFast.PlaceOfY <> nil then
      Y := FFast.PlaceOfY^;
    for I := 0 to Last do
      Outputs[I] := FFast.Eval(Inputs[I], Y);
    Inc(FFastRows);
    Inc(FastPoints, Last + 1);

    if not FSeen then
    begin
      { THE FIRST ROW IS CHECKED WHOLE, once per formula. A check that samples
        leaves a window: while it ran on every eighth row, seven rows of a
        surface could be drawn from a program that was already wrong - measured
        at 427 points on int(x)+frac(y), which is exactly seven rows of
        sixty-one. A whole row costs one interpreted row per formula, which is
        nothing beside the mesh, and it closes that window at the start. }
      for I := 0 to Last do
      begin
        Variable := Inputs[I];
        if not Same(Outputs[I], GetDouble(ExecuteScript(FScript)^)) then
        begin
          FFastOk := False;
          Break;
        end;
      end;
      FSeen := FFastOk;
    end
    else
    begin
      { AND THE CHECK KEEPS RIDING ALONG. One point every fourth row, and its
        place moves with the row, so what is compared is spread over the whole
        surface rather than gathered along one edge of it. About one part in
        twenty of the build. The moment a disagreement appears the fast program
        is retired for this formula and the row is done again the old way - a
        slow picture, never a wrong one. }
      Inc(FRow);
      if (FRow and 3) = 0 then
      begin
        J := FRow mod (Last + 1);
        Variable := Inputs[J];
        if not Same(Outputs[J], GetDouble(ExecuteScript(FScript)^)) then
          FFastOk := False;
      end;
    end;

    if not FFastOk then
    begin
      Dec(FFastRows);
      Dec(FastPoints, Last + 1);
      for I := 0 to Last do
      begin
        Variable := Inputs[I];
        Outputs[I] := GetDouble(ExecuteScript(FScript)^);
      end;
    end;
    Exit(True);
  end;

  for I := 0 to Last do
  begin
    Variable := Inputs[I];
    Outputs[I] := GetDouble(ExecuteScript(FScript)^);
  end;
  Result := True;
end;

end.
