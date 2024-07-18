library(openai)

api_key <- Sys.getenv("OPENAI_API_KEY", "")
if (!nzchar(api_key)) {
  stop("OPENAI_API_KEY environment variable is required")
}

client <- OpenAI()

query <- function(messages, model = "gpt-4o") {
  # TODO: Add tool call support

  completion <- client$chat$completions$create(
    model = model,
    messages = messages
  )
  completion
}
