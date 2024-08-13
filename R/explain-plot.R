library(ggplot2)
library(base64enc)
library(promises)
library(mirai)

#' Convert a plot object to a PNG data URI
#'
#' @param p The plot object; currently, plotly and ggplot2 are supported. Note
#'     that plotly requires Python, {reticulate}, and the PyPI packages {plotly}
#'     and {kaleido}.
plot_to_img_uri <- function(p) {
  UseMethod("plot_to_img_uri", p)
}

plot_to_img_uri.plotly <- function(p) {
  # Create a temporary file
  tmp <- tempfile(fileext = ".png")
  on.exit(unlink(tmp))

  # Save the plot as an image
  save_image(p, tmp, width = 800, height = 600)
  create_data_uri(tmp, "image/png")
}

plot_to_img_uri.ggplot <- function(p) {
  # Create a temporary file
  tmp <- tempfile(fileext = ".png")
  on.exit(unlink(tmp))

  ggsave(tmp, p, width = 800, height = 600, units = "px", dpi = 100)
  create_data_uri(tmp, "image/png")
}

create_data_uri <- function(filepath, content_type) {
  # Read the image and encode it to base64
  img_data <- readBin(filepath, "raw", file.info(filepath)$size)
  img_base64 <- base64encode(img_data)
  img_url <- paste0("data:", content_type, ";base64,", img_base64)
  img_url
}

explain_plot <- function(messages, p, ..., .ctx = NULL) {
  img_url <- plot_to_img_uri(p)

  new_message <- list(
    role = "user",
    content = list(
      list(
        type = "text",
        text = "Interpret this plot, which is based on the current state of the data (i.e. with filtering applied, if any). Try to make specific observations if you can, but be conservative in drawing firm conclusions and express uncertainty if you can't be confident."
      ),
      list(
        type = "image_url",
        image_url = list(url = img_url)
      )
    )
  )

  progress <- Progress$new()
  progress$set(
    message = "Examining plot...",
    value = NULL
  )

  mirai(
    msgs = c(messages, list(new_message)),
    {
      library(duckdb)
      library(DBI)
      library(here)
      source(here("R/query.R"), local = TRUE)

      conn <- dbConnect(duckdb(), dbdir = here("tips.duckdb"), read_only = TRUE)
      on.exit(dbDisconnect(conn))

      # update_dashboard is a no-op
      ctx = list(conn = conn, update_dashboard = \(query, title) {})

      query(msgs, .ctx = ctx)
    }
  ) |>
    
    finally(\() {
      progress$close()
    }) |>

    then(\(result) {
      completion <- result$completion
      response_md <- completion$choices[[1]]$message$content
      showModal(modalDialog(
        tags$button(
          type="button",
          class="btn-close d-block ms-auto mb-3",
          `data-bs-dismiss`="modal",
          aria_label="Close",
        ),
        tags$img(
          src = img_url,
          style = "max-width: min(100%, 400px);",
          class = "d-block border mx-auto mb-3"
        ),
        tags$div(style = "overflow-y: auto;",
          markdown(response_md)
        ),
        size = "l",
        easyClose = TRUE,
        title = NULL,
        footer = NULL,
      ) |> tagAppendAttributes(style = "--bs-modal-margin: 1.75rem;"))
    })
    
}
