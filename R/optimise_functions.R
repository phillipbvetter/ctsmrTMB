#######################################################
# CHECK AND SET DATA BEFORE OPTIMIZATION
#######################################################

check_and_set_data = function(data, self, private) {
  
  # RELATED TO ALL METHODS #
  
  # is data a list or data.frame
  if (!is.list(data) & !is.data.frame(data) & !is.matrix(data)) {
    stop("The data should be a list, data.frame or matrix")
  }
  
  # convert to data.frame
  data = as.data.frame(data)
  
  # calculate observations that are not provided
  data = calculate_observation_data(data, self, private)
  
  # check that all inputs and observations are provided in the data
  required.names = c(private$input.names,private$obs.names)
  bool = required.names %in% names(data)
  if (any(!bool)){
    stop("Please provide the following inputs in the given data: \n\t",
         paste(required.names[!bool],collapse=", "))
  }
  
  # time vector must be increasing
  if (any(diff(data$t)<=0)) {
    ids = which(diff(data$t)<=0)
    stop(sprintf("The time-vector is non-increasing at the following indice(s) %s",paste(ids,collapse=", ")))
  }
  # time vector must only contain numerics
  if (any(is.na(data$t))) {
    ids = which(is.na(data$t))
    stop(sprintf("The time-vector is NA at the following indice(s) %s",paste(ids,collapse=", ")))
  }
  
  # ODE time-steps
  if (private$ode.timestep - min(diff(data$t)) > 1e-10) {
    private$ode.timestep = min(diff(data$t))
    message(sprintf("The parsed 'ode.timestep' is larger than the minimum time difference. Reducing to min(diff(data$t)) = %s...", format(private$ode.timestep,digits=10,scientific=T)))
  }
  # correct time-step to give integer steps
  # if the step-size is N.1 or larger we use N+1 steps instead of N
  private$ode.N = floor(diff(data$t)/private$ode.timestep)
  bool = diff(data$t)/private$ode.timestep - private$ode.N > 1e-2
  private$ode.N[bool] = private$ode.N[bool] + 1
  private$ode.dt = diff(data$t)/private$ode.N
  #
  private$ode.Ncumsum = c(0,cumsum(private$ode.N))
  
  # RELATED TO "TMB METHOD #
  # Create vector to avoid using 'is.na' in TMB objective function in C++
  iobs = list()
  for (i in 1:private$m) {
    iobs[[i]] = (1:length(data$t))[!is.na(data[[private$obs.names[i]]])] - 1 #-1 because c++ 0-indexed
  }
  names(iobs) = paste("iobs_",private$obs.names,sep="")
  private$iobs = iobs
  
  # if the user did not supply state values in the data frame we construct them from the initial state values
  bool = !(private$state.names %in% names(data))
  if(private$method=="tmb"){
    if(any(bool)){
      data[private$state.names[bool]] =
        matrix(rep(private$initial.state$mean[bool], times=length(data$t)),ncol=sum(bool))
    }
    # save state values as tmb initial state values
    for(i in 1:private$n){
      private$tmb.initial.state.for.parameters[[i]] =
        rep(data[[private$state.names[i]]], times = c(private$ode.N,1))
    }
    names(private$tmb.initial.state.for.parameters) = private$state.names
  }
  
  # add date to private without unused columns
  private$data = data[,required.names]
  
  # Return
  return(invisible(self))
}

#######################################################
# CALCULATE THE COMPLEX OBSERVATION NAMES
#######################################################

calculate_observation_data = function(data, self, private){
  
  # Assign columns from data to their respective names
  for(i in 1:ncol(data)){
    assign(names(data)[i], data[[i]])
  }
  
  newdf = c()
  # We only need to calculate the lhs thats are of class 'call'
  bool = unlist(lapply(private$obs.eqs.trans, function(ls){inherits(ls$lhs,"call")}))
  ids = seq_along(private$obs.eqs.trans)[bool]
  
  for(i in ids){
    # get lhs form
    form = private$obs.eqs.trans[[i]]$lhs
    name = names(private$obs.eqs.trans)[i]
    # Check if the variables are available in data
    bool = all.vars(form) %in% names(data)
    if(!all(bool)){
      stop("Unable to compute the observation ",name," because the following variable(s) are not in the provided data: \n\t",all.vars(form)[!bool])
    }
    # Compute the observation and add to data.frame
    newnames = c(names(data),name)
    data = cbind(data, eval(form))
    names(data) = newnames
  }
  return(data)
}

#######################################################
# CONSTRUCT AD-FUN
#######################################################
construct_nll = function(self, private){
  
  # Find free parameters
  bool = private$parameter.names %in% names(private$fixed.pars)
  private$free.pars = private$parameters[!bool]
  
  ################################################
  # Data
  ################################################
  
  estMethod__ = switch(private$method,
                       ekf = 1,
                       ukf = 2,
                       tmb = 3
  )
  
  # Set initial state for estimate or predict
  initial.state.mean = private$initial.state$mean
  initial.state.cov = private$initial.state$cov
  if(private$pred.bool == 1){
    initial.state.mean = private$pred.initial.state$mean
    initial.state.cov = private$pred.initial.state$cov
  }
  
  # add mandatory entries to data
  .data1 = list(
    # method
    estMethod__ = estMethod__,
    pred__ = private$pred.bool,
    last_pred_index = private$last.pred.index,
    k_step_ahead = private$n.ahead,
    algo__ = private$algo,
    # initial
    X0__ = initial.state.mean,
    P0__ = initial.state.cov,
    # time-steps
    dt__ = private$ode.dt,
    N__ = private$ode.N,
    Nc__ = private$ode.Ncumsum,
    # loss function
    which_loss__ = private$loss$loss,
    loss_c_value__ = private$loss$c,
    tukey_pars__ = private$tukey.pars,
    # misc
    n__ = private$n,
    m__ = private$m,
    ng__ = private$ng
  )
  
  # add MAP entries to data if MAP is active
  if (!is.null(private$map)) {
    .data2 = list(
      map_bool__ = 1,
      map_mean__ = private$map$mean[!bool],
      map_cov__ = private$map$cov[!bool,!bool],
      map_ints__ = as.numeric(!bool),
      sum_map_ints__ = sum(as.numeric(!bool))
    )
    # private$map$mean = private$map$mean[!bool]
    # private$map$cov = private$map$cov[!bool,!bool]
  } else {
    .data2 = list(
      map_bool__ = 0
    )
  }
  # add constants to data
  .data3 = lapply(private$constants, function(x) x$rhs)
  
  # construct final data list
  data = c( private$data, .data1, private$iobs, .data2, .data3)
  
  ################################################
  # Parameters
  ################################################
  
  parameters = c(
    private$tmb.initial.state.for.parameters,
    lapply(private$parameters, function(x) x$init)
  )
  
  ################################################
  # Construct Neg. Log-Likelihood
  ################################################
  
  .random = private$state.names
  if (any(private$method==c("ekf","ukf"))) {
    .random = NULL
  }
  
  nll = TMB::MakeADFun(data = data,
                       parameters = parameters,
                       map = private$fixed.pars,
                       DLL = private$modelname,
                       silent = TRUE,
                       random = .random)
  
  # save objective function
  private$nll = nll
  return(invisible(self))
}

#######################################################
# OPTIMISE AD FUN
#######################################################

optimise_nll = function(self, private) {
  
  lb = unlist(lapply(private$free.pars, function(par) par$lower))
  ub = unlist(lapply(private$free.pars, function(par) par$upper))
  
  # IF METHOD IS KALMAN FILTER
  if (any(private$method==c("ekf","ukf"))) {
    
    # use function, gradient and hessian
    if (private$use.hessian) {
      comptime = system.time(
        opt <- try_withWarningRecovery(stats::nlminb(start = private$nll$par,
                                                     objective = private$nll$fn,
                                                     gradient = private$nll$gr,
                                                     he = private$nll$he,
                                                     lower = lb,
                                                     upper = ub,
                                                     control=private$control.nlminb))
      )
      # or just function and gradient
    } else {
      comptime = system.time(
        opt <- try_withWarningRecovery(stats::nlminb(start = private$nll$par,
                                                     objective = private$nll$fn,
                                                     gradient = private$nll$gr,
                                                     lower = lb,
                                                     upper = ub,
                                                     control=private$control.nlminb))
      )
    }
    
  }
  
  # IF METHOD IS TMB
  if (private$method =="tmb") {
    comptime = system.time(
      opt <- try_withWarningRecovery(stats::nlminb(start = private$nll$par,
                                                   objective = private$nll$fn,
                                                   gradient = private$nll$gr,
                                                   lower = lb,
                                                   upper = ub,
                                                   control=private$control.nlminb))
    )
  }
  
  # Check for error in the optimization
  if (inherits(opt,"try-error")) {
    message("The optimisation failed due to the following error: \n\n\t",opt)
    if(stringr::str_detect(opt,"NA/NaN")){
      message("You should consider the following to circumvent the error:
              1. Reduce the ODE step-size via argument 'ode.timestep'.
              2. Run the optimization with / without the hessian via argument 'use.hessian'.
              3. Play around with parameter initial values.
              4. Try the different ODE integration schemes via argument 'ode.solver'.")
    }
    private$opt = NULL
    return(invisible(self))
  }
  
  # store optimization object
  private$opt = opt
  
  # mgc and computation time
  outer_mgc = max(abs(private$nll$gr(opt$par)))
  comp.time = format(round(as.numeric(comptime["elapsed"])*1e4)/1e4,digits=5,scientific=F)
  
  # print convergence and timing result
  if(outer_mgc>1e-1){
    message("WARNING: THE MAXIMUM GRADIENT COMPONENT IS LARGE (>0.1) - FOUND OPTIMUM MIGHT BE INVALID.
            CONSIDER CHANGING OPTIMIZER TOLERANCES.")
  }
  message("\t Optimization finished!:
            Elapsed time: ", comp.time, " seconds.
            The objective value is: ",format(opt$objective,scientific=T),"
            The maximum gradient component is: ",format(outer_mgc,digits=2,scientific=T),"
            The convergence message is: ", opt$message,"
            Iterations: ",opt$iterations,"
            Evaluations: Fun: ",opt$evaluations["function"]," Grad: ",opt$evaluations[["gradient"]],"
            See stats::nlminb for available tolerance/control arguments."
  )
  
  # For TMB method: run sdreport
  if (private$method=="tmb") {
    private$sdr = TMB::sdreport(private$nll)
  }
  
  # return
  return(invisible(self))
}

#######################################################
# MAKE RETURN DATA NICE AFTER OPTIMIZATION
#######################################################

create_return_fit = function(self, private) {
  
  if (is.null(private$opt)) {
    return(NULL)
  }
  
  # store data in fit
  private$fit$data = private$data
  
  private$fit$convergence = private$opt$convergence
  private$fit$.__object__ = self$clone()
  
  ################################################
  # FOR KALMAN FILTERS
  ################################################
  
  if (private$method == "ekf" | private$method == "ukf") {
    
    # Objective value
    private$fit$nll = private$opt$objective
    
    # Gradient
    private$fit$nll.gradient = try_withWarningRecovery(
      {
        nll.grad = as.vector(private$nll$gr(private$opt$par))
        names(nll.grad) = names(private$free.pars)
        nll.grad
      }
    )
    if (inherits(private$fit$nll.gradient,"try-error")) {
      private$fit$nll.gradient = NA
    }
    
    # Hessian
    private$fit$nll.hessian = try_withWarningRecovery(
      {
        nll.hess = private$nll$he(private$opt$par)
        rownames(nll.hess) = names(private$free.pars)
        colnames(nll.hess) = names(private$free.pars)
        nll.hess
      }
    )
    if (inherits(private$fit$nll.hessian,"try-error")) {
      private$fit$nll.hessian = NA
    }
    
    # Parameter Estimate
    private$fit$par.fixed = private$opt$par
    private$fit$sd.fixed = tryCatch(sqrt(diag(solve(private$nll$he(private$opt$par)))),
                                    error=function(e) NA,
                                    warning=function(w) NA
    )
    
    # Parameter Covariance
    private$fit$cov.fixed = tryCatch(solve(private$nll$he(private$opt$par)),
                                     error=function(e) NA,
                                     warning=function(w) NA
    )
    
    # Extract reported items from nll
    rep = private$nll$report()
    
    # Prior States
    temp.states = do.call(rbind,rep$xPrior)
    temp.sd = sqrt(do.call(rbind,lapply(rep$pPrior,diag)))
    
    temp.states = cbind(private$data$t, temp.states)
    temp.sd = cbind(private$data$t, temp.sd)
    colnames(temp.states) = c("t",private$state.names)
    colnames(temp.sd) = c("t",private$state.names)
    private$fit$states$mean$prior = as.data.frame(temp.states)
    private$fit$states$sd$prior = as.data.frame(temp.sd)
    
    # Posterior States
    temp.states = do.call(rbind,rep$xPost)
    temp.sd = sqrt(do.call(rbind,lapply(rep$pPost,diag)))
    
    temp.states = cbind(private$data$t, temp.states)
    temp.sd = cbind(private$data$t, temp.sd)
    colnames(temp.states) = c("t",private$state.names)
    colnames(temp.sd) = c("t",private$state.names)
    private$fit$states$mean$posterior = as.data.frame(temp.states)
    private$fit$states$sd$posterior = as.data.frame(temp.sd)
    
    # Full Covariance Matrix - Prior and Posterior States
    private$fit$states$cov$prior = rep$pPost
    private$fit$states$cov$posterior = rep$pPrior
    names(private$fit$states$cov$prior) = paste("t=",private$data$t,sep="")
    names(private$fit$states$cov$posterior) = paste("t=",private$data$t,sep="")
    
    # Residuals
    rowNAs = as.matrix(!is.na(do.call(cbind,private$data[private$obs.names]))[-1,])
    sumrowNAs = rowSums(rowNAs)
    
    innovation = rep$Innovation
    innovation[[1]] = NULL
    innovation.cov = rep$InnovationCovariance
    innovation.cov[[1]] = NULL
    
    temp.res = matrix(nrow=length(private$data$t)-1,ncol=private$m)
    temp.var =  matrix(nrow=length(private$data$t)-1,ncol=private$m)
    
    # do.call(rbind,lapply(rep$Innovation, "length<-", private$m))
    
    for (i in 1:(length(private$data$t)-1)) {
      if (sumrowNAs[i] > 0) {
        temp.res[i,rowNAs[i,]] = innovation[[i]]
        temp.var[i,rowNAs[i,]] = diag(innovation.cov[[i]])
      }
    }
    temp.res = cbind(private$data$t[-1],temp.res)
    temp.sd = cbind(private$data$t[-1], sqrt(temp.var))
    
    names(innovation.cov) = paste("t=",private$data$t[-1],sep="")
    
    # should we remove the empty matrices?
    # innovation.cov = innovation.cov[sumrowNAs!=0]
    
    colnames(temp.res) = c("t",private$obs.names)
    colnames(temp.sd) = c("t",private$obs.names)
    private$fit$residuals$mean = as.data.frame(temp.res)
    private$fit$residuals$sd = as.data.frame(temp.sd)
    private$fit$residuals$normalized = as.data.frame(temp.res)
    private$fit$residuals$normalized[,-1] = private$fit$residuals$normalized[,-1]/temp.sd[,-1]
    private$fit$residuals$cov = innovation.cov
    
    
    # Observations
    # We need all states, inputs and parameter values to evaluate the observation
    # put them in a list
    listofvariables.prior = c(
      as.list(private$fit$states$mean$prior[-1]),
      as.list(private$fit$par.fixed),
      as.list(private$fit$data)
    )
    listofvariables.posterior = c(
      as.list(private$fit$states$mean$posterior[-1]),
      as.list(private$fit$par.fixed),
      as.list(private$fit$data)
    )
    obs.df.prior = as.data.frame(
      lapply(private$obs.eqs.trans, function(ls){eval(ls$rhs, envir = listofvariables.prior)})
    )
    obs.df.posterior = as.data.frame(
      lapply(private$obs.eqs.trans, function(ls){eval(ls$rhs, envir = listofvariables.posterior)})
    )
    private$fit$observations$mean$prior = data.frame(t=private$data$t, obs.df.prior)
    private$fit$observations$mean$posterior = data.frame(t=private$data$t, obs.df.posterior)
    
    # t-values and Pr( t > t_test )
    private$fit$tvalue = private$fit$par.fixed / private$fit$sd.fixed
    private$fit$Pr.tvalue = 2*pt(q=abs(private$fit$tvalue),df=sum(sumrowNAs),lower.tail=FALSE)
    
  }
  
  ################################################
  # FOR TMB
  ################################################
  
  if (private$method == "tmb") {
    
    # Objective and Gradient
    private$fit$nll = private$opt$objective
    private$fit$nll.gradient = private$sdr$gradient.fixed
    names(private$fit$nll.gradient) = names(private$free.pars)
    
    # Parameter Estimate
    private$fit$par.fixed = private$opt$par
    private$fit$sd.fixed = diag(private$sdr$cov.fixed)
    
    # Parameter Covariance
    private$fit$cov.fixed = private$sdr$cov.fixed
    
    # Posterior States (Smoothed)
    states.at.timepoints = cumsum(c(1,private$ode.N))
    temp = cbind(
      matrix(private$sdr$par.random,ncol=private$n),
      matrix(sqrt(private$sdr$diag.cov.random),ncol=private$n)
    )[states.at.timepoints,]
    temp.states = cbind(private$data$t, matrix(temp[,1:private$n],nrow=length(private$data$t)))
    temp.sd = cbind(private$data$t, matrix(temp[,(private$n+1):(2*private$n)],nrow=length(private$data$t)))
    #
    private$fit$states$mean$posterior = as.data.frame(temp.states)
    private$fit$states$sd$posterior = as.data.frame(temp.sd)
    colnames(private$fit$states$sd$posterior) = c("t",private$state.names)
    colnames(private$fit$states$mean$posterior) = c("t",private$state.names)
    
    # Residuals
    rowNAs = as.matrix(!is.na(do.call(cbind,private$data[private$obs.names]))[-1,])
    sumrowNAs = rowSums(rowNAs)
    
    # still need to figure out how to get residuals
    # TMB::oneStepPredict(private$nll,
    #                     observation.name=private$obs.names[1],
    #                     method="fullGaussian")
    
    # t-values and Pr( t > t_test )
    private$fit$tvalue = private$fit$par.fixed / private$fit$sd.fixed
    private$fit$Pr.tvalue = 2*pt(q=abs(private$fit$tvalue),df=sum(sumrowNAs),lower.tail=FALSE)
    
  }
  
  # Set S3 class
  class(private$fit) = "ctsmrTMB.fit"
  
  return(invisible(self))
}

#######################################################
# CREATE DATA.FRAME FOR PREDICT METHOD
#######################################################

construct_predict_dataframe = function(pars, rep, data, return.covariance, return.k.ahead, self, private){
  
  df.out = data.frame(matrix(nrow=private$last.pred.index*(private$n.ahead+1), ncol=5+private$n+private$n^2))
  
  disp_names = sprintf(rep("cor.%s.%s",private$n^2),rep(private$state.names,each=private$n),rep(private$state.names,private$n))
  disp_names[seq.int(1,private$n^2,by=private$n+1)] = sprintf(rep("var.%s",private$n),private$state.names)
  var_bool = !stringr::str_detect(disp_names,"cor")
  if(return.covariance){
    disp_names = sprintf(rep("cov.%s.%s",private$n^2),rep(private$state.names,each=private$n),rep(private$state.names,private$n))
    disp_names[seq.int(1,private$n^2,by=private$n+1)] = sprintf(rep("var.%s",private$n),private$state.names)
  }
  names(df.out) = c("i.","j.","t.i","t.j","k.ahead",private$state.names,disp_names)
  ran = 0:(private$last.pred.index-1)
  df.out["i."] = rep(ran,each=private$n.ahead+1)
  df.out["j."] = df.out["i."] + rep(0:private$n.ahead,private$last.pred.index)
  df.out["t.i"] = rep(data$t[ran+1],each=private$n.ahead+1)
  df.out["t.j"] = data$t[df.out[,"i."]+1+rep(0:private$n.ahead,private$last.pred.index)]
  df.out["k.ahead"] = rep(0:private$n.ahead,private$last.pred.index)
  df.out[,private$state.names] = do.call(rbind,rep$xk__)
  if(return.covariance){
    df.out[,disp_names] = do.call(rbind,rep$pk__)
  } else {
    df.out[,disp_names] = do.call(rbind, lapply(rep$pk__,function(x) do.call(rbind, apply(x,1, function(y) as.vector(cov2cor(matrix(y,ncol=2,byrow=T))),simplify=FALSE))))
    diag.ids = seq(from=1,to=private$n^2,by=private$n+1)
    df.out[,disp_names[diag.ids]] = do.call(rbind,rep$pk__)[,diag.ids]
  }
  
  # calculate observations at every time-step in predict
  inputs.df = private$data[df.out[,"j."]+1,private$input.names]
  
  env.list = c(
    as.list(df.out[private$state.names]),
    as.list(inputs.df),
    as.list(pars)
  )
  
  obs.df.predict = as.data.frame(
    lapply(private$obs.eqs.trans, function(ls){eval(ls$rhs, envir = env.list)})
  )
  names(obs.df.predict) = paste(private$obs.names,".predict",sep="")
  df.out = cbind(df.out, obs.df.predict)
  
  # add data observation to output data.frame 
  # obs.df = c()
  # for(i in seq_along(private$obs.names)){
  #   obs.df = cbind(obs.df, private$data[df.out[,"j."]+1,private$obs.names[i]])
  # }
  obs.df = private$data[df.out[,"j."]+1, private$obs.names]
  names(obs.df) = paste(private$obs.names,".data",sep="")
  df.out = cbind(df.out, obs.df)
  # obs.df = as.data.frame(obs.df)
  
  
  # return only specific n.ahead
  df.out = df.out[df.out[,"k.ahead"] %in% return.k.ahead,]
  class(df.out) = c("ctsmrTMB.pred", "data.frame")
  
  return(df.out)
}

