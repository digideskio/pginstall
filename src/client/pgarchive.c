/* PostgreSQL Extension Installer -- Dimitri Fontaine
 *
 * Author: Dimitri Fontaine <dimitri@2ndQuadrant.fr>
 * Licence: PostgreSQL
 * Copyright Dimitri Fontaine, 2011-2014
 *
 * For a description of the features see the README.md file from the same
 * distribution.
 */

#include "communicate.h"
#include "pgarchive.h"
#include "pginstall.h"
#include "platform.h"
#include "utils.h"

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include "postgres.h"

static int copy_data(struct archive *ar, struct archive *aw);

static char *escape_filename(const char *str);

/*
 * At CREATE EXTENSION time we check if the extension is already available,
 * which is driven by the presence of its control file on disk.
 *
 * If the extension is not already available, we ask the repository server for
 * it, and unpack received binary archive to the right place.
 *
 * TODO: actually talk to the repository server. Current prototype version
 * directly uses the local archive cache.
 */
void
download_and_unpack_archive(const char *extname)
{
    PlatformData platform;
    char *control_filename = get_extension_control_filename(extname);
    char *archive_filename;

    /*
     * No cache, download again each time asked: any existing control file for
     * the extension could be one we left behind from a previous version of the
     * extension's archive.
     *
     * This also means that if an extension is already provided by the
     * operating system, by installing pginstall you give preference to
     * pginstall builds.
     */
    current_platform(&platform);
    archive_filename = psprintf("%s/%s--%s--%s--%s--%s.tar.gz",
                                pginstall_archive_dir,
                                extname,
                                PG_VERSION,
                                escape_filename(platform.os_name),
                                escape_filename(platform.os_version),
                                escape_filename(platform.arch));

    /* Always try to download the newest known archive file */
    download_archive(archive_filename, extname, &platform);

    /*
     * Even if we didn't find any extension's archive file for our platform on
     * the repository server, it could be that the extension is available
     * locally either through the OS packages or maybe a local developer setup
     * (make install).
     *
     * In case when when extension control file still doesn't exists after
     * we've been communicating with the repository server, PostgreSQL will
     * issue its usual error message about a missing control file.
     */
    if (access(archive_filename, R_OK) == 0)
    {
        extract(extname, archive_filename);

        /* now rewrite the control file to "relocate" the extension */
        rewrite_control_file(extname, control_filename);
    }
    return;
}

/*
 * Given a filename read within an extension archive, compute where to extract
 * the associated data.
 *
 * The main control file is named "extname.control", it is to be extracted in
 * pginstall_control_dir.
 *
 * Other files are named "extname/<path>" and are to be extracted in
 * pginstall_extension_dir/extname/<path>.
 */
static char *
compute_target_path(const char *filename,
                    const char *control_filename,
                    int control_filename_len)
{
    if (strncmp(filename, control_filename, control_filename_len) == 0)
        return psprintf("%s/%s", pginstall_control_dir, filename);
    else
        return psprintf("%s/%s", pginstall_extension_dir, filename);
}

/*
 * The main archive extract function, loops over the archive entries and unpack
 * them at the right place.
 */
void
extract(const char *extname, const char *filename)
{
    struct archive *a;
    struct archive *ext;
    struct archive_entry *entry;
    int flags = ARCHIVE_EXTRACT_TIME;
    int r;

    char *control_filename = psprintf("%s.control", extname);
    int cflen = strlen(control_filename);

    a = archive_read_new();
    ext = archive_write_disk_new();
    archive_write_disk_set_options(ext, flags);

    /*
     * Do we care enough about the .so size to limit ourselves here? We might
     * want to reconsider and use archive_read_support_format_all() and
     * archive_read_support_filter_all() rather than just tar.gz.
     */
    archive_read_support_format_tar(a);
    archive_read_support_filter_gzip(a);

    if ((archive_read_open_filename(a, filename, 10240)))
        ereport(ERROR,
                (errcode(ERRCODE_INVALID_PARAMETER_VALUE),
                 errmsg("Failed to open archive \"%s\"", filename),
                 errdetail("%s", archive_error_string(a))));

    elog(DEBUG1, "Unpacking archive \"%s\"", filename);

    for (;;)
    {
        char *path;
        struct archive_entry *target;

        r = archive_read_next_header(a, &entry);
        if (r == ARCHIVE_EOF)
            break;

        if (r != ARCHIVE_OK)
            ereport(ERROR,
                    (errcode(ERRCODE_UNDEFINED_FILE),
                     errmsg("%s", archive_error_string(a))));

        target = archive_entry_clone(entry);
        path   = (char *)archive_entry_pathname(target);
        path   = (char *)compute_target_path(path, control_filename, cflen);
        archive_entry_set_pathname(target, path);

        elog(DEBUG1, "Extracting \"%s\" to \"%s\"",
             archive_entry_pathname(entry), path);

        r = archive_write_header(ext, target);

        if (r != ARCHIVE_OK)
            ereport(WARNING,
                    (errcode(ERRCODE_IO_ERROR),
                     errmsg("%s", archive_error_string(ext))));
        else
        {
            copy_data(a, ext);
            r = archive_write_finish_entry(ext);
            if (r != ARCHIVE_OK)
                ereport(ERROR,
                        (errcode(ERRCODE_IO_ERROR),
                         errmsg("%s", archive_error_string(ext))));
        }
        archive_entry_free(target);
    }

    archive_read_close(a);
    archive_read_free(a);
}

static int
copy_data(struct archive *ar, struct archive *aw)
{
    int r;
    const void *buff;
    size_t size;
#if ARCHIVE_VERSION >= 3000000
    int64_t offset;
#else
    off_t offset;
#endif

    for (;;)
    {
        r = archive_read_data_block(ar, &buff, &size, &offset);

        if (r == ARCHIVE_EOF)
            return ARCHIVE_OK;

        if (r != ARCHIVE_OK)
            return r;

        r = archive_write_data_block(aw, buff, size, offset);

        if (r != ARCHIVE_OK)
        {
            ereport(WARNING,
                    (errcode(ERRCODE_IO_ERROR),
                     errmsg("%s", archive_error_string(aw))));
            return r;
        }
    }
}

/*
 * Our platform details might include non filename compatible characters, such
 * as spaces. We clean up the name components here.
 *
 * Currently only handles space-to-underscore conversion, so we know the length
 * of the result string to be the same as which of the source string.
 */
static char *
escape_filename(const char *str)
{
    int i, len = strlen(str);
    char *result = pstrdup(str);

    for(i=0; i<len; i++)
    {
        if (result[i] == ' ')
            result[i] = '_';
    }
    return result;
}
