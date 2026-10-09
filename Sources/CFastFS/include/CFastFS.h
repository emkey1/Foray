#ifndef CFASTFS_H
#define CFASTFS_H

#include <membership.h>   // mbr_uid_to_uuid etc., for access lists (RFFileSystem)
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
    struct timespec chgtime;    // status change: also moves when xattrs (e.g. tags) change
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

// MARK: File operations (RFOperations)

/// Progress callback for rf_copy_file: bytes copied so far for this file. Return nonzero to stop
/// (the copy then fails with ECANCELED and the partial destination is removed).
typedef int (*rf_copy_progress_cb)(int64_t bytes_copied, void *ctx);

/// Copies one file, symlink or empty directory entry from `src` to `dst` with all metadata
/// (data, resource fork, xattrs, ACLs, flags, dates), cloning on APFS when possible (unless
/// `allow_clone` is 0) and keeping sparse files sparse. Never follows a symlink at `src` and never
/// overwrites `dst`. Returns 0 or an errno.
int rf_copy_file(const char *src, const char *dst, int allow_clone, rf_copy_progress_cb cb, void *ctx);

/// Copies a directory's own metadata (permissions, flags, xattrs, ACLs, dates) onto `dst`.
/// Call after its contents are copied, so the copied dates aren't disturbed. Returns 0 or an errno.
int rf_copy_directory_metadata(const char *src, const char *dst);

#endif
