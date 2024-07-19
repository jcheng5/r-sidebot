library(duckdb)
library(DBI)
library(here)

db_path <- here("tips.duckdb")

# Delete if exists
if (file.exists(db_path)) {
  unlink(db_path)
}

# Load tips.csv into a table named `tips`
conn <- dbConnect(duckdb(), dbdir = db_path)
duckdb_read_csv(conn, "tips", here("tips.csv"))
dbDisconnect(conn)
