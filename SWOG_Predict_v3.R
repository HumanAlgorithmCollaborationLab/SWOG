# ===================== HOW TO RUN =====================
# From terminal/command line:
#
# Rscript SWOG_Predict_v3.R \
#   --data path/to/input_data.csv \
#   --model path/to/model.rds
#
# Example:
# Rscript SWOG_Predict_v3.R \
#   --data ./data/patient_data.csv \
#   --model ./models/final_gbm_grid_model.rds
#
# Notes:
# - --data  : CSV file containing patient-level features
# - --model : RDS file containing trained gbm model
# - Output  : high_risk_patients.csv saved in same folder as input data
# - Output  : risk_distribution.png saved in same folder as input data
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

# Convert non-numeric features to numeric
cols_to_fix = features[!sapply(data[features], is.numeric)]
data[cols_to_fix] = lapply(data[cols_to_fix], as.numeric)

non_numeric_cols = features[!sapply(data[features], is.numeric)]
if (length(non_numeric_cols) > 0) {
  stop("Error: The following columns must be numeric: ", 
       paste(non_numeric_cols, collapse = ", "))
}

#######################################################
### Entirely Missing Column Imputation ################
#######################################################

# COSMOS Cohort Median Values
median_vals <- c(
  eosinophils_min = 0.1,
  eosinophils_percent_max = 3,
  band_neutrophils_manual_percent_first = 2,
  band_neutrophils_manual_percent_last = 2,
  band_neutrophils_manual_percent_max = 4,
  band_neutrophils_manual_percent_stdev = 2.394438,
  lymphocytes_first = 1.57,
  lymphocytes_last = 1.5,
  lymphocytes_max = 1.82,
  lymphocytes_stdev = 0.2792848,
  lymphocytes_percent_first = 24.3,
  lymphocytes_percent_last = 24,
  lymphocytes_percent_min = 18.3,
  lymphocytes_percent_max = 29,
  lymphocytes_percent_stdev = 4.684839,
  monocytes_first = 0.59,
  monocytes_last = 0.57,
  monocytes_min = 0.45,
  monocytes_max = 0.7,
  monocytes_stdev = 0.1309307,
  monocytes_percent_first = 8.2,
  monocytes_percent_last = 8.4,
  monocytes_percent_max = 10,
  monocytes_percent_stdev = 1.527624,
  mcv_first = 91.1,
  mcv_last = 91.4,
  rdw_percent_first = 13.6,
  rdw_percent_last = 13.8,
  rdw_percent_min = 13.2,
  rdw_percent_max = 14.4,
  neutrophils_max = 5.23,
  neutrophils_stdev = 0.991704,
  platelets_first = 234,
  platelets_last = 229,
  platelets_min = 199,
  platelets_max = 265,
  platelets_stdev = 27.36081,
  egfr_last = 76,
  egfr_min = 68,
  egfr_max = 82.1,
  urea_nitrogen_first = 16,
  urea_nitrogen_last = 16,
  urea_nitrogen_min = 13,
  urea_nitrogen_max = 19,
  glucose_first = 103,
  glucose_last = 103,
  calcium_min = 9,
  bilirubin_first = 0.5,
  bilirubin_last = 0.5,
  bilirubin_min = 0.4,
  bilirubin_max = 0.6,
  bilirubin_stdev = 0.1154701,
  carbon_dioxide_last = 26,
  carbon_dioxide_min = 24,
  chloride_first = 104,
  chloride_min = 102,
  fibrinogen_first = 367,
  fibrinogen_last = 365,
  fibrinogen_min = 324,
  fibrinogen_max = 408,
  fibrinogen_stdev = 69.68251,
  aptt_first = 30,
  aptt_last = 30,
  aptt_max = 31.1,
  aptt_stdev = 2.828427,
  pt_max = 13.1,
  uric_acid_first = 5.5,
  uric_acid_last = 5.2,
  uric_acid_min = 4.9,
  uric_acid_max = 5.8,
  uric_acid_stdev = 0.6969321
)

entirely_missing = features[sapply(data[features], function(x) all(is.na(x)))]

if (length(entirely_missing) > 0) {
  cat("\n--- Entirely Missing Columns Detected ---\n")
  for (col in entirely_missing) {
    if (grepl("_count$", col)) {
      data[[col]] <- 0
      cat("Entirely missing:", col, "-> imputed with 0 (count column)\n")
    } else if (col %in% names(median_vals)) {
      data[[col]] <- median_vals[[col]]
      cat("Entirely missing:", col, "-> imputed with COSMOS median\n")
    } else {
      cat("WARNING: Entirely missing:", col, "-> no imputation value found, leaving as NA\n")
    }
  }
  cat("-----------------------------------------\n\n")
} else {
  cat("No entirely missing columns detected.\n")
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

preds = predict(model, data, n.trees = model$n.trees, type = "response")

# Get IDs of patients with >= 20% risk
threshold = 0.20
high_risk_results = data.frame(
  PatientDurableKey = data$PatientDurableKey[preds >= threshold],
  PredictedProbability = round(100 * preds[preds >= threshold], 2)
)
# Sort by probability (highest risk first)
high_risk_results = high_risk_results[order(-high_risk_results$PredictedProbability), ]

# Write High Risk list to CSV
data_folder = dirname(data_path)
cat("Results will be saved to:", file.path(data_folder, "high_risk_patients.csv"), "\n")
write.csv(high_risk_results, file.path(data_folder, "high_risk_patients.csv"), row.names = FALSE)

#######################################################
### Risk Distribution Plot ############################
#######################################################

preds_pct = preds * 100

cat(sprintf(
  "\nRisk distribution: %d total patients | %d (%.1f%%) at or above 20%% predicted risk\n",
  length(preds_pct),
  sum(preds_pct >= 20),
  100 * mean(preds_pct >= 20)
))

# Compute quantiles across the full distribution
quantile_probs = c(0.50, 0.75, 0.80, 0.90, 0.95)
quantile_labels = c("Median (50th)", "75th", "80th", "90th", "95th")
quantile_vals = quantile(preds_pct, probs = quantile_probs)

# Build annotation data frames for vertical lines
quant_df = data.frame(
  x     = as.numeric(quantile_vals),
  label = paste0(quantile_labels, " (", round(quantile_vals, 1), "%)")
)

threshold_df = data.frame(
  x     = 20,
  label = "20% Initial Threshold"
)

# Assign colors: quantile lines in a sequential blue palette, threshold in red
quant_colors  = c("#1b7837", "#4dac26", "#d9ef8b", "#f1a340", "#e08214")
names(quant_colors) = quant_df$label
thresh_color  = c("20% Initial Threshold" = "#d73027")
all_colors    = c(quant_colors, thresh_color)

# Build the plot
p = ggplot(data.frame(risk = preds_pct), aes(x = risk)) +
  geom_density(fill = "#deebf7", color = "#2171b5", alpha = 0.6, linewidth = 0.8) +
  # Quantile lines (solid)
  geom_vline(
    data = quant_df,
    aes(xintercept = x, color = label),
    linewidth = 0.75,
    linetype  = "solid"
  ) +
  # 20% threshold line (dotted)
  geom_vline(
    data = threshold_df,
    aes(xintercept = x, color = label),
    linewidth = 1.0,
    linetype  = "dotted"
  ) +
  scale_color_manual(
    name   = "Reference Lines",
    values = all_colors,
    breaks = c(names(quant_colors), "20% Initial Threshold")
  ) +
  scale_x_continuous(
    labels = function(x) paste0(x, "%"),
    expand = expansion(mult = c(0.01, 0.02))
  ) +
  scale_y_continuous(expand = expansion(mult = c(0, 0.05))) +
  labs(
    title    = "Estimated Risk Distribution — Full Cohort",
    subtitle = sprintf(
      "Full cohort (n = %d) | %d patients (%.1f%%) at or above 20%% risk",
      length(preds_pct), sum(preds_pct >= 20), 100 * mean(preds_pct >= 20)
    ),
    x = "Estimated Risk (%)",
    y = "Density"
  ) +
  theme_minimal(base_size = 13) +
  theme(
    plot.title       = element_text(face = "bold", size = 14),
    plot.subtitle    = element_text(color = "gray40", size = 11),
    legend.position  = "right",
    legend.title     = element_text(face = "bold", size = 11),
    legend.text      = element_text(size = 10),
    panel.grid.minor = element_blank(),
    axis.title       = element_text(size = 12)
  )

# Save plot
plot_path = file.path(data_folder, "risk_distribution.png")
ggsave(plot_path, plot = p, width = 9, height = 5.5, dpi = 150)
cat("Risk distribution plot saved to:", plot_path, "\n")