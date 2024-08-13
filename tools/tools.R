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

update_dashboard <- function(query, title, .ctx) {
  # Verify that the query is OK
  dbGetQuery(.ctx$conn, query)
  
  .ctx$update_dashboard(query = query, title = title)
}

reset_dashboard <- function(.ctx) {
  .ctx$update_dashboard(query = "", title = "")
}