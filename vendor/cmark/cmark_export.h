// Hand-authored replacement for the CMake-generated cmark_export.h.
//
// cmark normally produces this via `generate_export_header` in its
// CMakeLists.txt — a portable shim around shared-vs-static visibility
// attributes (__attribute__((visibility("default"))) /
// __declspec(dllexport) / etc.). Since we vendor cmark as a STATIC
// archive linked into the host exe, all of those macros collapse to
// no-ops. Keeping the symbol names so cmark.h compiles unchanged.
#ifndef CMARK_EXPORT_H
#define CMARK_EXPORT_H

#define CMARK_EXPORT
#define CMARK_NO_EXPORT
#define CMARK_DEPRECATED(msg)
#define CMARK_DEPRECATED_EXPORT
#define CMARK_DEPRECATED_NO_EXPORT

#endif /* CMARK_EXPORT_H */
