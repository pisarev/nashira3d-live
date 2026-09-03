{ Three evaluators of one formula, put side by side on a grid of points.

  The machine code the desktop library compiles (TJitParser), the interpreter
  that walks the parsed formula (the shim with its fast back end switched off),
  and the fast back end itself. Three columns rather than two, because with two
  a difference that was there before this evaluator existed would be laid at its
  door: tan is one such - the machine code and the interpreter part company on
  it, and they did so before any of this.

  What the run has to show is the third column agreeing with the second
  everywhere, and the count of rows that actually went the fast way being the
  whole of them. A fast path retires itself the moment it disagrees, so
  agreement alone proves nothing: it is agreement WITH the rows counted that
  means the thing ran.

  Build (a desktop compiler, since the machine code side is needed):

    fpc -Mdelphi -O2 -Sh -dNOFORMS -dNOGRAPHICS ^
        -Fu<engine> -Fu<parser>/src -Fu<parser>/src/compat -Fu<parser>/jit ^
        -Fi<parser>/src test_fasteval.pas }
program test_fasteval;


{$MODE DELPHI}
{$APPTYPE CONSOLE}

uses
  SysUtils, Math, ValueTypes, ValueUtils, ParseErrors, ParseTypes, Parser,
  ParseJit.Parser, nsh_fasteval, nsh_nojit;

const
  N = 61;

var
  GXj, GYj, GXs, GYs, GXf, GYf: Double;
  PJ: TJitParser;
  PS: TNoJitParser;   { the interpreter: fast path off }
  PF: TNoJitParser;   { the fast back end }
  Bad, Total, Fast: LongInt;

function Same(const A, B: Double): Boolean;
begin
  Result := (A = B) or (IsNan(A) and IsNan(B));
end;

{ WHAT IS ACCEPTED MUST BE THE SAME ON BOTH SIDES. A formula naming something
  that does not exist still parses, and the interpreter left to itself evaluates
  it to nought: zzz drew a flat plane and x+zzz lost the term that was good,
  while the library refused all of them. Agreement about VALUES says nothing
  about this - the two never got as far as a value. }
procedure Accept(const Formula: string);
var
  In1, O1, O2, O3: array[0..0] of Double;
  a, b, c: Boolean;
begin
  Inc(Total);
  In1[0] := 1; GYj := 1; GYs := 1; GYf := 1;
  a := PJ.ExecuteMany(Formula, GXj, In1, O1);
  b := PS.ExecuteMany(Formula, GXs, In1, O2);
  c := PF.ExecuteMany(Formula, GXf, In1, O3);
  if (a = b) and (b = c) then
    WriteLn(Format('  %-40s accepted by all three: %s',
      [Formula, BoolToStr(a, True)]))
  else
  begin
    Inc(Bad);
    WriteLn(Format('  %-40s ACCEPTANCE DIFFERS: jit %s, interpreter %s, fast %s',
      [Formula, BoolToStr(a, True), BoolToStr(b, True), BoolToStr(c, True)]));
  end;
end;

procedure Check(const Formula: string; X0, X1, Y0, Y1: Double);
var
  Xs, Zj, Zs, Zf: array[0..N - 1] of Double;
  I, J, DiffJS, DiffSF: LongInt;
  Y: Double;
  Prog: TFastProgram;
  Used: Boolean;
  Note: string;
  Rows0: Int64;
begin
  Inc(Total);
  Prog := TFastProgram.Create;
  try
    Used := Prog.Compile(PS, Formula);
  finally
    Prog.Free;
  end;
  if Used then Inc(Fast);
  Rows0 := PF.FastRows;
  DiffJS := 0;
  DiffSF := 0;
  for J := 0 to N - 1 do
  begin
    Y := Y0 + (Y1 - Y0) * J / (N - 1);
    for I := 0 to N - 1 do
      Xs[I] := X0 + (X1 - X0) * I / (N - 1);
    GYj := Y; GYs := Y; GYf := Y;
    if not PJ.ExecuteMany(Formula, GXj, Xs, Zj) then
    begin
      WriteLn('  ', Formula, ': JIT refused'); Exit;
    end;
    if not PS.ExecuteMany(Formula, GXs, Xs, Zs) then
    begin
      WriteLn('  ', Formula, ': interpreter refused'); Exit;
    end;
    if not PF.ExecuteMany(Formula, GXf, Xs, Zf) then
    begin
      WriteLn('  ', Formula, ': fast refused'); Exit;
    end;
    for I := 0 to N - 1 do
    begin
      if not Same(Zj[I], Zs[I]) then Inc(DiffJS);
      if not Same(Zs[I], Zf[I]) then
      begin
        if DiffSF = 0 then
          WriteLn(Format('      first at x=%.6f y=%.6f: interp %.17g fast %.17g',
            [Xs[I], Y, Zs[I], Zf[I]]));
        Inc(DiffSF);
      end;
    end;
  end;
  Note := Format('  [fast rows %d of %d]', [PF.FastRows - Rows0, N]);
  if DiffJS > 0 then
    Note := Note +
      Format('  [machine code differs from interpreter in %d - not ours]',
      [DiffJS]);
  if DiffSF > 0 then
  begin
    Inc(Bad);
    WriteLn(Format('  %-40s fast %-5s  OURS DIFFER in %d of %d%s',
      [Formula, BoolToStr(Used, True), DiffSF, N * N, Note]));
  end
  else
    WriteLn(Format('  %-40s fast %-5s  agree on %d%s',
      [Formula, BoolToStr(Used, True), N * N, Note]));
end;

begin
  { THE SAME ARITHMETIC AS THE TARGET. WebAssembly has no floating point traps:
    division by zero gives an infinity and a root of a negative gives a NaN. On
    a processor those same cases end the program by default, and the check
    would then be judging something other than what ships. }
  SetExceptionMask([exInvalidOp, exDenormalized, exZeroDivide,
                    exOverflow, exUnderflow, exPrecision]);
  PJ := TJitParser.Create(nil);
  PS := TNoJitParser.Create(nil);
  PF := TNoJitParser.Create(nil);
  try
    PJ.AddVariable('x', GXj); PJ.AddVariable('y', GYj);
    PS.AddVariable('x', GXs); PS.AddVariable('y', GYs);
    PF.AddVariable('x', GXf); PF.AddVariable('y', GYf);
    PS.FastOff := True;
    Bad := 0; Total := 0; Fast := 0;
    Check('sin(x)*cos(y)', -6, 6, -6, 6);
    Check('x*x+y*y', -3, 3, -3, 3);
    Check('x*x-y*y', -3, 3, -3, 3);
    Check('sin(sqrt(x*x+y*y))', -12, 12, -12, 12);
    Check('sin(sqrt(x*x+y*y))*exp(-0.1*(x*x+y*y))', -8, 8, -8, 8);
    Check('1/(x*x+y*y)', -2, 2, -2, 2);
    Check('x/y', -3, 3, -3, 3);
    Check('-x + 2.5', -3, 3, -3, 3);
    Check('2*(x+y)', -3, 3, -3, 3);
    Check('sin(x+y)/(1+x*x)', -6, 6, -6, 6);
    Check('abs(x) - ln(y)', -3, 3, -3, 3);
    Check('ln(x*x)', -3, 3, -3, 3);
    Check('sqrt(x)', -3, 3, -3, 3);
    Check('tan(x)*tan(y)', -3, 3, -3, 3);
    Check('exp(x)*exp(y)', -8, 8, -8, 8);
    Check('lg(x)', -3, 3, -3, 3);
    Check('arcsin(x)', -2, 2, -2, 2);
    Check('arccos(x/3)', -3, 3, -3, 3);
    Check('arctan(x*y)', -3, 3, -3, 3);
    Check('sinh(x)+cosh(y)', -4, 4, -4, 4);
    Check('tanh(x*y)', -3, 3, -3, 3);
    Check('int(x)', -3, 3, -3, 3);
    Check('frac(x)', -3, 3, -3, 3);
    Check('int(x)+frac(y)', -3, 3, -3, 3);
    Check('trunc(x)', -3, 3, -3, 3);
    Check('sqr(x)-sqr(y)', -3, 3, -3, 3);
    Check('pi*x', -3, 3, -3, 3);
    Check('x*pi/y', -3, 3, -3, 3);
    Check('0.5', -3, 3, -3, 3);
    Check('x', -3, 3, -3, 3);
    Check('y', -3, 3, -3, 3);
    { These must NOT reach the fast path, and must still agree through the
      interpreter. }
    Check('x^y', -3, 3, -3, 3);
    Check('x mod y', -3, 3, -3, 3);
    Check('min(x,y)', -3, 3, -3, 3);
    Check('hypot(x,y)', -3, 3, -3, 3);
    Check('round(x)', -3, 3, -3, 3);
    Check('factorial(3)', -3, 3, -3, 3);
    { Names that do not exist, and a bracket left open. All must be refused,
      and refused by all three alike. }
    WriteLn;
    Accept('nosuchfn(x)');
    Accept('zzz');
    Accept('x+zzz');
    Accept('sim(x)');
    Accept('sin(x');
    Accept('x*x+y*y');
    Accept('sin(x)*cos(y)');
    { DEGENERATE INPUT, four species of it. The sign that a formula names
      something absent is that the decoder yields no steps, and before trusting
      it the other side has to be looked at: is there a LEGAL formula that also
      yields none? Measured - the lone sign is the only input of these that
      does, and both sides refuse it anyway. Nothing legal came out empty. }
    Accept('');
    Accept('   ');
    Accept('(');
    Accept('()');
    Accept('+');
    Accept('.');
    Accept('0');
    Accept('0.5');
    Accept('pi');
    Accept('x');
    Accept('-x');
    WriteLn;
    WriteLn(Format('formulas %d, on the fast path %d, ours differing %d',
      [Total, Fast, Bad]));
    if Bad = 0 then WriteLn('FAST PATH AGREES WITH THE INTERPRETER EVERYWHERE')
    else WriteLn('THERE ARE DIFFERENCES');
  finally
    PF.Free;
    PS.Free;
    PJ.Free;
  end;
end.
