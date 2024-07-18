get_current_time <- function(tz = NULL) {
  if (is.null(tz)) {
    tz <- "UTC"
  }
  as.POSIXct(Sys.time(), tz)
}
