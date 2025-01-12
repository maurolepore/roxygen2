# Processed first
ns_tags_import <- c(
  "import",
  "importFrom",
  "importClassesFrom",
  "importMethodsFrom",
  "useDynLib",
  "rawNamespace"
)
ns_tags <- c(
  ns_tags_import,
  "evalNamespace",
  "export",
  "exportClass",
  "exportMethod",
  "exportS3Method",
  "exportPattern"
)

#' Roclet: make `NAMESPACE`
#'
#' @description
#' This roclet automates the production of a `NAMESPACE` file, which controls
#' the functions imported and exported by your package, as described in
#' [Writing R extensions](https://cran.r-project.org/doc/manuals/r-release/R-exts.html).
#'
#' The `NAMESPACE` is generated in two passes: the first generates only
#' import directives (because this can be computed without evaluating package
#' code), and the second generates everything (after the package has been
#' loaded).
#'
#' See `vignette("namespace")` for details.
#'
#' @family roclets
#' @export
#' @eval tag_aliases(roclet_tags.roclet_namespace)
#' @examples
#' # The most common namespace tag is @@export, which declares that a function
#' # is part of the external interface of your package
#' #' @export
#' foofy <- function(x, y, z) {
#' }
#'
#' # You'll also often find global imports living in a file called
#' # R/{package}-package.R.
#' #' @@importFrom magrittr %>%
#' #' @@import rlang
#' NULL
namespace_roclet <- function() {
  roclet("namespace")
}

#' @export
roclet_preprocess.roclet_namespace <- function(x,
                                               blocks,
                                               base_path,
                                               global_options = list()) {

  lines <- unlist(lapply(blocks, block_to_ns, tag_set = ns_tags_import)) %||% character()
  lines <- sort_c(unique(lines))

  NAMESPACE <- file.path(base_path, "NAMESPACE")
  if (purrr::is_empty(lines) && !made_by_roxygen(NAMESPACE)) {
    return(x)
  }

  results <- c(made_by("#"), lines)
  write_if_different(NAMESPACE, results, check = FALSE)

  invisible(x)
}


#' @export
roclet_process.roclet_namespace <- function(x,
                                            blocks,
                                            env,
                                            base_path,
                                            global_options = list()) {

  ns <- unlist(lapply(blocks, block_to_ns, env = env)) %||%
    character()
  sort_c(unique(ns))
}

#' @export
roclet_tags.roclet_namespace <- function(x) {
  list(
    evalNamespace = tag_code,
    export = tag_words_line,
    exportClass = tag_words(1),
    exportS3Method = tag_words(min = 0, max = 2),
    exportMethod = tag_words(1),
    exportPattern = tag_words(1),
    import = tag_words(1),
    importClassesFrom = tag_words(2),
    importFrom = tag_words(2),
    importMethodsFrom = tag_words(2),
    rawNamespace = tag_code,
    useDynLib = tag_words(1)
  )
}

block_to_ns <- function(block, env, tag_set = ns_tags) {
  tags <- intersect(names(block), tag_set)
  lapply(tags, ns_process_tag, block = block, env = env)
}

ns_process_tag <- function(tag_name, block, env) {
  f <- if (tag_name == "evalNamespace") {
    function(tag, block) ns_evalNamespace(tag, block, env)
  } else {
    get(paste0("ns_", tag_name), mode = "function")
  }
  tags <- block[names(block) == tag_name]

  lapply(tags, f, block = block)
}

#' @export
roclet_output.roclet_namespace <- function(x, results, base_path, ...) {
  NAMESPACE <- file.path(base_path, "NAMESPACE")
  results <- c(made_by("#"), results)

  # Always check for roxygen2 header before overwriting NAMESPACE (#436),
  # even when running for the first time
  write_if_different(NAMESPACE, results, check = TRUE)

  NAMESPACE
}

#' @export
roclet_clean.roclet_namespace <- function(x, base_path) {
  NAMESPACE <- file.path(base_path, "NAMESPACE")
  if (made_by_roxygen(NAMESPACE)) {
    unlink(NAMESPACE)
  }
}

# Functions that take complete block and return NAMESPACE lines
ns_export <- function(tag, block) {
  if (identical(tag, "")) {
    # FIXME: check for empty exports (i.e. no name)
    default_export(attr(block, "object"), block)
  } else {
    export(tag)
  }
}
default_export <- function(x, block) UseMethod("default_export")
#' @export
default_export.s4class   <- function(x, block) export_class(x$value@className)
#' @export
default_export.s4generic <- function(x, block) export(x$value@generic)
#' @export
default_export.s4method  <- function(x, block) export_s4_method(x$value@generic)
#' @export
default_export.s3method  <- function(x, block) export_s3_method(attr(x$value, "s3method"))
#' @export
default_export.rcclass   <- function(x, block) export_class(x$value@className)
#' @export
default_export.default   <- function(x, block) export(x$alias)
#' @export
default_export.NULL      <- function(x, block) export(block$name)

ns_exportClass       <- function(tag, block) export_class(tag)
ns_exportMethod      <- function(tag, block) export_s4_method(tag)
ns_exportPattern     <- function(tag, block) one_per_line("exportPattern", tag)
ns_import            <- function(tag, block) one_per_line("import", tag)
ns_importFrom        <- function(tag, block) repeat_first("importFrom", tag)
ns_importClassesFrom <- function(tag, block) repeat_first("importClassesFrom", tag)
ns_importMethodsFrom <- function(tag, block) repeat_first("importMethodsFrom", tag)

ns_exportS3Method    <- function(tag, block) {
  obj <- attr(block, "object")

  if (length(tag) < 2 && !inherits(obj, "s3method")) {
    block_warning(block,
      "`@exportS3Method` and `@exportS3Method generic` must be used with an S3 method"
    )
    return()
  }

  if (identical(tag, "")) {
    method <- attr(obj$value, "s3method")
  } else if (length(tag) == 1) {
    method <- c(tag, attr(obj$value, "s3method")[[2]])
  } else {
    method <- tag
  }

  export_s3_method(method)
}


ns_useDynLib         <- function(tag, block) {
  if (length(tag) == 1) {
    return(paste0("useDynLib(", auto_quote(tag), ")"))
  }

  if (any(grepl(",", tag))) {
    # If there's a comma in list, don't quote output. This makes it possible
    # for roxygen2 to support other NAMESPACE forms not otherwise mapped
    args <- paste0(tag, collapse = " ")
    paste0("useDynLib(", args, ")")
  } else {
    repeat_first("useDynLib", tag)
  }
}
ns_rawNamespace  <- function(tag, block) tag
ns_evalNamespace <- function(tag, block, env) {
  block_eval(tag, block, env, "@evalNamespace")
}

# Functions used by both default_export and ns_* functions
export           <- function(x) one_per_line("export", x)
export_class     <- function(x) one_per_line("exportClasses", x)
export_s4_method <- function(x) one_per_line("exportMethods", x)
export_s3_method <- function(x) {
  args <- paste0(auto_backtick(x), collapse = ",")
  paste0("S3method(", args, ")")
}

# Helpers -----------------------------------------------------------------

one_per_line <- function(name, x) {
  paste0(name, "(", auto_backtick(x), ")")
}
repeat_first <- function(name, x) {
  paste0(name, "(", auto_backtick(x[1]), ",", auto_backtick(x[-1]), ")")
}
