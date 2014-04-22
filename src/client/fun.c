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
#include "fun.h"
#include "pgarchive.h"

#include "postgres.h"

#include "funcapi.h"
#include "miscadmin.h"
#include "utils/builtins.h"
#include "utils/memutils.h"

Datum       pginstall_platform(PG_FUNCTION_ARGS);
Datum       pginstall_available_extensions(PG_FUNCTION_ARGS);

PG_FUNCTION_INFO_V1(pginstall_platform);

Datum
pginstall_platform(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc   tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext per_query_ctx;
    MemoryContext oldcontext;
    PlatformData platform;
	Datum       values[3];
	bool        nulls[3];

    /* Fetch the list of available extensions */
    current_platform(&platform);

    /* check to see if caller supports us returning a tuplestore */
    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not " \
                        "allowed in this context")));

    /* Build a tuple descriptor for our result type */
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        elog(ERROR, "return type must be a row type");

    /* Build tuplestore to hold the result rows */
    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tupstore;
    rsinfo->setDesc = tupdesc;

    MemoryContextSwitchTo(oldcontext);

	memset(values, 0, sizeof(values));
	memset(nulls, 0, sizeof(nulls));

	/* os name */
	values[0] = CStringGetTextDatum(platform.os_name);

	/* os version */
	values[1] = CStringGetTextDatum(platform.os_version);

	/* arch */
	values[2] = CStringGetTextDatum(platform.arch);

	tuplestore_putvalues(tupstore, tupdesc, values, nulls);

	/* clean up and return the tuplestore */
    tuplestore_donestoring(tupstore);

    return (Datum) 0;

}

PG_FUNCTION_INFO_V1(pginstall_available_extensions);

Datum
pginstall_available_extensions(PG_FUNCTION_ARGS)
{
    ReturnSetInfo *rsinfo = (ReturnSetInfo *) fcinfo->resultinfo;
    TupleDesc   tupdesc;
    Tuplestorestate *tupstore;
    MemoryContext per_query_ctx;
    MemoryContext oldcontext;
    List *extensions = NIL;
    ListCell *lc;
    PlatformData platform;

    /* Fetch the list of available extensions */
    current_platform(&platform);

    if (pginstall_serve_from_archive_dir)
        extensions = list_available_extensions_in_archive_dir(&platform);

    /*
     * Don't duplicate extensions (based on shortname), keep only the local
     * cache one in case of duplicates.
     *
     * XXX: expensive algorithm, we might want to switch to using hash tables
     * here at some point.
     */
    if (pginstall_repository != NULL && strcmp(pginstall_repository, "") != 0)
    {
        List *repo_exts = list_available_extensions_on_repository(&platform);

        if (extensions == NIL)
            extensions = repo_exts;
        else
        {
            List *keep = NIL;
            ListCell *lc2;

            foreach(lc, repo_exts)
            {
                pginstall_extension *ext = (pginstall_extension *) lfirst(lc);

                bool keep_this_one = true;

                foreach(lc2, extensions)
                {
                    pginstall_extension *ext2 =
                        (pginstall_extension *) lfirst(lc2);

                    if (strcmp(ext->shortname, ext2->shortname) == 0)
                    {
                        keep_this_one = false;
                        break;
                    }
                    if (keep_this_one)
                        keep = lappend(keep, ext);
                }
            }
            extensions = list_concat(extensions, keep);
        }
    }

    /* check to see if caller supports us returning a tuplestore */
    if (rsinfo == NULL || !IsA(rsinfo, ReturnSetInfo))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("set-valued function called in context that cannot accept a set")));
    if (!(rsinfo->allowedModes & SFRM_Materialize))
        ereport(ERROR,
                (errcode(ERRCODE_FEATURE_NOT_SUPPORTED),
                 errmsg("materialize mode required, but it is not " \
                        "allowed in this context")));

    /* Build a tuple descriptor for our result type */
    if (get_call_result_type(fcinfo, NULL, &tupdesc) != TYPEFUNC_COMPOSITE)
        elog(ERROR, "return type must be a row type");

    /* Build tuplestore to hold the result rows */
    per_query_ctx = rsinfo->econtext->ecxt_per_query_memory;
    oldcontext = MemoryContextSwitchTo(per_query_ctx);

    tupstore = tuplestore_begin_heap(true, false, work_mem);
    rsinfo->returnMode = SFRM_Materialize;
    rsinfo->setResult = tupstore;
    rsinfo->setDesc = tupdesc;

    MemoryContextSwitchTo(oldcontext);

    foreach(lc, extensions)
    {
        pginstall_extension *ext = (pginstall_extension *) lfirst(lc);

        Datum       values[5];
        bool        nulls[5];

        memset(values, 0, sizeof(values));
        memset(nulls, 0, sizeof(nulls));

        /* id */
        if (ext->id == -1)
            nulls[0] = true;
        else
            values[0] = Int64GetDatumFast(ext->id);

        /* shortname */
        values[1] = CStringGetTextDatum(ext->shortname);

        /* fullname */
        if (ext->fullname == NULL)
            nulls[2] = true;
        else
            values[2] = CStringGetTextDatum(ext->fullname);

        /* uri */
        values[3] = CStringGetTextDatum(ext->uri);

        /* description */
        if (ext->description == NULL)
            nulls[4] = true;
        else
            values[4] = CStringGetTextDatum(ext->description);

        tuplestore_putvalues(tupstore, tupdesc, values, nulls);
    }

    /* clean up and return the tuplestore */
    tuplestore_donestoring(tupstore);

    return (Datum) 0;
}

