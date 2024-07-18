library(openai)

api_key <- Sys.getenv("OPENAI_API_KEY", "")
if (!nzchar(api_key)) {
  stop("OPENAI_API_KEY environment variable is required")
}

client <- OpenAI()

query <- function(messages, model = "gpt-4o") {
  # TODO: Add tool call support
  # TODO: verify it's a good response

  while (TRUE) {
    completion <- client$chat$completions$create(
      model = model,
      messages = messages,
      tools = tool_infos
    )

    msg <- completion$choices[[1]]$message
    if (!is.null(msg$tool_calls)) {
      # TODO: optionally return the tool calls to the caller as well
      messages <- c(messages, list(msg))
      tool_response_msgs <- lapply(msg$tool_calls, \(tool_call) {
        id <- tool_call$id
        type <- tool_call$type
        fname <- tool_call$`function`$name
        args <- jsonlite::parse_json(tool_call$`function`$arguments)
        func <- tool_funcs[[fname]]
        if (is.null(func)) {
          stop("Called unknown tool '", fname, "'")
        }
        result <- do.call(func, args)

        list(
          role = "tool",
          tool_call_id = id,
          name = fname,
          content = result
        )
      })
      messages <- c(messages, tool_response_msgs)
    } else {
      # TODO: We're assuming it's a response, we should double check
      break
    }
  }
  print(completion$choices[[1]])
  completion
}

tools_env = new.env(parent = globalenv())
source("tools/tools.R", local = tools_env)
tool_funcs <- as.list(tools_env)

tool_infos <- names(tool_funcs) |> lapply(\(fname) {
  jsonlite::read_json(paste0("tools/", fname, ".json"))
})