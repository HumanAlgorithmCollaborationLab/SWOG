library(gbm)
library(tidyverse)
library(pROC)
library(caret)

setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
source("Helper_Functions.R")

model_files = list.files("Data/Output/GBM_Grid_Models", full.names = TRUE)
test = readRDS("Data/Output/test_data.RDS")
train = readRDS("Data/Output/train_data.RDS")

##############################################################
## Select Best Model #########################################
##############################################################

results = lapply(model_files, function(f) {
  m = readRDS(f)
  preds = predict(m, test,  n.trees = m$n.trees, type = "response")
  roc_obj = pROC::roc(test$mortality_180, preds)
  auc_val = pROC::auc(roc_obj)
  
  data.frame(
    file = f,
    depth = m$interaction.depth,
    trees = m$n.trees,
    shrinkage = m$shrinkage,
    nminobs = m$n.minobsinnode,
    test_auc = auc_val
  )
})

results_bound = do.call(rbind, results)
results_bound = results_bound %>% arrange(desc(test_auc))
best_result = results_bound %>% filter(test_auc == max(test_auc))
best_model = readRDS(best_result$file)

##############################################################
## Best Model Evaluation #####################################
##############################################################
# Evaluate GBM at Optimal Threshold
evaluate_gbm(best_model, train, test, threshold = "optimal")

# Evaluate GBM at High-Risk Threshold (flags top X% of predicted probabilities)
evaluate_gbm(best_model, train, test, threshold = 0.2)

# Feature Importance
importance = summary(best_model, plotit = FALSE)
importance$rel.inf = round(importance$rel.inf, 2)
print(importance)

# Calibration Plot
cal_result = create_gbm_calibration_plot(test, best_model)
cal_result

#saveRDS(best_model, "Data/Output/final_gbm_grid_model.RDS")
