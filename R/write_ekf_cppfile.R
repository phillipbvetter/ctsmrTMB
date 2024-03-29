write_ekf_cppfile = function(self, private) {
  
  #Initialize C++ file
  fileconn = file(paste(private$cppfile.path,"_ekf.cpp",sep=""))
  
  txt = "#include <TMB.hpp>"
  txt = c(txt, "using namespace density;")
  
  ##################################################
  # CONSTRUCT AUX FUNCTIONS
  ##################################################
  
  # Function for NA-checking
  txt = c(txt, "\n//////////// helper fun: find NA locations in vector ///////////")
  txt = c(txt, "template <class Type>
vector<Type> is_not_na(vector<Type> x){
	vector<Type> y(x.size());
	y.fill(Type(1.0));
    for(int i=0; i<x.size(); i++){
		if( R_IsNA(asDouble(x(i))) ){
			y(i) = Type(0.0);
		}
	}
	return y;
}")
  
  # Implements Tukey and Huber loss functions
  txt = c(txt, "\n//////////// helper fun: extract non-NAs from vector ///////////")
  txt = c(txt,"template<class Type>
vector<Type> remove_nas__(vector<Type> data_vector, int number_of_datas, vector<Type> na_bool){
  int ii = 0;
	vector<Type> y_reduced(number_of_datas);
	for(int i=0; i < data_vector.size(); i++){
		if(na_bool(i) == Type(1.0)){
			y_reduced(ii) = data_vector(i);
			ii++;
		}
	}
  return y_reduced;
}")
  
  # Implements Tukey and Huber loss functions
  txt = c(txt, "\n//////////// helper fun: construct permutation matrix ///////////")
  txt = c(txt, "template <class Type>
matrix<Type> construct_permutation_matrix(int number_of_datas, int m, vector<Type> na_bool){
	matrix<Type> E(number_of_datas,m);
	E.setZero();
	/**/
	int j=0;
	for(int i=0; i < m; i++){
		if(na_bool(i) == Type(1.0)){ /*if p(i) is 1 then include by setting 1 in diagonal of matrix*/
			E(j,i) = Type(1.0);
			j += 1;
		}
	}
	return E;
}")
  
  # Implements Tukey and Huber loss functions
  txt = c(txt, "\n//////////// loss function ///////////")
  txt = c(txt,"template<class Type>
Type lossfunction__(Type x, vector<Type> tukeypars, Type huber_c, int lossFunc){
  Type loss;
  if(lossFunc==1){
    Type a = tukeypars(0);
    Type b = tukeypars(1);
    Type c = tukeypars(2);
    Type d = tukeypars(3);
    loss = d * ( (Type(1.0)/(Type(1.0)+exp(-a*(x-b)))) + c );
  } else if (lossFunc==2){
    Type c_squared = pow(huber_c,2);
    loss = c_squared * (sqrt(1 + (x / c_squared)) - 1);
  } else {
    loss = x;
  }
  return(loss);
}")
  
  # Helper function for MAP estimation
  txt = c(txt, "\n//////////// MAP estimation helper ///////////")
  txt = c(txt, "template<class Type>
vector<Type> get_free_pars__(vector<int> mapints, int sum_mapints, vector<Type> parvec) {
	vector<Type> ans(sum_mapints);
	int j=0;
	for(int i=0;i<mapints.size();i++){
		if(mapints(i)==1){
			ans(j) = parvec(i);
			j += 1;
		}
	}
	return(ans);
}")
  
  ####################################################################
  # FUNCTIONS FOR DRIFT, DIFFUSION, OBSERVATION, OBS VARIANCE, ETC...
  ####################################################################
  
  # Construct drift function
  ##################################################
  
  fvars0 = sort(unique(unlist(lapply(private$diff.terms, function(x) all.vars(x$dt)))))
  fvars0_sigma = fvars0[!(fvars0 %in% private$state.names)]
  fvars1 = paste("Type", fvars0, collapse=", ")
  fvars1_sigma = paste("Type", fvars0_sigma, collapse=", ")
  fvars2 = fvars0
  fvars2.pred = fvars0
  fvars2.tmb = fvars0
  fvars2_sigma = fvars0
  fvars2_sigma2 = fvars0_sigma
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      fvars2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=fvars2)
      fvars2.pred = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i+k)",private$input.names[i]), x=fvars2.pred)
      fvars2.tmb = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=fvars2.tmb)
      fvars2_sigma2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=fvars2_sigma2)
    }
  }
  for(i in 1:private$n){
    fvars2 = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),fvars2)
    fvars2.pred = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),fvars2.pred)
    fvars2.tmb = sub(pattern=sprintf("^%s$",private$state.names[i]), replacement=sprintf("%s(Nc__(i)+j)",private$state.names[i]), x=fvars2.tmb)
    fvars2_sigma = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0(%s)",i-1),fvars2_sigma)
  }
  if(length(fvars2)<1){
    fvars1 = "Type a"
    fvars2 = "Type(0.0)"
    fvars2.tmb = "Type(0.0)"
    fvars2.pred = "Type(0.0)"
  }
  if(length(fvars2_sigma2)<1){
    fvars1_sigma = "Type a"
    fvars2_sigma2 = "Type(0.0)"
  }
  
  txt = c(txt, "\n//////////// drift function ///////////")
  temptxt = sprintf("template<class Type>\nvector<Type> f__(%s){",fvars1)
  temptxt = c(temptxt, sprintf("\tvector<Type> ans(%i);",private$n))
  for(i in 1:private$n){
    term = paste(deparse(hat2pow(private$diff.terms[[i]]$dt)),collapse="")
    temptxt = c(temptxt, sprintf("\tans(%i) = %s;",i-1,term))
  }
  temptxt = c(temptxt, "\treturn ans;\n}")
  txt = c(txt, temptxt)
  
  ##################################################
  # Construct jacobian of drift function
  
  dfdxvars0 = c()
  for(i in 1:private$n){
    dfdxvars0 = c(dfdxvars0, unlist(lapply(lapply(private$state.names,function(x) Deriv::Deriv(private$diff.terms[[i]]$dt,x=x,cache.exp=FALSE)),all.vars)))
  }
  dfdxvars0 = sort(unique(dfdxvars0))
  dfdxvars1 = paste("Type", dfdxvars0, collapse=", ")
  dfdxvars2 = dfdxvars0
  dfdxvars2.pred = dfdxvars0
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      dfdxvars2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=dfdxvars2)
      dfdxvars2.pred = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i+k)",private$input.names[i]), x=dfdxvars2.pred)
    }
  }
  for(i in 1:private$n){
    dfdxvars2 = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),dfdxvars2)
    dfdxvars2.pred = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),dfdxvars2.pred)
  }
  if(length(dfdxvars2)<1){
    dfdxvars1 = "Type void_filler"
    dfdxvars2 = "Type(0.0)"
    dfdxvars2.pred = "Type(0.0)"
  }
  
  dfdx = matrix(0,nrow=private$n,ncol=private$n)
  for(i in 1:private$n){
    terms = lapply(private$state.names,function(x) hat2pow(Deriv::Deriv(private$diff.terms[[i]]$dt,x=x,cache.exp=FALSE)))
    for(j in 1:private$n){
      dfdx[i,j] = paste(deparse(terms[[j]]),collapse="")
    }
  }
  txt = c(txt, "\n//////////// jacobian of drift function ///////////")
  temptxt = sprintf("template<class Type>\nmatrix<Type> dfdx__(%s){",dfdxvars1)
  temptxt = c(temptxt, sprintf("\tmatrix<Type> ans(%i,%i);",private$n,private$n))
  for(i in 1:private$n){
    for(j in 1:private$n){
      temptxt = c(temptxt, sprintf("\tans(%s,%s) = %s;",i-1,j-1,dfdx[i,j]))
    }
  }
  temptxt = c(temptxt, "\treturn ans;\n}")
  txt = c(txt, temptxt)
  
  
  
  ##################################################
  # Construct diffusion function
  
  gvars0 = c()
  for(i in 1:private$n){
    gvars0 = c(gvars0, unlist(lapply(private$diff.terms[[i]][-1],all.vars)))
  }
  gvars0 = sort(unique(gvars0))
  gvars1 = paste("Type", gvars0, collapse=", ")
  gvars2 = gvars0
  gvars2.pred = gvars0
  gvars2.tmb = gvars0
  gvars2_sigma = gvars0
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      gvars2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=gvars2)
      gvars2.pred = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i+k)",private$input.names[i]), x=gvars2.pred)
      gvars2.tmb = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=gvars2.tmb)
      gvars2_sigma = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("Xsp0__(0,%s)",i-1),gvars2)
    }
  }
  for(i in 1:length(private$state.names)){
    gvars2.tmb = sub(pattern=sprintf("^%s$",private$state.names[i]), replacement=sprintf("%s(Nc__(i)+j)",private$state.names[i]), x=gvars2.tmb)
  }
  
  txt = c(txt, "\n//////////// diffusion function ///////////")
  temptxt = sprintf("template<class Type>\nmatrix<Type> g__(%s){",gvars1)
  temptxt = c(temptxt, sprintf("\tmatrix<Type> ans(%i,%i);",private$n,private$ng))
  for(i in 1:private$n){
    for(j in 1:private$ng){
      term = paste(deparse(hat2pow(private$diff.terms[[i]][[j+1]])),collapse = "")
      temptxt = c(temptxt, sprintf("\tans(%s,%s) = %s;",i-1,j-1,term))
    }
  }
  temptxt = c(temptxt, "\treturn ans;\n}")
  txt = c(txt, temptxt)
  
  ##################################################
  # Construct observation function
  
  hvars0 = sort(unique(unlist(lapply(lapply(private$obs.eqs.trans, function(x) x$rhs), all.vars))))
  hvars0.withoutStates = hvars0[!(hvars0 %in% private$state.names)]
  # 
  hvars1 = paste("Type", hvars0, collapse=", ")
  hvars1.withoutStates = paste("Type", hvars0.withoutStates, collapse=", ")
  # 
  hvars2 = hvars0
  hvars2.withoutStates = hvars0.withoutStates
  hvars2.tmb = hvars0
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      hvars2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=hvars2)
      hvars2.tmb = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=hvars2.tmb)
      hvars2.withoutStates = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=hvars2.withoutStates)
    }
  }
  for(i in 1:private$n){
    hvars2 = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),hvars2)
    hvars2.tmb = sub(pattern=sprintf("^%s$",private$state.names[i]), replacement=sprintf("%s(Nc__(i))",private$state.names[i]), x=hvars2.tmb)
  }
  if(length(hvars0.withoutStates)<1){
    hvars1.withoutStates = "Type void_filler"
    hvars2.withoutStates = "Type(0.0)"
  }
  h = c()
  for(i in 1:private$m){
    term = paste(deparse(hat2pow(private$obs.eqs.trans[[i]]$rhs)),collapse = "")
    h[i] = term
  }
  txt = c(txt, "\n//////////// observation function ///////////")
  temptxt = sprintf("template<class Type>\nvector<Type> h__(%s){",hvars1)
  temptxt = c(temptxt, sprintf("\tvector<Type> ans(%i);",private$m))
  for(i in 1:private$m){
    temptxt = c(temptxt, sprintf("\tans(%s) = %s;",i-1,h[i]))
  }
  temptxt = c(temptxt, "\treturn ans;\n}")
  txt = c(txt, temptxt)
  
  
  ##################################################
  # Construct jacobian of observation function
  
  dhdxvars0 = c()
  for(i in 1:private$m){
    dhdxvars0 = c(dhdxvars0 , unlist(lapply(lapply(private$state.names, function(x) Deriv::Deriv(private$obs.eqs.trans[[i]]$rhs,x=x,cache.exp=FALSE)),all.vars)))
  }
  dhdxvars0 = sort(unique(dhdxvars0))
  dhdxvars1 = paste("Type", dhdxvars0, collapse=", ")
  dhdxvars2 = dhdxvars0
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      dhdxvars2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=dhdxvars2)
    }
  }
  for(i in 1:private$n){
    dhdxvars2 = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),dhdxvars2)
  }
  if(length(dhdxvars2)<1){
    dhdxvars1 = "Type state_void_filler"
    dhdxvars2 = "Type(0.0)"
  }
  
  dhdx = matrix(NA,nrow=private$m,ncol=private$n)
  for(i in 1:private$m){
    terms = lapply(private$state.names, function(x) hat2pow(Deriv::Deriv(private$obs.eqs.trans[[i]]$rhs,x=x,cache.exp=FALSE)))
    for(j in 1:private$n){
      dhdx[i,j] = paste(deparse(terms[[j]]),collapse = "")
    }
  }
  txt = c(txt, "\n//////////// jacobian of observation function ///////////")
  temptxt = sprintf("template<class Type>\nmatrix<Type> dhdx__(%s){",dhdxvars1)
  temptxt = c(temptxt, sprintf("\tmatrix<Type> ans(%i,%i);",private$m,private$n))
  for(i in 1:private$m){
    for(j in 1:private$n){
      temptxt = c(temptxt, sprintf("\tans(%s,%s) = %s;",i-1,j-1,dhdx[i,j]))
    }
  }
  temptxt = c(temptxt, "\treturn ans;\n}")
  txt = c(txt, temptxt)
  
  ##################################################
  # Construct ODE template method
  
  # created for the structure below
  allvars0 = sort(unique(c(fvars0,dfdxvars0,gvars0)))
  allvars0_nostate_notime = allvars0[!(allvars0 %in% c(private$state.names,"t"))]
  allvars1_nostate_notime = paste("Type", allvars0_nostate_notime, collapse=", ")
  allvars2_nostate_notime = allvars0_nostate_notime
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      allvars2_nostate_notime = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=allvars2_nostate_notime)
    }
  }
  fvars2_new = stringr::str_replace(fvars2_sigma,"x0","x0__")
  dfdxvars2_new = stringr::str_replace(dfdxvars2,"\\(i\\)","")
  gvars2_new = stringr::str_replace(gvars2,"\\(i\\)","")
  allvars2_nostate_notime_pred = stringr::str_replace(allvars2_nostate_notime,"\\(i\\)","\\(i+k\\)") 
  
  
  txt = c(txt, sprintf("template<class Type>
struct ode_integration {
	vector<Type> X_next;
	matrix<Type> P_next;
	ode_integration(vector<Type> x0__, matrix<Type> p0__, Type t, Type dt__, int algo__, %s){
		if(algo__==1){
			/*Forward Euler*/
			X_next = x0__ + f__(%s) * dt__;
			P_next = p0__ + (dfdx__(%s)*p0__ + p0__*dfdx__(%s).transpose() + g__(%s)*g__(%s).transpose()) * dt__;
		} else if (algo__==2){
			/*4th Order Runge-Kutta 4th*/
			vector<Type> X0__ = x0__;
			matrix<Type> P0__ = p0__;
			/**/
			vector<Type> k1__,k2__,k3__,k4__;
			matrix<Type> a1__,a2__,a3__,a4__;
			/*SOLVE ODE*/
			/*step 1*/
			k1__ = dt__ * f__(%s);
			a1__ = dt__ * (dfdx__(%s)*p0__ + p0__*dfdx__(%s).transpose() + g__(%s)*g__(%s).transpose());
			/*step 2*/
			t = t + 0.5 * dt__;
			x0__ = X0__ + 0.5 * k1__;
			p0__ = P0__ + 0.5 * a1__;
      k2__ = dt__ * f__(%s);
      a2__ = dt__ * (dfdx__(%s)*p0__ + p0__*dfdx__(%s).transpose() + g__(%s)*g__(%s).transpose());
			/*step 3*/
			x0__ = X0__ + 0.5 * k2__;
			p0__ = P0__ + 0.5 * a2__;
      k3__ = dt__ * f__(%s);
      a3__ = dt__ * (dfdx__(%s)*p0__ + p0__*dfdx__(%s).transpose() + g__(%s)*g__(%s).transpose());
			/*step 4*/
			t = t + 0.5 * dt__;
			x0__ = X0__ + k3__;
			p0__ = P0__ + a3__;
      k4__ = dt__ * f__(%s);
      a4__ = dt__ * (dfdx__(%s)*p0__ + p0__*dfdx__(%s).transpose() + g__(%s)*g__(%s).transpose());
			/*ODE UPDATE*/
			X_next = X0__ + (k1__ + 2.0*k2__ + 2.0*k3__ + k4__)/6.0;
			P_next = P0__ + (a1__ + 2.0*a2__ + 2.0*a3__ + a4__)/6.0;
		} else {
			/*nothing*/
		}
	}
};",
allvars1_nostate_notime,
paste(fvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(gvars2_new,collapse=", "), paste(gvars2_new,collapse=", "),
paste(fvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(gvars2_new,collapse=", "), paste(gvars2_new,collapse=", "),
paste(fvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(gvars2_new,collapse=", "), paste(gvars2_new,collapse=", "),
paste(fvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(gvars2_new,collapse=", "), paste(gvars2_new,collapse=", "),
paste(fvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(dfdxvars2_new,collapse=", "), paste(gvars2_new,collapse=", "), paste(gvars2_new,collapse=", ")))
  
  ##################################################
  # Construct observation variance function
  
  obsvars0 = sort(unique(unlist(lapply(private$obs.var.trans,function(x) all.vars(x$rhs)))))
  obsvars0.withoutStates = obsvars0[!(obsvars0 %in% private$state.names)]
  obsvars1 = paste("Type", obsvars0, collapse=", ")
  obsvars1.withoutStates = paste("Type", obsvars0.withoutStates, collapse=", ")
  obsvars2 = obsvars0
  obsvars2.withoutStates = obsvars0.withoutStates
  obsvars2.withoutInputIndices = obsvars0
  obsvars2.tmb = obsvars0
  if(length(private$input.names)>0){
    for(i in 1:length(private$input.names)){
      obsvars2 = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=obsvars2)
      obsvars2.tmb = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=obsvars2.tmb)
      obsvars2.withoutStates = sub(pattern=sprintf("^%s$",private$input.names[i]), replacement=sprintf("%s(i)",private$input.names[i]), x=obsvars2.withoutStates)
    }
  }
  for(i in 1:private$n){
    obsvars2 = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),obsvars2)
    obsvars2.withoutInputIndices = sub(pattern=sprintf("^%s$",private$state.names[i]),replacement=sprintf("x0__(%s)",i-1),obsvars2.withoutInputIndices)
    obsvars2.tmb = sub(pattern=sprintf("^%s$",private$state.names[i]), replacement=sprintf("%s(Nc__(i))",private$state.names[i]), x=obsvars2.tmb)
  }
  if(length(obsvars2)<1){
    obsvars1 = "Type void_filler"
    obsvars2 = "Type(0.0)"
    obsvars2.tmb = "Type(0.0)"
  }
  if(length(obsvars2.withoutStates)<1){
    obsvars1.withoutStates = "Type void_filler"
    obsvars2.withoutStates = "Type(0.0)"
  }
  
  txt = c(txt, "\n//////////// observation variance matrix function ///////////")
  temptxt = sprintf("template<class Type>\nmatrix<Type> obsvarFun__(%s){",obsvars1)
  temptxt = c(temptxt, sprintf("\tmatrix<Type> V(%i,%i);",private$m,private$m))
  for(i in 1:private$m){
    temptxt = c(temptxt, sprintf("\tV(%s,%s) = %s;",i-1,i-1,paste(deparse(hat2pow(private$obs.var.trans[[i]]$rhs)),collapse="")))
  }
  temptxt = c(temptxt, "\treturn V;\n}")
  txt = c(txt, temptxt)

  ##################################################
  # BEGIN OBJECTIVE FUNCTION
  ##################################################
  
  # Initialize objective function
  txt = c(txt, "\n//////////// objective function ///////////")
  txt = c(txt,"template<class Type>\nType objective_function<Type>::operator() ()\n{")
  
  txt = c(txt, "\t DATA_INTEGER(pred__);")
  txt = c(txt, "\t DATA_INTEGER(algo__);")
  txt = c(txt, "\t Type nll__ = 0;")
  
  ##################################################
  # EKF OBJECTIVE FUNCTION
  ##################################################
  
  txt = c(txt, "\n//////////// EKF METHOD ///////////")

  txt = c(txt, "\n\t //////////// Estimation //////////////")
  txt = c(txt, "\n\t //////////// Estimation //////////////")
  txt = c(txt, "\t if(pred__ == 0){")
  
  # Observation Vectors
  txt = c(txt, "\n//// observations ////")
  for(i in 1:length(private$obs.names)){
    txt = c(txt, sprintf("\t DATA_VECTOR(%s);",private$obs.names[i]))
  }
  
  # Input Vectors
  txt = c(txt, "\n//// inputs ////")
  for(i in 1:length(private$input.names)){
    txt = c(txt, sprintf("\t DATA_VECTOR(%s);",private$input.names[i]))
  }
  
  # Initialize State
  txt = c(txt, "\n//// initial state ////")
  txt = c(txt, "\t DATA_VECTOR(X0__);")
  txt = c(txt, "\t DATA_MATRIX(P0__);")
  
  # Time-step
  txt = c(txt, "\t DATA_VECTOR(dt__);")
  txt = c(txt, "\t DATA_IVECTOR(N__);")
  
  # Loss parameters
  txt = c(txt, "\n//// loss parameters ////")
  txt = c(txt, "\t DATA_VECTOR(tukey_pars__);")
  txt = c(txt, "\t DATA_INTEGER(which_loss__);")
  txt = c(txt, "\t DATA_SCALAR(loss_c_value__);")
  
  # Maximum a Posterior
  txt = c(txt, "\n//// map estimation ////")
  txt = c(txt, "\t DATA_INTEGER(map_bool__);")
  
  # Parameters
  txt = c(txt, "\n//// parameters ////")
  for(i in 1:length(private$parameters)){
    txt = c(txt, sprintf("\t PARAMETER(%s);",private$parameter.names[i]))
  }
  
  # Constants
  txt = c(txt, "\n//// constants ////")
  for (i in 1:length(private$constants)) {
    txt = c( txt , sprintf("\t DATA_SCALAR(%s);",private$constant.names[i]))
  }
  
  # system size
  txt = c(txt, "\n//// system size ////")
  txt = c( txt , "\t DATA_INTEGER(n__);")
  txt = c( txt , "\t DATA_INTEGER(m__);")
  
  # Storage variables
  txt = c(txt, "\n//////////// storage variables ///////////")
  txt = c(txt, "\t vector<vector<Type>> xPrior(t.size());")
  txt = c(txt, "\t vector<matrix<Type>> pPrior(t.size());")
  txt = c(txt, "\t vector<vector<Type>> xPost(t.size());")
  txt = c(txt, "\t vector<matrix<Type>> pPost(t.size());")
  txt = c(txt, "\t vector<vector<Type>> Innovation(t.size());")
  txt = c(txt, "\t vector<matrix<Type>> InnovationCovariance(t.size());")
  
  txt = c(txt, "\n//////////// set initial value ///////////")
  txt = c(txt, "\t vector<Type> x0__ = X0__;")
  txt = c(txt, "\t matrix<Type> p0__ = P0__;")
  txt = c(txt, "\t xPrior(0) = X0__;")
  txt = c(txt, "\t xPost(0) = X0__;")
  txt = c(txt, "\t pPrior(0) = P0__;")
  txt = c(txt, "\t pPost(0) = P0__;")
  
  # Initiaze variables
  txt = c(txt, "\n\t //////////// initialize variables ///////////")
  txt = c(txt, "\t int s__;")
  txt = c(txt, "\t Type half_log2PI = Type(0.5)*log(2*M_PI);")
  txt = c(txt, "\t vector<Type> data_vector__(m__),na_bool__,e__,y__,F__,H__;")
  txt = c(txt, "\t matrix<Type> C__,R__,K__,E__,V__,Ri__,A__,G__;")
  
  # Identity Matrix
  txt = c(txt, "\n\t //////////// identity matrix ///////////")
  txt = c(txt, "\t matrix<Type> I__(n__,n__);")
  txt = c(txt, "\t I__.setIdentity();")
  
  # Main For-Loop
  txt = c(txt, "\n\t //////////// MAIN LOOP OVER TIME POINTS ///////////")
  
  # Time for-loop
  txt = c(txt, "\t for(int i=0 ; i<t.size()-1 ; i++){")
  
  # Solve Moment ODEs
  txt = c(txt, "\n\t\t //////////// TIME-UPDATE: SOLVE MOMENT ODES ///////////")
  txt = c(txt, "\t\t for(int j=0 ; j<N__(i) ; j++){")
  
  txt = c(txt, sprintf("\t\t\t ode_integration<Type> odelist = {x0__, p0__, t(i)+j*dt__(i), dt__(i), algo__, %s};",paste(allvars2_nostate_notime,collapse=", ")))
  txt = c(txt,"\t\t\t x0__ = odelist.X_next;")
  txt = c(txt,"\t\t\t p0__ = odelist.P_next;")
  txt = c(txt, "\t\t }")
  #
  txt = c(txt, "\t\t xPrior(i+1) = x0__;")
  txt = c(txt, "\t\t pPrior(i+1) = p0__;")
  
  # Data Update
  txt = c(txt, "\n\t\t //////////// DATA-UPDATE ///////////")
  obs.lhs = paste(names(private$obs.eqs.trans),"(i+1)",sep="")
  txt = c(txt, sprintf("\t\t data_vector__ << %s;", paste(obs.lhs,collapse=", ")))
  txt = c(txt, "\t\t na_bool__ = is_not_na(data_vector__);")
  txt = c(txt, "\t\t s__ = CppAD::Integer(sum(na_bool__));")
  
  # Start if statement for observations
  txt = c(txt, "\t\t if( s__ > 0 ){")
  txt = c(txt, "\t\t\t y__  = remove_nas__(data_vector__, s__, na_bool__);")
  txt = c(txt, "\t\t\t E__  = construct_permutation_matrix(s__, m__, na_bool__);")
  txt = c(txt, sprintf("\t\t\t H__  = h__(%s);",paste(hvars2,collapse=", ")))
  txt = c(txt, sprintf("\t\t\t C__  = E__ * dhdx__(%s);", paste(dhdxvars2,collapse=", ")))
  txt = c(txt, "\t\t\t e__  = y__ - E__ * H__;")
  txt = c(txt, sprintf("\t\t\t V__  = E__ * obsvarFun__(%s) * E__.transpose();", paste(obsvars2,collapse=" ,")))
  txt = c(txt, "\t\t\t R__  = C__ * p0__ * C__.transpose() + V__;")
  txt = c(txt, "\t\t\t Ri__ = R__.inverse();")
  txt = c(txt, "\t\t\t K__ 	= p0__ * C__.transpose() * Ri__;")
  txt = c(txt, "\t\t\t x0__ = x0__ + K__*e__;")
  txt = c(txt, "\t\t\t p0__ = (I__ - K__ * C__) * p0__ * (I__ - K__ * C__).transpose() + K__* V__ * K__.transpose();")
  txt = c(txt, "\t\t\t nll__ += Type(0.5)*atomic::logdet(R__) + Type(0.5)*lossfunction__((e__*(Ri__*e__)).sum(),tukey_pars__,loss_c_value__,which_loss__) + half_log2PI * asDouble(s__);")
  txt = c(txt, "\t\t\t Innovation(i+1) = e__;")
  txt = c(txt, "\t\t\t InnovationCovariance(i+1) = R__;")
  txt = c(txt, "\t\t }")
  # end if statement for observations
  
  txt = c(txt, "\t\t xPost(i+1) = x0__;")
  txt = c(txt, "\t\t pPost(i+1) = p0__;")
  #
  txt = c(txt, "\t }")
  
  
  # Maximum-A-Posterior
  txt = c(txt, "\n\t\t //////////// MAP CONTRIBUTION ///////////")
  #
  txt = c(txt, "\t if(map_bool__==1){")
  txt = c(txt, "\t\t DATA_VECTOR(map_mean__);")
  txt = c(txt, "\t\t DATA_MATRIX(map_cov__);")
  txt = c(txt, "\t\t DATA_IVECTOR(map_ints__);")
  txt = c(txt, "\t\t DATA_INTEGER(sum_map_ints__);")
  txt = c(txt, sprintf("\t\t vector<Type> parvec__(%s);",length(private$parameters)))
  txt = c(txt, "\t\t vector<Type> map_pars__;")
  txt = c(txt, sprintf("\t\t parvec__ << %s;",paste(private$parameter.names,collapse=", ")))
  txt = c(txt, sprintf("\t\t map_pars__ = get_free_pars__(map_ints__,sum_map_ints__,parvec__);"))
  txt = c(txt, "\t\t vector<Type> pars_eps__ = map_pars__ - map_mean__;")
  txt = c(txt, "\t\t matrix<Type> map_invcov__ = map_cov__.inverse();")
  txt = c(txt, "\t\t Type map_nll__ = Type(0.5) * atomic::logdet(map_cov__) + Type(0.5) * (pars_eps__ * (map_invcov__ * pars_eps__)).sum();")
  txt = c(txt, "\t\t nll__ += map_nll__;")
  txt = c(txt, "\t\t REPORT(map_nll__);")
  txt = c(txt, "\t\t REPORT(map_pars__);")
  txt = c(txt, "\t\t REPORT(pars_eps__);")
  txt = c(txt, "\t }")
  
  
  # Report variables
  txt = c(txt, "\n\t //////////// Return/Report //////////////")
  #
  txt = c(txt ,"\t REPORT(Innovation);")
  txt = c(txt ,"\t REPORT(InnovationCovariance);")
  txt = c(txt ,"\t REPORT(xPrior);")
  txt = c(txt ,"\t REPORT(xPost);")
  txt = c(txt, "\t REPORT(pPrior);")
  txt = c(txt, "\t REPORT(pPost);")
  
  
  txt = c(txt, "\n\t //////////// Prediction //////////////")
  txt = c(txt, "\n\t //////////// Prediction //////////////")
  txt = c(txt, "\t } else if(pred__ == 1){")
  
  # Observation Vectors
  txt = c(txt, "\n//// observations ////")
  for(i in 1:length(private$obs.names)){
    txt = c(txt, sprintf("\t DATA_VECTOR(%s);",private$obs.names[i]))
  }
  
  # Input Vectors
  txt = c(txt, "\n//// inputs ////")
  for(i in 1:length(private$input.names)){
    txt = c(txt, sprintf("\t DATA_VECTOR(%s);",private$input.names[i]))
  }
  
  # Initialize State
  txt = c(txt, "\n//// initial state ////")
  txt = c(txt, "\t DATA_VECTOR(X0__);")
  txt = c(txt, "\t DATA_MATRIX(P0__);")
  
  # Time-step
  txt = c(txt, "\t DATA_VECTOR(dt__);")
  txt = c(txt, "\t DATA_IVECTOR(N__);")
  
  # Parameters
  txt = c(txt, "\n//// parameters ////")
  for(i in 1:length(private$parameters)){
    txt = c(txt, sprintf("\t PARAMETER(%s);",private$parameter.names[i]))
  }
  
  # Constants
  txt = c(txt, "\n//// constants ////")
  for (i in 1:length(private$constants)) {
    txt = c( txt , sprintf("\t DATA_SCALAR(%s);",private$constant.names[i]))
  }
  
  # System size
  txt = c(txt, "\n//// system size ////")
  txt = c( txt , "\t DATA_INTEGER(n__);")
  txt = c( txt , "\t DATA_INTEGER(m__);")
  
  # Prediction variables
  txt = c( txt , "\t DATA_INTEGER(last_pred_index);")
  txt = c( txt , "\t DATA_INTEGER(k_step_ahead);")
  
  # Prediction storage
  # index i storage
  txt = c(txt, "\t vector<matrix<Type>> xk__(last_pred_index);")
  txt = c(txt, "\t vector<matrix<Type>> pk__(last_pred_index);")
  txt = c(txt, "\t xk__.fill(matrix<Type>(k_step_ahead+1,n__));")
  txt = c(txt, "\t pk__.fill(matrix<Type>(k_step_ahead+1,n__*n__));")
  # temp index k storage
  txt = c(txt, "\t matrix<Type> xk_temp__(k_step_ahead+1,n__);")
  txt = c(txt, "\t array<Type> pk_temp__(n__,n__,k_step_ahead+1);")
  
  # in each k-step-ahead im saving k state vectors, and k covariance matrices temporarily.
  # these can be saved into a matrix and stored in a vector of index i...
  
  txt = c(txt, "\n//////////// set initial value ///////////")
  txt = c(txt, "\t vector<Type> x0__ = X0__;")
  txt = c(txt, "\t matrix<Type> p0__ = P0__;")
  
  # Initiaze variables
  txt = c(txt, "\n\t //////////// initialize variables ///////////")
  txt = c(txt, "\t int s__;")
  txt = c(txt, "\t vector<Type> data_vector__(m__),na_bool__,e__,y__,F__,H__;")
  txt = c(txt, "\t matrix<Type> C__,R__,K__,E__,V__,Ri__,A__,G__;")
  
  # Identity Matrix
  txt = c(txt, "\n\t //////////// identity matrix ///////////")
  txt = c(txt, "\t matrix<Type> I__(n__,n__);")
  txt = c(txt, "\t I__.setIdentity();")
  
  # Main For-Loop
  txt = c(txt, "\n\t //////////// MAIN LOOP OVER TIME POINTS ///////////")
  txt = c(txt, "\t for(int i=0 ; i<last_pred_index ; i++){")
  
  txt = c(txt,"\n\t\t xk_temp__.row(0) = x0__;")
  txt = c(txt,"\t\t pk_temp__.col(0) = p0__;")
  
  # K-step-ahead for-loop
  txt = c(txt, "\n\t //////////// K-STEP-AHEAD LOOP ///////////")
  txt = c(txt, "\t for(int k=0 ; k < k_step_ahead ; k++){")
  
  # Solve Moment ODEs
  txt = c(txt, "\n\t\t //////////// TIME-UPDATE: SOLVE MOMENT ODES ///////////")
  txt = c(txt, "\t\t for(int j=0 ; j<N__(i+k) ; j++){")
 
  txt = c(txt, sprintf("\t\t\t ode_integration<Type> odelist = {x0__, p0__, t(i+k)+j*dt__(i+k), dt__(i+k), algo__, %s};",paste(allvars2_nostate_notime_pred,collapse=", ")))
  txt = c(txt,"\t\t\t x0__ = odelist.X_next;")
  txt = c(txt,"\t\t\t p0__ = odelist.P_next;")
  txt = c(txt, "\t\t }")
  
  txt = c(txt, "\n\t\t\t //////////// save k-step-ahead prediction ///////////")
  txt = c(txt,"\t\t\t xk_temp__.row(k+1) = x0__;")
  txt = c(txt,"\t\t\t pk_temp__.col(k+1) = p0__;")
  txt = c(txt, "\t\t }")
  
  txt = c(txt, "\n\t\t //////////// save all 0 to k step-ahead predictions ///////////")
  txt = c(txt,"\t\t xk__(i) = xk_temp__;")
  txt = c(txt,"\t\t for(int kk=0 ; kk < k_step_ahead+1 ; kk++){")
  txt = c(txt,"\t\t\t pk__(i).row(kk) = vector<Type>(pk_temp__.col(kk).transpose());")
  txt = c(txt, "\t\t }")
  
  txt = c(txt, "\n\t\t //////////// rewrite x0 and p0 to one-step predictions ///////////")
  txt = c(txt,"\t\t x0__ = xk_temp__.row(1);")
  txt = c(txt,"\t\t p0__ = pk_temp__.col(1).matrix();")
  
  # Data Update
  txt = c(txt, "\n\t\t //////////// DATA-UPDATE ///////////")
  
  obs.lhs = paste(names(private$obs.eqs.trans),"(i+1)",sep="")
  txt = c(txt, sprintf("\t\t data_vector__ << %s;", paste(obs.lhs,collapse=", ")))
  txt = c(txt, "\t\t na_bool__ = is_not_na(data_vector__);")
  txt = c(txt, "\t\t s__ = CppAD::Integer(sum(na_bool__));")
  
  # Start if statement for observations
  txt = c(txt, "\t\t if( s__ > 0 ){")
  txt = c(txt, "\t\t\t y__  = remove_nas__(data_vector__, s__, na_bool__);")
  txt = c(txt, "\t\t\t E__  = construct_permutation_matrix(s__, m__, na_bool__);")
  txt = c(txt, sprintf("\t\t\t H__  = h__(%s);",paste(hvars2,collapse=", ")))
  txt = c(txt, sprintf("\t\t\t C__  = E__ * dhdx__(%s);", paste(dhdxvars2,collapse=", ")))
  txt = c(txt, "\t\t\t e__  = y__ - E__ * H__;")
  txt = c(txt, sprintf("\t\t\t V__  = E__ * obsvarFun__(%s) * E__.transpose();", paste(obsvars2,collapse=" ,")))
  txt = c(txt, "\t\t\t R__  = C__ * p0__ * C__.transpose() + V__;")
  txt = c(txt, "\t\t\t Ri__ = R__.inverse();")
  txt = c(txt, "\t\t\t K__ 	= p0__ * C__.transpose() * Ri__;")
  txt = c(txt, "\t\t\t x0__ = x0__ + K__*e__;")
  txt = c(txt, "\t\t\t p0__ = (I__ - K__ * C__) * p0__ * (I__ - K__ * C__).transpose() + K__* V__ * K__.transpose();")
  txt = c(txt, "\t\t }")
  txt = c(txt, "\t }")
  
  
  # Report variables
  txt = c(txt, "\n\t //////////// Return/Report //////////////")
  txt = c(txt ,"\t REPORT(xk__);")
  txt = c(txt ,"\t REPORT(pk__);")
  txt = c(txt, "\t }")
  
  # Return nll
  txt = c(txt, "return nll__;")
  txt = c(txt, "}")
  
  # Write cpp function and close file connection
  writeLines(txt,fileconn)
  close(fileconn)
  
  # Return
  return(invisible(self))
}
