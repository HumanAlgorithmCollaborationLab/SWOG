# ===================== HOW TO RUN =====================
# From terminal/command line:
#
# Rscript SWOG_Predict_v2.R \
#   --data path/to/input_data.csv \
#   --model path/to/model.rds
#
# Example:
# Rscript SWOG_Predict_v2.R \
#   --data ./data/patient_data.csv \
#   --model ./models/gbm_model.rds
#
# Notes:
# - --data  : CSV file containing patient-level features
# - --model : RDS file containing trained gbm model
# - Output  : high_risk_patients.csv saved in same folder as input data
# =====================================================

#######################################################
### Require Packages ##################################
#######################################################

load_packages = function(packages) {
  for (pkg in packages) {
    if (!require(pkg, character.only = TRUE, quietly = TRUE)) {
      cat("Installing missing package:", pkg, "\n")
      install.packages(pkg, repos = "https://cran.rstudio.com/")
      library(pkg, character.only = TRUE)
    }
  }
}

# Load required packages
required_packages = c("gbm", "tidyverse")
load_packages(required_packages)

#######################################################
### Parse Args ########################################
#######################################################

# Parse command line args
args = commandArgs(trailingOnly = TRUE)

# args as a named list
parse_args = function(args) {
  res = list()
  for (i in seq(1, length(args), by = 2)) {
    flag = args[i]
    val  = args[i + 1]
    name = sub("^--", "", flag)  # remove leading --
    res[[name]] = val
  }
  res
}

parsed = parse_args(args)

# Check required arguments
if (is.null(parsed$data) || is.null(parsed$model)) {
  stop("Please provide both --data and --model arguments.\nUsage: Rscript analyze.R --data data.csv --model model.rds")
}

data_path  = parsed$data
model_path = parsed$model

# Check files exist
if (!file.exists(data_path)) {
  stop("Data file does not exist: ", data_path)
}
if (!file.exists(model_path)) {
  stop("Model file does not exist: ", model_path)
}

# Load RDS objects
data  = read.csv(data_path)
model = readRDS(model_path)

#######################################################
### Data Check ########################################
#######################################################

features = model$var.names

# Check ID column
if (!("PatientDurableKey" %in% names(data))) {
  stop("? ID column not found in data: PatientDurableKey")
}

# Check features
missing_features = setdiff(features, names(data))

if (length(missing_features) > 0) {
  stop("? Missing feature(s) in data: ", paste(missing_features, collapse = ", "))
}

non_numeric_cols = features[!sapply(data[features], is.numeric)]
if (length(non_numeric_cols) > 0) {
  stop("Error: The following columns must be numeric: ", 
       paste(non_numeric_cols, collapse = ", "))
}

#######################################################
### Imputation ########################################
#######################################################

count_stdev_columns = features[grepl("_count$|_stdev$", features)]
other_columns = setdiff(features, count_stdev_columns)

# Calculate medians
medians = sapply(data[other_columns], median, na.rm = TRUE)

# Impute count and stdev columns with 0
for(col in count_stdev_columns) {
  if(sum(is.na(data[[col]])) > 0) {
    cat("Imputing", sum(is.na(data[[col]])), "missing values", col, "with 0\n")
    data[[col]][is.na(data[[col]])] = 0
  }
}

# Impute other columns with median
for(col in other_columns) {
  median_value = medians[col]
  if(sum(is.na(data[[col]])) > 0) {
    cat("Imputing", sum(is.na(data[[col]])), "missing values", col, "with median:", median_value, "\n")
    data[[col]][is.na(data[[col]])] = median_value
  }
}

#######################################################
### Predictions #######################################
#######################################################

preds = predict(model, data,  n.trees = model$n.trees, type = "response")

# Get IDs of patients with >= 20% risk
threshold = 0.20
high_risk_results = data.frame(
  PatientDurableKey = data$PatientDurableKey[preds >= threshold],
  PredictedProbability = round(100*preds[preds >= threshold],2)
)
# Sort by probability (highest risk first)
high_risk_results = high_risk_results[order(-high_risk_results$PredictedProbability), ]

# Write to High Risk list to CSV
data_folder = dirname(data_path)
cat("Results will be saved to:", file.path(data_folder, "high_risk_patients.csv"), "\n")
write.csv(high_risk_results, file.path(data_folder, "high_risk_patients.csv"), row.names = FALSE)


