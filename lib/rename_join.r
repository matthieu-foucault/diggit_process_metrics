library(RMongo)
library(rjson)
library(coin)
library(reshape)
library(ggplot2)

load_metrics = function(key) {
  match = '{$match: {number_of_renames:{$gt:0}}}'
	project = paste('{$project:{"',key,'":1}}', sep="")
	unwind = paste('{$unwind:"$',key,'"}',sep="")
	group = paste('{$group:{"_id":"a", metrics:{$addToSet:"$',key,'"}}}',sep="")

	mongo = mongoDbConnect("diggit")
	lst = fromJSON(dbAggregate(mongo, "delta_metrics", c(match,project, unwind, group)))$metrics
	df = data.frame(matrix(unlist(lst), nrow = length(lst), byrow=T),stringsAsFactors = F)
	colnames(df) = colnames(data.frame(lst[1]))
  
  # fix data types
  for(col in c("ownModule", "ownModuleChurn", "touches", "churn")) {
    df[,col] = as.numeric(df[,col])
  }
  
	return(df)
}

metrics = merge(load_metrics("metrics_rename"), load_metrics("metrics_no_rename"), 
                by=c("project","developer","module","X.date"), 
                all=T, suffixes=c("_rename","_no_rename"))
metrics[is.na(metrics)] = 0

compute_module_metrics = function(module_metrics) {
  with(module_metrics,
       data.frame(module = module[1], 
                  project = project[1],
                  
                  NoD_rename = length(subset(ownModule_rename, ownModule_rename > 0)),
                  NoC_rename = sum(touches_rename),
                  Churn_rename = sum(churn_rename),
                  MVO_rename = max(ownModule_rename),
                  Major_rename = length(subset(ownModule_rename, ownModule_rename  >= 0.05)),
                  Minor_rename = length(subset(ownModule_rename, ownModule_rename < 0.05 && ownModule_rename > 0)),
                  
                  NoD_no_rename = length(subset(ownModule_no_rename, ownModule_no_rename > 0)),
                  NoC_no_rename = sum(touches_no_rename),
                  Churn_no_rename = sum(churn_no_rename),
                  MVO_no_rename = max(ownModule_no_rename),
                  Major_no_rename = length(subset(ownModule_no_rename, ownModule_no_rename  >= 0.05)),
                  Minor_no_rename = length(subset(ownModule_no_rename, ownModule_no_rename < 0.05 && ownModule_no_rename > 0))
       )
  )
}

extract_process_metrics = function(project_metrics) {
  do.call(rbind, by(project_metrics, project_metrics$module, compute_module_metrics))
}

cliff_d_paired = function (x, y) {
  library(orddom)
  n_x = length(x)
  n_y = length(y)
  dom <- dm(x, y)
  dw <- -mean(diag(dom))
  
  db <- -((sum(dom) - sum(diag(dom)))/(n_x * (n_y -1)))
  return(dw + db)
}



extract_differences = function(project_metrics) {
  do.call(cbind,lapply(c("NoD", "NoC", "Churn","MVO"), function(metric) {
    x = project_metrics[, paste(metric, "rename", sep="_")]
    y = project_metrics[, paste(metric, "no_rename", sep="_")]
    
    if (all(x==y)){
      a = data.frame(0, 1, 1)
    } else {
      pearson = cor.test(x,y, method="pearson")
      spearman = cor.test(x,y,method="spearman")
      delta = cliff_d_paired(x,y)
      a = data.frame(delta, pearson$estimate, spearman$estimate)
    }
    colnames(a) = c(paste("cliff",metric,"estimate",sep="_"),
                    paste("pearson", metric, "estimate", sep="_"),
                    paste("spearman", metric, "estimate", sep="_"))
    rownames(a) = project_metrics$project[1]
    return(a)
  }))
}

process_metrics = do.call(rbind,by(metrics, list(metrics$project, metrics$X.date), extract_process_metrics))

results = do.call(rbind,by(process_metrics, process_metrics$project, extract_differences))

results$project = row.names(results)
melted = melt(results, "project")

cairo_pdf("./cliff.pdf", width=7, height=6)
print(
ggplot(subset(melted, grepl("cliff_.*_estimate", melted$variable)), aes(x=variable, y=abs(value))) +
  geom_violin(scale="width", fill="grey") +
  scale_x_discrete(labels=c("NoD", "NoC", "Churn","MVO")) +
  labs(x="", y="Cliff's Delta", title="Effect Size of Rename Detection") +
  theme_bw()
)
dev.off()

cairo_pdf("./spearman.pdf", width=7, height=6)
print(
ggplot(subset(melted, grepl("spearman_.*_estimate", melted$variable)), aes(x=variable, y=value)) +
  geom_violin(scale="width", fill = "grey") +
  theme_bw()
)
dev.off()

cairo_pdf("./pearson.pdf", width=7, height=6)
print(
ggplot(subset(melted, grepl("pearson_.*_estimate", melted$variable)), aes(x=variable, y=value)) +
  geom_violin(scale="width", fill = "grey") +
  theme_bw()
)
dev.off()
