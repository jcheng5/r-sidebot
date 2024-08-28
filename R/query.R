# pak::pak("irudnyts/openai@r6")
library(openai)
library(here)
library(httr2)

log <- function(...) {}
log <- message

api_key <- Sys.getenv("OPENAI_API_KEY", "")
if (!nzchar(api_key)) {
  stop("OPENAI_API_KEY environment variable is required")
}

client <- OpenAI()

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

chat_async <- function(
  messages,
  model = "gpt-4o",
  on_chunk = \(chunk) {},
  polling_interval_secs = 0.2,
  .ctx = NULL
) {
  api_endpoint <- "https://api.openai.com/v1/chat/completions"
  api_key <- Sys.getenv("OPENAI_API_KEY")

  # Build the request
  response <- request(api_endpoint) %>%
    req_headers(
      "Content-Type" = "application/json",
      "Authorization" = paste("Bearer", api_key)
    ) %>%
    req_body_json(list(
      model = "gpt-4o",
      stream = TRUE,
      temperature = 0.7,
      messages = messages$as_list(),
      tools = tool_infos
    )) %>%
    req_perform_connection(mode = "rt", blocking = FALSE)

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

        # We've gathered all the chunks
        resolve(Reduce(elmer:::merge_dicts, chunks))
      })
    }
    do_next()
  }) %>% promises::then(\(completion) {
    msg <- completion$choices[[1]]$delta
    messages$add(msg)
    if (!is.null(msg$tool_calls)) {
      log("Handling tool calls")
      # TODO: optionally return the tool calls to the caller as well
      tool_response_msgs <- lapply(msg$tool_calls, \(tool_call) {
        id <- tool_call$id
        type <- tool_call$type
        fname <- tool_call$`function`$name
        log("Calling ", fname)
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
            list(success = FALSE, error = "An error occurred")
          }
        )

        list(
          role = "tool",
          tool_call_id = id,
          name = fname,
          content = jsonlite::toJSON(result, auto_unbox = TRUE)
        )
      })
      for (tool_response_msg in tool_response_msgs) {
        messages$add(tool_response_msg)
      }

      # Now that the tools have been invoked, continue the conversation
      chat_async(messages, model=model, on_chunk=on_chunk, polling_interval_secs=polling_interval_secs, .ctx=.ctx)
    } else {
      # The conversation is over for now; the `messages` queue has been
      # populated with the new messages and callbacks have been invoked with the
      # chunks.
      invisible()
    }
  })
}

query <- function(messages, model = "gpt-4o", ..., .ctx = NULL) {
  # TODO: verify it's a good response

  # Stores messages exchanged between the user input and assistant's
  # final response (i.e., tool calls)
  intermediate_messages <- list()

  while (TRUE) {
    # print(tail(messages, 1))
    httr2::with_verbosity(verbosity = 2,
      completion <- client$chat$completions$create(
        model = model,
        messages = c(messages, intermediate_messages),
        temperature = 0.7,
        tools = tool_infos
      )
    )

    msg <- completion$choices[[1]]$message
    if (!is.null(msg$tool_calls)) {
      log("Handling tool calls")
      # TODO: optionally return the tool calls to the caller as well
      intermediate_messages <- c(intermediate_messages, list(msg))
      tool_response_msgs <- lapply(msg$tool_calls, \(tool_call) {
        id <- tool_call$id
        type <- tool_call$type
        fname <- tool_call$`function`$name
        log("Calling ", fname)
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
            list(success = FALSE, error = "An error occurred")
          }
        )

        list(
          role = "tool",
          tool_call_id = id,
          name = fname,
          content = result
        )
      })
      intermediate_messages <- c(intermediate_messages, tool_response_msgs)
    } else {
      # TODO: We're assuming it's a response, we should double check
      break
    }
  }
  # print(completion$choices[[1]])
  list(
    completion = completion,
    intermediate_messages = intermediate_messages
  )
}

tools_env = new.env(parent = globalenv())
source(here("tools/tools.R"), local = tools_env)
tool_funcs <- as.list(tools_env)

tool_infos <- names(tool_funcs) |> lapply(\(fname) {
  jsonlite::read_json(here(paste0("tools/", fname, ".json")))
})
