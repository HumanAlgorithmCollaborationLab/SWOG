extract_column_names = function(text) {
  # Function to extract column names from formatted text
  
  matches = regmatches(text, gregexpr("\\('([^']+)', '([^']+)'\\)", text))[[1]]
  
  column_names = character()
  for (match in matches) {
    parts = regmatches(match, gregexpr("'([^']+)'", match))[[1]]
    if (length(parts) >= 2) {
      second_item = gsub("'", "", parts[2])
      column_names = c(column_names, second_item)
    }
  }
  
  return(unique(column_names))
}

extract_codes = function(text_input) {
  # Function to extract LOINC codes from formatted text
  
  # Split the input by lines and collapse into single string
  if(is.character(text_input) && length(text_input) > 1) {
    text_input = paste(text_input, collapse = "\n")
  }
  
  # Extract everything between single quotes that comes after opening parenthesis
  # Pattern explanation: \\('([^']+)' matches ('code' format
  codes = regmatches(text_input, gregexpr("\\('([^']+)'", text_input))[[1]]
  
  # Remove the (' and ' parts to get just the codes
  codes = gsub("\\('|'", "", codes)
  
  # Remove any empty strings
  codes = codes[codes != ""]
  
  # Return as R vector format
  return(codes)
}

extract_codes_to_r = function(text_input) {
  # Function to print LOINC code list for copying
  
  codes = extract_codes(text_input)
  r_code = paste0("(", paste0("'", codes, "'", collapse = ", "), ")")
  cat(r_code)
  return(invisible(codes))
}

create_suffixed_columns = function(base_names) {
  # Function to create column names with suffixes
  
  suffixes = c("_first", "_last", "_min", "_max", "_count", "_stdev")
  
  all_columns = character()
  for (base_name in base_names) {
    suffixed_names = paste0(base_name, suffixes)
    all_columns = c(all_columns, suffixed_names)
  }
  
  return(all_columns)
}

apply_missing_thresh = function(df, column_names, threshold = 0.5) {
  # Function to identify high NA columns by base names (lab suffixes optional)
  
  existing_cols = column_names[column_names %in% names(df)]
  if (length(existing_cols) == 0) {
    return(data.frame(column_name = character(), na_percentage = numeric()))
  }
  
  na_percentages = sapply(existing_cols, function(col_name) {
    sum(is.na(df[[col_name]])) / nrow(df)
  })
  
  results = data.frame(
    column_name = existing_cols,
    na_percentage = na_percentages,
    stringsAsFactors = FALSE
  )
  
  high_na_results = results[results$na_percentage >= threshold, ]
  high_na_results = high_na_results[order(-high_na_results$na_percentage), ]
  rownames(high_na_results) = NULL
  
  return(high_na_results)
}

count_median_imputation = function(train, test, in_vars) {
  # Function to impute train and test datasets
  
  # Identify columns that end with "count" or "stdev"
  count_stdev_columns <- in_vars[grepl("_count$|_stdev$", in_vars)]
  other_columns <- setdiff(in_vars, count_stdev_columns)
  
  # Calculate medians from training data for other columns
  train_medians <- sapply(train[other_columns], median, na.rm = TRUE)
  
  # Impute count and stdev columns with 0
  for(col in count_stdev_columns) {
    if(sum(is.na(train[[col]])) > 0) {
      cat("Imputing", sum(is.na(train[[col]])), "missing values in TRAIN", col, "with 0\n")
      train[[col]][is.na(train[[col]])] <- 0
    }
    if(sum(is.na(test[[col]])) > 0) {
      cat("Imputing", sum(is.na(test[[col]])), "missing values in TEST", col, "with 0\n")
      test[[col]][is.na(test[[col]])] <- 0
    }
  }
  
  # Impute other columns with median (using training medians for both)
  for(col in other_columns) {
    median_value <- train_medians[col]
    if(sum(is.na(train[[col]])) > 0) {
      cat("Imputing", sum(is.na(train[[col]])), "missing values in TRAIN", col, "with median:", median_value, "\n")
      train[[col]][is.na(train[[col]])] <- median_value
    }
    if(sum(is.na(test[[col]])) > 0) {
      cat("Imputing", sum(is.na(test[[col]])), "missing values in TEST", col, "with training median:", median_value, "\n")
      test[[col]][is.na(test[[col]])] <- median_value
    }
  }
  return(list(train = train, test = test))
}

discretize_var = function(x, bins = 5) {
  #Discretizes continuous features for mutual information processes
  cut(x, breaks = bins, labels = FALSE, include.lowest = TRUE)
}

batch_mutual_info = function(df, feature_cols, target_discrete, batch_size = 25){
  # Calculates feature mutual information in batches
  n_features = length(feature_cols)
  mi_scores = numeric(n_features)
  names(mi_scores) = feature_cols
  
  for (i in seq(1, n_features, batch_size)) {
    end_idx = min(i + batch_size - 1, n_features)
    batch_cols = feature_cols[i:end_idx]
    
    cat("Processing batch", ceiling(i/batch_size), "- features", i, "to", end_idx, "\n")
    
    for (j in seq_along(batch_cols)) {
      col_name = batch_cols[j]
      x = df[[col_name]]
      x_discrete = discretize_var(x)
      
      # Remove NA values
      valid_idx = !is.na(x_discrete) & !is.na(target_discrete)
      x_clean = x_discrete[valid_idx]
      y_clean = target_discrete[valid_idx]
      
      if (length(unique(x_clean)) <= 1) {
        mi_scores[col_name] = 0
        next
      }
      
      # Calculate contingency table
      cont_table = table(x_clean, y_clean)
      
      # Calculate mutual information
      n = sum(cont_table)
      p_xy = cont_table / n
      p_x = rowSums(p_xy)
      p_y = colSums(p_xy)
      
      mi = 0
      for (ii in 1:nrow(p_xy)) {
        for (jj in 1:ncol(p_xy)) {
          if (p_xy[ii,jj] > 0) {
            mi = mi + p_xy[ii,jj] * log2(p_xy[ii,jj] / (p_x[ii] * p_y[jj]))
          }
        }
      }
      mi_scores[col_name] = mi
    }
    
    # Clean up memory
    gc()
  }
  
  # Create data frame with variable names and scores
  feature_scores = data.frame(
    var = names(mi_scores),
    score = mi_scores,
    stringsAsFactors = FALSE
  )
  
  return(feature_scores)
}

evaluate_gbm <- function(model, train, test, outcome = "mortality_180", threshold = "optimal") {
  n_trees <- model$n.trees
  
  #Predict
  train_probs <- predict(model, train, n.trees = n_trees, type = "response")
  test_probs  <- predict(model, test,  n.trees = n_trees, type = "response")
  y_train <- train[[outcome]]
  y_test  <- test[[outcome]]
  
  # AUC
  train_auc <- roc(y_train, train_probs)$auc
  test_roc  <- roc(y_test,  test_probs)
  test_auc  <- test_roc$auc
  
  # Threshold selection
  if (is.character(threshold) && threshold == "optimal") {
    # Youden's J
    thresh <- as.numeric(coords(test_roc, "best", ret = "threshold", transpose = FALSE)[1])
  } else if (is.numeric(threshold) && threshold > 0 && threshold < 1) {
    # Top X% flagging
    thresh <- quantile(test_probs, probs = 1 - threshold, na.rm = TRUE)
  } else {
    stop("threshold must be 'optimal' or a number between 0 and 1 for top %")
  }
  
  # Predict using chosen threshold
  test_preds <- ifelse(test_probs > thresh, 1, 0)
  
  # Factor outcomes for confusionMatrix
  test_preds_factor <- factor(test_preds, levels = c(0,1))
  y_test_factor     <- factor(y_test,     levels = c(0,1))
  conf_mat <- confusionMatrix(test_preds_factor, y_test_factor)
  
  # Generate results table
  results <- data.frame(
    Metric = c("Train AUC", "AUC", "Probability Threshold", "Accuracy", 
               "Sensitivity", "Specificity", "Precision", "Proportion Flagged"),
    Value = c(
      round(train_auc, 3),
      round(test_auc, 3),
      round(100*thresh, 1),
      round(conf_mat$overall["Accuracy"], 3),
      round(conf_mat$byClass["Sensitivity"], 3),
      round(conf_mat$byClass["Specificity"], 3),
      round(conf_mat$byClass["Pos Pred Value"], 3),
      round(100*mean(test_preds), 1)
    ),
    row.names = NULL
  )
  
  return(results)
}

create_gbm_calibration_plot = function(test_data, gbm_model, n_bins = 10) {
  
  # Get predictions on test set
  predicted_probs = predict(gbm_model, newdata = test_data, 
                            type = "response", n.trees = gbm_model$n.trees)
  
  # Get actual outcomes from test set
  actual_outcomes = test_data$mortality_180
  
  # Create data frame
  cal_data = data.frame(
    predicted = predicted_probs,
    actual = actual_outcomes
  )
  
  # Create bins based on predicted probabilities
  cal_data$bin = cut(cal_data$predicted, 
                     breaks = quantile(cal_data$predicted, 
                                       probs = seq(0, 1, length.out = n_bins + 1)),
                     include.lowest = TRUE,
                     labels = FALSE)
  
  # Calculate calibration statistics by bin
  cal_stats = cal_data %>%
    group_by(bin) %>%
    summarise(
      n_patients = n(),
      mean_predicted = mean(predicted),
      observed_rate = mean(actual),
      se = sqrt(observed_rate * (1 - observed_rate) / n_patients),
      ci_lower = pmax(0, observed_rate - 1.96 * se),
      ci_upper = pmin(1, observed_rate + 1.96 * se),
      .groups = 'drop'
    )
  
  p = ggplot(cal_stats, aes(x = mean_predicted, y = observed_rate)) +
    # Blue dots with dummy shape legend
    geom_point(aes(shape = "Binned Estimates by Predicted Risk Decile"),
               color = "blue", size = 4, alpha = 0.5) +
    
    # Error bars (blue, no legend)
    geom_errorbar(aes(ymin = ci_lower, ymax = ci_upper),
                  width = 0.01, color = "blue", alpha = 0.5, show.legend = FALSE) +
    
    # Perfect calibration line
    geom_abline(intercept = 0, slope = 1,
                linetype = "dashed", color = "red", size = 1) +
    
    # Smoothed calibration curve
    geom_smooth(method = "loess", se = TRUE, color = "black", alpha = 0.3) +
    
    # Manual legend for shape
    scale_shape_manual(name = "", values = 16) +
    
    labs(
      title = "Calibration Plot: GBM Mortality Prediction",
      subtitle = "Perfect calibration shown by red dashed line",
      x = "Mean Predicted Probability",
      y = "Observed Mortality Rate",
      caption = paste("Test set with", nrow(test_data),
                      "patient-encounters binned into", n_bins, "groups")
    ) +
    theme_minimal() +
    theme(
      plot.title = element_text(size = 14, face = "bold"),
      plot.subtitle = element_text(size = 11),
      axis.title = element_text(size = 12),
      legend.position = "bottom"
    ) +
    coord_cartesian(xlim = c(0, 0.3), ylim = c(0, 0.4)) +
    scale_x_continuous(labels = scales::percent_format()) +
    scale_y_continuous(labels = scales::percent_format())
  
  
  return(p)
}
