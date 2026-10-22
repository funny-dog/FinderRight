#ifndef C_ARCHIVE_SHIM_H
#define C_ARCHIVE_SHIM_H

#include <sys/types.h>
#include <sys/stat.h>
#include <stdint.h>
#include <stddef.h>
#include <time.h>

#if __has_include(<archive.h>) && __has_include(<archive_entry.h>)
#include <archive.h>
#include <archive_entry.h>
#else
/* Some macOS SDKs omit libarchive headers; declare only the C API used here. */

#define ARCHIVE_EOF 1
#define ARCHIVE_OK 0
#define ARCHIVE_WARN (-20)

#define AE_IFMT 0170000
#define AE_IFLNK 0120000
#define AE_IFDIR 0040000

typedef struct archive ARCHIVE;
typedef struct archive_entry ARCHIVE_ENTRY;

typedef ssize_t (*archive_read_callback)(struct archive *, void *_client_data, const void **_buffer);
typedef int64_t (*archive_skip_callback)(struct archive *, void *_client_data, int64_t request);
typedef int64_t (*archive_seek_callback)(struct archive *, void *_client_data, int64_t request, int whence);
typedef int (*archive_open_callback)(struct archive *, void *_client_data);
typedef int (*archive_close_callback)(struct archive *, void *_client_data);

struct archive *archive_read_new(void);
int archive_read_support_format_tar(struct archive *);
int archive_read_support_format_7zip(struct archive *);
int archive_read_support_format_rar(struct archive *);
int archive_read_support_format_rar5(struct archive *);

int archive_read_support_filter_none(struct archive *);
int archive_read_support_filter_gzip(struct archive *);
int archive_read_support_filter_xz(struct archive *);

int archive_read_set_seek_callback(struct archive *, archive_seek_callback seeker);

int archive_read_open2(struct archive *,
                       void *client_data,
                       archive_open_callback opener,
                       archive_read_callback reader,
                       archive_skip_callback skipper,
                       archive_close_callback closer);

int archive_read_next_header(struct archive *, struct archive_entry **);
int archive_read_free(struct archive *);

const char *archive_error_string(struct archive *);
int archive_errno(struct archive *);
int archive_read_has_encrypted_entries(struct archive *);
int64_t archive_filter_bytes(struct archive *, int);

const char *archive_entry_pathname(struct archive_entry *);
const char *archive_entry_pathname_utf8(struct archive_entry *);
mode_t archive_entry_filetype(struct archive_entry *);
int archive_entry_size_is_set(struct archive_entry *);
int64_t archive_entry_size(struct archive_entry *);
int archive_entry_mtime_is_set(struct archive_entry *);
time_t archive_entry_mtime(struct archive_entry *);
long archive_entry_mtime_nsec(struct archive_entry *);
int archive_entry_is_encrypted(struct archive_entry *);

#endif // __has_include

#endif // C_ARCHIVE_SHIM_H
