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
library(promises)
library(mirai)

# Allow up to 4 simultaneous chat requests. This number can go higher as it's
# almost all just blocking on the network.
mirai::daemons(4, output = TRUE)

# Open the duckdb database
conn <- dbConnect(duckdb(), dbdir = here("tips.duckdb"), read_only = TRUE)
# Close the database when the app stops
onStop(\() dbDisconnect(conn))

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

icon_explain <- tags$img(src = "stars.svg")

ui <- page_sidebar(
  style = "background-color: rgb(248, 248, 248);",
  title = "Restaurant tipping",
  includeCSS(here("styles.css")),
  sidebar = sidebar(
    width = 400,
    style = "height: 100%;",
    selectInput("model", NULL, c("GPT-4o" = "gpt-4o", "GPT-4o Mini" = "gpt-4o-mini")),
    chat_ui("chat", height = "100%", fill = TRUE)
  ),
  useBusyIndicators(),

  # 🏷️ Header
  textOutput("show_title", container = h3),
  verbatimTextOutput("show_query") |>
    tagAppendAttributes(style = "max-height: 100px; overflow: auto;"),

  # 🎯 Value boxes
  layout_columns(
    fill = FALSE,
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
    style = "min-height: 450px;",
    col_widths = c(6, 6, 12),

    # 🔍 Data table
    card(
      style = "height: 500px;",
      card_header("Tips data"),
      reactableOutput("table", height = "100%")
    ),

    # 📊 Scatter plot
    card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        "Total bill vs tip",
        span(
          actionLink(
            "interpret_scatter",
            icon_explain,
            class = "me-3 text-decoration-none",
            aria_label = "Explain scatter plot"
          ),
          popover(
            title = "Add a color variable", placement = "top",
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

    # 📊 Ridge plot
    card(
      card_header(
        class = "d-flex justify-content-between align-items-center",
        "Tip percentages",
        span(
          actionLink(
            "interpret_ridge",
            icon_explain,
            class = "me-3 text-decoration-none",
            aria_label = "Explain ridgeplot"
          ),
          popover(
            title = "Split ridgeplot", placement = "top",
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
  # 🔄 Reactive state/computation --------------------------------------------

  current_title <- reactiveVal(NULL)
  current_query <- reactiveVal("")

  # This object must always be passed as the `.ctx` argument to query(), so that
  # tool functions can access the context they need to do their jobs; in this
  # case, the database connection that query() needs.
  ctx <- list(conn = conn)

  # The reactive data frame. Either returns the entire dataset, or filtered by
  # whatever Sidebot decided.
  tips_data <- reactive({
    sql <- current_query()
    if (is.null(sql) || sql == "") {
      sql <- "SELECT * FROM tips;"
    }
    dbGetQuery(conn, sql)
  })



  # 🏷️ Header outputs --------------------------------------------------------

  output$show_title <- renderText({
    current_title()
  })

  output$show_query <- renderText({
    current_query()
  })



  # 🎯 Value box outputs -----------------------------------------------------

  output$total_tippers <- renderText({
    nrow(tips_data())
  })

  output$average_tip <- renderText({
    x <- mean(tips_data()$tip / tips_data()$total_bill) * 100
    paste0(formatC(x, format = "f", digits = 1, big.mark = ","), "%")
  })

  output$average_bill <- renderText({
    x <- mean(tips_data()$total_bill)
    paste0("$", formatC(x, format = "f", digits = 2, big.mark = ","))
  })



  # 🔍 Data table ------------------------------------------------------------

  output$table <- renderReactable({
    reactable(tips_data(),
      pagination = FALSE, bordered = TRUE
    )
  })



  # 📊 Scatter plot ----------------------------------------------------------

  scatterplot <- reactive({
    req(nrow(tips_data()) > 0)

    color <- input$scatter_color

    data <- tips_data()

    p <- plot_ly(data, x = ~total_bill, y = ~tip, type = "scatter", mode = "markers")

    if (color != "none") {
      p <- plot_ly(data,
        x = ~total_bill, y = ~tip, color = as.formula(paste0("~", color)),
        type = "scatter", mode = "markers"
      )
    }

    p <- p |> add_lines(
      x = ~total_bill, y = fitted(loess(tip ~ total_bill, data = data)),
      line = list(color = "rgba(255, 0, 0, 0.5)"),
      name = "LOESS", inherit = FALSE
    )

    p <- p |> layout(showlegend = FALSE)

    return(p)
  })

  output$scatterplot <- renderPlotly({
    scatterplot()
  })

  observeEvent(input$interpret_scatter, {
    explain_plot(messages$as_list(), scatterplot(), input$model, .ctx = ctx)
  })



  # 📊 Ridge plot ------------------------------------------------------------

  tip_perc <- reactive({
    req(nrow(tips_data()) > 0)

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



  # ✨ Sidebot ✨ -------------------------------------------------------------

  # The entire chat history up to this point, from the assistant's point of view
  # (not the user). We'll add new messages whenever the user asks a new question
  # or the chat model returns a new response.
  #
  # (We could've just used a list here, but fastqueue has a nicer looking API
  # for adding new elements.)
  messages <- fastqueue()

  # Preload the conversation with the system prompt. These are instructions for
  # the chat model, and must not be shown to the end user.
  messages$add(system_prompt_msg)

  # Prepopulate the chat UI with a welcome message that appears to be from the
  # chat model (but is actually hard-coded). This is just for the user, not for
  # the chat model to see.
  chat_append_message("chat", list(
    role = "assistant",
    content = greeting
  ))

  # Handle user input
  observeEvent(input$chat_user_input, {
    # Add user message to the chat history
    messages$add(
      list(role = "user", content = input$chat_user_input)
    )

    content_accum <- ""
    on_chunk <- function(chunk) {
      if (!is.null(chunk$choices[[1]]$delta$content)) {
        content_accum <<- paste0(content_accum, chunk$choices[[1]]$delta$content)
        chat_append_message("chat", list(role = "assistant", content = content_accum), chunk = TRUE, session = session)
      }
    }

    update_dashboard <- function(query, title) {
      if (!is.null(query)) {
        current_query(query)
      }
      if (!is.null(title)) {
        current_title(title)
      }
    }

    chat_append_message("chat", list(role = "assistant", content = ""), chunk = "start")

    chat_async(
      messages,
      model = "gpt-4o",
      on_chunk = on_chunk,
      .ctx = list(conn = conn, update_dashboard = update_dashboard)) |>

      catch(\(err) {
        print(err)
        err_msg <- list(
          role = "assistant",
          # TODO: Make sure error doesn't contain HTML
          content = paste0("**Error:** ", conditionMessage(err))
        )
        messages$add(err_msg)
        chat_append_message("chat", err_msg)
      }) |>
      finally(\() {
        chat_append_message("chat", list(role = "assistant", content = content_accum), chunk = "end")
      })
  })
}

shinyApp(ui, server)
