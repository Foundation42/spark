// Hand-authored replacement for the CMake-generated cmark_version.h.
// Mirrors what `configure_file(cmark_version.h.in ...)` would emit
// for cmark 0.31.2 — the version we vendored. Bump these in lockstep
// when the vendored tarball is updated.
#ifndef CMARK_VERSION_H
#define CMARK_VERSION_H

#define CMARK_VERSION ((0 << 16) | (31 << 8) | 2)
#define CMARK_VERSION_STRING "0.31.2"

#endif
