#include "CFastFS.h"

#include <errno.h>
#include <fcntl.h>
#include <libkern/OSByteOrder.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/vnode.h>
#include <unistd.h>

#define RF_BULK_BUFSIZE (256 * 1024)

// Requested attributes. With FSOPT_PACK_INVAL_ATTRS every requested *common* attribute is present
// in every record (zero-filled when invalid). Directory attributes appear only in directory records
// and file attributes only in non-directory records (verified on APFS, macOS 26). Order:
// ATTR_CMN_RETURNED_ATTRS, ATTR_CMN_ERROR (special: right after the returned set), then common
// attributes in bit order, then directory attributes, then file attributes.
static void make_attrlist(struct attrlist *al) {
    memset(al, 0, sizeof *al);
    al->bitmapcount = ATTR_BIT_MAP_COUNT;
    al->commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_ERROR | ATTR_CMN_NAME | ATTR_CMN_DEVID |
                     ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FNDRINFO |
                     ATTR_CMN_ACCESSMASK | ATTR_CMN_FLAGS | ATTR_CMN_FILEID | ATTR_CMN_ADDEDTIME;
    al->dirattr = ATTR_DIR_MOUNTSTATUS;
    al->fileattr = ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;
}

static inline void take(void *dst, const char **cur, size_t n) {
    memcpy(dst, *cur, n);
    *cur += n;
}

static inline int fits(const char *cur, const char *end, size_t n) { return cur + n <= end; }

/// Parses one record starting at `entry` (which begins with its uint32 length). Returns the length.
static uint32_t parse_record(const char *entry, rf_entry *e) {
    const char *cur = entry;
    uint32_t length;
    take(&length, &cur, sizeof length);
    const char *end = entry + length;

    attribute_set_t returned;
    take(&returned, &cur, sizeof returned);

    memset(e, 0, sizeof *e);
    take(&e->error, &cur, sizeof e->error);

    const char *name_ref_pos = cur;
    attrreference_t name_ref;
    take(&name_ref, &cur, sizeof name_ref);
    e->name = name_ref_pos + name_ref.attr_dataoffset;

    dev_t dev;
    take(&dev, &cur, sizeof dev);
    e->device = dev;
    take(&e->objtype, &cur, sizeof e->objtype);
    take(&e->crtime, &cur, sizeof e->crtime);
    take(&e->modtime, &cur, sizeof e->modtime);

    uint8_t finderinfo[32];
    take(finderinfo, &cur, sizeof finderinfo);
    uint16_t ff;
    memcpy(&ff, finderinfo + 8, sizeof ff);  // FileInfo/FolderInfo.finderFlags, big-endian
    e->finderflags = OSSwapBigToHostInt16(ff);

    take(&e->mode, &cur, sizeof e->mode);
    take(&e->flags, &cur, sizeof e->flags);
    take(&e->fileid, &cur, sizeof e->fileid);
    take(&e->addedtime, &cur, sizeof e->addedtime);
    if (!(returned.commonattr & ATTR_CMN_ADDEDTIME)) memset(&e->addedtime, 0, sizeof e->addedtime);

    if (e->objtype == VDIR) {
        uint32_t mountstatus = 0;
        if (fits(cur, end, sizeof mountstatus)) take(&mountstatus, &cur, sizeof mountstatus);
        e->ismountpoint = (returned.dirattr & ATTR_DIR_MOUNTSTATUS) && (mountstatus & DIR_MNTSTATUS_MNTPOINT);
    } else {
        off_t alloc = 0, len = 0;
        if (fits(cur, end, sizeof alloc)) take(&alloc, &cur, sizeof alloc);
        if (fits(cur, end, sizeof len)) take(&len, &cur, sizeof len);
        if (returned.fileattr & ATTR_FILE_ALLOCSIZE) e->allocsize = alloc;
        if (returned.fileattr & ATTR_FILE_DATALENGTH) e->size = len;
    }
    return length;
}

int rf_enumerate(const char *path, rf_entry_cb cb, void *ctx) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return errno;

    struct attrlist al;
    make_attrlist(&al);
    char *buf = malloc(RF_BULK_BUFSIZE);
    if (!buf) { close(fd); return ENOMEM; }

    int result = 0;
    for (;;) {
        int count = getattrlistbulk(fd, &al, buf, RF_BULK_BUFSIZE, FSOPT_PACK_INVAL_ATTRS);
        if (count < 0) { result = errno; break; }
        if (count == 0) break;
        const char *entry = buf;
        for (int i = 0; i < count; i++) {
            rf_entry e;
            entry += parse_record(entry, &e);
            if (cb(&e, ctx) != 0) { result = ECANCELED; goto done; }
        }
    }
done:
    free(buf);
    close(fd);
    return result;
}

int rf_stat(const char *path, rf_entry_cb cb, void *ctx) {
    struct attrlist al;
    make_attrlist(&al);
    // getattrlist doesn't support ATTR_CMN_ERROR; it reports failure through its return value.
    al.commonattr &= ~ATTR_CMN_ERROR;

    char buf[2048];
    if (getattrlist(path, &al, buf, sizeof buf, FSOPT_NOFOLLOW | FSOPT_PACK_INVAL_ATTRS) != 0) return errno;

    // Re-pack into the bulk layout (which has the error field) so one parser serves both.
    uint32_t length;
    memcpy(&length, buf, sizeof length);
    char *rec = malloc(length + sizeof(uint32_t) + 8);
    if (!rec) return ENOMEM;
    size_t head = sizeof(uint32_t) + sizeof(attribute_set_t);
    memcpy(rec, buf, head);
    uint32_t zero = 0;
    memcpy(rec + head, &zero, sizeof zero);
    // The name attrreference's offset is relative to its own position; both it and the data
    // shift by 4 bytes, so the relative offset stays valid.
    memcpy(rec + head + sizeof zero, buf + head, length - head);
    uint32_t newlen = length + sizeof zero;
    memcpy(rec, &newlen, sizeof newlen);

    rf_entry e;
    parse_record(rec, &e);
    cb(&e, ctx);
    free(rec);
    return 0;
}
