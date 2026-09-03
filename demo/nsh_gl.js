/* The Nashira3D renderer for a browser - ONE for every page of the site.
   ---------------------------------------------------------------------
   The showcase and the builder draw with the same code. There must not be two
   copies: they start parting on the first edit, and the parting shows up not in
   the code but in a picture, which is to say too late.

   Everything here is carried over from core/nsh_render.pas and core/nsh_text.pas
   with the dialect changed from GLSL 330 to GLSL ES 300. The agreement with the
   library is checked pixel by pixel: tools/frame_gate.py compares a frame of the
   page against a frame of the library at five views, covering every branch of
   the choice of edges and corners.

   What is handed out is createRenderer(gl): it builds the programs, keeps the
   buffers, takes a mesh through upload and draws a frame from a set of settings
   through draw. The settings are passed EXPLICITLY rather than picked up from
   the surroundings: there are two pages, and they differ in domain, in box
   proportions and in camera.
   --------------------------------------------------------------------- */

export function createRenderer(gl) {

  /* The state of the renderer. It used to live in the scope of the page; now it
     belongs to the module, and every page gets its own instance. */
  let prog = null, bgProg = null, lineProg = null, lineVao = null, lineCount = 0;
  let vao = null, vbo = null, ebo = null, gridEbo = null, gridCount = 0;
  /* The scale the vertices were normalised by. Everything that reads a
     height afterwards has to read it through the SAME pair - the shading of
     the normals, the reference of the contour lines and their step - or the
     lines land on levels the surface does not have. */
  let zMid = 0, zSpan = 1;
  let idxCount = 0, info = [0, 0, 0, 0];

  /* The line program of the library, carried over from LINE_VERT_SRC and
     LINE_FRAG_SRC in nsh_render.pas. The tint fades with depth so that the far
     edges of the box do not compete with the surface for attention. */
  /* ---- tick labels -------------------------------------------------------
     The library keeps its own bitmap font: seventeen glyphs of five by seven
     bits, drawn into a six by nine cell. The stretch is carried over as it is,
     not cleaned up - sampled NEAREST, some columns double and some rows repeat,
     and that is what the picture actually looks like. Digits, minus, dot, e and
     the three axis letters are all the alphabet a tick label ever needs. */
  const GLYPH_W = 5, GLYPH_H = 7, GLYPH_N = 17, CELL_W = 6, CELL_H = 9;
  const BOX_XY = 1.0, BOX_Z = 1.0, DIV_COUNT = 5;
  const FONT = [
    [14, 17, 19, 21, 25, 17, 14],   /* 0 */
    [ 4, 12,  4,  4,  4,  4, 14],   /* 1 */
    [14, 17,  1,  2,  4,  8, 31],   /* 2 */
    [31,  2,  4,  2,  1, 17, 14],   /* 3 */
    [ 2,  6, 10, 18, 31,  2,  2],   /* 4 */
    [31, 16, 30,  1,  1, 17, 14],   /* 5 */
    [ 6,  8, 16, 30, 17, 17, 14],   /* 6 */
    [31,  1,  2,  4,  8,  8,  8],   /* 7 */
    [14, 17, 17, 14, 17, 17, 14],   /* 8 */
    [14, 17, 17, 15,  1,  2, 12],   /* 9 */
    [ 0,  0,  0, 31,  0,  0,  0],   /* - */
    [ 0,  0,  0,  0,  0, 12, 12],   /* . */
    [ 0,  0, 14, 17, 31, 16, 14],   /* e */
    [ 0,  0, 17, 10,  4, 10, 17],   /* x */
    [ 0,  0, 17, 17, 15,  1, 14],   /* y */
    [ 0,  0, 31,  2,  4,  8, 31],   /* z */
    [ 0,  0, 31,  0, 31,  0,  0]    /* = */
  ];
  const glyphOf = c => {
    if (c >= "0" && c <= "9") return c.charCodeAt(0) - 48;
    const k = "-.,=eExXyYzZ".indexOf(c);
    if (k < 0) return -1;
    return [10, 11, 11, 16, 12, 12, 13, 13, 14, 14, 15, 15][k];
  };


  let txtProg = null, txtTex = null, txtVao = null, txtVbo = null;

  const TEXT_VS = `#version 300 es
    layout(location = 0) in vec3 aAnchor;
    layout(location = 1) in vec2 aOffset;
    layout(location = 2) in vec2 aUV;
    uniform mat4 uMVP;
    uniform vec2 uPxToNdc;
    out vec2 vUV;
    void main() {
      vec4 p = uMVP * vec4(aAnchor, 1.0);
      p /= p.w;
      /* Snap to a whole pixel. The anchor is a projected box corner and lands
         wherever it lands; at a fractional position the five-by-seven font
         breaks up - the library measured 38 per cent of letter pixels turning
         into half-tones before this line was added. The offset is rounded too:
         half a cell height is -4.5, and leaving it alone would spend the whole
         gain on that one number. */
      vec2 sc = floor(p.xy / uPxToNdc + 0.5) + floor(aOffset + 0.5);
      gl_Position = vec4(sc * uPxToNdc, p.z, 1.0);
      vUV = aUV;
    }`;
  const TEXT_FS = `#version 300 es
    precision highp float;
    in vec2 vUV;
    uniform sampler2D uFont;
    out vec4 fColor;
    void main() {
      float a = texture(uFont, vUV).r;
      if (a < 0.5) discard;
      fColor = vec4(0.85, 0.88, 0.94, 1.0);
    }`;

  /* The number under a tick. Three significant digits, and a plain exponent
     for what does not fit - the library's own rule, spelled out the same way. */
  const fmtTick = v => {
    if (Number.isNaN(v)) return "?";
    if (!Number.isFinite(v)) return v > 0 ? "inf" : "-inf";
    const a = Math.abs(v);
    if (a < 1e-10) return "0";
    if (a < 1e-3 || a >= 1e5)
      return v.toExponential(1).replace("e+", "e");
    return String(Number(v.toPrecision(3)));
  };

  const LINE_VS = `#version 300 es
    layout(location = 0) in vec3 aPos;
    uniform mat4 uMVP;
    out float vDep;
    void main() {
      vec4 p = uMVP * vec4(aPos, 1.0);
      vDep = p.z / p.w;
      gl_Position = p;
    }`;

  const LINE_FS = `#version 300 es
    precision highp float;
    in float vDep;
    uniform vec4 uTint;
    out vec4 fColor;
    void main() {
      float t = clamp(vDep * 0.5 + 0.5, 0.0, 1.0);
      float k = mix(1.0, 0.32, smoothstep(0.55, 1.0, t));
      fColor = vec4(uTint.rgb * k, uTint.a);
    }`;

  const BG_SRC = `
    vec3 bgAt(vec2 uv) {
      vec3 top = vec3(0.070, 0.092, 0.128);
      vec3 bot = vec3(0.026, 0.035, 0.052);
      vec3 c = mix(bot, top, smoothstep(0.0, 1.0, uv.y));
      vec2 d = uv - 0.5;
      c *= 1.0 - 0.55 * dot(d, d);
      return c;
    }`;

  /* The box: twelve edges and the tick marks, exactly as BuildAxes builds them
     in nsh_render.pas. The constants are its constants - BOX_XY 1, BOX_Z 1,
     five divisions, tick 0.04 - and the vertices sit in the same normalised
     box the mesh does, so the model scale in the MVP carries them along. */
  const axesSegments = () => {
    const B = 1.0, Z = 1.0, DIV = 5, TICK = 0.04, v = [];
    const seg = (x1, y1, z1, x2, y2, z2) => v.push(x1, y1, z1, x2, y2, z2);
    for (const z of [-Z, Z]) {
      seg(-B, -B, z,  B, -B, z);
      seg( B, -B, z,  B,  B, z);
      seg( B,  B, z, -B,  B, z);
      seg(-B,  B, z, -B, -B, z);
    }
    seg(-B, -B, -Z, -B, -B, Z);
    seg( B, -B, -Z,  B, -B, Z);
    seg( B,  B, -Z,  B,  B, Z);
    seg(-B,  B, -Z, -B,  B, Z);
    for (let i = 1; i < DIV; i++) {
      const tt = -B + 2 * B * i / DIV;
      seg(tt, -B, -Z, tt, -B - TICK, -Z);
      seg(-B, tt, -Z, -B - TICK, tt, -Z);
      const tz = -Z + 2 * Z * i / DIV;
      seg(-B, -B, tz, -B - TICK, -B - TICK, tz);
    }
    return new Float32Array(v);
  };

  const BG_VS = `#version 300 es
    out vec2 vUv;
    void main() {
      vec2 p = vec2((gl_VertexID << 1) & 2, gl_VertexID & 2);
      vUv = p;
      gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0);
    }`;

  const BG_FS = `#version 300 es
    precision highp float;
    ${BG_SRC}
    in vec2 vUv;
    out vec4 fColor;
    void main() { fColor = vec4(bgAt(vUv), 1.0); }`;

  const VS = `#version 300 es
    layout(location = 0) in vec3 aPos;
    layout(location = 1) in vec3 aNrm;
    uniform mat4 uMVP;
    uniform vec3 uScale;
    uniform vec3 uNrmScale;
    out vec3 vNrm;
    out vec3 vPos;
    out float vH;
    void main() {
      gl_Position = uMVP * vec4(aPos, 1.0);
      vNrm = normalize(aNrm * uNrmScale);
      vPos = aPos * uScale;
      vH = aPos.z;
    }`;

  const FS = `#version 300 es
    precision highp float;
    ${BG_SRC}
    in vec3 vNrm;
    in vec3 vPos;
    in float vH;
    uniform vec3 uLight;
    uniform vec3 uEye;
    uniform vec2 uMeshHalf;
    uniform vec2 uViewport;
    uniform int uShade;
    uniform vec3 uCont;
    out vec4 fColor;
    vec3 ramp(float t) {
      vec3 a = vec3(0.13, 0.18, 0.52);
      vec3 b = vec3(0.10, 0.68, 0.56);
      vec3 c = vec3(0.98, 0.86, 0.30);
      return t < 0.5 ? mix(a, b, smoothstep(0.0, 1.0, t * 2.0))
                     : mix(b, c, smoothstep(0.0, 1.0, (t - 0.5) * 2.0));
    }
    float contNum(float t) { return (uCont.x + t * uCont.y) / uCont.z; }
    vec3 contInk(vec3 base, float f, float fw) {
      float d  = abs(fract(f + 0.5) - 0.5) / max(fw, 1E-6);
      float mn = 1.0 - smoothstep(0.30, 0.95, d);
      float d5 = abs(fract(f * 0.2 + 0.5) - 0.5) * 5.0 / max(fw, 1E-6);
      float mj = 1.0 - smoothstep(0.45, 1.25, d5);
      float vis = (1.0 - smoothstep(0.40, 1.10, fw)) * smoothstep(0.004, 0.02, fw);
      float a = clamp(mn * 0.55 + mj * 0.45, 0.0, 1.0) * vis;
      return mix(base, vec3(0.07, 0.11, 0.17), a);
    }
    void main() {
      vec3 n = normalize(vNrm);
      vec3 l = normalize(uLight);
      vec3 v = normalize(uEye - vPos);
      if (dot(n, v) < 0.0) { n = -n; l.z = -l.z; }
      vec3 h = normalize(l + v);
      float d = max(dot(n, l), 0.0);
      float w = d * 0.75 + 0.25;
      float sp = pow(max(dot(n, h), 0.0), 42.0);
      float rim = pow(1.0 - max(dot(n, v), 0.0), 3.0);
      vec3 base = (uShade == 0) ? vec3(0.80, 0.83, 0.86)
                                : ramp(clamp((vH + 1.0) * 0.5, 0.0, 1.0));
      float spk = (uShade == 0) ? 0.13 : 0.30;
      vec3 col = base * (0.20 + 0.80 * w);
      col += vec3(0.95, 0.98, 1.00) * sp * spk;
      col += vec3(0.35, 0.62, 0.80) * rim * 0.16;
      if (uShade != 1) {
        float f = contNum(vH);
        col = contInk(col, f, fwidth(f));
      }
      /* THE FAR EDGE DISSOLVES. On the endless sheet the mesh has to stop
         somewhere, and a straight cut across the frame would read as the
         edge of the surface - which it is not. Counted along THE PATH LEFT
         to the mesh boundary rather than by distance from the eye: the mesh
         is built on a BOUNDING rectangle, so one number for the limit would
         dissolve the corners and the sides differently.

         It dissolves INTO THE COLOUR OF THE BACKGROUND, not into
         transparency: blending would need an order of drawing and would
         argue with the depth test. The background is computed by the very
         function that paints it, so it matches exactly.

         uMeshHalf.y <= 0 means do not dissolve: a declared region has edges
         a person put there, and they are the subject. */
      if (uMeshHalf.y > 0.0) {
        vec2 o = uEye.xy;
        vec2 dir = vPos.xy - o;
        float t = 1.0e30;
        if (abs(dir.x) > 1.0e-9) {
          float bx = (dir.x > 0.0) ? uMeshHalf.x : -uMeshHalf.x;
          t = min(t, (bx - o.x) / dir.x);
        }
        if (abs(dir.y) > 1.0e-9) {
          float by = (dir.y > 0.0) ? uMeshHalf.y : -uMeshHalf.y;
          t = min(t, (by - o.y) / dir.y);
        }
        float r = max(t - 1.0, 0.0);
        /* THE 1.5 IS NOT A KNOB, and it was not chosen by eye. t says how many
           times further than this point the ray leaves the rectangle of the
           mesh, so r = t - 1 is the path still to go measured in what has
           already been walked, and at the boundary r is nought and the colour
           becomes the background EXACTLY, whatever the direction. The older
           dissolve ran by reciprocal distance from 0.4 of the limit to the
           limit, which in these same units is exactly r from 1.5 down to 0, so
           where the boundary sat at the limit this reproduces it exactly.
           By reciprocal distance rather than distance because the library
           measured the other way: on a shallow view an even dissolve by
           distance took TWO ROWS of a frame of two hundred and twenty, which is
           to say it was not visible at all. */
        float u = clamp(1.0 - r / 1.5, 0.0, 1.0);
        /* A smoothed step, not u*u: its derivative is zero at BOTH ends, and
           the ledge it leaves stays below one level of brightness out of
           255. The plain square left twelve, and twelve is visible. */
        float k = u * u * (3.0 - 2.0 * u);
        col = mix(col, bgAt(gl_FragCoord.xy / uViewport), k);
      }
      fColor = vec4(col, 1.0);
    }`;

  const compile = (type, src) => {
    const s = gl.createShader(type);
    gl.shaderSource(s, src.trim());
    gl.compileShader(s);
    if (!gl.getShaderParameter(s, gl.COMPILE_STATUS))
      throw new Error(gl.getShaderInfoLog(s));
    return s;
  };

  /* Matrices, written out rather than pulled from a library: four functions
     are cheaper than a dependency, and the page loads nothing from anywhere
     else. Column-major, as OpenGL wants. */
  const mul = (a, b) => {
    const o = new Float32Array(16);
    for (let c = 0; c < 4; c++)
      for (let r = 0; r < 4; r++) {
        let s = 0;
        for (let k = 0; k < 4; k++) s += a[k * 4 + r] * b[c * 4 + k];
        o[c * 4 + r] = s;
      }
    return o;
  };
  const perspective = (fovy, aspect, near, far) => {
    const f = 1 / Math.tan(fovy / 2), o = new Float32Array(16);
    o[0] = f / aspect; o[5] = f; o[10] = (far + near) / (near - far);
    o[11] = -1; o[14] = 2 * far * near / (near - far);
    return o;
  };
  const lookAt = (e, c, up) => {
    const sub = (a, b) => [a[0] - b[0], a[1] - b[1], a[2] - b[2]];
    const norm = a => { const L = Math.hypot(a[0], a[1], a[2]) || 1; return [a[0] / L, a[1] / L, a[2] / L]; };
    const cross = (a, b) => [a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0]];
    const dot = (a, b) => a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
    const f = norm(sub(c, e)), s = norm(cross(f, up)), u = cross(s, f);
    const o = new Float32Array(16);
    o[0] = s[0]; o[4] = s[1]; o[8] = s[2];
    o[1] = u[0]; o[5] = u[1]; o[9] = u[2];
    o[2] = -f[0]; o[6] = -f[1]; o[10] = -f[2];
    o[12] = -dot(s, e); o[13] = -dot(u, e); o[14] = dot(f, e); o[15] = 1;
    return o;
  };

  /* Where every label goes. Carried over from the library step for step: the
     edge that reads lowest on screen takes the x numbers, the same test on the
     other pair takes y, and z hangs on the leftmost of the four uprights. */
  const labelVerts = (mvp, w, h, dom, info) => {
    const V = [];
    const add = (text, wx, wy, wz, pxX, pxY) => {
      let x0 = pxX;
      for (const c of text) {
        const g = glyphOf(c);
        if (g >= 0) {
          const u0 = g / GLYPH_N, u1 = (g + 1) / GLYPH_N;
          V.push(wx, wy, wz, x0,          pxY,          u0, 1,
                 wx, wy, wz, x0 + CELL_W, pxY,          u1, 1,
                 wx, wy, wz, x0,          pxY + CELL_H, u0, 0,
                 wx, wy, wz, x0 + CELL_W, pxY,          u1, 1,
                 wx, wy, wz, x0 + CELL_W, pxY + CELL_H, u1, 0,
                 wx, wy, wz, x0,          pxY + CELL_H, u0, 0);
        }
        x0 += CELL_W;
      }
    };
    const proj = (x, y, z) => {
      const cx = mvp[0] * x + mvp[4] * y + mvp[8] * z + mvp[12];
      const cy = mvp[1] * x + mvp[5] * y + mvp[9] * z + mvp[13];
      let cw = mvp[3] * x + mvp[7] * y + mvp[11] * z + mvp[15];
      if (Math.abs(cw) < 1e-9) cw = 1e-9;
      return [cx / cw, cy / cw];
    };
    const midY = (x, y) => proj(x, y, -BOX_Z)[1];
    const edgeY = midY(0, -BOX_XY) <= midY(0, BOX_XY) ? -BOX_XY : BOX_XY;
    const edgeX = midY(-BOX_XY, 0) <= midY(BOX_XY, 0) ? -BOX_XY : BOX_XY;
    let bestX = 1e30, cornX = -BOX_XY, cornY = -BOX_XY;
    for (let i = 0; i < 4; i++) {
      const cx = BOX_XY * (1 - 2 * (i & 1));
      const cy = BOX_XY * (1 - 2 * ((i >> 1) & 1));
      const v = proj(cx, cy, 0)[0];
      if (v < bestX) { bestX = v; cornX = cx; cornY = cy; }
    }
    /* A label is kept with an eye on its neighbour. When an edge points nearly
       along the line of sight all five of its numbers pile into one spot. The
       two end labels are never dropped: an axis whose end is unlabelled looks
       shorter than it is, and that is worse than a crowd. Distance is measured
       in pixels, because letters keep their size on screen. */
    const lastX = [0, 0], lastY = [0, 0], lastOk = [false, false];
    const keep = (axis, idx, x, y, chars) => {
      const p = proj(x, y, -BOX_Z);
      const px = (p[0] * 0.5 + 0.5) * w, py = (1 - (p[1] * 0.5 + 0.5)) * h;
      if (idx === 0 || idx === DIV_COUNT || !lastOk[axis]) {
        lastX[axis] = px; lastY[axis] = py; lastOk[axis] = true;
        return true;
      }
      const ok = Math.abs(px - lastX[axis]) >= CELL_W * (chars + 1)
              || Math.abs(py - lastY[axis]) >= CELL_H * 1.4;
      if (ok) { lastX[axis] = px; lastY[axis] = py; }
      return ok;
    };
    for (let i = 0; i <= DIV_COUNT; i++) {
      const tt = -BOX_XY + 2 * BOX_XY * i / DIV_COUNT;
      let s = fmtTick(dom[0] + (dom[1] - dom[0]) * i / DIV_COUNT);
      if (keep(0, i, tt, edgeY, s.length))
        add(s, tt, edgeY, -BOX_Z, -CELL_W * s.length / 2, -CELL_H - 5);
      s = fmtTick(dom[2] + (dom[3] - dom[2]) * i / DIV_COUNT);
      if (keep(1, i, edgeX, tt, s.length))
        add(s, edgeX, tt, -BOX_Z, -CELL_W * s.length / 2, -CELL_H - 5);
    }
    /* z gets two divisions, not five: the box is a third of the height and
       five numbers there run together. Taking every other one of the five is
       not an option - the top value would go unlabelled, and an axis that lies
       about its own span is worse than one with no numbers at all. */
    for (let i = 0; i <= 2; i++) {
      const s = fmtTick(info[0] + (info[1] - info[0]) * i / 2);
      add(s, cornX, cornY, -BOX_Z + 2 * BOX_Z * i / 2,
          -CELL_W * s.length - 10, -CELL_H / 2);
    }
    /* The axis letter sits BEYOND the end of its edge: in the middle it lands
       on top of a tick number. */
    add("x", BOX_XY * 1.18, edgeY, -BOX_Z, -CELL_W / 2, -CELL_H - 5);
    add("y", edgeX, BOX_XY * 1.18, -BOX_Z, -CELL_W / 2, -CELL_H - 5);
    add("z", cornX, cornY, BOX_Z * 1.35, -CELL_W - 12, -CELL_H / 2);
    return new Float32Array(V);
  };

  const draw = o => {
    if (!gl || !idxCount) return;
    const w = gl.canvas.width, h = gl.canvas.height;
    gl.viewport(0, 0, w, h);
    const paper = o.plate || "#E9EBE4";
    const m = /^#?([0-9a-f]{2})([0-9a-f]{2})([0-9a-f]{2})$/i.exec(paper);
    if (m) gl.clearColor(parseInt(m[1], 16) / 255, parseInt(m[2], 16) / 255,
                         parseInt(m[3], 16) / 255, 1);
    else gl.clearColor(0.91, 0.92, 0.89, 1);
    gl.clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT);

    /* The backdrop goes down first and takes no part in the depth buffer: it
       is behind everything by construction, and testing it against depth would
       only invite a driver to disagree. */
    if (bgProg) {
      gl.disable(gl.DEPTH_TEST);
      gl.useProgram(bgProg);
      gl.bindVertexArray(vao);
      gl.drawArrays(gl.TRIANGLES, 0, 3);
    }
    gl.enable(gl.DEPTH_TEST);

    const az = o.az, el = o.el, BOX = o.box, DIST = o.dist;
    const ce = Math.cos(el), se = Math.sin(el);
    const fov = o.fov || 0.9;

    /* THE PAN IS GIVEN IN THE PLANE OF THE FRAME, so it has to be resolved
       along the right and up axes of the very camera that draws. The library
       does it here rather than inside lookAt, where neither the azimuth nor the
       tilt is left - only a finished point. */
    const pan = o.pan || [0, 0];
    const rx = -Math.sin(az), ry = Math.cos(az);
    let ux = -se * Math.cos(az), uy = -se * Math.sin(az), uz = ce;
    let ul = Math.hypot(ux, uy, uz);
    if (ul < 1e-12) ul = 1;
    ux /= ul; uy /= ul; uz /= ul;
    const tx = rx * pan[0] + ux * pan[1];
    const ty = ry * pan[0] + uy * pan[1];
    const tz =               uz * pan[1];

    /* TWO CAMERAS, and the difference is not a detail. An orbit is given by a
       distance from the origin; a standing camera is given by a point and a
       signed height, and has no distance at all - the tilt changes only the
       direction, a drag only the point, the wheel only the height. The near
       plane is taken finer for it: it may stand right against the surface, or
       inside it, and 0.05 would clip it away. Fitting the frame is off for a
       standing camera by construction: fitting moves the camera, and here its
       position is the thing a person set. */
    let eye, target, near, far, doFit;
    if (o.stand) {
      eye = [o.stand[0] + tx, o.stand[1] + ty, o.stand[2] + tz];
      target = [eye[0] - ce * Math.cos(az), eye[1] - ce * Math.sin(az), eye[2] - se];
      near = 0.002; far = 400; doFit = false;
    } else {
      eye = [DIST * ce * Math.cos(az) + tx, DIST * ce * Math.sin(az) + ty,
             DIST * se + tz];
      target = [tx, ty, tz];
      near = 0.05; far = 100; doFit = !!o.fit;
    }

    /* The box proportions belong in the model matrix, not in the shader: the
       vertex shader passes aPos to uMVP untouched and uses uScale only for the
       world position it hands to the lighting. Leaving the scale out here drew
       the surface at a box of 1.0 in height where the library draws 0.3 -
       three times too tall, and the gate that compares frames said so in
       pixels before anyone said it in words. */
    const scale = (sx, sy, sz) => {
      const o2 = new Float32Array(16);
      o2[0] = sx; o2[5] = sy; o2[10] = sz; o2[15] = 1;
      return o2;
    };
    const mvp = mul(mul(perspective(fov, w / h, near, far),
                        lookAt(eye, target, [0, 0, 1])),
                    scale(BOX[0], BOX[1], BOX[2]));

    /* FITTING THE FRAME. The size is taken from the SPHERE around the box, not
       from the silhouette, and that is not a nicety: it is the only way the
       picture does not jump as the view turns. The library measured what the
       silhouette costs - from above the box fills 72 by 86 per cent of the
       frame, edge on 94 by 45 - because the shape of a silhouette depends on
       the angle, and a scale computed from it depends on the angle too. A
       sphere does not notice a turn at all.

       Fill is given from outside rather than settled here. A scale that does
       not depend on the angle cannot also fill the frame at every tilt: a flat
       sheet is wide from above and narrow from the edge. One number cannot do
       both, so the choice belongs to whoever is looking. */
    if (doFit) {
      let rad = Math.hypot(BOX[0], BOX[1], BOX[2]);
      if (rad > DIST * 0.98) rad = DIST * 0.98;
      let hy = Math.tan(Math.asin(rad / DIST)) / Math.tan(fov / 2);
      if (hy < 1e-9) hy = 1e-9;
      const fill = (o.fill > 0) ? o.fill : 1;
      const need = fill / hy;
      for (let p = 0; p < 4; p++) { mvp[p * 4] *= need; mvp[p * 4 + 1] *= need; }
    }
    gl.useProgram(prog);
    const U = n => gl.getUniformLocation(prog, n);
    gl.uniformMatrix4fv(U("uMVP"), false, mvp);
    gl.uniform3f(U("uScale"), BOX[0], BOX[1], BOX[2]);
    const zspan = Math.max(zSpan, 1e-9);
    gl.uniform3f(U("uNrmScale"), o.half / BOX[0], o.half / BOX[1], zspan / (2 * BOX[2]));
    const laz = (o.light && o.light[0] !== undefined) ? o.light[0] : 2.2;
    const lel = (o.light && o.light[1] !== undefined) ? o.light[1] : 0.9;
    gl.uniform3f(U("uLight"), Math.cos(lel) * Math.cos(laz),
                 Math.cos(lel) * Math.sin(laz), Math.sin(lel));
    gl.uniform3f(U("uEye"), eye[0], eye[1], eye[2]);
    const mh = o.meshHalf || [0, 0];
    gl.uniform2f(U("uMeshHalf"), mh[0], mh[1]);
    gl.uniform2f(U("uViewport"), gl.drawingBufferWidth,
                 gl.drawingBufferHeight);
    /* 0 contours, 1 colour, 2 both - the library's own numbering. */
    gl.uniform1i(U("uShade"), (o.shade === undefined) ? 2 : o.shade);
    /* The step of the contour lines, and this time it really is the rule the
       library uses: NiceStep in nsh_ticks.pas takes the span over FIFTEEN, not
       fourteen, and picks the nearest of 1, 2, 5 across three decades by the
       distance of logarithms. The old fourteen agreed by luck on the sample
       formulas and would have parted company on others. */
    const raw = zspan / 15;
    const e = Math.floor(Math.log10(Math.max(raw, 1e-12)));
    let step = 1, best = Infinity;
    for (let k = -1; k <= 1; k++)
      for (const m of [1, 2, 5]) {
        const cand = m * Math.pow(10, e + k);
        const d = Math.abs(Math.log(cand) - Math.log(raw));
        if (cand > 0 && d < best) { best = d; step = cand; }
      }
    gl.uniform3f(U("uCont"), zMid, zspan / 2, step);
    gl.bindVertexArray(vao);
    /* The surface is pushed one step back in depth: without it the grid lines,
       lying in the very same places, fight it for pixels and shimmer. */
    gl.enable(gl.POLYGON_OFFSET_FILL);
    gl.polygonOffset(1.0, 1.0);
    gl.drawElements(gl.TRIANGLES, idxCount, gl.UNSIGNED_INT, 0);
    gl.disable(gl.POLYGON_OFFSET_FILL);

    if (o.lines && lineProg && gridCount > 0) {
      gl.useProgram(lineProg);
      gl.uniformMatrix4fv(gl.getUniformLocation(lineProg, "uMVP"), false, mvp);
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gridEbo);
      gl.enable(gl.BLEND);
      /* Only the colour is blended. A plain blendFunc would touch the alpha
         channel as well, and a line at 0.3 would leave the frame with 152
         where 255 belongs - the frame would stop being opaque. */
      gl.blendFuncSeparate(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA, gl.ZERO, gl.ONE);
      gl.uniform4f(gl.getUniformLocation(lineProg, "uTint"), 0.85, 0.93, 1.00, 0.30);
      gl.drawElements(gl.LINES, gridCount, gl.UNSIGNED_INT, 0);
      gl.disable(gl.BLEND);
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    }

    /* The box goes on last, with the tint the library gives it. */
    /* The box is asked for separately from the mesh grid. On the endless
       sheet the grid is the subject and the box has no edges to draw. */
    if (o.lines && o.box3d !== false && lineProg && lineCount > 0) {
      gl.useProgram(lineProg);
      gl.uniformMatrix4fv(gl.getUniformLocation(lineProg, "uMVP"), false, mvp);
      gl.uniform4f(gl.getUniformLocation(lineProg, "uTint"), 0.62, 0.70, 0.82, 1.0);
      gl.bindVertexArray(lineVao);
      gl.drawArrays(gl.LINES, 0, lineCount);
      gl.bindVertexArray(null);
    }

    /* The numbers go on top of everything with depth off, as the library puts
       them: a label belongs to the frame, not to the scene. */
    if (o.labels && txtProg && idxCount) {
      const tv = labelVerts(mvp, w, h, o.dom, info);
      if (tv.length) {
        gl.disable(gl.DEPTH_TEST);
        gl.useProgram(txtProg);
        gl.uniformMatrix4fv(gl.getUniformLocation(txtProg, "uMVP"), false, mvp);
        gl.uniform2f(gl.getUniformLocation(txtProg, "uPxToNdc"), 2 / w, 2 / h);
        gl.activeTexture(gl.TEXTURE0);
        gl.bindTexture(gl.TEXTURE_2D, txtTex);
        gl.uniform1i(gl.getUniformLocation(txtProg, "uFont"), 0);
        gl.bindVertexArray(txtVao);
        gl.bindBuffer(gl.ARRAY_BUFFER, txtVbo);
        gl.bufferData(gl.ARRAY_BUFFER, tv, gl.DYNAMIC_DRAW);
        gl.drawArrays(gl.TRIANGLES, 0, tv.length / 7);
        gl.bindVertexArray(null);
        gl.enable(gl.DEPTH_TEST);
      }
    }
  };

  /* Building the programs. The order and the attitude to failure are carried over
     from the page word for word: the surface has to build, everything else
     degrades one at a time, and each loss is named where it happens. */
  const init = () => {
    const p = gl.createProgram();
    gl.attachShader(p, compile(gl.VERTEX_SHADER, VS));
    gl.attachShader(p, compile(gl.FRAGMENT_SHADER, FS));
    gl.linkProgram(p);
    if (!gl.getProgramParameter(p, gl.LINK_STATUS))
      throw new Error(gl.getProgramInfoLog(p));
    prog = p;

    /* The background program is built the same way, and its failure is not
       fatal: without it the canvas keeps the flat clear colour and the plot
       still appears. A demo that shows the surface on the wrong backdrop is
       worth more than a demo that shows nothing. */
    try {
      const bp = gl.createProgram();
      gl.attachShader(bp, compile(gl.VERTEX_SHADER, BG_VS));
      gl.attachShader(bp, compile(gl.FRAGMENT_SHADER, BG_FS));
      gl.linkProgram(bp);
      if (gl.getProgramParameter(bp, gl.LINK_STATUS)) bgProg = bp;
    } catch (e) {
      bgProg = null;
    }

    /* The line program, and its failure is not fatal either: without it the
       plot loses its box and keeps its surface. */
    try {
      const lp = gl.createProgram();
      gl.attachShader(lp, compile(gl.VERTEX_SHADER, LINE_VS));
      gl.attachShader(lp, compile(gl.FRAGMENT_SHADER, LINE_FS));
      gl.linkProgram(lp);
      if (gl.getProgramParameter(lp, gl.LINK_STATUS)) {
        lineProg = lp;
        const segs = axesSegments();
        lineCount = segs.length / 3;
        lineVao = gl.createVertexArray();
        gl.bindVertexArray(lineVao);
        const lb = gl.createBuffer();
        gl.bindBuffer(gl.ARRAY_BUFFER, lb);
        gl.bufferData(gl.ARRAY_BUFFER, segs, gl.STATIC_DRAW);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 12, 0);
        gl.bindVertexArray(null);
      }
    } catch (e) {
      lineProg = null;
    }

    /* The text program. Failing it costs the numbers on the axes and nothing
       else, so it degrades the same way the other two do. */
    try {
      const tp = gl.createProgram();
      gl.attachShader(tp, compile(gl.VERTEX_SHADER, TEXT_VS));
      gl.attachShader(tp, compile(gl.FRAGMENT_SHADER, TEXT_FS));
      gl.linkProgram(tp);
      if (gl.getProgramParameter(tp, gl.LINK_STATUS)) {
        txtProg = tp;
        /* One atlas row, seventeen glyphs across, one byte a texel. */
        const pix = new Uint8Array(GLYPH_N * GLYPH_W * GLYPH_H);
        for (let g = 0; g < GLYPH_N; g++)
        for (let row = 0; row < GLYPH_H; row++)
          for (let col = 0; col < GLYPH_W; col++)
            pix[row * (GLYPH_N * GLYPH_W) + g * GLYPH_W + col] =
            (FONT[g][row] >> (GLYPH_W - 1 - col)) & 1 ? 255 : 0;
        txtTex = gl.createTexture();
        gl.bindTexture(gl.TEXTURE_2D, txtTex);
        gl.pixelStorei(gl.UNPACK_ALIGNMENT, 1);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.R8, GLYPH_N * GLYPH_W, GLYPH_H, 0,
                gl.RED, gl.UNSIGNED_BYTE, pix);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.NEAREST);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
        gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
        txtVao = gl.createVertexArray();
        txtVbo = gl.createBuffer();
        gl.bindVertexArray(txtVao);
        gl.bindBuffer(gl.ARRAY_BUFFER, txtVbo);
        gl.enableVertexAttribArray(0);
        gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 28, 0);
        gl.enableVertexAttribArray(1);
        gl.vertexAttribPointer(1, 2, gl.FLOAT, false, 28, 12);
        gl.enableVertexAttribArray(2);
        gl.vertexAttribPointer(2, 2, gl.FLOAT, false, 28, 20);
        gl.bindVertexArray(null);
      }
    } catch (e) {
      txtProg = null;
    }

    vao = gl.createVertexArray();
    gl.bindVertexArray(vao);
    vbo = gl.createBuffer(); ebo = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.enableVertexAttribArray(0);
    gl.vertexAttribPointer(0, 3, gl.FLOAT, false, 24, 0);
    gl.enableVertexAttribArray(1);
    gl.vertexAttribPointer(1, 3, gl.FLOAT, false, 24, 12);
  };

  /* Loading the mesh. Bringing it to the unit box follows the library's own rule
     (RndUpload): the centre of the domain is subtracted, the sides are divided by
     the LARGER half-width and the height by half the span. The showcase got away
     with dividing by HALF because its domain is square and centred on zero; the
     builder's is not. */
  /* zref, when given, is the FROZEN scale of the relief: its middle and its
     span. Without it the mesh is normalised by its own extremes, and on the
     endless sheet the hills would then breathe with every step - the region
     changes, the extremes change, and the same hill is drawn to a different
     height. The library freezes it at the first mesh after a change of
     formula for exactly that reason. */
  const upload = (raw, idx, inf, zref) => {
    info = inf;
    const n = raw.length / 6;
    const cx = (raw[0] + raw[(n - 1) * 6]) / 2;
    const cy = (raw[1] + raw[(n - 1) * 6 + 1]) / 2;
    let half = Math.max(Math.abs(raw[(n - 1) * 6] - cx),
                        Math.abs(raw[(n - 1) * 6 + 1] - cy));
    if (half < 1e-12) half = 1;
    const zmid = zref ? zref[0] : (info[0] + info[1]) / 2;
    let span = zref ? zref[1] : (info[1] - info[0]);
    if (span < 1e-12) span = 1;
    const zh = span / 2;
    zMid = zmid;
    zSpan = span;
    const v = new Float32Array(raw.length);
    for (let i = 0; i < raw.length; i += 6) {
      v[i] = (raw[i] - cx) / half;
      v[i + 1] = (raw[i + 1] - cy) / half;
      v[i + 2] = (raw[i + 2] - zmid) / zh;
      v[i + 3] = raw[i + 3]; v[i + 4] = raw[i + 4]; v[i + 5] = raw[i + 5];
    }
    gl.bindVertexArray(vao);
    gl.bindBuffer(gl.ARRAY_BUFFER, vbo);
    gl.bufferData(gl.ARRAY_BUFFER, v, gl.STATIC_DRAW);
    gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, idx, gl.STATIC_DRAW);
    const side = info[2] | 0;
    const g = [];
    if (side > 1) {
      const step = Math.max(1, (side - 1) / 12 | 0);
      const finite = k => Number.isFinite(raw[k * 6 + 2]);
      for (let j = 0; j < side; j += step)
        for (let i = 0; i < side - 1; i++) {
          const a = j * side + i;
          if (finite(a) && finite(a + 1)) g.push(a, a + 1);
        }
      for (let i = 0; i < side; i += step)
        for (let j = 0; j < side - 1; j++) {
          const a = j * side + i;
          if (finite(a) && finite(a + side)) g.push(a, a + side);
        }
    }
    gridCount = g.length;
    if (gridCount > 0) {
      if (!gridEbo) gridEbo = gl.createBuffer();
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, gridEbo);
      gl.bufferData(gl.ELEMENT_ARRAY_BUFFER, new Uint32Array(g), gl.STATIC_DRAW);
      gl.bindBuffer(gl.ELEMENT_ARRAY_BUFFER, ebo);
    }
    idxCount = idx.length;
    return { half: half, centre: [cx, cy] };
  };

  init();
  return {
    upload: upload,
    draw: draw,
    half: 1,
    get ready() { return prog !== null; },
    get idxCount() { return idxCount; },
    get info() { return info; }
  };
}
