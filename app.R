library(shiny)
library(bslib)

source("chat.R", local = TRUE)
source("query.R", local = TRUE)

options(shiny.trace = T)

ui <- page_fill(
  chat_ui("chat", height = "100%", fill = TRUE)
)

server <- function(input, output, session) {
  messages <- list()

  observe({
    req(input$chat_user_input)

    messages <<- c(
      messages,
      list(
        list(
          role = "user",
          content = input$chat_user_input
        )
      )
    )

    completion <- query(messages)
    response_msg <- completion$choices[[1]]$message
    # TODO: verify it's a good response
    messages <<- c(messages, list(response_msg))
    chat_append_message("chat", response_msg)
  })
}

shinyApp(ui, server)
