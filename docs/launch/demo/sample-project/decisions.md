File uploads are capped at 25 MB because our CDN rejects any object larger than
that with a 413 at the edge. Validate client-side before the upload starts.
Money is stored as integer cents, never floats, to avoid rounding drift.
