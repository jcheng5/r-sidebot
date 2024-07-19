library(DBI)
library(jsonlite)

get_current_time <- function(tz = NULL) {
  if (is.null(tz)) {
    tz <- "UTC"
  }
  as.POSIXct(Sys.time(), tz)
}

query <- function(query, .ctx) {
  df <- dbGetQuery(.ctx$conn, query)
  df |> toJSON()
}
