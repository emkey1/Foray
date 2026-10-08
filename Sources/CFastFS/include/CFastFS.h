#ifndef CFASTFS_H
#define CFASTFS_H

#include <stdint.h>
#include <time.h>

/// One directory entry as returned by getattrlistbulk(2). See DESIGN.md §5.4.
typedef struct {
    const char *name;           // UTF-8; valid only during the callback
    uint32_t objtype;           // VREG, VDIR, VLNK, ... (sys/vnode.h)
    uint32_t flags;             // st_flags: UF_HIDDEN, UF_IMMUTABLE, SF_DATALESS, ...
    uint32_t mode;              // permission bits (ATTR_CMN_ACCESSMASK)
    int32_t device;             // dev_t of the containing volume
    uint64_t fileid;
    int64_t size;               // logical data length (files only)
    int64_t allocsize;          // allocated bytes (files only)
    struct timespec crtime;
    struct timespec modtime;
    struct timespec addedtime;  // tv_sec == 0 when unknown
    uint16_t finderflags;       // FileInfo.finderFlags, host byte order (kHasBundle, kIsAlias, ...)
    uint8_t ismountpoint;       // directory is a mount point
    uint32_t error;             // per-entry errno (0 = ok)
} rf_entry;

/// Return nonzero to stop enumerating (rf_enumerate then returns ECANCELED).
typedef int (*rf_entry_cb)(const rf_entry *entry, void *ctx);

/// Enumerates the directory at `path`. Returns 0 or an errno.
int rf_enumerate(const char *path, rf_entry_cb cb, void *ctx);

/// Same attributes for a single item (used to re-stat after change events). Returns 0 or an errno.
int rf_stat(const char *path, rf_entry_cb cb, void *ctx);

#endif
