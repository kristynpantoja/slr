#' Sigmoid Function
#'
#' @param x Real number.
#'
#' @return Number between 0 and 1.
#' @export
#'
#' @examples
sigmoid = function(x){
  1 / (1 + exp(-x))
}

graph.laplacian <- function(W, normalized = TRUE, zeta=0.01){
  stopifnot(nrow(W) == ncol(W))

  n = nrow(W)    # number of vertices
  # We perturb the network by adding some links with low edge weights
  W <- W + zeta * mean(colSums(W))/n * tcrossprod(rep(1,n))
  g <- colSums(W) # degrees of vertices

  if(normalized){
    D_half = diag(1 / sqrt(g) )
    return(D_half %*% W %*% D_half )
  } else {
    return(W)
  }
}

#' Spectral Clustering
#'
#' @param W Similarity matrix.
#' @param n_eig Number of clusters.
#' @param zeta Small number used to perturb the network by adding some links with low edge weights in the calculation of the Normalized Laplacian.
#'
#' @return cluster assignments
#' @export
#'
#' @examples
spectral.clustering <- function(W, n_eig = 2, zeta = 0) {
  L = graph.laplacian(W,zeta = zeta) # compute graph Laplacian
  ei = eigen(L, symmetric = TRUE)    # Compute the eigenvectors and values of L
  # we will use k-means to cluster the eigenvectors corresponding to
  # the leading smallest eigenvalues
  ei$vectors <- ei$vectors[,base::order(abs(ei$values),decreasing=TRUE)]
  obj <- kmeans(ei$vectors[, 1:n_eig], centers = n_eig, nstart = 100, algorithm = "Lloyd")
  if (n_eig==2){
    cl <- 2*(obj$cluster - 1) - 1
  } else {
    cl <- obj$cluster
  }
  names(cl) <- rownames(W)
  # return the cluster membership
  return(cl)
}

#' Aitchison Variation
#'
#' @param x Matrix of relative abundances of compositional covariates (n sample proportions of p compositional components).
#'
#' @return Pairwise correlation matrix where each cell (j, k) is the Aitchison variation between the jth and kth columns of x.
#' @export
#'
#' @examples
getAitchisonVar = function(x){
  p = ncol(x)
  A <- matrix(0, p, p)
  for (j in 1:p){
    for (k in 1:p){
      if (k == j){
        next
      }
      else{
        A[j,k] <- stats::var(log(x[,j])-log(x[,k])) # Aitchison variation
      }
    }
  }
  return(A)
}

#' Feature Scores
#'
#' @param x Matrix of relative abundances of compositional covariates (n sample proportions of p compositional components).
#' @param y Response vector (with length n).
#' @param screen.method "correlation" or "wald".
#' @param response.type "survival", "continuous", or "binary" -- survival is not yet implemented.
#' @param s0.perc Factor for denominator of score statistic, between 0 and 1: the percentile of standard deviation values added to the denominator. Default is 0.
#'
#' @return
#' @export
#'
#' @examples
getFeatureScores = function(x, y, screen.method, response.type, s0.perc){
  n = length(y)

  ## Compute univariate coefficient
  xclr <- apply(x, 1, function(a) log(a) - mean(log(a)))
  if (screen.method=='wald'){
    xclr.centered <- base::scale(t(xclr),center=TRUE,scale=TRUE)
    if (response.type=='continuous'){
      y.centered <- y - mean(y)
      sxx <- diag(crossprod(xclr.centered))
      sxy <- crossprod(xclr.centered,y.centered)
      syy <- sum(y.centered^2)
      numer <- sxy/sxx
      sd <- sqrt((syy/sxx - numer^2)/(n - 2)) # variance estimate

      if (is.null(s0.perc)) {
        fudge <- median(sd)
      }
      if (!is.null(s0.perc)) {
        if (s0.perc >= 0) {
          fudge <- quantile(sd, s0.perc)
        }
        if (s0.perc < 0) {
          fudge <- 0
        }
      }
      # this is the wald-statistic
      fs <- numer/(sd + fudge)
      # t-distribution with n-2 df
      fs <- stats::pt(abs(fs), df = n-2)
    } else if (response.type=='binary'){
      fs <- rep(0,ncol(xclr.centered))
      for (j in 1:ncol(xclr.centered)){
        fit <- glm(y~x,data=data.frame(
          x=xclr.centered[,j],y=as.factor(y)),family=binomial(link='logit'))
        fs[j] <- coef(summary(fit))[2,3]
      }
      fs <- stats::pnorm(abs(fs))
    }
  }
  if (screen.method=='correlation'){
    fs <- cor(t(xclr),y)
  }
  return(fs)
}


#' Supervised Log-Ratios
#'
#' @param x Matrix of relative abundances of compositional covariates (n sample proportions of p compositional components) for n observations with an observed response.
#' @param y Response vector (with length n).
#' @param screen.method Method of variable screening: could be correlation based ("correlation") or wald score based ("wald").
#' @param cluster.method Method of clustering: "spectral" or "hierarchical".
#' @param response.type Type of response variable: could be "survival", "continuous", or "binary". Currently only continuous and binary responses are allowed.
#' @param threshold Nonnegative constant between 0 and 1. If NULL, then no variable screening is performed.
#' @param s0.perc Factor for denominator of score statistic, between 0 and 1: the percentile of standard deviation values added to the denominator. Default is 0.
#' @param zeta Small number used to perturb the network by adding some links with low edge weights in the calculation of the Normalized Laplacian.
#' @param x.unlabeled Matrix of relative abundances of compositional covariates for observations with unobserved response.
#' @param use.unlabeled Logical flag indicating whether to use the unlabeled data in clustering.
#' @param positive.slope Logical flag indicating whether to define the balance such that its corresponding parameter estimate is positive.
#'
#' @return
#' @export
#'
#' @examples
slr = function(
    x,
    y,
    screen.method=c('correlation','wald'),
    cluster.method = c('spectral', 'hierarchical'),
    response.type=c('survival','continuous','binary'),
    threshold,
    s0.perc=0,
    zeta=0,
    x.unlabeled = NULL, use.unlabeled = FALSE,
    positive.slope = FALSE
){
  this.call <- match.call()
  screen.method <- match.arg(screen.method)
  response.type <- match.arg(response.type)

  n <- length(y)

  feature.scores = getFeatureScores(x, y, screen.method, response.type, s0.perc)
  which.features <- (abs(feature.scores) >= threshold)
  if (sum(which.features)<2){
    # Fit an intercept only regression model
    if (response.type=='binary'){
      model.train <- glm(y~.,data=data.frame(
        y=as.factor(y)),family=binomial(link='logit'))
    } else if (response.type=='continuous'){
      model.train <- lm(y~.,data=data.frame(y=y))
    }
    object <- list(sbp=NULL, Aitchison.var = NULL, cluster.mat = NULL)
  } else {
    x.reduced <- x[,which.features] # reduced data matrix
    if(use.unlabeled){
      if(is.null(x.unlabeled)){
        stop("use.unlabeled is TRUE but x.unlabeled is missing!!")
      }
      if(!all.equal(colnames(x), colnames(x.unlabeled))){
        stop("x and x.unlabeled don't have the same components/covariates/columns! cannot use the unlabeled data.")
      }
      all.x = rbind(x, x.unlabeled)
      all.x.reduced <- all.x[,which.features]
      Aitchison.var = getAitchisonVar(all.x.reduced)
      rownames(Aitchison.var) <- colnames(Aitchison.var) <- colnames(all.x.reduced)
    } else{
      Aitchison.var = getAitchisonVar(x.reduced)
      rownames(Aitchison.var) <- colnames(Aitchison.var) <- colnames(x.reduced)
    }
    if(cluster.method == "spectral" | nrow(Aitchison.var) == 2){
      Aitchison.sim <- max(Aitchison.var) - Aitchison.var
      ## Perform spectral clustering
      sbp.est <- spectral.clustering(Aitchison.sim, zeta = zeta)
      cluster.mat = Aitchison.sim
    } else if(cluster.method == "hierarchical"){
      ## Perform hierarchical clustering
      htree.est <- hclust(dist(Aitchison.var))
      sbp.est <- balance::sbp.fromHclust(htree.est)[, 1] # grab 1st partition
      cluster.mat = Aitchison.var
    } else{
      stop("invalid cluster.method arg was provided!!")
    }
    balance <- slr.fromContrast(x.reduced, sbp.est) # predict from labeled data
    # model fitting
    if (response.type=='binary'){
      model.train <- glm(
        y~balance,data=data.frame(balance=balance,y=as.factor(y)),
        family=binomial(link='logit'))
      if(positive.slope){
        if(coefficients(model.train)[2] < 0){
          sbp.est = -sbp.est
          balance <- slr.fromContrast(x.reduced, sbp.est)
          model.train <- glm(
            y~balance,data=data.frame(balance=balance,y=as.factor(y)),
            family=binomial(link='logit'))
        }
      }
    } else if (response.type=='continuous'){
      model.train <- lm(
        y~balance,data=data.frame(balance=balance,y=y))
      if(positive.slope){
        if(coefficients(model.train)[2] < 0){
          sbp.est = -sbp.est
          balance <- slr.fromContrast(x.reduced, sbp.est)
          model.train <- lm(
            y~balance,data=data.frame(balance=balance,y=y))
        }
      }
    }
    object <- list(
      sbp = sbp.est, Aitchison.var = Aitchison.var, cluster.mat = cluster.mat)
  }
  object$feature.scores <- feature.scores
  object$theta <- as.numeric(coefficients(model.train))
  object$fit <- model.train

  class(object) <- 'slr'
  return(object)
}


#' Predict from a Supervised Log-Ratios Model
#'
#' @param object An object output by slr.
#' @param newdata Matrix of relative abundances of compositional covariates.
#' @param response.type Type of response variable: could be "survival", "continuous", or "binary". Currently only continuous and binary responses are allowed.
#'
#' @return Predicted response.
#' @export
#'
#' @examples
predict.slr <- function(
    object, newdata = NULL, response.type=c('survival','continuous','binary')
){
  # prediction will be based on the canonical space
  if (missing(newdata) || is.null(newdata)) {
    stop('No new data provided!')
  } else {
    if (is.null(object$sbp)){
      predictor <- sigmoid(rep(1,nrow(newdata)) * object$theta)
    } else {
      newdata.reduced <- newdata[,colnames(newdata) %in% names(object$sbp)]
      new.balance <- slr.fromContrast(newdata.reduced,object$sbp)
      if (response.type=='binary'){
        fitted.results <- predict(
          object$fit,newdata=data.frame(balance=new.balance),type='response')
        predictor = fitted.results
      } else if (response.type=='continuous'){
        predictor <- cbind(1,new.balance) %*% object$theta
      }
    }
    as.numeric(predictor)
  }
}


buildPredmat <- function(
    outlist,threshold,x,y,foldid,response.type,type.measure
){
  nfolds = max(foldid)
  predmat = matrix(NA, nfolds, length(threshold))
  for(i in 1:nfolds){ # predict for each fold
    which = foldid == i
    y.i = y[which]
    fitobj = outlist[[i]]
    x.i = x[which, , drop=FALSE]
    predy.i = sapply(
      fitobj, function(a) predict.slr(
        a,newdata=x.i,response.type=response.type))
    for(j in 1:length(threshold)){
      predy.ij = predy.i[, j]
      if (response.type == 'continuous'){ # mse, to be minimized
        if(type.measure != "mse"){
          stop("if response.type is continuous, then type.measure must be mse!!")
        }
        predmat[i, j] <- mean((as.numeric(y.i)-predy.ij)^2)
      } else if (response.type=='binary'){
        if(!(type.measure %in% c("accuracy", "auc"))){
          stop("if response.type is binary, then type.measure must be either accuracy or auc!!")
        }
        if(type.measure == "accuracy"){# accuracy, minimize the # that don't match
          predmat[i, j] <- mean((predy.ij > 0.5) != y.i)
        } else if(type.measure == "auc"){# auc, minimize 1 - auc
          predmat[i, j] = tryCatch({
            1 - pROC::auc(
              y.i,predy.ij, levels = c(0, 1), direction = "<", quiet = TRUE)
          }, error = function(e){return(NA)}
          )
        }
      }
    }
  }
  predmat
}

getOptcv <- function(threshold, cvm, cvsd){
  # if(match(cvname,c("AUC","C-index"),0))cvm=-cvm
  cvmin = min(cvm, na.rm = TRUE)
  idmin = cvm <= cvmin
  threshold.min = max(threshold[idmin], na.rm = TRUE)
  idmin = match(threshold.min, threshold)
  semin = (cvm + cvsd)[idmin]
  id1se = cvm <= semin
  threshold.1se = max(threshold[id1se], na.rm = TRUE)
  id1se = match(threshold.1se, threshold)
  index=matrix(c(idmin,id1se),2,1,dimnames=list(c("min","1se"),"threshold"))
  list(
    threshold.min = threshold.min,
    threshold.1se = threshold.1se,
    index = index
  )
}


#' Cross Validation for Supervised Log-Ratios
#'
#' @param x Matrix of relative abundances of compositional covariates (n sample proportions of p compositional components) for n observations with an observed response.
#' @param y Response vector (with length n).
#' @param screen.method Method of variable screening: could be correlation based ("correlation") or wald score based ("wald").
#' @param cluster.method Method of clustering: "spectral" or "hierarchical".
#' @param response.type Type of response variable: could be "survival", "continuous", or "binary". Currently only continuous and binary responses are allowed.
#' @param threshold Nonnegative constant between 0 and 1. If NULL, then no variable screening is performed.
#' @param s0.perc Factor for denominator of score statistic, between 0 and 1: the percentile of standard deviation values added to the denominator. Default is 0.
#' @param zeta Small number used to perturb the network by adding some links with low edge weights in the calculation of the Normalized Laplacian.
#' @param x.unlabeled Matrix of relative abundances of compositional covariates for observations with unobserved response.
#' @param use.unlabeled Logical flag indicating whether to use the unlabeled data in clustering.
#' @param type.measure
#' @param scale
#' @param nfolds
#' @param foldid
#' @param weights
#' @param fold.unlabeled
#' @param foldid.unlabeled
#' @param trace.it
#'
#' @return
#' @export
#'
#' @examples
cv.slr <- function(
    x, y, screen.method = c('correlation', 'wald'),
    cluster.method = c('spectral', 'hierarchical'),
    response.type=c('survival', 'continuous', 'binary'),
    threshold = NULL,
    s0.perc = 0, zeta = 0,
    x.unlabeled = NULL, use.unlabeled = FALSE, #
    type.measure = c(
      "default", "mse", "deviance", "class", "auc", "mae", "C", "accuracy"
    ),
    scale = FALSE, nfolds = 10,
    foldid = NULL, weights = NULL, #
    fold.unlabeled = FALSE, foldid.unlabeled = NULL, #
    trace.it = FALSE #
){
  type.measure = match.arg(type.measure)
  N <- nrow(x)
  p <- ncol(x)
  N2 = nrow(x.unlabeled)

  if (is.null(weights)){
    weights = rep(1, nfolds)
  }

  if (is.null(threshold)) {
    xclr <- apply(x,1,function(a) log(a) - mean(log(a)))
    xclr.centered <- base::scale(t(xclr),center=TRUE, scale=TRUE)

    # determine threshold based on univariate score statistics or correlations
    threshold = sort(
      getFeatureScores(x, y, screen.method, response.type, s0.perc))
  }

  if (is.null(foldid)) {
    foldid = sample(rep(seq(nfolds), length = N))
  } else {
    nfolds = max(foldid)
  }
  if (nfolds < 3){
    stop("nfolds must be bigger than 3; nfolds=10 recommended")
  }
  if(fold.unlabeled & is.null(foldid.unlabeled)){
    if(is.null(x.unlabeled)){
      stop("fold.unlabeled is TRUE but x.unlabeled is missing!!")
    }
    if(nfolds > N2){
      stop("nfolds is greater than the number of samples in x.unlabeled! cannot divide into folds.")
    }
    foldid.unlabeled = sample(rep(seq(nfolds), length = N2))
  }

  if (trace.it){
    cat("Training\n")
  }

  outlist = as.list(seq(nfolds))
  for (i in seq(nfolds)) {
    if (trace.it){
      cat(sprintf("Fold: %d/%d\n", i, nfolds))
    }
    which.fold.i = foldid == i
    # x_in <- x[which.fold.i, ,drop=FALSE]
    x_sub <- x[!which.fold.i, ,drop=FALSE]
    y_sub <- y[!which.fold.i]
    if(use.unlabeled){
      if(is.null(x.unlabeled)){
        stop("use.unlabeled is TRUE but x.unlabeled is missing!!")
      }
      if(fold.unlabeled){
        which.fold.i.unlabeled = foldid.unlabeled == i
        x.unlab_sub = x.unlabeled[!which.fold.i.unlabeled, ,drop=FALSE]
      } else{
        x.unlab_sub = x.unlabeled
      }
    } else{
      x.unlab_sub = NULL
    }
    outlist[[i]] <- lapply(threshold, function(l) slr(
      x = x_sub, y = y_sub,
      screen.method = screen.method, cluster.method = cluster.method,
      response.type = response.type,
      threshold = l,
      s0.perc = s0.perc, zeta = zeta,
      x.unlabeled = x.unlab_sub, use.unlabeled = use.unlabeled))
  }

  # collect all out-of-sample predicted values
  #   with the updated code, this is more like a CV matrix
  predmat <- buildPredmat(
    outlist, threshold, x, y, foldid, response.type = response.type,
    type.measure = type.measure)

  cvm <- apply(predmat, 2, weighted.mean, w=weights, na.rm = TRUE)
  cvsd = apply(predmat, 2, stats::sd, na.rm = TRUE) / sqrt(nfolds)

  out <- list(
    threshold = threshold,
    cvm=cvm,cvsd = cvsd,
    fit.preval = predmat,
    foldid = foldid
  )

  lamin <- with(out, getOptcv(threshold, cvm, cvsd))

  obj = c(out, as.list(lamin))
  class(obj) = "cv.slr"
  obj
}

# slr.fromSBP <- function(x, y){
#
#   if(!identical(colnames(x), rownames(y))){
#
#     stop("Component names for data matrix and balance matrix do not match.")
#   }
#
#   x <- as.matrix(x)
#
#   if(any(x == 0)){
#
#     message("Alert: Replacing 0s with next smallest value to calculate balances.")
#     zeros <- x == 0
#     x[zeros] <- min(x[!zeros])
#   }
#
#   res <- apply(y, 2, function(z) slr.fromContrast(x, z))
#   rownames(res) <- as.character(1:nrow(res))
#   return(res)
# }

#' Supervised Log-Ratios Microbial Signature
#'
#' @param x Matrix of relative abundances of compositional covariates.
#' @param contrast Contrast vector that takes values from -1, 0, 1, indicating the log-ratio discovered by slr.
#'
#' @return The microbial signature, or balance, corresponding to x, under the supervised log-ratios balance regression model.
#' @export
#'
#' @examples
slr.fromContrast <- function(x, contrast){

  if(length(contrast) != ncol(x)) stop("Contrast must have length ncol(x) = D.")
  if(any(!contrast %in% c(-1, 0, 1))) stop("Contrast must contain [-1, 0, 1] only.")

  # lpos <- sum(contrast == 1)
  # lneg <- sum(contrast == -1)
  # const <- sqrt((lpos*lneg)/(lpos+lneg))
  logX <- log(x)
  ipos <- rowMeans(logX[, contrast == 1, drop = FALSE])
  ineg <- rowMeans(logX[, contrast == -1, drop = FALSE])

  ipos - ineg
}