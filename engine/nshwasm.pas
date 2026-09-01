{ The engine of the live demo: the REAL surface builder, compiled to
  WebAssembly.

  What matters here, and what it is for. The page computes nothing of its own -
  not the formula, not the mesh, not the normals. It calls this module, and this
  module is exactly the nsh_surface that ships in the library, with the same
  formula parser underneath. There is one difference from a desktop build: there
  the frame is drawn by the graphics card through EGL, and here it is drawn by
  the browser through WebGL2 - with the same shader, carried over from GLSL 330
  to GLSL ES 300.

  Hence the line the demo draws for itself, and the page states it plainly: the
  geometry is real, the drawing belongs to the browser.

  Building: build_wasm.ps1, next door. A wasm32-wasip1 cross compiler
  (ppcrosswasm32) is needed - FPC gained one in 3.3.1, while the library itself
  is built with 3.2.2. That, too, is stated plainly: the demo is compiled by a
  different compiler.

  Memory is handed out without ownership: the page asks for a buffer through
  WAlloc, receives bytes into it, and releases it through WFree. Neither side
  assumes anything about what the other one owns. }
{ A LIBRARY, not a program. The difference is not cosmetic here: a program gives
  a command module with _start, which runs its body and EXITS - unit
  finalisation runs with it, and a parser created later calls into a table of
  functions that has already been torn down. Measured: a crash reading "null
  function or function signature mismatch" inside
  TCustomParser.InternalAddFunction on the very first call to WBuild. A library
  gives a reactor module with _initialize: it prepares the module and stays
  alive. }
library nshwasm;

{$mode objfpc}{$H+}

uses
  SysUtils, nsh_surface;

var
  GS   : TSurface;
  GErr : AnsiString = '';
  GOk  : Boolean = False;

function WAlloc(Size: LongInt): Pointer; cdecl;
begin
  if Size <= 0 then Exit(nil);
  Result := GetMem(Size);
end;

procedure WFree(Data: Pointer); cdecl;
begin
  if Data <> nil then FreeMem(Data);
end;

{ Build the surface. Returns the number of vertices, or minus one on a refusal -
  the reason is then asked of WNote. }
function WBuild(Text: PAnsiChar; Size: LongInt; X0, X1, Y0, Y1: Double;
  Quality: LongInt): LongInt; cdecl;
var
  F: AnsiString;
begin
  GOk := False;
  GErr := '';
  if (Text = nil) or (Size <= 0) or (Size > 4096) then
  begin
    GErr := 'the formula is empty or too long';
    Exit(-1);
  end;
  SetLength(F, Size);
  Move(Text^, F[1], Size);
  if not BuildSurface(F, X0, X1, Y0, Y1, Quality, GS, GErr) then
    Exit(-1);
  GOk := True;
  Result := Length(GS.Verts);
end;

{ The same mesh, but on GIVEN sample lines: they need not be evenly spaced.

  This is what the endless sheet is built on. Nodes are placed by screen
  density - dense underfoot, sparse towards the horizon - because an even
  spacing hands half of them to a distance that occupies ten rows of the frame.
  Choosing the lines is the camera's business and belongs to the caller; here
  the mesh is built on what it decided.

  Returns the number of vertices, or minus one on a refusal - the reason is then
  asked of WNote. }
function WBuildAt(Text: PAnsiChar; Size: LongInt; Xs: PDouble; NX: LongInt;
  Ys: PDouble; NY: LongInt): LongInt; cdecl;
var
  F: AnsiString;
  Lx, Ly: array of Double;
begin
  GOk := False;
  GErr := '';
  if (Text = nil) or (Size <= 0) or (Size > 4096) then
  begin
    GErr := 'the formula is empty or too long';
    Exit(-1);
  end;
  { Two lines are the least a grid can be built on, and 4096 is far above what
    any quality asks for - the top is 256. The bound is here so that a wrong
    number from the page cannot reach a memory move. }
  if (Xs = nil) or (Ys = nil) or (NX < 2) or (NY < 2) or (NX > 4096) or
    (NY > 4096) then
  begin
    GErr := 'the sample lines are missing or out of range';
    Exit(-1);
  end;
  SetLength(F, Size);
  Move(Text^, F[1], Size);
  SetLength(Lx, NX);
  SetLength(Ly, NY);
  Move(Xs^, Lx[0], NX * SizeOf(Double));
  Move(Ys^, Ly[0], NY * SizeOf(Double));
  if not BuildSurfaceFrom(F, Lx, Ly, GS, GErr) then Exit(-1);
  GOk := True;
  Result := Length(GS.Verts);
end;

{ The vertices in a row: x, y, z, nx, ny, nz - six single-precision numbers to a
  vertex, exactly as TVertex holds them. Returns the number of numbers WRITTEN. }
function WVerts(Buffer: PSingle; Capacity: LongInt): LongInt; cdecl;
var
  N: LongInt;
begin
  if (not GOk) or (Buffer = nil) then Exit(0);
  N := Length(GS.Verts) * 6;
  if N > Capacity then N := Capacity - (Capacity mod 6);
  if N <= 0 then Exit(0);
  Move(GS.Verts[0], Buffer^, N * SizeOf(Single));
  Result := N;
end;

{ The triangles: three references to a vertex apiece. }
function WIdx(Buffer: PLongWord; Capacity: LongInt): LongInt; cdecl;
var
  N: LongInt;
begin
  if (not GOk) or (Buffer = nil) then Exit(0);
  N := Length(GS.Idx);
  if N > Capacity then N := Capacity - (Capacity mod 3);
  if N <= 0 then Exit(0);
  Move(GS.Idx[0], Buffer^, N * SizeOf(LongWord));
  Result := N;
end;

{ The span of the height and the number of cells that were skipped. The skipped
  ones are a number, not a feeling: they show that the function has holes rather
  than that the renderer went wrong. }
function WInfo(Buffer: PDouble): LongInt; cdecl;
begin
  if (not GOk) or (Buffer = nil) then Exit(0);
  Buffer[0] := GS.ZMin;
  Buffer[1] := GS.ZMax;
  Buffer[2] := GS.Side;
  Buffer[3] := GS.Holes;
  Result := 4;
end;

{ The last reason for a refusal, in words. }
function WNote(Buffer: PAnsiChar; Capacity: LongInt): LongInt; cdecl;
var
  N: LongInt;
begin
  if (Buffer = nil) or (Capacity <= 0) then Exit(0);
  N := Length(GErr);
  if N > Capacity - 1 then N := Capacity - 1;
  if N > 0 then Move(GErr[1], Buffer^, N);
  Buffer[N] := #0;
  Result := N;
end;

{ How many nodes a side this quality gives. The page needs the number to set up
  its buffers BEFORE the build rather than guess at the size. }
function WSide(Quality: LongInt): LongInt; cdecl;
begin
  Result := SideFromQuality(Quality);
end;

{ The names on the outside are given explicitly and in lower case. Relying on
  how a compiler preserves case will not do: that is its business, not the
  contract's. }
exports
  WAlloc name 'walloc',
  WFree  name 'wfree',
  WBuild name 'build',
  WBuildAt name 'build_at',
  WVerts name 'verts',
  WIdx   name 'idx',
  WInfo  name 'info',
  WNote  name 'note',
  WSide  name 'side';

begin
end.
