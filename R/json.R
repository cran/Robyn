# Copyright (c) Meta Platforms, Inc. and its affiliates.

# This source code is licensed under the MIT license found in the
# LICENSE file in the root directory of this source tree.

####################################################################
#' Import and Export Robyn JSON files
#'
#' \code{robyn_write()} generates light JSON files with all the information
#' required to replicate Robyn models. Depending on user inputs, there are
#' 3 use cases: only the inputs data, input data + modeling results data,
#' and input data, modeling results + specifics of a single selected model.
#' To replicate a model, you must provide InputCollect, OutputCollect, and,
#' if OutputCollect contains more than one model, the select_model.
#'
#' @inheritParams robyn_outputs
#' @param InputCollect \code{robyn_inputs()} output.
#' @param select_model Character. Which model ID do you want to export
#' into the JSON file?
#' @param add_data Boolean. Include raw dataset. Useful to recreate models
#' with a single file containing all the required information (no need of CSV).
#' @param dir Character. Existing directory to export JSON file to.
#' @param pareto_df Dataframe. Save all pareto solutions to json file.
#' @param ... Additional parameters to export into a custom Extras element.
#' @examples
#' \dontrun{
#' InputCollectJSON <- robyn_inputs(
#'   dt_input = Robyn::dt_simulated_weekly,
#'   json_file = "~/Desktop/RobynModel-1_29_12.json"
#' )
#' print(InputCollectJSON)
#' }
#' @return (invisible) List. Contains all inputs and outputs of exported model.
#' Class: \code{robyn_write}.
#' @export
robyn_write <- function(InputCollect,
                        OutputCollect = NULL,
                        select_model = NULL,
                        dir = OutputCollect$plot_folder,
                        add_data = TRUE,
                        export = TRUE,
                        quiet = FALSE,
                        pareto_df = NULL,
                        ...) {
  # Checks
  stopifnot(inherits(InputCollect, "robyn_inputs"))
  if (!is.null(OutputCollect)) {
    stopifnot(inherits(OutputCollect, "robyn_outputs"))
    if (is.null(select_model) && length(OutputCollect$allSolutions == 1)) {
      select_model <- OutputCollect$allSolutions
    }
  }
  if (is.null(dir)) dir <- getwd()

  # InputCollect JSON
  ret <- list()
  skip <- which(unlist(lapply(InputCollect, function(x) is.list(x) | is.null(x))))
  skip <- skip[!names(skip) %in% c("calibration_input", "hyperparameters", "custom_params")]
  ret[["InputCollect"]] <- InputCollect[-skip]
  # toJSON(ret$InputCollect, pretty = TRUE)
  if (!"paid_media_selected" %in% names(InputCollect)) {
    InputCollect$paid_media_selected <- InputCollect$paid_media_spends
  }

  # ExportedModel JSON
  if (!is.null(OutputCollect)) {
    # Modeling associated data
    collect <- list()
    collect$ts_validation <- OutputCollect$OutputModels$ts_validation
    collect$train_timestamp <- OutputCollect$OutputModels$train_timestamp
    collect$export_timestamp <- Sys.time()
    collect$run_time <- sprintf("%s min", attr(OutputCollect$OutputModels, "runTime"))
    collect$outputs_time <- sprintf("%s min", attr(OutputCollect, "runTime"))
    collect$total_time <- sprintf(
      "%s min", attr(OutputCollect, "runTime") +
        attr(OutputCollect$OutputModels, "runTime")
    )
    collect$total_iters <- OutputCollect$OutputModels$iterations *
      OutputCollect$OutputModels$trials
    collect$conv_msg <- gsub("\\:.*", "", OutputCollect$OutputModels$convergence$conv_msg)
    if ("clusters" %in% names(OutputCollect)) {
      collect$n_clusters <- OutputCollect$clusters$n_clusters
    }

    skip <- which(unlist(lapply(OutputCollect, function(x) is.list(x) | is.null(x))))
    skip <- c(skip, which(names(OutputCollect) %in% "allSolutions"))
    collect <- append(collect, OutputCollect[-skip])
    ret[["ModelsCollect"]] <- collect

    # Model associated data
    if (length(select_model) == 1) {
      stopifnot(select_model %in% OutputCollect$allSolutions)
      outputs <- list()
      outputs$select_model <- select_model
      sp <- select(InputCollect$dt_mod, InputCollect$paid_media_selected)
      df <- filter(OutputCollect$mediaVecCollect, .data$solID %in% select_model, .data$type == "decompMedia")
      perf_metric <- ifelse(InputCollect$dep_var_type == "revenue", "ROAS", "CPA")
      performance <- left_join(
        tidyr::gather(dplyr::summarize_all(select(sp, InputCollect$paid_media_selected), sum), "channel", "spend"),
        tidyr::gather(dplyr::summarize_all(select(df, InputCollect$paid_media_selected), sum), "channel", "response"),
        by = "channel"
      ) %>%
        dplyr::rowwise() %>%
        mutate(
          metric = perf_metric,
          performance = ifelse(
            perf_metric == "ROAS",
            .data$response / .data$spend,
            .data$spend / .data$response
          )
        )
      outputs$performance <- performance %>%
        group_by(solID = select_model, .data$metric) %>%
        dplyr::summarize_if(is.numeric, sum) %>%
        mutate(solID = select_model)
      outputs$summary <- filter(OutputCollect$xDecompAgg, .data$solID == select_model) %>%
        left_join(performance, by = c("rn" = "channel")) %>%
        select(
          variable = .data$rn, coef = .data$coef,
          decompPer = .data$xDecompPerc, decompAgg = .data$xDecompAggRF,
          .data$performance, "mean_response" = .data$response, "mean_spend" = .data$spend,
          contains("boot_mean"), contains("ci_")
        ) %>%
        mutate(
          mean_response = .data$mean_response / InputCollect$totalObservations,
          mean_spend = .data$mean_spend / InputCollect$totalObservations
        )
      outputs$errors <- filter(OutputCollect$resultHypParam, .data$solID == select_model) %>%
        select(starts_with("rsq_"), starts_with("nrmse"), .data$decomp.rssd, .data$mape)
      outputs$hyper_values <- OutputCollect$resultHypParam %>%
        filter(.data$solID == select_model) %>%
        select(contains(HYPS_NAMES), dplyr::ends_with("_penalty"), any_of(HYPS_OTHERS)) %>%
        select(order(colnames(.))) %>%
        as.list()
      outputs$hyper_updated <- OutputCollect$hyper_updated
      if ("clusters" %in% names(OutputCollect)) {
        outputs$clusters <- list(
          data = OutputCollect$clusters$data %>%
            group_by(.data$cluster) %>% mutate(n = n()) %>%
            filter(.data$solID == select_model) %>%
            select(any_of(c("solID", "cluster", "n")))
        )
      }
      ret[["ExportedModel"]] <- outputs
    } else {
      select_model <- "models"
    }
  } else {
    select_model <- "inputs"
  }

  extras <- list(...)
  if (isTRUE(add_data) & !"raw_data" %in% names(extras)) {
    extras[["raw_data"]] <- as_tibble(InputCollect$dt_input)
  }
  if (length(extras) > 0) {
    ret[["Extras"]] <- extras
  }

  if (!dir.exists(dir) & export) dir.create(dir, recursive = TRUE)
  filename <- sprintf("%s/RobynModel-%s.json", dir, select_model)
  filename <- gsub("//", "/", filename)
  class(ret) <- c("robyn_write", class(ret))
  attr(ret, "json_file") <- filename
  if (export) {
    if (!quiet) message(sprintf(">> Exported %s as %s", select_model, filename))
    if (!is.null(pareto_df)) {
      if (!all(c("solID", "cluster") %in% names(pareto_df))) {
        warning(paste(
          "Input 'pareto_df' is not a valid data.frame;",
          "must contain 'solID' and 'cluster' columns."
        ))
      } else {
        all_c <- unique(pareto_df$cluster)
        pareto_df <- lapply(all_c, function(x) {
          (pareto_df %>% filter(.data$cluster == x))$solID
        })
        names(pareto_df) <- paste0("cluster", all_c)
        ret[["OutputCollect"]][["all_sols"]] <- pareto_df
      }
    }
    write_json(ret, filename, pretty = TRUE, digits = 10)
  }
  return(invisible(ret))
}


#' @rdname robyn_write
#' @aliases robyn_write
#' @param x \code{robyn_read()} or \code{robyn_write()} output.
#' @export
print.robyn_write <- function(x, ...) {
  val <- any(c(x$ExportedModel$ts_validation, x$ModelsCollect$ts_validation))
  print(glued(
    "
   Exported directory: {x$ExportedModel$plot_folder}
   Exported model: {x$ExportedModel$select_model}
   Window: {start} to {end} ({periods} {type}s)
   Time Series Validation: {val} (train size = {val_detail})",
    start = x$InputCollect$window_start,
    end = x$InputCollect$window_end,
    periods = x$InputCollect$rollingWindowLength,
    type = x$InputCollect$intervalType,
    val_detail = formatNum(100 * x$ExportedModel$hyper_values$train_size, 2, pos = "%")
  ))
  errors <- x$ExportedModel$errors
  print(glued(
    "\n\nModel's Performance and Errors:\n    {performance}{errors}",
    performance = ifelse("performance" %in% names(x$ExportedModel), sprintf(
      "Total Model %s = %s\n    ",
      x$ExportedModel$performance$metric, signif(x$ExportedModel$performance$performance, 4)
    ), ""),
    errors = paste(
      sprintf(
        "Adj.R2 (train): %s",
        signif(errors$rsq_train, 4)
      ),
      "| NRMSE =", signif(errors$nrmse, 4),
      "| DECOMP.RSSD =", signif(errors$decomp.rssd, 4),
      "| MAPE =", signif(errors$mape, 4)
    )
  ))

  if ("ExportedModel" %in% names(x)) {
    print(glued("\n\nSummary Values on Selected Model:"))

    print(x$ExportedModel$summary %>%
      select(-contains("boot"), -contains("ci_")) %>%
      dplyr::rename_at("performance", list(~ ifelse(x$InputCollect$dep_var_type == "revenue", "ROAS", "CPA"))) %>%
      mutate(decompPer = formatNum(100 * .data$decompPer, pos = "%")) %>%
      dplyr::mutate_if(is.numeric, function(x) ifelse(!is.infinite(x), x, 0)) %>%
      dplyr::mutate_if(is.numeric, function(x) formatNum(x, 4, abbr = TRUE)) %>%
      replace(., . == "NA", "-") %>% as.data.frame())

    print(glued(
      "\n\nHyper-parameters:\n    Adstock: {x$InputCollect$adstock}"
    ))

    # Nice and tidy table format for hyper-parameters
    HYPS_NAMES <- c(HYPS_NAMES, "penalty")
    regex <- paste(paste0("_", HYPS_NAMES), collapse = "|")
    hyper_df <- as.data.frame(x$ExportedModel$hyper_values) %>%
      select(-contains("lambda"), -any_of(HYPS_OTHERS)) %>%
      tidyr::gather() %>%
      tidyr::separate(.data$key,
        into = c("channel", "none"),
        sep = regex, remove = FALSE
      ) %>%
      mutate(hyperparameter = gsub("^.*_", "", .data$key)) %>%
      select(.data$channel, .data$hyperparameter, .data$value) %>%
      tidyr::spread(key = "hyperparameter", value = "value")
    print(hyper_df)
  }
}


#' @rdname robyn_write
#' @aliases robyn_write
#' @param json_file Character. JSON file name to read and import.
#' @param step Integer. 1 for import only and 2 for import and output.
#' @export
robyn_read <- function(json_file = NULL, step = 1, quiet = FALSE, ...) {
  if (!is.null(json_file)) {
    if (inherits(json_file, "character")) {
      if (lares::right(tolower(json_file), 4) != "json") {
        stop("JSON file must be a valid .json file")
      }
      if (!file.exists(json_file)) {
        stop("JSON file can't be imported: ", json_file)
      }
      json <- read_json(json_file, simplifyVector = TRUE)
      json$InputCollect <- json$InputCollect[lapply(json$InputCollect, length) > 0]
      json$ExportedModel <- append(json$ModelsCollect, json$ExportedModel)
      # Add train_size if not available (<3.9.0)
      if (!"train_size" %in% names(json$ExportedModel$hyper_values)) {
        json$ExportedModel$hyper_values$train_size <- 1
      }
      if (!"InputCollect" %in% names(json) && step == 1) {
        stop("JSON file must contain InputCollect element")
      }
      if (!"ExportedModel" %in% names(json) && step == 2) {
        stop("JSON file must contain ExportedModel element")
      }
      json$ModelsCollect <- NULL
      if (!quiet) message("Imported JSON file successfully: ", json_file)
      class(json) <- c("robyn_read", class(json))
      return(json)
    }
  }
  return(json_file)
}

#' @rdname robyn_write
#' @aliases robyn_write
#' @export
print.robyn_read <- function(x, ...) {
  a <- x$InputCollect
  print(glued(
    "
############ InputCollect ############

Date: {a$date_var}
Dependent: {a$dep_var} [{a$dep_var_type}]
Paid Media: {paste(a$paid_media_vars, collapse = ', ')}
Paid Media Spend: {paste(a$paid_media_spends, collapse = ', ')}
Context: {paste(a$context_vars, collapse = ', ')}
Organic: {paste(a$organic_vars, collapse = ', ')}
Prophet (Auto-generated): {prophet}
Unused variables: {unused}
Model Window: {windows} ({a$rollingWindowEndWhich - a$rollingWindowStartWhich + 1} {a$intervalType}s)
With Calibration: {!is.null(a$calibration_input)}
Custom parameters: {custom_params}

Adstock: {a$adstock}
{hyps}
",
    windows = paste(a$window_start, a$window_end, sep = ":"),
    custom_params = if (length(a$custom_params) > 0) paste("\n", flatten_hyps(a$custom_params)) else "None",
    prophet = if (!is.null(a$prophet_vars)) {
      sprintf("%s on %s", paste(a$prophet_vars, collapse = ", "), a$prophet_country)
    } else {
      "\033[0;31mDeactivated\033[0m"
    },
    unused = if (length(a$unused_vars) > 0) {
      paste(a$unused_vars, collapse = ", ")
    } else {
      "None"
    },
    hyps = glued(
      "Hyper-parameters ranges:\n{flatten_hyps(a$hyperparameters)}"
    )
  ))

  if (!is.null(x$ExportedModel)) {
    temp <- x
    class(temp) <- "robyn_write"
    print(glued("\n\n############ Exported Model ############\n"))
    print(temp)
  }
  return(invisible(x))
}

#' @rdname robyn_write
#' @aliases robyn_write
#' @export
robyn_recreate <- function(json_file, quiet = FALSE, ...) {
  json <- robyn_read(json_file, quiet = TRUE)
  message(">>> Recreating ", json$ExportedModel$select_model)
  args <- list(...)
  if (!"InputCollect" %in% names(args)) {
    InputCollect <- robyn_inputs(
      json_file = json_file,
      quiet = quiet,
      ...
    )
    if (!is.null(json$ExportedModel$select_model)) {
      OutputCollect <- robyn_run(
        InputCollect = InputCollect,
        json_file = json_file,
        export = FALSE,
        quiet = quiet,
        ...
      )
    } else {
      OutputCollect <- NULL
    }
  } else {
    # Use case: skip feature engineering when InputCollect is provided
    InputCollect <- args[["InputCollect"]]
    OutputCollect <- robyn_run(
      json_file = json_file,
      export = FALSE,
      quiet = quiet,
      ...
    )
  }
  return(invisible(list(
    InputCollect = InputCollect,
    OutputCollect = OutputCollect,
    Extras = json[["Extras"]]
  )))
}

# Import the whole chain any refresh model to init
robyn_chain <- function(json_file) {
  json_data <- robyn_read(json_file, quiet = TRUE)
  ids <- c(json_data$InputCollect$refreshChain, json_data$ExportedModel$select_model)
  plot_folder <- json_data$ExportedModel$plot_folder
  temp <- str_split(plot_folder, "/")[[1]]
  chain <- temp[startsWith(temp, "Robyn_") & grepl("_init+$|_rf[0-9]+$", temp)]
  if (length(chain) == 0) chain <- tail(temp[temp != ""], 1)
  avlb <- NULL
  if (length(ids) != length(chain)) {
    temp <- list.files(plot_folder)
    mods <- unique(temp[
      (startsWith(temp, "RobynModel") | grepl("\\.json+$", temp)) &
        grepl("^[^_]*_[^_]*_[^_]*$", temp)
    ])
    avlb <- gsub("RobynModel-|\\.json", "", mods)
    if (length(ids) == length(mods)) {
      chain <- rep_len(chain, length(mods))
    }
  }
  base_dir <- gsub(sprintf("\\/%s.*", chain[1]), "", plot_folder)
  chainData <- list()
  for (i in rev(seq_along(ids))) {
    if (i == length(ids)) {
      json_new <- json_data
    } else {
      file <- paste0("RobynModel-", json_new$InputCollect$refreshSourceID, ".json")
      filename <- paste(c(base_dir, chain[1:i], file), collapse = "/")
      if (file.exists(filename)) {
        json_new <- robyn_read(filename, quiet = TRUE)
      } else {
        if (ids[i] %in% avlb) {
          filename <- mods[avlb == ids[i]]
          json_new <- robyn_read(filename, quiet = TRUE)
        } else {
          last_try <- gsub(chain[1], "", filename)
          if (file.exists(last_try)) {
            json_new <- robyn_read(last_try, quiet = TRUE)
            message("Stored original model in new file: ", filename)
            jsonlite::write_json(json_new, filename, pretty = TRUE)
          } else {
            message("Skipping chain. File can't be found: ", filename)
          }
        }
      }
    }
    chainData[[json_new$ExportedModel$select_model]] <- json_new
  }
  chainData <- chainData[rev(seq_along(chain))]
  dirs <- unlist(lapply(chainData, function(x) x$ExportedModel$plot_folder))
  dirs[!dir.exists(dirs)] <- plot_folder
  json_files <- paste0(dirs, "RobynModel-", names(dirs), ".json")
  attr(chainData, "json_files") <- json_files
  attr(chainData, "chain") <- ids # names(chainData)
  if (length(ids) != length(names(chainData))) {
    warning("Can't replicate chain-like results if you don't follow Robyn's chain structure")
  }
  return(invisible(chainData))
}
