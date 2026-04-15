library(tidyverse)
library(caret)
library(gbm)

setwd(dirname(rstudioapi::getActiveDocumentContext()$path))
in_vars = readRDS("Data/Output/in_vars.RDS")
train = readRDS("Data/Output/train_data.RDS")

# Directory to save models
save_dir <- "Data/Output/GBM_Grid_Models"
dir.create(save_dir, showWarnings = FALSE, recursive = TRUE)

# Hyperparameter grid
fullgrid <- expand.grid(
  interaction.depth = c(2,3,4,5),
  n.trees = c(100,150,200,250),
  shrinkage = c(0.1),
  n.minobsinnode = c(100)
)

ctrl <- trainControl(
  method = "none",
  classProbs = TRUE,
  summaryFunction = twoClassSummary
)

# Specify model outcome and features
formula_str = paste("mortality_180 ~", paste(in_vars, collapse = " + "))
formula_obj = as.formula(formula_str)

start <- Sys.time()

# Save each model separately
for (i in 1:nrow(fullgrid)) {
  params <- fullgrid[i, ]
  message("Training model ", i, " of ", nrow(fullgrid), " ...")
  
  fit <- gbm(
    formula = formula_obj,
    data = train,
    distribution = "bernoulli",
    n.trees = params$n.trees,
    interaction.depth = params$interaction.depth,
    shrinkage = params$shrinkage,
    n.minobsinnode = params$n.minobsinnode,
    bag.fraction = 0.8,
    train.fraction = 0.8,
    cv.folds = 0,
    keep.data = FALSE,
    verbose = TRUE
  )
  
  saveRDS(fit, file = file.path(save_dir, paste0("gbm_model_", i, ".rds")))
}

end <- Sys.time()
gbmtime = end - start
paste0("Runtime: ", round(gbmtime,2), " hours")
