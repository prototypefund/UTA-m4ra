#' Cache weighted networks for routing query
#'
#' Uses a default cache location specified by `rappdirs::user_cache_dir()`. This
#' location can be over-ridden by specifying a local environment variable,
#' "M4RA_CACHE_DIR". The "city" parameter is only used as a prefix for the
#' cached networks.
#'
#' @param net A \pkg{silicate}, "SC", format object containing network data used
#' to generate weighted street networks.
#' @param city Name of city; only used to name cached network files.
#' @param quiet If `FALSE`, display progress information on screen.
#' @return A character vector of local locations of cached versions of the
#' variously weighted network representations used in the various routing
#' functions.
#' @family cache
#' @export
m4ra_weight_networks <- function (net, city, quiet = TRUE) {

    checkmate::assert_character (city)

    city <- gsub ("\\s+", "-", tolower (city))

    attr (net, "hash") <- m4ra_network_hash (net)

    wt_profiles <- c ("foot", "bicycle", "motorcar")

    filenames <- cache_networks (
        net,
        city = city,
        wt_profiles = wt_profiles,
        quiet = quiet
    )

    filenames <- c (filenames, cache_vertex_indices (city))

    return (filenames)
}

cache_networks <- function (net, city, wt_profiles, quiet = TRUE) {

    hash <- m4ra_network_hash (net)

    cache_dir <- fs::path (m4ra_cache_dir (), city)
    if (!dir.exists (cache_dir)) {
        dir.create (cache_dir, recursive = TRUE)
    }

    filenames <- fs::dir_ls (cache_dir, regexp = "\\-(foot|bicycle|motorcar)\\-")
    filenames <- filenames [which (!grepl ("\\-gtfs\\-", filenames))]
    filenames <- filenames [which (!grepl ("\\-vert\\-index\\-", filenames))]

    cache_flag <- fs::path (
        cache_dir,
        paste0 ("m4ra-", city, "-", hash, "-done")
    )

    if (fs::file_exists (cache_flag)) {
        return (filenames)
    }

    writeLines ("done", cache_flag)

    for (w in wt_profiles) {

        if (!quiet) {
            cli::cli_alert_info (cli::col_blue (
                "Weighting network with '{w}' profile"
            ))
        }
        if (w == "motorcar") {
            f <- write_wt_profile (traffic_lights = 16, turn = 1)
            f_new <- fs::path (cache_dir, "wt_profile.json")
            if (!fs::file_exists (f_new)) {
                fs::file_copy (f, f_new)
            }
            fs::file_delete (f)

            net_w <- dodgr::weight_streetnet (
                net,
                wt_profile = w,
                wt_profile_file = f_new,
                turn_penalty = TRUE
            )
        } else {
            net_w <- dodgr::weight_streetnet (net, wt_profile = w)
            attr (net_w, "wt_profile") <- w
        }

        # Update hash from 'dodgr' value which uses random edge IDs to
        # reproducible value based on OSM 'object_' columns:
        attr (net_w, "hash") <- get_hash (net_w, force = TRUE)

        filenames <- c (
            filenames,
            m4ra_cache_network (net_w, city = city, mode = w)
        )

        if (!quiet) {
            cli::cli_alert_success (cli::col_green (
                "Weighted network with '{w}' profile"
            ))
        }
    }

    return (filenames)
}

cache_vertex_indices <- function (city) {

    cache_dir <- fs::path (m4ra_cache_dir (), city)

    # Then cache the indices needed to match vertices between the different
    # networks:
    graph_f <- m4ra_load_cached_network (city, mode = "foot", contracted = TRUE)
    v_f <- m4ra_vertices (graph_f, city)
    hash_f <- substring (get_hash (graph_f), 1, 6)
    graph_b <- m4ra_load_cached_network (city, mode = "bicycle", contracted = TRUE)
    v_b <- m4ra_vertices (graph_b, city)
    hash_b <- substring (get_hash (graph_b), 1, 6)
    graph_m <- m4ra_load_cached_network (city, mode = "motorcar", contracted = TRUE)
    v_m <- m4ra_vertices (graph_m, city)
    hash_m <- substring (get_hash (graph_m), 1, 6)

    modes <- c ("foot", "bicycle", "motorcar")

    flist <- NULL

    for (m in modes) {
        v1 <- get (paste0 ("v_", substring (m, 1, 1)))
        hash1 <- get (paste0 ("hash_", substring (m, 1, 1)))
        for (n in modes [which (!modes == m)]) {
            v2 <- get (paste0 ("v_", substring (n, 1, 1)))
            hash2 <- get (paste0 ("hash_", substring (n, 1, 1)))
            fname <- fs::path (
                cache_dir,
                paste0 (
                    "m4ra-",
                    city,
                    "-vert-index-",
                    m,
                    "-",
                    n,
                    "-",
                    hash1,
                    "-",
                    hash2,
                    ".Rds"
                )
            )
            if (!fs::file_exists (fname)) {
                index <- dodgr::match_points_to_verts (v1, v2 [, c ("x", "y")])
                saveRDS (index, fname)
            }
            flist <- c (flist, fname)
        }
    }

    return (flist)
}

load_vert_index <- function (city, mode1, mode2) {

    cache_dir <- fs::path (m4ra_cache_dir (), city)
    flist <- fs::dir_ls (cache_dir, regexp = "\\-vert\\-index\\-")
    f <- grep (paste0 ("\\-", mode1, "\\-", mode2, "\\-"), flist, value = TRUE)
    readRDS (f)
}

write_wt_profile <- function (traffic_lights = 1, turn = 2) {

    f <- fs::path (fs::path_temp (), "wt_profile.json")
    dodgr::write_dodgr_wt_profile (f)

    w <- readLines (f)

    p <- grep ("\"penalties\"\\:\\s", w)
    m <- grep ("\"motorcar\"", w)
    m <- m [which (m > p) [1]]
    tl <- grep ("\"traffic_lights\"", w)
    tl <- tl [which (tl > m) [1]]
    tu <- grep ("\"turn\"", w)
    tu <- tu [which (tu > m) [1]]

    w [tl] <- gsub (
        "[0-9]*\\,$",
        paste0 (traffic_lights, ","),
        w [tl],
        fixed = FALSE
    )
    w [tu] <- gsub (
        "[0-9]*(\\.[0-9])\\,$",
        paste0 (turn, ","),
        w [tu],
        fixed = FALSE
    )

    writeLines (w, f)

    return (f)
}

#' Cache a directory full of street networks for routing queries
#'
#' This function runs of a directory which contain a number of \pkg{silicate} or
#' `sc`-formatted street networks, generated with the `dodgr_streetnet_sc`
#' function of the \pkg{dodgr} package. The function uses a default cache
#' location specified by `rappdirs::user_cache_dir()`. This location can be
#' over-ridden by specifying a local environment variable, "M4RA_CACHE_DIR".
#'
#' @param net_dir Path of local directory containing 'sc'-format street
#' networks.
#' @param remove_these Names of any 'sc'-format files which should not be
#' converted into weighted network form.
#' @return A character vector of local locations of cached versions of the
#' variously weighted network representations used in the various routing
#' functions.
#' @family cache
#' @export
m4ra_batch_weight_networks <- function (net_dir, remove_these = NULL) {

    flist <- fs::dir_ls (net_dir, regexp = "\\.Rds")
    cities <- gsub ("\\-sc.*$", "", flist) # nolint
    cities <- cities [which (!cities %in% remove_these)]

    out <- NULL

    count <- 1
    for (ci in cities) {

        city <- ifelse (
            grepl ("^san\\-", ci),
            ci,
            gsub ("(\\-|\\s).*$", "", ci)
        )

        cli::cli_h2 (paste0 (
            cli::col_green (ci), " [", count, " / ", length (cities), "]"
        ))
        count <- count + 1

        f <- grep (city, flist, value = TRUE, fixed = TRUE)
        if (length (f) != 1L) {
            stop ("Error determining network file for [", city, "]")
        }

        net <- readRDS (f)
        filenames <- m4ra_weight_networks (
            net,
            city = city,
            quiet = FALSE
        )

        out <- c (out, filenames)
    }

    return (out)
}
