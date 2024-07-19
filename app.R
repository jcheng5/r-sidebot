library(shiny)
library(bslib)
library(fastmap)
library(duckdb)
library(DBI)
library(fontawesome)
library(reactable)
library(here)
library(plotly)
library(ggplot2)
library(ggridges)
library(dplyr)

source(here("chat.R"), local = TRUE)
source(here("query.R"), local = TRUE)
source(here("explain-plot.R"), local = TRUE)

# Prepare the duckdb database
conn <- dbConnect(duckdb(), dbdir = ":memory:")
# Close the database when the app stops
onStop(\() dbDisconnect(conn))
# Load tips.csv into a table named `tips`
duckdb_read_csv(conn, "tips", here("tips.csv"))

# Dynamically create the system prompt, based on the real data. For an actually
# large database, you wouldn't want to retrieve all the data like this, but
# instead either hand-write the schema or write your own routine that is more
# efficient than system_prompt().
#
# This value has the shape list(role = "system", content = "<SYSTEM_PROMPT>")
system_prompt_msg <- system_prompt(dbGetQuery(conn, "SELECT * FROM tips"), "tips")

# This is the greeting that should initially appear in the sidebar when the app
# loads.
greeting <- paste(readLines(here("greeting.md")), collapse = "\n")

ui <- page_sidebar(
  style = "background-color: rgb(248, 248, 248);",
  title = "Restaurant tipping",
  sidebar = sidebar(
    width = 400,
    style = "height: 100%;",
    chat_ui("chat", height = "100%", fill = TRUE)
  ),
  useBusyIndicators(),
  textOutput("title", container = h3),
  verbatimTextOutput("sql") |>
    tagAppendAttributes(style = "max-height: 100px; overflow: auto;"),
  layout_columns(fill = FALSE,
    value_box(
      showcase = fa_i("user"),
      "Total tippers",
      textOutput("total_tippers", inline = TRUE)
    ),
    value_box(
      showcase = fa_i("wallet"),
      "Average tips",
      textOutput("average_tip", inline = TRUE)
    ),
    value_box(
      showcase = fa_i("dollar-sign"),
      "Average bill",
      textOutput("average_bill", inline = TRUE)
    ),
  ),
  layout_columns(
    col_widths = c(6, 6, 12),
    card(
      card_header("Tips data"),
      reactableOutput("table", height = "100%")
    ),
    card(
      card_header(class = "d-flex justify-content-between align-items-center",
        "Total bill vs tip",
        span(
          actionLink("interpret_scatter", fa_i("robot"), class = "me-3"),
          popover(title = "Add a color variable", placement = "top",
            fa_i("ellipsis"),
            radioButtons(
              "scatter_color",
              NULL,
              c("none", "sex", "smoker", "day", "time"),
              inline = TRUE
            )
          )
        )
      ),
      plotlyOutput("scatterplot")
    ),
    card(
      card_header(class = "d-flex justify-content-between align-items-center",
        "Tip percentages",
        span(
          actionLink("interpret_ridge", fa_i("robot"), class = "me-3"),
          popover(title = "Split ridgeplot", placement = "top",
            fa_i("ellipsis"),
            radioButtons(
              "tip_perc_y",
              "Split by",
              c("sex", "smoker", "day", "time"),
              "day",
              inline = TRUE
            )
          )
        )
      ),
      plotOutput("tip_perc")
    ),
  )
)

server <- function(input, output, session) {
  current_title <- reactiveVal(NULL)
  current_query <- reactiveVal("")

  # This object must always be passed as the `.ctx` argument to query(), so that
  # tool functions can access the context they need to do their jobs; in this
  # case, the database connection that query() needs.
  ctx <- list(conn = conn)

  tips_data <- reactive({
    sql <- current_query()
    if (is.null(sql) || sql == "") {
      sql <- "SELECT * FROM tips;"
    }
    dbGetQuery(conn, sql)
  })

  output$title <- renderText({
    current_title()
  })

  output$sql <- renderText({
    current_query()
  })

  output$total_tippers <- renderText({
    nrow(tips_data())
  })

  output$average_tip <- renderText({
    x <- mean(tips_data()$tip / tips_data()$total_bill) * 100
    paste0(formatC(x, format="f", digits=1, big.mark=","), "%")
  })

  output$average_bill <- renderText({
    x <- mean(tips_data()$total_bill)
    paste0("$", formatC(x, format="f", digits=2, big.mark=","))
  })

  output$table <- renderReactable({
    reactable(tips_data(),
      pagination = FALSE, bordered = TRUE
    )
  })

  scatterplot <- reactive({
    color <- input$scatter_color

    data <- tips_data()

    p <- plot_ly(data, x = ~total_bill, y = ~tip, type = "scatter", mode = "markers")

    if (color != "none") {
      p <- plot_ly(data, x = ~total_bill, y = ~tip, color = as.formula(paste0("~", color)),
        type = "scatter", mode = "markers")
    }

    p <- p |> add_lines(x = ~total_bill, y = fitted(loess(tip ~ total_bill, data = data)),
      line = list(color = 'rgba(255, 0, 0, 0.5)'),
      name = 'LOESS', inherit = FALSE)

    p <- p |> layout(showlegend = FALSE)

    return(p)
  })

  output$scatterplot <- renderPlotly({
    scatterplot()
  })

  observeEvent(input$interpret_scatter, {
    explain_plot(messages$as_list(), scatterplot(), .ctx = ctx)
  })

  tip_perc <- reactive({
    df <- tips_data() |> mutate(percent = tip / total_bill)

    ggplot(df, aes_string(x = "percent", y = input$tip_perc_y, fill = input$tip_perc_y)) +
      geom_density_ridges(scale = 3, rel_min_height = 0.01, alpha = 0.6) +
      scale_fill_viridis_d() +
      theme_ridges() +
      labs(x = "Percent", y = NULL, title = "Tip Percentages by Day") +
      theme(legend.position = "none")
  })

  output$tip_perc <- renderPlot({
    tip_perc()
  })

  observeEvent(input$interpret_ridge, {
    explain_plot(messages$as_list(), tip_perc(), .ctx = ctx)
  })

  # We could've just used a list here, but fastqueue has
  # a nicer looking API for adding new elements
  messages <- fastqueue()
  messages$add(system_prompt_msg)
  chat_append_message("chat", list(
    role = "assistant",
    content = greeting
  ))

  observeEvent(input$chat_user_input, {
    # Add user message to the chat history
    messages$add(
      list(role = "user", content = input$chat_user_input)
    )

    completion <- tryCatch(
      {
        withProgress(value = NULL, message = "Thinking...", {
          query(messages$as_list(), .ctx = ctx)
        })
      },
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
    msg_parsed <- jsonlite::fromJSON(response_msg$content, simplifyDataFrame = FALSE)

    # Add response to the chat history
    messages$add(response_msg)

    if (!is.null(msg_parsed$sql) && msg_parsed$sql != "") {
      current_query(msg_parsed$sql)
    }
    if ("title" %in% names(msg_parsed)) {
      current_title(msg_parsed$title)
    }

    # Show response in the UI
    chat_append_message("chat", list(
      role = "assistant",
      content = msg_parsed$response
    ))
  })
}

shinyApp(ui, server)
