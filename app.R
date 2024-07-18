library(shiny)
library(bslib)
library(fastmap)

source("chat.R", local = TRUE)
source("query.R", local = TRUE)

options(shiny.trace = T)

ui <- page_fill(
  chat_ui("chat", height = "100%", fill = TRUE)
)

server <- function(input, output, session) {
  # We could've just used a list here, but fastqueue has
  # a nicer looking API for adding new elements
  messages <- fastqueue()

  observeEvent(input$chat_user_input, {
    # Add user message to the chat history
    messages$add(
      list(role = "user", content = input$chat_user_input)
    )

    completion <- tryCatch(query(messages$as_list()),
      error = \(err) {
        err_msg <- list(
          role = "assistant",
          # TODO: Make sure error doesn't contain HTML
          content = paste0("**Error:** ", conditionMessage(err))
        )
        messages$add(err_msg)
        chat_append_message("chat", err_msg)
        NULL
      }
    )

    if (is.null(completion)) {
      # An error must've occurred
      return()
    }

    response_msg <- completion$choices[[1]]$message
    # print(response_msg)

    # Add response to the chat history
    messages$add(response_msg)

    # Show response in the UI
    chat_append_message("chat", response_msg)
  })
}

shinyApp(ui, server)
