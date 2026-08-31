# nashira3d-live

The showcase page for [Nashira3D](https://github.com/pisarev/nashira3d), a
library that draws three-dimensional surface plots straight from a formula.

The page is one file, with one script in it and one thing it fetches: the
engine of the live demo, from this same repository. There are no web fonts and
no requests to anyone else's servers, so it loads fast and keeps working when
they do not.

## The live demo

The mesh you turn with the mouse is not a picture of the library. It is the
library: `core/nsh_surface.pas`, the file that ships in the release, compiled to
WebAssembly, with the same parser under it. The vertices, the normals, the span
of the height and the number of cells the function left undefined all come back
from that code.

Where the line is drawn:

* **The geometry is real.** Nothing about the mesh is computed by the page.
* **The drawing is not.** On a desktop the core renders through EGL on the
  graphics card without opening a window; here the browser draws with WebGL2 -
  the same shader, carried over from GLSL 330 to GLSL ES 300.
* **One thing is genuinely missing.** The desktop library compiles a formula to
  machine code and evaluates a whole row of the mesh in one call. WebAssembly
  has no executable memory at all, so that cannot be there; the same parser runs
  as an interpreter instead, a point at a time. That is why a heavy formula
  takes tenths of a second in the browser and milliseconds on a desktop.

### Building the engine

```
$env:FPC_WASM = "<fpc with a wasm32-wasip1 cross compiler>"
$env:NASHIRA3D_SRC = "<a checkout of nashira3d>"
engine/build_wasm.ps1
```

The cross compiler `ppcrosswasm32` arrived in FPC 3.3.1, while the library
itself is built with 3.2.2 - so the demo is compiled by a different compiler
than the release, and that is stated plainly rather than hidden.

`engine/nsh_nojit.pas` is the one piece of Pascal that exists only for the
browser: it gives the interpreter the batch call the JIT provides on a desktop.
It is not part of the library and the library never builds it.

## The pictures

Every drawing on the page came out of the library itself:

```
NASHIRA3D_LIB=<path to the built library> python tools/render_assets.py
```

The script asks the core for two frames of each surface - one in colour to get
the silhouette, one in contour lines - and turns the second into dark lines on
light paper. Nothing is traced or touched up by hand, so the pictures cannot
drift away from what the code does.

## Licence

MIT, the same as the library.
