library(ggplot2)

#' Convert a plot object to a PNG data URI
#'
#' @param p The plot object; currently, plotly and ggplot2 are supported. Note
#'     that plotly requires Python, {reticulate}, and the PyPI packages {plotly}
#'     and {kaleido}.
plot_to_img_content <- function(p) {
  UseMethod("plot_to_img_content", p)
}

plot_to_img_content.plotly <- function(p) {
  # Create a temporary file
  tmp <- tempfile(fileext = ".png")
  on.exit(unlink(tmp))

  # Save the plot as an image
  save_image(p, tmp, width = 800, height = 600)
  elmer::content_image_file(tmp, resize = "high")
}

plot_to_img_content.ggplot <- function(p) {
  # Create a temporary file
  tmp <- tempfile(fileext = ".png")
  on.exit(unlink(tmp))

  ggsave(tmp, p, width = 800, height = 600, units = "px", dpi = 100)
  elmer::content_image_file(tmp, resize = "high")
}

explain_plot <- function(chat, p, model, ..., .ctx = NULL, session = getDefaultReactiveDomain()) {
  chat_id <- paste0("explain_plot_", sample.int(1e9, 1))
  # chat <- chat$clone()

  img_content <- plot_to_img_content(p)
  img_url <- paste0("data:", img_content@type, ";base64,", img_content@data)

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
    chat_ui(chat_id),
    size = "l",
    easyClose = TRUE,
    title = NULL,
    footer = NULL,
  ) |> tagAppendAttributes(style = "--bs-modal-margin: 1.75rem;"))

  session$onFlushed(function() {
    stream <- chat$stream_async(
      "Interpret this plot, which is based on the current state of the data (i.e. with filtering applied, if any). Try to make specific observations if you can, but be conservative in drawing firm conclusions and express uncertainty if you can't be confident.",
      img_content
    )
    chat_append(chat_id, stream)
  })

  observeEvent(session$input[[paste0(chat_id, "_user_input")]], {
    stream <- chat$stream_async(session$input[[paste0(chat_id, "_user_input")]])
    chat_append(chat_id, stream)
  })
}
