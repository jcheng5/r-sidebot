# This is a stripped-down port of the ui.Chat feature in py-shiny. The main
# things it's missing are server-side state management, i.e. the py-shiny
# version will keep the list of messages for you, and will handle the
# trimming of the message history to fit within the context window; these
# are left for the caller to handle in the R version.

chat_deps <- htmltools::htmlDependency(
  "shiny-chat",
  "1.0.0",
  src = normalizePath("chat", mustWork = TRUE),
  script = "chat.js",
  stylesheet = "chat.css"
)

chat_ui <- function(
    id,
    placeholder = "Enter a message...",
    width = "min(680px, 100%)",
    height = "auto",
    fill = TRUE,
    ...) {
  tag("shiny-chat-container", list(
    id = id,
    style = htmltools::css(
      width = width,
      height = height
    ),
    placeholder = placeholder,
    fill = fill,
    chat_deps,
    ...
  ))
}

chat_append_message <- function(id, msg, chunk = FALSE, session = getDefaultReactiveDomain()) {
  if (identical(msg[["role"]], "system")) {
    return()
  }

  if (!isFALSE(chunk)) {
    msg_type <- "shiny-chat-append-message-chunk"
    if (chunk == "start") {
      chunk_type <- "message_start"
    } else if (chunk == "end") {
      chunk_type <- "message_end"
    } else {
      stop("Invalid chunk argument")
    }
  } else {
    msg_type <- "shiny-chat-append-message"
    chunk_type <- NULL
  }

  if (identical(class(msg[["content"]]), "character")) {
    content_type <- "markdown"
  } else {
    content_type <- "html"
  }

  msg <- list(
    content = msg[["content"]],
    role = msg[["role"]],
    content_type = content_type,
    chunk_type = chunk_type
  )

  session$sendCustomMessage("shinyChatMessage", list(
    id = id,
    handler = msg_type,
    obj = msg
  ))
}
