/* The Nashira3D engine in a browser - ONE for every page of the site.
   ---------------------------------------------------------------------
   This is the library itself: nsh_surface.pas and the same formula parser,
   compiled to wasm32-wasip1. A page parses nothing and computes nothing - it
   asks for a mesh and gets vertices, indices and a summary.

   The WASI shim lives here as well. The module is built as a reactor: it has
   _initialize, it never exits and does not pretend to be a process, so the shim
   has nothing to act out - only a clock and random bytes are wanted.
   --------------------------------------------------------------------- */

const OK = 0, BADF = 8, NOSUP = 58;

function shim(memRef) {
  const view = () => new DataView(memRef.mem.buffer);
  const zero2 = (a, b) => {
    const v = view();
    v.setUint32(a, 0, true);
    v.setUint32(b, 0, true);
    return OK;
  };
  return {
    args_get: () => OK, args_sizes_get: zero2,
    environ_get: () => OK, environ_sizes_get: zero2,
    clock_time_get: (i, p, o) => {
      view().setBigUint64(o, BigInt(Math.round(performance.now() * 1e6)), true);
      return OK;
    },
    fd_close: () => BADF, fd_fdstat_get: () => BADF, fd_filestat_get: () => BADF,
    fd_filestat_set_size: () => BADF, fd_filestat_set_times: () => BADF,
    fd_prestat_get: () => BADF, fd_prestat_dir_name: () => BADF,
    fd_read: () => BADF, fd_readdir: () => BADF, fd_seek: () => BADF,
    fd_tell: () => BADF,
    fd_write: (f, i, n, w) => { view().setUint32(w, 0, true); return OK; },
    path_create_directory: () => NOSUP, path_filestat_get: () => NOSUP,
    path_filestat_set_times: () => NOSUP, path_open: () => NOSUP,
    path_readlink: () => NOSUP, path_remove_directory: () => NOSUP,
    path_rename: () => NOSUP, path_unlink_file: () => NOSUP,
    poll_oneoff: () => NOSUP,
    proc_exit: c => { throw new Error("the engine exited with " + c); },
    random_get: (p, n) => {
      crypto.getRandomValues(new Uint8Array(memRef.mem.buffer, p, n));
      return OK;
    }
  };
}

/* Fetch the engine and bring it up. The deadline and the lower bound on the
   size are not ornaments: without a deadline the page hangs in silence, and
   without a bound an error page from some proxy is accepted in place of the
   module, so the failure happens inside WebAssembly, where the reason cannot be
   read. */
export async function loadEngine(url, timeoutMs) {
  const ctl = new AbortController();
  const timer = setTimeout(() => ctl.abort(), timeoutMs || 30000);
  const memRef = { mem: null };
  try {
    const r = await fetch(url, { signal: ctl.signal, cache: "no-store" });
    if (!r.ok) throw new Error("the server answered " + r.status + " for " + url);
    const buf = await r.arrayBuffer();
    if (buf.byteLength < 1024 * 1024)
      throw new Error("the module came back as " + buf.byteLength +
                      " bytes, which is not the engine");
    const { instance } = await WebAssembly.instantiate(
      buf, { wasi_snapshot_preview1: shim(memRef) });
    const eng = instance.exports;
    memRef.mem = eng.memory;
    (eng._initialize || eng._start)();
    return makeEngine(eng, memRef);
  } finally {
    clearTimeout(timer);
  }
}

function makeEngine(eng, memRef) {
  const mem = () => memRef.mem;

  /* The reason for a refusal is asked of the engine itself: it alone knows what
     it did not like about the formula, and retelling that on the page's side
     would mean starting a second parser. */
  const note = () => {
    const p = eng.walloc(256), n = eng.note(p, 256);
    const s = new TextDecoder().decode(new Uint8Array(mem().buffer.slice(p, p + n)));
    eng.wfree(p);
    return s;
  };

  /* Build the mesh. Returns vertices, indices and a summary - or a refusal in
     words. The buffers are copied out AT ONCE: any later call is entitled to
     grow the module's memory, and a view onto the old one is detached without
     warning. */
  const build = (text, x0, x1, y0, y1, quality) => {
    const b = new TextEncoder().encode(text);
    const p = eng.walloc(b.length);
    new Uint8Array(mem().buffer, p, b.length).set(b);
    const t0 = performance.now();
    const cnt = eng.build(p, b.length, x0, x1, y0, y1, quality);
    const ms = performance.now() - t0;
    eng.wfree(p);
    if (cnt < 0) return { error: note() };
    return harvest(cnt, ms);
  };

  /* The same mesh on GIVEN sample lines. On the endless sheet they are not
     evenly spaced: nodes go where they are seen, dense underfoot and sparse
     towards the horizon. Choosing them is the camera's business and is done
     by the caller; the module only builds on what it is handed. */
  const buildAt = (text, xs, ys) => {
    const b = new TextEncoder().encode(text);
    const p = eng.walloc(b.length);
    new Uint8Array(mem().buffer, p, b.length).set(b);
    const xp = eng.walloc(xs.length * 8);
    const yp = eng.walloc(ys.length * 8);
    new Float64Array(mem().buffer, xp, xs.length).set(xs);
    new Float64Array(mem().buffer, yp, ys.length).set(ys);
    const t0 = performance.now();
    const cnt = eng.build_at(p, b.length, xp, xs.length, yp, ys.length);
    const ms = performance.now() - t0;
    eng.wfree(p);
    eng.wfree(xp);
    eng.wfree(yp);
    if (cnt < 0) return { error: note() };
    return harvest(cnt, ms);
  };

  /* Fetching the finished mesh is the same whichever way it was built, and it
     is written once: two copies of a memory walk part on the first edit, and
     the parting shows up as a torn picture rather than as an error. */
  const harvest = (cnt, ms) => {
    const vb = eng.walloc(cnt * 6 * 4);
    const got = eng.verts(vb, cnt * 6);
    const raw = new Float32Array(mem().buffer.slice(vb, vb + got * 4));
    eng.wfree(vb);

    const ib = eng.walloc(cnt * 8 * 4);
    const ic = eng.idx(ib, cnt * 8);
    const idx = new Uint32Array(mem().buffer.slice(ib, ib + ic * 4));
    eng.wfree(ib);

    const ip = eng.walloc(32);
    eng.info(ip);
    const info = Array.from(new Float64Array(mem().buffer.slice(ip, ip + 32)));
    eng.wfree(ip);

    return { raw: raw, idx: idx, info: info, count: cnt, tris: ic / 3, ms: ms };
  };

  return { build: build, buildAt: buildAt, note: note, raw: eng };
}
