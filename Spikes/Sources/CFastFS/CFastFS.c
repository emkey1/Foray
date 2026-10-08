#include "CFastFS.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/fsgetpath.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/vnode.h>
#include <unistd.h>

#define RF_BULK_BUFSIZE (256 * 1024)

static inline void take(void *dst, const char **cur, size_t n) {
    memcpy(dst, *cur, n);
    *cur += n;
}

int rf_enumerate(const char *path, rf_entry_cb cb, void *ctx) {
    int fd = open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (fd < 0) return errno;

    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.commonattr = ATTR_CMN_RETURNED_ATTRS | ATTR_CMN_NAME | ATTR_CMN_ERROR | ATTR_CMN_OBJTYPE |
                    ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_FLAGS | ATTR_CMN_FILEID |
                    ATTR_CMN_ADDEDTIME;
    al.fileattr = ATTR_FILE_ALLOCSIZE | ATTR_FILE_DATALENGTH;

    char *buf = malloc(RF_BULK_BUFSIZE);
    if (!buf) { close(fd); return ENOMEM; }

    int result = 0;
    for (;;) {
        int count = getattrlistbulk(fd, &al, buf, RF_BULK_BUFSIZE, FSOPT_PACK_INVAL_ATTRS);
        if (count < 0) { result = errno; break; }
        if (count == 0) break;

        const char *entry = buf;
        for (int i = 0; i < count; i++) {
            const char *cur = entry;
            uint32_t length;
            take(&length, &cur, sizeof length);

            attribute_set_t returned;
            take(&returned, &cur, sizeof returned);

            rf_entry e = {0};
            take(&e.error, &cur, sizeof e.error);  // ATTR_CMN_ERROR always follows RETURNED_ATTRS

            const char *nameRefPos = cur;
            attrreference_t nameRef;
            take(&nameRef, &cur, sizeof nameRef);
            e.name = nameRefPos + nameRef.attr_dataoffset;

            take(&e.objtype, &cur, sizeof e.objtype);
            take(&e.crtime, &cur, sizeof e.crtime);
            take(&e.modtime, &cur, sizeof e.modtime);
            take(&e.flags, &cur, sizeof e.flags);
            take(&e.fileid, &cur, sizeof e.fileid);
            take(&e.addedtime, &cur, sizeof e.addedtime);

            off_t alloc = 0, len = 0;
            take(&alloc, &cur, sizeof alloc);
            take(&len, &cur, sizeof len);
            if (returned.fileattr & ATTR_FILE_ALLOCSIZE) e.allocsize = alloc;
            if (returned.fileattr & ATTR_FILE_DATALENGTH) e.size = len;

            cb(&e, ctx);
            entry += length;
        }
    }
    free(buf);
    close(fd);
    return result;
}

int rf_volume_supports_searchfs(const char *path) {
    struct attrlist al = {0};
    al.bitmapcount = ATTR_BIT_MAP_COUNT;
    al.volattr = ATTR_VOL_INFO | ATTR_VOL_CAPABILITIES;
    struct {
        uint32_t length;
        vol_capabilities_attr_t caps;
    } __attribute__((aligned(4), packed)) reply;

    struct statfs sfs;
    if (statfs(path, &sfs) != 0) return -errno;
    if (getattrlist(sfs.f_mntonname, &al, &reply, sizeof reply, 0) != 0) return -errno;
    uint32_t valid = reply.caps.valid[VOL_CAPABILITIES_INTERFACES];
    uint32_t caps = reply.caps.capabilities[VOL_CAPABILITIES_INTERFACES];
    return (valid & VOL_CAP_INT_SEARCHFS) && (caps & VOL_CAP_INT_SEARCHFS) ? 1 : 0;
}

struct name_search_params {
    uint32_t size;
    attrreference_t ref;
    char name[PATH_MAX];
} __attribute__((packed));

int rf_searchfs(const char *volume, const char *needle, rf_path_cb cb, void *ctx, uint64_t *matches) {
    struct statfs sfs;
    if (statfs(volume, &sfs) != 0) return errno;

    size_t nlen = strlen(needle) + 1;
    if (nlen > PATH_MAX) return ENAMETOOLONG;

    struct name_search_params p1 = {0}, p2 = {0};
    p1.ref.attr_dataoffset = sizeof(attrreference_t);
    p1.ref.attr_length = (uint32_t)nlen;
    memcpy(p1.name, needle, nlen);
    p1.size = (uint32_t)(sizeof(uint32_t) + sizeof(attrreference_t) + ((nlen + 3) & ~3u));
    p2 = p1;

    struct attrlist ret = {0};
    ret.bitmapcount = ATTR_BIT_MAP_COUNT;
    ret.commonattr = ATTR_CMN_NAME | ATTR_CMN_FILEID;

    size_t bufsize = 256 * 1024;
    char *buf = malloc(bufsize);
    if (!buf) return ENOMEM;

    struct fssearchblock sb = {0};
    sb.returnattrs = &ret;
    sb.returnbuffer = buf;
    sb.returnbuffersize = bufsize;
    sb.maxmatches = 4096;
    sb.timelimit.tv_sec = 1;
    sb.searchparams1 = &p1;
    sb.sizeofsearchparams1 = p1.size;
    sb.searchparams2 = &p2;
    sb.sizeofsearchparams2 = p2.size;
    sb.searchattrs.bitmapcount = ATTR_BIT_MAP_COUNT;
    sb.searchattrs.commonattr = ATTR_CMN_NAME;

    struct searchstate state;
    unsigned int options = SRCHFS_START | SRCHFS_MATCHPARTIALNAMES | SRCHFS_MATCHFILES | SRCHFS_MATCHDIRS;
    uint64_t total = 0;
    int result = 0;
    char path[MAXPATHLEN];

    for (;;) {
        unsigned long n = 0;
        int rc = searchfs(sfs.f_mntonname, &sb, &n, 0x08000103 /* kTextEncodingUTF8-ish script code used by Apple samples */,
                          options, &state);
        int err = rc == 0 ? 0 : errno;
        if (rc != 0 && err != EAGAIN) { result = err; break; }

        const char *entry = buf;
        for (unsigned long i = 0; i < n; i++) {
            const char *cur = entry;
            uint32_t length;
            take(&length, &cur, sizeof length);
            attrreference_t nameRef;
            take(&nameRef, &cur, sizeof nameRef);  // name itself is unused; fsgetpath gives the full path
            uint64_t fileid;
            take(&fileid, &cur, sizeof fileid);
            ssize_t plen = fsgetpath(path, sizeof path, &sfs.f_fsid, fileid);
            if (plen > 0) cb(path, ctx);
            entry += length;
        }
        total += n;
        options &= ~SRCHFS_START;
        if (rc == 0) break;
    }
    free(buf);
    if (matches) *matches = total;
    return result;
}
