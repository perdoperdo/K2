# load required packages
require(xgboost) # not on CRAN? devtools::install_github('dmlc/xgboost',subdir='R-package')
library(data.table)
require(bit64)
library(gbm)
library(tidyr)
library(ggplot2) 
library(scales)
library(caret)
library(lubridate)
library(corrplot)
library(plyr)
library(dplyr)
library(pROC)
library(RANN)
require(Ckmeans.1d.dp) # for XGBoost plot

macWD <- "~/Documents/science/kaggle/springleaf/K2"
winWD <- "D:/usr/science/kaggle/springleaf/K2"
if (file.exists(macWD)) {
  setwd(macWD)
} else {
  setwd(winWD)
}
source('funcs.R') # common funcs - inherited from previous Kaggle project

try(dev.off(),silent=T) # prevent graphics errors
set.seed(314159)
Sys.setlocale("LC_TIME", "C")
epoch <- now()
gc()

settings.useSmallSample <- F # set to true to quickly test changes on a subset of the training data
# settings.useSmallSample <- T # set to true to quickly test changes on a subset of the training data

settings.doCaretTuning <- T
settings.doXGBoost <- T
settings.doScoring <- !settings.useSmallSample # score the test set for the Kaggle LB
settings.doGeneratePlots <- F # whether to generate plots for every field 
settings.threshold.symbin.minsize <- 10 # TODO: add numbin seeting here (minobs)
settings.threshold.TreatIntAsNumeric <- 100
settings.cutoffUnivariateAUC <- 0.51 # predictors with lower AUC will be deselected
settings.correlationThreshold <- 0.80 # predictors with higher correlation will be deselected

settings.gbm.n.trees <- 300 # 300 for benchmarking, 1000 for real score
settings.gbm.interaction.depth <- 20 # 30 for real score
settings.gbm.shrinkage <- 0.02 # TODO need to find best value here 
settings.gbm.cv.folds <- 3 # often 3 on Mac, 5 on Lenovo


###########################
# Read Data
###########################

if(settings.useSmallSample) {
  train <- fread("./data/train_small.csv", header = T, sep = ",",
                 stringsAsFactors=F,integer64="double",data.table=F)
  test <- fread("./data/test_small.csv", header = T, sep = ",",
                stringsAsFactors=F,integer64="double",data.table=F)
} else {
  train <- fread("./data/train-2.csv", header = T, sep = ",",
                 stringsAsFactors=F,integer64="double",data.table=F)
  test <- fread("./data/test-2.csv", header = T, sep = ",",stringsAsFactors=F,integer64="double",data.table=F)
}
xtraDemographic <- fread("./additionalData/cityInfo.csv", header=T,sep=",")
train <- join(train, xtraDemographic, by="ID", type="left")
test <- join(test, xtraDemographic, by="ID", type="left")
train$ID <- NULL

for (col in 1:ncol(train)) { # change logicals into numerics
  if (is.logical(train[[col]])) train[[col]] <- as.numeric(train[[col]])
}
for (col in 1:ncol(test)) {
  if (is.logical(test[[col]])) test[[col]] <- as.numeric(test[[col]])
}

testIDs <- test$ID
test$ID <- NULL

# Quickly replace '-1' and '' by NA in symbolic fields - should not influence binning but will
# influence NA row count below
for (colName in colnames(train)[which(sapply(train, function(col) { return (!is.numeric(col)) } ))]) {
#   print(createSymbin(train[[colName]],train$target))
  train[[colName]][train[[colName]] == "-1" | train[[colName]] == ""] <- NA
  test[[colName]][test[[colName]] == "-1" | test[[colName]] == ""] <- NA
  #   print(createSymbin(train[[colName]],train$target))
}

# Special extra fields - before doing any further processing
# Add variable with nr of missing values per row. Make double to ensure numeric treatment.
print("Counting NA's per row - time consuming")
train$xtraNumNAs <- as.double(apply(train, 1, function(z) sum(is.na(z))))
test$xtraNumNAs <- as.double(apply(test, 1, function(z) sum(is.na(z))))

# Dev/val split
trainIndex <- createDataPartition(train$target, p=0.80, list=FALSE)
train_dev <- train[ trainIndex,]
train_val <- train[-trainIndex,]

###########################
# Preliminary Data Analysis
###########################

dataMetrics <- dataAnalysis(train_dev, train_val, test, 
                            settings.doGeneratePlots, "plots")

# dump & write to files for external analysis
#print(head(dataMetrics))
write.table(cbind(rownames(dataMetrics), data.frame(lapply(dataMetrics, as.character), stringsAsFactors=FALSE)), 
            "./dataMetrics.csv", sep=";", row.names=F,
            col.names = c("Field", names(dataMetrics)))

if (F) {
  # Save a dataset with the vars with many distincts for review
  # NB: VAR_0200 seems to be a region, perhaps use that. But VAR_0274 is state already.
  dataSetManyDistincts <- train[, which(dataMetrics$nDistinct > 50 & dataMetrics$isSymbolic & !dataMetrics$isDate)]
  write.table(dataSetManyDistincts, "./dataSetManyDistincts.csv", sep=";", row.names=F)
  
  write.table(sample_n(train, 10000), "./trainSample10k.csv", sep=";")
}

rm(train) # no longer need this
gc()

###########################
# Feature engineering
###########################

print("Feature engineering")

# Convert dates to time to epoch and add derived field(s) like weekday
processDateFlds <- function(ds, colNames) {
  extraDateFlds <- NULL
  for (colName in colNames) {
    #cat("Date: ", colName, fill=T)
    asDate <- strptime(ds[[colName]], format="%d%b%y")
    asDate_wday <- as.character( c("Sun","Mon","Tue","Wed","Thu","Fri","Sat") [wday(asDate)])
    asDate_week <- week(asDate)
    if (is.null(extraDateFlds)) {
      extraDateFlds <- data.frame(asDate_wday, asDate_week, stringsAsFactors = F)
      colnames(extraDateFlds) <- c(paste(colName, "_wday", sep=""),
                                   paste(colName, "_week", sep=""))
    } else {
      prevNames <- colnames(extraDateFlds)
      extraDateFlds <- cbind(extraDateFlds, asDate_wday, asDate_week, stringsAsFactors = F)
      colnames(extraDateFlds) <- c(prevNames, 
                                   paste(colName, "_wday", sep=""),
                                   paste(colName, "_week", sep=""))
    }
    
    # convert field itself to date and append field name
    ds[[colName]] <- as.double(epoch - asDate)
    colnames(ds) [which(colnames(ds) == colName)] <- paste(colName, "_asdate", sep="")
  }
  return(cbind(ds, extraDateFlds))
}

dateFldNames <- rownames(dataMetrics) [dataMetrics$isDate]
cat("Date fields: ", dateFldNames, " (", length(dateFldNames), ")", fill=T)

if (length(dateFldNames) > 0) {
  train_dev <- processDateFlds(train_dev, dateFldNames)
  train_val <- processDateFlds(train_val, dateFldNames)
  test <- processDateFlds(test, dateFldNames)
  
  # Create combinations of all possible date pairs. Perhaps some date differences are a good predictor.
  combineDates <- function(ds, fldNames) {
    if (length(fldNames) >= 2) {
      first <- fldNames[1]
      rest <- fldNames[2:length(fldNames)]
      
      # add new column side by side with old one (new name)
      for (second in rest) {
        combinedName <- paste(first, second, sep="_")
        cat("Combine dates: ", combinedName, fill=T)
        ds[[combinedName]] <- ds[[second]] - ds[[first]]
      }
      return(combineDates(ds, rest))
    } else {
      return(ds)
    }
  }
  train_dev <- combineDates(train_dev, paste( dateFldNames, '_asdate', sep=""))
  train_val <- combineDates(train_val, paste( dateFldNames, '_asdate', sep=""))
  test <- combineDates(test, paste( dateFldNames, '_asdate', sep=""))
}

# Add newly engineered fields to the data metrics overview
newFields <- setdiff(setdiff(colnames(train_dev), rownames(dataMetrics)),"target")
newFieldsWithTarget <- c(newFields, "target")
metricsNewFields <- dataAnalysis(train_dev[, newFieldsWithTarget], 
                                 train_val[, newFieldsWithTarget],
                                 test[, newFields],
                                 settings.doGeneratePlots, "plots")
dataMetrics <- rbind(dataMetrics, metricsNewFields)

###########################
# Data Analysis
###########################

print("Data Analysis")

dataMetrics$AUCVal <- NA
dataMetrics$AUCDev <- NA
dataMetrics$Binning <- NA
dataMetrics$BinParam <- NA
dataMetrics$FinalName <- NA

# if all is well, some fields will now not be binned

doTreatAsSymbolic <- function( dataMetrics )
{
  treatAsSymbolic <- (dataMetrics$isSymbolic && !dataMetrics$isDate) ||
    (dataMetrics$className == "integer" && dataMetrics$Overlap > 0.90)  
  return(treatAsSymbolic)
}

doTreatAsNumeric <- function( dataMetrics )
{
  treatAsNumeric <-  (dataMetrics$className == "numeric") ||
                        (dataMetrics$nDistinct > settings.threshold.TreatIntAsNumeric)
  
  return(treatAsNumeric)
}

for (colName in colnames(test)) {
  dataMetricRow <- which(rownames(dataMetrics) == colName)
  if (dataMetrics$nDistinct[dataMetricRow] > 2) {
    if (doTreatAsSymbolic( dataMetrics[dataMetricRow,] )) {
      # do symbolic binning with residuals
      
      cat("SymBin fld:", colName, fill=T)

      paramRange <- c(settings.threshold.symbin.minsize/nrow(train_dev)) # no variation now
      #paramRange <- c(0.001,0.002,0.005,0.01,0.02, 10/nrow(train_dev)) # instead of settings.threshold.symbin.MinPercentage

      bestPerf <- 0
      for (param in paramRange) {
        binning <- createSymbin(train_dev[[colName]], train_dev$target, 
                                param)
        perf <- auc(train_val$target, applySymbin(binning, train_val[[colName]]))
        if (perf > bestPerf) {
          bestPerf <- perf
          bestBinning <- binning
          bestParam <- param
        }
        cat("Symbin params:",param,perf,bestPerf,bestParam,fill=T)
      }
      
      if (settings.doGeneratePlots) {
        sb.plotOne(bestBinning, train_dev, train_val, test, colName, "target", plotFolder="plots")
      }
      print(head(bestBinning))
      if (nrow(bestBinning) > 6) { print(tail(bestBinning)) }
      
      train_dev[[colName]] <- applySymbin(bestBinning, train_dev[[colName]])
      train_val[[colName]] <- applySymbin(bestBinning, train_val[[colName]])
      test[[colName]]      <- applySymbin(bestBinning, test[[colName]])
      
      # replace column but change name
      newColName <- paste(colName, "_symbin", sep="")
      colnames(train_dev) [which(colnames(train_dev) == colName)] <- 
        colnames(train_val) [which(colnames(train_val) == colName)] <- 
        colnames(test) [which(colnames(test) == colName)] <- newColName
      
      # keep AUC
      dataMetrics$AUCVal[dataMetricRow] <- auc(train_val$target, train_val[[newColName]])
      dataMetrics$AUCDev[dataMetricRow] <- auc(train_dev$target, train_dev[[newColName]])
      dataMetrics$Binning[dataMetricRow] <- "symbin"
      dataMetrics$BinParam [dataMetricRow] <- bestParam*nrow(train_dev)
      dataMetrics$FinalName[dataMetricRow] <- newColName
      
    } else if (doTreatAsNumeric( dataMetrics[dataMetricRow,] )) { 
      
      # do numeric binning 
      cat("Numbin fld:", colName, fill=T)
      
      #paramRange <- c(2,4,8,seq(10,90,by=10),seq(100,300,by=50)) 
      #paramRange <- paramRange[ paramRange <= dataMetrics$nDistinct[dataMetricRow] ]
      paramRange <- c(100)
      bestPerf <- 0
      for (param in paramRange) {
        binning <- createNumbin(train_dev[[colName]],train_dev$target,param)
        perf <- auc(train_val$target, applyNumbin(binning, train_val[[colName]]))
        if (perf > bestPerf) {
          bestPerf <- perf
          bestBinning <- binning
          bestParam <- param
        }
        cat("Numbin params:",param,perf,bestPerf,bestParam,fill=T)
      }
      
      if (settings.doGeneratePlots) {
        plotNumbin(bestBinning, "plots")
      }
      print(head(bestBinning))
      if (nrow(bestBinning) > 6) { print(tail(bestBinning)) }
      
      train_dev[[colName]] <- applyNumbin(bestBinning, train_dev[[colName]])
      train_val[[colName]] <- applyNumbin(bestBinning, train_val[[colName]])
      test[[colName]] <- applyNumbin(bestBinning, test[[colName]])
      
      # replace column but change name
      newColName <- paste(colName, "_numbin", sep="")
      colnames(train_dev) [which(colnames(train_dev) == colName)] <- 
        colnames(train_val) [which(colnames(train_val) == colName)] <- 
        colnames(test) [which(colnames(test) == colName)] <- newColName

      # keep AUC
      dataMetrics$AUCVal[dataMetricRow] <- auc(train_val$target, train_val[[newColName]])
      dataMetrics$AUCDev[dataMetricRow] <- auc(train_dev$target, train_dev[[newColName]])
      dataMetrics$Binning[dataMetricRow] <- "numbin"
      dataMetrics$BinParam [dataMetricRow] <- bestParam
      dataMetrics$FinalName[dataMetricRow] <- newColName
    } else { # not binned numeric
      
      # Replace NAs by column mean (binned columns will have 'no' NAs ... not really true)
      # ??? not sure
#       if (any(is.na(aCol))) {
#         m <- colMeans(aCol,  na.rm = TRUE)
#         if (verbose) {
#           cat("   imputing", colnames(ds) [colNo], sum(!complete.cases(aCol)),"NAs with mean", m, fill=TRUE)
#         }
#         ds[!complete.cases(aCol), colNo] <- m
#       }
      
      
      # keep AUC
      dataMetrics$AUCVal[dataMetricRow] <- auc(train_val$target, train_val[[colName]])
      dataMetrics$AUCDev[dataMetricRow] <- auc(train_dev$target, train_dev[[colName]])
      dataMetrics$Binning[dataMetricRow] <- "none"
      dataMetrics$BinParam [dataMetricRow] <- NA
      dataMetrics$FinalName[dataMetricRow] <- colName
    }
  } else {
    # < 2 distinct values
    dataMetrics$AUCVal[dataMetricRow] <- 0.50
    dataMetrics$AUCDev[dataMetricRow] <- 0.50
    dataMetrics$Binning[dataMetricRow] <- NA
    dataMetrics$BinParam [dataMetricRow] <- NA
    dataMetrics$FinalName[dataMetricRow] <- colName
  }
}

# Write data analysis results again, now including the newly created fields
write.table(cbind(rownames(dataMetrics), 
                  data.frame(lapply(dataMetrics, as.character), stringsAsFactors=FALSE)), 
            "./dataMetrics.csv", sep=";", row.names=F,
            col.names = c("Field", names(dataMetrics)))

###########################
# Feature selection
###########################

print("Feature selection")

# Univariate selection
removedUnivariate <- rownames(dataMetrics) [dataMetrics$isSymbolic | 
                                          (!is.na(dataMetrics$AUCVal) &
                                             dataMetrics$AUCVal < settings.cutoffUnivariateAUC)]
cat("Removed after univariate analysis:", length(removedUnivariate), fill=T)
train_dev <- train_dev[,!(names(train_dev) %in% removedUnivariate)]
train_val <- train_val[,!(names(train_val) %in% removedUnivariate)]
test      <- test[,!(names(test) %in% removedUnivariate)]
cat("Remaining after univariate selection:", length(colnames(train_dev)), fill=T)

# Brute force NA imputation - not sure. Maybe not needed, and knn would be beter anyhow.
# train_dev <- imputeNAs(train_dev)
# train_val <- imputeNAs(train_val)
# test <- imputeNAs(test)

###########################
# Correlations
###########################
cat("Correlation", fill=T)
trainCor <- cor( sample_n(select(train_dev, -target), min(nrow(train_dev),10000))) # TODO: effect of this number?
#  trainCor <- cor( sample_n(select(train_dev, -target), 10000), use="everything") # use="everything", "all.obs", "complete.obs", "na.or.complete", or "pairwise.complete.obs"

# Pair-wise selection of predictors with high correlation. From each pair,
# deselect the one with the lower univariate AUC. The resulting 'corrMetrics' 
# data frame contains names and metrics of all highly correlated variables.
corrMetrics <- data.frame(which(trainCor > settings.correlationThreshold, arr.ind=TRUE), row.names=NULL) %>% 
  filter( col > row) %>%
  mutate( A = rownames(trainCor)[row]) %>%
  mutate( B = rownames(trainCor)[col]) %>%
  inner_join( select(dataMetrics, AUCVal, FinalName), by=c("A" = "FinalName")) %>%
  mutate( A_AUC = AUCVal, AUCVal = NULL ) %>% 
  inner_join( select(dataMetrics, AUCVal, FinalName), by=c("B" = "FinalName")) %>%
  mutate( B_AUC = AUCVal, AUCVal = NULL ) %>% 
  mutate( Drop = ifelse(A_AUC>B_AUC, B, A))
corrMetrics$Corr <- 0
for (n in 1:nrow(corrMetrics)) {
  corrMetrics$Corr[n] <- trainCor[corrMetrics$row[n], corrMetrics$col[n]]
}
corrMetrics <- arrange(corrMetrics, desc(Corr))

print(head(corrMetrics))

highlyCorrelatedVars <- c()
for (dropRow in 1:nrow(corrMetrics)) {
  if (!corrMetrics$A[dropRow] %in% highlyCorrelatedVars && !corrMetrics$B[dropRow] %in% highlyCorrelatedVars) {
    highlyCorrelatedVars <- c(highlyCorrelatedVars, corrMetrics$Drop[dropRow])
  }
}

cat("Removing", length(highlyCorrelatedVars), "highly correlated variables", fill=T)

train_dev_noNAs <- train_dev[, as.vector(which( sapply(train_dev, 
                                                       function(col) { 
                                                         return(is.numeric(col) & !any(is.na(col))) 
                                                         }) ))]
linearCombos <- findLinearCombos(as.matrix(train_dev_noNAs))
removeLinear <- names(train_dev_noNAs)[ linearCombos[["remove"]]]

cat("Removing", length(removeLinear), "linear combinations", fill=T)

highlyCorrelatedVars <- c(highlyCorrelatedVars, removeLinear)

if (length(highlyCorrelatedVars) > 0) {
  train_dev <- train_dev[!(names(train_dev) %in% highlyCorrelatedVars)]
  train_val <- train_val[!(names(train_val) %in% highlyCorrelatedVars)]
  test      <- test[!(names(test) %in% highlyCorrelatedVars)]
  
  #trainCor <- cor(select(imputeNAs(train_dev), -IsClick))
  #corrplot(trainCor, method="circle", type="upper", order = "hclust", addrect = 3)
} else {
  print("No highly correlated or linear variables")
}

# Dump the data here. Taking the col names from our analysis but using the original data.
# Just for the purpose of analyzing with ADM/PAD limiting the number of columns to < 1000 - hopefully.
if (F) {
  keep_cols <- names(train_dev)
  test_ori <- fread("./data/test-2.csv", header = T, sep = ",",stringsAsFactors=T, nrows=1000) # just for cols
  drop_cols <- setdiff(names(test_ori),keep_cols)
  
  train_ori <- fread("./data/train-2.csv", header = T, sep = ",",stringsAsFactors=T, drop=drop_cols)
  test_ori <- fread("./data/test-2.csv", header = T, sep = ",",stringsAsFactors=T, drop=drop_cols)  
  
  cat("Dimension: ", dim(train_ori), fill=T)
  write.csv(sample_n(train_ori, 10000), "./data/train-trunc-small.csv", row.names=FALSE)
  write.csv(sample_n(test_ori, 10000), "./data/test-trunc-small.csv", row.names=FALSE)
  write.csv(train_ori, "./data/train-trunc-full.csv", row.names=FALSE)
  write.csv(test_ori, "./data/test-trunc-full.csv", row.names=FALSE)
}

#########################################
# Fit Logistic regression (as a benchmark)
#########################################
logitModel  <- glm(target ~ ., data=train_dev) # family = "binomial"
cat("Number of vars: ", length(colnames(train_dev)), fill=T)
cat('GLM benchmark Val AUC:', 
    auc(train_val$target, predict(logitModel, train_val)),
    'Dev AUC:',
    auc(train_dev$target, predict(logitModel, train_dev)), 
    fill=T )

###########################
# Fit model
###########################
print('Fit model')
gc()
if (settings.doCaretTuning) {
  # unfinished - see http://topepo.github.io/caret/training.html
  
  train_dev$target <- as.factor(train_dev$target) # model needs factor
  levels(train_dev$target) <- c("no", "yes") # predicting probs needs this for some reason
  # not val?
  
  fitControl <- trainControl(## 10-fold CV
    method = "repeatedcv",
    number = 3,
    ## repeated ten times
    repeats = 1,
    classProbs = TRUE,
    summaryFunction = twoClassSummary,
    verboseIter=T)
  
  #Stochastic Gradient Boosting  gbm	Dual Use	gbm, plyr	n.trees, interaction.depth, shrinkage, n.minobsinnode
  #eXtreme Gradient Boosting  xgbLinear	Dual Use	nrounds, lambda, alpha
  #eXtreme Gradient Boosting	xgbTree	Dual Use	nrounds, max_depth, eta
  
  xgbTreeGrid <- expand.grid(
    nrounds = 2000, # 2000
    max_depth = 8,
    eta = c(0.05,0.02))

  xgbLinearGrid <- expand.grid(
    nrounds = seq(100,200,by=100),
    lambda = seq(200,400,by=50),
    alpha = c(10,20))
  
  modelTime <- system.time(model <- train(target ~ ., data = train_dev
                                          ,method="xgbTree"
                                          ,tuneGrid=xgbTreeGrid
#                                           ,method="xgbLinear"
#                                           ,tuneGrid=xgbLinearGrid
                                          ,preProcess = c("knnImpute")
                                          ,metric = "ROC"
                                          ,trControl = fitControl
                                          #,cv.folds=5
                                          # n.cores=2
                                          ,verbose=1
                                          ,lambda = 250
                                          ,alpha = 20))
  
  cat("Duration:",modelTime,fill=T)
  cat("Duration:",modelTime[3]/3600,"hrs",fill=T)
  print(model)
  
  trellis.par.set(caretTheme())
  print( plot(model) )
  
  va <- varImp(model, scale = FALSE) # Caret variable importance
#   print(va)
  print( plot(va, top=50) )
  
  # get best params from caret
  print(model[["bestTune"]])

  # predictions
  predictions <- predict(model, newdata=select(train_val, -target), type = "prob", na.action="na.pass") [["yes"]]
  predictions_dev <- predict(model, newdata=select(train_dev, -target), type = "prob", na.action="na.pass")[["yes"]]
  if (settings.doScoring) {
    print("Scoring test set")
    pr <- predict(model, newdata=test, type = "prob", na.action="na.pass")[["yes"]]
  }
} 

if (settings.doXGBoost) {
  if (class(train_dev$target) == "factor") { #yuk, happens after caret stuff
    y_dev <- ifelse(train_dev$target == "yes",1,0)
  } else {
    y_dev <- train_dev$target
  }
  if (class(train_val$target) == "factor") {
    y_val <- ifelse(train_val$target == "yes",1,0)
  } else {
    y_val <- train_val$target
  }
  dtrain_dev <- xgb.DMatrix(data.matrix(select(train_dev, -target)), label=y_dev,missing=NA)
  dtrain_val <- xgb.DMatrix(data.matrix(select(train_val, -target)), label=y_val,missing=NA)
  print(gc())
  
  watchlist <- list(eval = dtrain_val, train = dtrain_dev)
    
  # see https://www.kaggle.com/mrooijer/springleaf-marketing-response/xgboost-run-local/code
  param <- list(  objective           = "binary:logistic", 
                  #booster = "gblinear",
                  #alpha = 2,
                  eta                 = 0.01,
                  max_depth           = 8,  
                  subsample           = 0.7, 
                  colsample_bytree    = 0.5,
                  min_child_weight    = 20,
                  alpha               = 4,
                  gamma               = 100,
                  nthreads            = 3,
                  eval_metric         = "auc"
#                   scale_pos_weight = 1/mean(train_dev$target)
                  # alpha = 0.0001, 
                  # lambda = 1
  )
  
  xgbModel <- xgb.train(params              = param, 
                        data                = dtrain_dev, 
                        nrounds             = 1000,
                        verbose             = 1, 
                        print.every.n       = 10,
                        early.stop.round    = 100,
                        watchlist           = watchlist,
                        maximize            = TRUE)
  
  cat("Best XGB iteration:",xgbModel$bestInd,fill=T)
  cat("Best XGB score:",xgbModel$bestScore,fill=T)

  # feature importance
  importance_mx <- xgb.importance(names(train_dev), model=xgbModel)
  print( xgb.plot.importance(head(importance_mx,50) )) 
  
  # predictions
  predictions <- predict(xgbModel, dtrain_val, ntreelimit=xgbModel$bestInd)
  predictions_dev <- predict(xgbModel, dtrain_dev, ntreelimit=xgbModel$bestInd)
  if (settings.doScoring) {
    print("Scoring test set")
    pr <- predict(xgbModel, xgb.DMatrix(data.matrix(test), missing = NA), ntreelimit=xgbModel$bestInd)
  }
}

cat("Number of vars: ", length(colnames(train_dev)), fill=T)
cat('GLM benchmark Val AUC:', 
    auc(train_val$target, predict(logitModel, train_val)),
    'Dev AUC:',
    auc(train_dev$target, predict(logitModel, train_dev)), 
    fill=T )

cat('Val AUC:', auc(train_val$target, predictions), 
    '#predictors:', ncol(test), 
    'total time:', difftime(now(),epoch,units='mins'), 'minutes', 
    fill=T )
cat('Dev AUC:', auc(train_dev$target, predictions_dev), 
    fill=T )

###########################
# Apply model on test set
###########################

if (settings.doScoring) {
  print("Writing test set")
  subm <- data.frame(testIDs, pr)
  colnames(subm) <- c('ID','target')
  write.csv(subm, "./submission.csv", row.names=FALSE)
} else {
  print("Not scoring test set")
}
