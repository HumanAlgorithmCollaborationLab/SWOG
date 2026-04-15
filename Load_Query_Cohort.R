library(odbc)
library(DBI)
library(tidyverse)

setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
source("Helper_Functions.R")

##############################################################
##  Load SQL Table from Projects DB ##########################
##############################################################
# Define server and database variables
server = "PROJECTS"
database = "ProjectD41E126" # replace with class-specific project database
# Define the SQL connection string variable
odbcString = sprintf("driver={ODBC Driver 17 for SQL Server}; Server=tcp:%s; Database=%s; 
                       Trusted_Connection=yes; timeout=10", server, database)
# Define a SQL connection variable
con = dbConnect(odbc(), .connection_string = odbcString)
# Define a string variable to store your SQL query
sqlQuery = "SELECT * FROM dbo.AAG_SWOG_Cohort"
# Execute the SQL query to populate a data frame
df = dbGetQuery(con, sqlQuery)
# Close the SQL connection
dbDisconnect(con)

##############################################################
##  Create Feature List ######################################
##############################################################
# Labs
lab_text = paste(readLines("Data/Input/lab_names_9-9.txt"), collapse = "")
lab_base_names = extract_column_names(lab_text)
lab_features = create_suffixed_columns(lab_base_names)
# Elixhauser Conditions
condition_features = df %>% select(ends_with("total_count"), ends_with("recent_count")) %>% names()
percentages = sapply(df[condition_features], function(x) {
  round(sum(x > 0, na.rm = TRUE) / length(x),3)
})
print(percentages)

all_features = c("Age", "Sex", lab_features, condition_features)

##############################################################
##  Train/Test Split #########################################
##############################################################
set.seed(100)
train_idx = sample(seq_len(nrow(df)), size = 0.7 * nrow(df))
train_data = df[train_idx, ]
test_data  = df[-train_idx, ]

##############################################################
##  Imputation ###############################################
##############################################################
imputed_dfs = count_median_imputation(train=train_data, test=test_data, in_vars=all_features)
train = imputed_dfs$train
test = imputed_dfs$test

##############################################################
##  Feature Selection Process ################################
##############################################################
feature_matrix = train %>% select(all_of(all_features))

######### 1. Drop Variables with Zero Variance ######### 
feature_variances = sapply(seq_len(ncol(feature_matrix)), function(i) {
  var(feature_matrix[[i]])
})

nonzero_var_features = !is.na(feature_variances) & feature_variances != 0
fm_var_filter = feature_matrix[, nonzero_var_features]

######### 2. Drop Highly Correlated Features ######### 
CORRELATION_THRESHOLD = 0.95
grouped = c()
grouped_dict = list()
cor_map = cor(fm_var_filter, use = "complete.obs")

for (var in rownames(cor_map)) {
  if (!var %in% grouped) {
    cor_vec = cor_map[var, ]
    idb_cor = cor_vec > CORRELATION_THRESHOLD
    collected = names(cor_vec)[idb_cor]
    collected = collected[collected != var]
    grouped = c(grouped, collected)
    grouped_dict[[var]] = collected
  }
}

# Drop those variables that have been grouped into a single representative
fm_cor_filter = fm_var_filter[, !names(fm_var_filter) %in% grouped]

######### 3. Drop Features with no Mutual Information ######### 
curr_feature_cols = names(fm_cor_filter)
fm_outcome = cbind(mortality_180 = train$mortality_180, fm_cor_filter)
target_discrete = fm_outcome$mortality_180

# Calculate mutual information in batches to avoid memory issues
mi_scores = batch_mutual_info(fm_outcome, curr_feature_cols, target_discrete, batch_size = 25)
low_mi_vars = mi_scores[mi_scores$score < 0.0001, "var"]
print(head(mi_scores[order(-mi_scores$score), ], 200))
# Filter out near-zero mutual information variables
fm_mi_filter = fm_outcome[, c("mortality_180", curr_feature_cols[!curr_feature_cols %in% low_mi_vars])]

######### 4. Save Selected Features & Train/Test Data ######### 
in_vars = colnames(fm_mi_filter %>% select(-mortality_180))

saveRDS(in_vars, "Data/Output/in_vars.RDS")
saveRDS(train_data, "Data/Output/train_data.RDS")
saveRDS(test_data, "Data/Output/test_data.RDS")



