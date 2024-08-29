library(here)
library(httr2)

log <- function(...) {}
log <- message

api_key <- Sys.getenv("OPENAI_API_KEY", "")
if (!nzchar(api_key)) {
  stop("OPENAI_API_KEY environment variable is required")
}

system_prompt <- function(df, name, categorical_threshold = 10) {
  schema <- df_to_schema(df, name, categorical_threshold)

  # Read the prompt file
  prompt_path <- here("prompt.md")
  prompt_content <- readLines(prompt_path, warn = FALSE)
  prompt_text <- paste(prompt_content, collapse = "\n")

  # Replace the placeholder with the schema
  prompt_text <- gsub("\\$\\{SCHEMA\\}", schema, prompt_text)

  # Return as a named list (equivalent to Python dict)
  return(list(role = "system", content = prompt_text))
}

df_to_schema <- function(df, name, categorical_threshold) {
  schema <- c(paste("Table:", name), "Columns:")

  column_info <- lapply(names(df), function(column) {
    # Map R classes to SQL-like types
    sql_type <- if (is.integer(df[[column]])) {
      "INTEGER"
    } else if (is.numeric(df[[column]])) {
      "FLOAT"
    } else if (is.logical(df[[column]])) {
      "BOOLEAN"
    } else if (inherits(df[[column]], "POSIXt")) {
      "DATETIME"
    } else {
      "TEXT"
    }

    info <- paste0("- ", column, " (", sql_type, ")")

    # For TEXT columns, check if they're categorical
    if (sql_type == "TEXT") {
      unique_values <- length(unique(df[[column]]))
      if (unique_values <= categorical_threshold) {
        categories <- unique(df[[column]])
        categories_str <- paste0("'", categories, "'", collapse = ", ")
        info <- c(info, paste0("  Categorical values: ", categories_str))
      }
    }

    return(info)
  })

  schema <- c(schema, unlist(column_info))
  return(paste(schema, collapse = "\n"))
}

# Run a single streaming query to OpenAI, asynchronously. Streaming chunks are
# reported to the on_chunk callback, and the returned promise is resolved to the
# final completion object.
chat_once_async <- function(
  body,
  on_chunk = \(chunk) {},
  polling_interval_secs = 0.2,
  .ctx = NULL,
  api_endpoint = "https://api.openai.com/v1/chat/completions",
  api_key = Sys.getenv("OPENAI_API_KEY")
) {
  # Build the request
  response <- request(api_endpoint) %>%
    req_headers(
      "Content-Type" = "application/json",
      "Authorization" = paste("Bearer", api_key)
    ) %>%
    req_body_json(body) %>%
    req_perform_connection(mode = "text", blocking = FALSE)

  chunks <- list()

  promises::promise(\(resolve, reject) {
    do_next <- \() {
      shiny:::withLogErrors({
        while (TRUE) {
          sse <- resp_stream_sse(response)
          if (!is.null(sse)) {
            if (identical(sse$data, "[DONE]")) {
              break
            }
            chunk <- jsonlite::fromJSON(sse$data, simplifyVector = FALSE)
            # message(sse$data)
            on_chunk(chunk)
            chunks <<- c(chunks, list(chunk))
          } else {
            if (isIncomplete(response$body)) {
              later::later(do_next, polling_interval_secs)
              return()
            } else {
              reject(simpleError("Chat response terminated unexpectedly (connection dropped?)"))
            }
          }
        }

        combined <- Reduce(elmer:::merge_dicts, chunks)
        combined$choices <- lapply(combined$choices, \(choice) {
          if ("delta" %in% names(choice)) {
            names(choice)[names(choice) == "delta"] <- "message"
          }
          choice
        })

        # We've gathered all the chunks
        resolve(combined)
      })
    }
    do_next()
  })
}

chat_async <- function(
  messages,
  model = "gpt-4o",
  on_chunk = \(chunk) {},
  polling_interval_secs = 0.2,
  .ctx = NULL,
  api_endpoint = "https://api.openai.com/v1/chat/completions",
  api_key = Sys.getenv("OPENAI_API_KEY")
) {
  chat_once_async(
    body = list(
      model = "gpt-4o",
      stream = TRUE,
      temperature = 0.7,
      messages = messages$as_list(),
      tools = tool_infos
    ),
    on_chunk = on_chunk,
    polling_interval_secs = polling_interval_secs,
    .ctx = .ctx,
    api_endpoint = api_endpoint,
    api_key = api_key
  ) %>% promises::then(\(completion) {
    msg <- completion$choices[[1]]$message
    finish_reason <- completion$choices[[1]][["finish_reason"]]
    messages$add(msg)
    if (finish_reason == "tool_calls") {
      log("Handling tool calls")
      for (tool_call in msg$tool_calls) {
        tool_response_msg <- call_tool(tool_call, .ctx)
        messages$add(tool_response_msg)
      }

      # Now that the tools have been invoked, continue the conversation
      return(chat_async(
        messages,
        model = model,
        on_chunk = on_chunk,
        polling_interval_secs = polling_interval_secs,
        .ctx = .ctx,
        api_endpoint = api_endpoint,
        api_key = api_key
      ))
    } else if (finish_reason %in% c("stop", "limit")) {
      # The conversation is over for now; the `messages` queue has been
      # populated with the new messages and callbacks have been invoked with the
      # chunks.
      return(invisible())
    } else if (finish_reason == "length") {
      stop("Conversation reached its length limit")
    }
  })
}

call_tool <- function(tool_call, .ctx) {
  fname <- tool_call$`function`$name
  args <- jsonlite::parse_json(tool_call$`function`$arguments)

  func <- tool_funcs[[fname]]
  if (is.null(func)) {
    stop("Called unknown tool '", fname, "'")
  }
  if (".ctx" %in% names(formals(func))) {
    args$.ctx <- .ctx
  }
  result <- tryCatch(
    {
      do.call(func, args)
    },
    error = \(e) {
      message(conditionMessage(e))
      list(
        success = FALSE,
        error = paste0("An error occurred: ", conditionMessage(e))
      )
    }
  )

  list(
    role = "tool",
    tool_call_id = tool_call$id,
    name = fname,
    content = jsonlite::toJSON(result, auto_unbox = TRUE)
  )
}

tools_env = new.env(parent = globalenv())
source(here("tools/tools.R"), local = tools_env)
tool_funcs <- as.list(tools_env)

tool_infos <- names(tool_funcs) |> lapply(\(fname) {
  jsonlite::read_json(here(paste0("tools/", fname, ".json")))
})
