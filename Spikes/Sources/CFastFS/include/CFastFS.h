#ifndef CFASTFS_H
#define CFASTFS_H

#include <stdint.h>
#include <time.h>

/// One directory entry as returned by getattrlistbulk(2).
typedef struct {
    const char *name;        // valid only during the callback
    uint32_t objtype;        // VREG, VDIR, VLNK, ...
    uint32_t flags;          // st_flags (UF_HIDDEN, UF_IMMUTABLE, ...)
    uint64_t fileid;
    int64_t size;            // data fork logical length (files only)
    int64_t allocsize;       // allocated size (files only)
    struct timespec crtime;
    struct timespec modtime;
    struct timespec addedtime;
    uint32_t error;          // per-entry error (0 = ok)
} rf_entry;

typedef void (*rf_entry_cb)(const rf_entry *entry, void *ctx);

/// Enumerates `path` with getattrlistbulk. Returns 0 or an errno.
int rf_enumerate(const char *path, rf_entry_cb cb, void *ctx);

/// 1 if the volume containing `path` advertises VOL_CAP_INT_SEARCHFS, 0 if not, -errno on failure.
int rf_volume_supports_searchfs(const char *path);

typedef void (*rf_path_cb)(const char *path, void *ctx);

/// Catalog search for names containing `needle` on the volume mounted at `volume`.
/// Reports full paths (via fsgetpath). Returns 0 or an errno. `*matches` gets the total count.
int rf_searchfs(const char *volume, const char *needle, rf_path_cb cb, void *ctx, uint64_t *matches);

#endif
