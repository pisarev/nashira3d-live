# nashira3d-live

The showcase page for [Nashira3D](https://github.com/pisarev/nashira3d), a
library that draws three-dimensional surface plots straight from a formula.

The page is one file. There are no web fonts, no scripts, and no requests to
anyone else's servers, so it loads instantly and keeps working when they do
not.

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
