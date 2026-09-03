{ A fast evaluator for the browser build - the part machine code plays on a
  desktop, done without machine code.

  WHY. The library reads a formula with TMathParser and then compiles it to
  machine code with TJitParser; that is where its speed comes from. WebAssembly
  has no executable memory, so the browser build falls back to the interpreter,
  and the interpreter walks a tree of boxed values for every node of the mesh.
  Measured on the published page: about 2 microseconds a node, which is 68
  milliseconds for a mesh of 184 nodes a side, against about 11 for the whole
  frame in the library. It shows in how each side answers a heavier formula -
  the library went from 9.2 to 12.1 ms across four formulas of rising weight
  while the page went from 32 to 179.

  WHAT THIS IS. Not a second parser. The formula is read by the SAME parser and
  decoded by the SAME decoder the machine-code backend uses; only the back end
  differs. Where TJitParser emits instructions for a processor, this emits a
  short postfix program over a stack of doubles and walks it.

  WHY IT CANNOT QUIETLY LIE. Two evaluators of one formula are two chances to
  disagree, and a disagreement here would be a wrong picture rather than an
  error. So the program is not trusted on the strength of its author: while the
  surface is being built, points scattered across it are computed BOTH ways and
  compared bit for bit. One mismatch and the fast program is thrown away for
  that formula and the interpreter finishes the job. A future change in the
  parser cannot make the pictures wrong - it can only make them slow again.

  WHAT IT EXPECTS OF THE MACHINE. Plain IEEE arithmetic that does not trap:
  division by zero gives an infinity, a square root of a negative gives a NaN,
  and the mesh turns both into a hole. WebAssembly has no floating point traps
  at all, so that is what it gives. A build for a processor that leaves those
  exceptions unmasked has to mask them first, or the first hole in a surface
  will end the program instead of showing through.

  WHAT IT REFUSES. Everything it has not been taught: multi-argument calls, any
  operator inside a term other than multiplication and division, any name that
  is not x, y or Pi, and any function outside a short list. A refusal is not a
  failure - it means the interpreter does the work, exactly as before. }
unit nsh_fasteval;

{$mode objfpc}{$H+}

interface

uses
  ParseTypes, Parser, ValueTypes;

type
  TFastProgram = class
  private
    FCode  : array of Byte;
    FVal   : array of Double;
    FLen   : LongInt;
    FDepth : LongInt;   { the deepest the stack goes, checked while emitting }
    FPeak  : LongInt;
    FOk    : Boolean;
    { WHERE y LIVES. The batch call is handed the values of x and nothing
      else: y is a variable the parser holds by reference, and only the parser
      knows where. The decoder names that place - in VariableRef, which is the
      address the caller bound, while the neighbouring Variable field stays
      empty. Taken once at compile time and read once a row rather than once a
      node. Nil means the formula does not mention y, or that its variable is
      not a plain double. }
    FPY    : PDouble;
    { WHETHER THE NAMES IN THE FORMULA EXIST AT ALL. A formula that names
      something the parser does not know still parses, and the interpreter
      then evaluates it to nought without a word - zzz draws a flat plane,
      and x+zzz loses the term that was good. The decoder is stricter: for
      such a formula it yields no steps at all, while the plainest legal one
      yields at least one. That is the difference, and it is what the
      machine-code side refuses on. }
    FNamesOk: Boolean;
    procedure Emit(ACode: Byte; const AValue: Double);
  public
    constructor Create;
    { Reads the formula with the given parser and builds a program from it.
      False means the formula uses something this evaluator has not been taught;
      the caller then keeps to the interpreter. }
    function Compile(AParser: TParser; const Expr: string): Boolean;
    { The value at a point. Meaningful only after Compile returned True. }
    function Eval(const X, Y: Double): Double;
    property Ok: Boolean read FOk;
    property PlaceOfY: PDouble read FPY;
    { True only after Compile has read the formula. False means the formula
      names something that does not exist, and the caller must refuse it
      rather than draw nought. }
    property NamesOk: Boolean read FNamesOk;
  end;

var
  { HOW MANY POINTS WENT THE FAST WAY, over the life of the module. A check
    that only compares pictures cannot tell a fast path that agrees from one
    that quietly retired itself and left the interpreter agreeing with itself.
    This number is the difference between the two, and it is exported so that a
    gate can read it rather than believe it. }
  FastPoints: Int64 = 0;

implementation

uses
  SysUtils, Math, ValueUtils, ParseErrors, ParseJit.Decoder;

const
  { The stack never grows deeper than the expression nests. Sixty-four is far
    past anything a person types, and the bound is here so that a formula
    nested past reason meets a refusal rather than memory it does not own. }
  STACK_MAX = 64;

  opConst  = 0;
  opX      = 1;
  opY      = 2;
  opAdd    = 3;
  opSub    = 4;
  opMul    = 5;
  opDiv    = 6;
  opNeg    = 7;
  opSin    = 8;
  opCos    = 9;
  opTan    = 10;
  opSqrt   = 11;
  opSqr    = 12;
  opAbs    = 13;
  opExp    = 14;
  opLn     = 15;
  opLg     = 16;
  opASin   = 17;
  opACos   = 18;
  opATan   = 19;
  opSinh   = 20;
  opCosh   = 21;
  opTanh   = 22;
  opInt    = 23;
  opTrunc  = 24;
  opFrac   = 25;

{ THE LIST IS SHORT ON PURPOSE. Every name here has to answer exactly as the
  interpreter answers, including at the edges of its domain, and every name is
  checked against it while the surface is built. A name absent from this list
  costs nothing but speed. }
function FuncCode(const Name: string): LongInt;
var
  N: string;
begin
  N := LowerCase(Name);
  if N = 'sin' then Exit(opSin);
  if N = 'cos' then Exit(opCos);
  if N = 'tan' then Exit(opTan);
  if N = 'sqrt' then Exit(opSqrt);
  if N = 'sqr' then Exit(opSqr);
  if N = 'abs' then Exit(opAbs);
  if N = 'exp' then Exit(opExp);
  if N = 'ln' then Exit(opLn);
  if N = 'lg' then Exit(opLg);
  if N = 'arcsin' then Exit(opASin);
  if N = 'arccos' then Exit(opACos);
  if N = 'arctan' then Exit(opATan);
  if N = 'sinh' then Exit(opSinh);
  if N = 'cosh' then Exit(opCosh);
  if N = 'tanh' then Exit(opTanh);
  if N = 'int' then Exit(opInt);
  if N = 'trunc' then Exit(opTrunc);
  if N = 'frac' then Exit(opFrac);
  Result := -1;
end;

constructor TFastProgram.Create;
begin
  inherited Create;
  FOk := False;
  FPY := nil;
  FNamesOk := False;
end;

procedure TFastProgram.Emit(ACode: Byte; const AValue: Double);
begin
  if FLen >= Length(FCode) then
  begin
    SetLength(FCode, 64 + Length(FCode) * 2);
    SetLength(FVal, Length(FCode));
  end;
  FCode[FLen] := ACode;
  FVal[FLen] := AValue;
  Inc(FLen);
  { The stack is tracked as the program is written rather than measured when it
    runs: a program that would overflow must be refused before it is offered,
    not caught halfway through a mesh. }
  case ACode of
    opConst, opX, opY:
      begin
        Inc(FDepth);
        if FDepth > FPeak then FPeak := FDepth;
      end;
    opAdd, opSub, opMul, opDiv:
      Dec(FDepth);
  end;
end;

function TFastProgram.Eval(const X, Y: Double): Double;
var
  S: array[0..STACK_MAX - 1] of Double;
  N, I: LongInt;
begin
  N := 0;
  for I := 0 to FLen - 1 do
    case FCode[I] of
      opConst: begin S[N] := FVal[I]; Inc(N); end;
      opX: begin S[N] := X; Inc(N); end;
      opY: begin S[N] := Y; Inc(N); end;
      opAdd: begin Dec(N); S[N - 1] := S[N - 1] + S[N]; end;
      opSub: begin Dec(N); S[N - 1] := S[N - 1] - S[N]; end;
      opMul: begin Dec(N); S[N - 1] := S[N - 1] * S[N]; end;
      opDiv: begin Dec(N); S[N - 1] := S[N - 1] / S[N]; end;
      opNeg: S[N - 1] := -S[N - 1];
      opSin: S[N - 1] := Sin(S[N - 1]);
      opCos: S[N - 1] := Cos(S[N - 1]);
      opTan: S[N - 1] := Tan(S[N - 1]);
      opSqrt: S[N - 1] := Sqrt(S[N - 1]);
      opSqr: S[N - 1] := S[N - 1] * S[N - 1];
      opAbs: S[N - 1] := Abs(S[N - 1]);
      opExp: S[N - 1] := Exp(S[N - 1]);
      opLn: S[N - 1] := Ln(S[N - 1]);
      opLg: S[N - 1] := Log10(S[N - 1]);
      opASin: S[N - 1] := ArcSin(S[N - 1]);
      opACos: S[N - 1] := ArcCos(S[N - 1]);
      opATan: S[N - 1] := ArcTan(S[N - 1]);
      opSinh: S[N - 1] := Sinh(S[N - 1]);
      opCosh: S[N - 1] := Cosh(S[N - 1]);
      opTanh: S[N - 1] := Tanh(S[N - 1]);
      opInt: S[N - 1] := Int(S[N - 1]);
      opTrunc: S[N - 1] := Int(S[N - 1]);
      opFrac: S[N - 1] := Frac(S[N - 1]);
    end;
  if N = 1 then
    Result := S[0]
  else
    Result := NaN;
end;

function TFastProgram.Compile(AParser: TParser; const Expr: string): Boolean;
var
  Script  : TScript;
  Err     : ParseErrors.TError;
  Decoder : TJitDecoder;
  Ops     : TJitOpArray;
  Count   : LongInt;
  Pos     : LongInt;

  function IsBinOp(const Name: string): Boolean;
  begin
    Result := (Name = '*') or (Name = '/');
  end;

  function EmitFactor: Boolean; forward;

  { A script is a SUM OF TERMS. The sign lives on the term, and a sign on the
    very first one is a negation rather than a subtraction. }
  function EmitScriptBody(const Nested: Boolean): Boolean;
  var
    First: Boolean;
    Sign: NativeInt;
  begin
    First := True;
    Result := False;
    while Pos < Count do
    begin
      if Ops[Pos].Code = joScriptEnd then
      begin
        Result := Nested and (not First);
        Exit;
      end;
      if Ops[Pos].Code <> joTermBegin then Exit;
      Sign := Ops[Pos].Sign;
      Inc(Pos);
      if not EmitFactor then Exit;
      { A TERM is factors joined by operators. Only multiplication and division
        are taken: they share one precedence and go left to right, which is what
        this loop does. Anything else - the caret, which in this parser is
        exclusive or rather than a power, and mod, div and the comparisons -
        would need a table of precedence, and a table guessed wrong is a wrong
        picture. They are refused instead. }
      while (Pos < Count) and (Ops[Pos].Code = joCall) and IsBinOp(Ops[Pos].Name) do
      begin
        if Ops[Pos].Name = '*' then
        begin
          Inc(Pos);
          if not EmitFactor then Exit;
          Emit(opMul, 0);
        end
        else begin
          Inc(Pos);
          if not EmitFactor then Exit;
          Emit(opDiv, 0);
        end;
      end;
      if (Pos >= Count) or (Ops[Pos].Code <> joTermEnd) then Exit;
      Inc(Pos);
      if First then
      begin
        if Sign <> 0 then Emit(opNeg, 0);
        First := False;
      end
      else
        if Sign <> 0 then Emit(opSub, 0) else Emit(opAdd, 0);
    end;
    Result := (not Nested) and (not First);
  end;

  function EmitFactor: Boolean;
  var
    F: LongInt;
    N: string;
  begin
    Result := False;
    if Pos >= Count then Exit;
    case Ops[Pos].Code of
      joConst:
        begin
          Emit(opConst, GetDouble(Ops[Pos].Value));
          Inc(Pos);
          Result := True;
        end;
      joVariable:
        begin
          N := LowerCase(Ops[Pos].Name);
          if N = 'x' then Emit(opX, 0)
          else if N = 'y' then
          begin
            { The reference is taken only for a variable that IS a double.
              This parser records one declared as Double under vtExtended, and
              on the targets that matter Extended is a double - but where it is
              not, reading it as one would be reading somebody else's bytes, so
              the whole formula is refused instead. }
            if (Ops[Pos].VariableRef = nil) or
              not ((Ops[Pos].VariableType = vtDouble) or
                   ((Ops[Pos].VariableType = vtExtended) and
                    (SizeOf(Extended) = SizeOf(Double)))) then Exit;
            Emit(opY, 0);
            FPY := PDouble(Ops[Pos].VariableRef);
          end
          else if N = 'pi' then Emit(opConst, Pi)
          else Exit;
          Inc(Pos);
          Result := True;
        end;
      joScriptBegin:
        begin
          { A bracket standing on its own: its contents are a script. }
          Inc(Pos);
          if not EmitScriptBody(True) then Exit;
          if (Pos >= Count) or (Ops[Pos].Code <> joScriptEnd) then Exit;
          Inc(Pos);
          Result := True;
        end;
      joCall:
        begin
          F := FuncCode(Ops[Pos].Name);
          if F < 0 then Exit;
          Inc(Pos);
          { A call of one argument is followed by its bracket. A call of several
            opens joParameterBegin instead, and there the parameters are not
            told apart from the terms of one sum - so those are refused. }
          if (Pos >= Count) or (Ops[Pos].Code <> joScriptBegin) then Exit;
          Inc(Pos);
          if not EmitScriptBody(True) then Exit;
          if (Pos >= Count) or (Ops[Pos].Code <> joScriptEnd) then Exit;
          Inc(Pos);
          Emit(Byte(F), 0);
          Result := True;
        end;
    end;
  end;

begin
  Result := False;
  FOk := False;
  FLen := 0;
  FDepth := 0;
  FPeak := 0;
  FPY := nil;
  FNamesOk := False;
  if AParser = nil then Exit;
  Script := nil;
  try
    AParser.StringToScript(Expr, Script, Err);
  except
    Exit;
  end;
  if Script = nil then Exit;
  Decoder := TJitDecoder.Create(AParser);
  try
    try
      if not Decoder.Decode(Script) then Exit;
    except
      Exit;
    end;
    if not Decoder.Supported then Exit;
    Ops := Decoder.Ops;
    Count := Decoder.Count;
    { NO STEPS AT ALL means a name in the formula does not exist. That is a
      verdict about the formula rather than about this back end, so it is
      recorded apart from the refusal: the caller must not fall back to the
      interpreter and draw nought, it must refuse. }
    FNamesOk := Count > 0;
    if Count <= 0 then Exit;
    Pos := 0;
    if not EmitScriptBody(False) then Exit;
    if Pos <> Count then Exit;
    if (FPeak <= 0) or (FPeak >= STACK_MAX) then Exit;
    if FDepth <> 1 then Exit;
    FOk := True;
    Result := True;
  finally
    Decoder.Free;
  end;
end;

end.
