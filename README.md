# Sidebot (R Edition)

This is a demonstration of using an LLM to enhance a data dashboard written in [Shiny](https://shiny.posit.co/), via the [querychat](https://github.com/posit-dev/querychat) package.

[**Live demo**](https://jcheng.shinyapps.io/sidebot) (Python version)

To run locally, you'll need to create an `.Renviron` file in the repo root with `OPENAI_API_KEY=` followed by a valid OpenAI API key. Or if that environment value is set some other way, you can skip the `.Renviron` file.

Then run:

```r
pak::pak(c("dplyr", "ggridges", "here", "plotly", "reactable",
  "posit-dev/querychat/r-package"))
```

## Warnings and limitations

This app sends at least your data schema to a remote LLM. As written, it also permits the LLM to run SQL queries against your data and get the results back. Please keep these facts in mind when dealing with sensitive data.

## Other versions

You can find the Python version of this app (including live demo) at [https://github.com/jcheng5/py-sidebot](https://github.com/jcheng5/py-sidebot).
