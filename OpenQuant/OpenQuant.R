## This R script generates a set of basic plots and tables which summarise the PEP section of mzTab files.
## It is divided into three parts:
## (1) definition of global options and parameters
## (2) definition of functions
## (3) main part i.e. generation of plots and tables
##
## To install dependencies, please run in R:
## install.packages("corrplot")     # for correlation of peptide intensities
## install.packages("xtable")       # for peptides/proteins of interest tables
## install.packages("ggfortify")    # for plotPCA(), But we can do PCA without additional packages, see plotPCAscatter() etc.
## install.packages('rasterVis')
## install.packages('reshape2')

library(corrplot)
library(xtable)
#library(ggfortify)    # for plotPCA()
library(rasterVis)
library(reshape2)

# clear entire workspace
rm(list = ls())

####
## (1) definition of global options and parameters
####

#input.file <- 'analysis.mzTab'
input.file <- 'example_6.mzTab'

# maximum number of digits
options(digits=10)

# switch off warnings
options(warn=-1)

# fold change cutoff, i.e. infinite fc values are mapped to +/-FcCutoff
FcCutoff <- 8

# study variable labels
# The PEP section of the mzTab file contains columns peptide_abundance_study_variable[*]. Each column can be labelled with a string such as "control" or "treated".
# If the number of study variable columns is not equal to the length of the labels vector, then the labels vector is ignored.
labels.of.study.variables <- rep(c("H", "BL", "fu48"), times = 18)

# Biognosys iRT spike-in peptides
#peptides.of.interest <- c("LGGNEQVTR", "GAGSSEPVTGLDAK", "VEATFGVDESNAK", "YILAGVENSK", "TPVISGGPYEYR", "TPVITGAPYEYR", "DGLDAASYYAPVR", "ADVTPADFSEWSK", "GTFIIDPGGVIR", "GTFIIDPAAVIR", "LFLQFGAQGSPFLK")

# Pierce spike-in peptides
peptides.of.interest <- c("SSAAPPPPPR", "GISNEGQNASIK", "HVLTSIGEK", "DIPVPKPK", "IGDYAGIK", "TASEFDSAIAQDK", "SAAGAFGPELSR", "ELGQSGVDTYLQTK", "GLILVGGYGTR", "GILFVGSGVSGGEEGAR", "SFANQPLEVVYSK", "LTILEELR", "NGFILDGFPR", "ELASGLSFPVGFK", "LSSEAPALFQFDLK")

# some random human peptides
#peptides.of.interest <- c("LSLMYAR", "EQCCYNCGKPGHLAR", "LSAIYGGTYMLNKPVDDIIMENGKVVGVK", "MVQEAEKYKAEDEKQR", "TVPFCSTFAAFFTR", "GNFGGSFAGSFGGAGGHAPGVAR", "LGWDPKPGEGHLDALLR")

# proteins of interest
proteins.of.interest <- c("P46783", "P12270")






####
## (2) definition of functions
####

# find start of the section
startSection <- function(file, section.identifier) {
  data <- file(file, "r")
  row = 0
  while (TRUE) {
    row = row + 1
    line = readLines(data, n=1)
    if (substr(line, 1, 3)==section.identifier) {
      break
    }
  }
  close(data)
  return (row)
}

# check if the vector/column is empty
# i.e. all entries are NA or "" etc. or the the vector is of length 0
isEmpty <- function(column)
{
  column <- column[!is.na(column)]
  column <- column[column != c("")]
  return(length(column) == 0)
}

# count the occurences of character c in string s
countOccurrences <- function(char,s) {
  s2 <- gsub(char,"",s)
  return (nchar(s) - nchar(s2))
}

# check that the protein accession is of the format *|*|*
# Note that NA returns TRUE.
checkAccessionFormat <- function(accession) {
  if (isEmpty(accession)) {
    return(FALSE)
  }
  
  if (all(is.na(accession))) {
    return (TRUE)
  }
  n <- length(accession)
  count <- countOccurrences("[|]",accession)
  m <- length(which(count==2))
  return (n==m)
}

# Extracts the second entry from a string of the form *|*|*.
getAccession <- function(string) {
  if (is.na(string)) {
    return (NA)
  }
  return (unlist(strsplit(string, "[|]"))[2])
}

# Extracts the third entry from a string of the form *|*|*.
getGene <- function(string) {
  if (is.na(string)) {
    return (NA)
  }
  return (unlist(strsplit(string, "[|]"))[3])
}

# read the PEP section of an mzTab file
readMzTabPEP <- function(file) {
  
  # find start of the PEP section
  first.row <- startSection(file, "PEH")
  
  # read entire mzTab
  data <- read.table(file, sep="\t", skip=first.row-1, fill=TRUE, header=TRUE, quote="", na.strings=c("null","NA"), stringsAsFactors=FALSE, check.names=FALSE)
  
  # extract PEP data
  peptide.data <- data[which(data[,1]=="PEP"),]
  peptide.data$PEH <- NULL
  
  # In case the accession column is of the format *|*|*, we split this column into an accession and a gene column.
  if (all(sapply(peptide.data$accession, checkAccessionFormat))) {
    peptide.data$gene <- sapply(peptide.data$accession, getGene)
    peptide.data$accession <- sapply(peptide.data$accession, getAccession)
  }
  
  return (peptide.data)
}

# splits fasta protein accession into UniProt accession and gene name
splitAccession <- function(peptide.data) {
  # simplify accession (in case it is of the format *|*|* )
  peptide.data$accession <- as.character(peptide.data$accession)
  if (checkAccessionFormat(peptide.data$accession)) {
    list <- strsplit(peptide.data$accession,"[|]")
    peptide.data$accession <- unlist(lapply(list, '[[', 2))
    peptide.data$gene <- unlist(lapply(list, '[[', 3))
  }
  
  return (peptide.data)
}

# check if a specific "peptide_abundance_study_variable[n]" column exists
studyVariableExists <- function(data, n)
{
  column <- paste("peptide_abundance_study_variable[",as.character(n),"]",sep="")
  return (column %in% colnames(data))
}

# returns the number of quantification channels i.e. the number of "peptide_abundance_study_variable[*]" columns
numberOfStudyVariables <- function(data)
{
  columns <- colnames(data)
  return(length(which(grepl("peptide_abundance_study_variable", columns))))
}

# determine fold changes and map to finite numbers
# fc = log2(abundances1/abundances2)
# Should be NA-save, i.e. abundance vectors may contain NAs.
calculateFoldChange <- function(abundances1, abundances2) {
  offset <- 1e-10       # avoids devisions by zero
  max.fc <- FcCutoff    # map knock-out fold changes to finite values 
  
  abundances1[is.na(abundances1)] <- 0
  abundances2[is.na(abundances2)] <- 0
  
  # calculate fold changes
  abundances1 <- abundances1 + offset
  abundances2 <- abundances2 + offset
  fc <- log2(abundances1/abundances2)
  
  # map fc to finite values
  fc[which(fc < -FcCutoff)] <- -FcCutoff
  fc[which(fc > +FcCutoff)] <- +FcCutoff
  
  return (fc)
}

# returns a unique colour for each string
uniqueColors <- function(string.vector)
{
  unique <- unique(string.vector)
  palette <- rainbow(length(unique))
  names(palette) <- unique
  
  return(palette[string.vector])
}

# plot fold change vs log intensity
plotFcLogIntensity <- function(fc.vector, intensity.vector, fc.label, pdf.file)
{
  pdf(file=pdf.file)
  idx <- complete.cases(fc.vector) & complete.cases(intensity.vector)
  x <- fc.vector[idx]
  y <- log10(intensity.vector[idx])
  df <- data.frame(x,y)
  x <- densCols(x,y, colramp=colorRampPalette(c("black", "white")))
  df$dens <- col2rgb(x)[1,] + 1L
  #cols <- colorRampPalette(c("#000099", "#00FEFF", "#45FE4F", "#FCFF00", "#FF9400", "#FF3100"))(256)
  cols <-  colorRampPalette(c("#2166AC", "#3F8EC0", "#80B9D8", "#BCDAEA", "#E6EFF3", "#F9EAE1", "#FAC8AF", "#ED9576", "#D25749", "#B2182B"))(256)
  df$col <- cols[df$dens]
  plot(y~x, data=df[order(df$dens),], pch=20, col=col, xlab=fc.label, ylab=expression('log'[10]*' intensity'))
  abline(v=0, col = "gray", lty=1)
  abline(v=median(fc.vector, na.rm=TRUE), col = "gray", lty=2)
  dev.off()
}

# plot peptide fold change vs log intensity for a single specific protein
# (same peptide sequence -> same colour)
plotFcLogIntensitySingleProtein <- function(data, protein, sample.1, sample.2, pdf.file)
{
  idx <- which(data$accession == protein)
  data <- data[idx,]
  
  # make (modified sequence, charge) pair unique i.e. use best quants only
  data <- makeModifiedSequenceChargeUnique(data)
  
  # calculate fc and average intensity
  column.1 <- paste("peptide_abundance_study_variable[", as.character(sample.1), "]", sep="")
  column.2 <- paste("peptide_abundance_study_variable[", as.character(sample.2), "]", sep="")
  data$fc <- calculateFoldChange(data[[column.1]], data[[column.2]])
  data$intensity <- getAverageIntensity(data)
  idx <- complete.cases(data[,c("fc","intensity")])
  data <- data[idx,]
  
  # define colours
  colours <- c("grey", "red")

  pdf(file=pdf.file)
  plot(data$fc, data$intensity, pch=20, col=colours[data$unique+1], xlab=paste("fold change (sample ", sample.1, " vs ", sample.2, ")", sep=""), ylab="intensity", log="y", main=protein)
  abline(v=0, col = "gray", lty=1)
  abline(v=median(data$fc, na.rm=TRUE), col = "gray", lty=2)
  legend("topright", legend=c("unique", "non-unique"), fill=c("red", "grey"), box.lty=0)
  dev.off()
}

# plot sample (or group) index vs fold change for all peptides of a specific protein
# The fold change is calculated relative to the sample with the most peptide quantifications.
plotFcSingleProtein <- function(data, protein, pdf.file)
{
  # count the number of not NA
  numberNonNA <- function(vector)
  {
    return(length(which(!is.na(vector))))
  }
  
  # filter for the protein of interest
  idx <- which(data$accession == protein)
  data <- data[idx,]
  quants <- getPeptideQuants(data)
  
  # find sample with most quants
  number.of.quants <- apply(quants, 2, numberNonNA)
  idx.max <- which(number.of.quants == max(number.of.quants))[1]
  ylabel <- paste("fold change (sample i vs sample ", as.character(idx.max), ")", sep="")
  
  # calculate fold changes
  fc <- apply(quants, 2, calculateFoldChange, abundances2=quants[,idx.max])
  
  fc <- cbind(data$sequence, data.frame(fc))
  colnames(fc) <- c("sequence", as.character(1:numberOfStudyVariables(data)))
  fc <- melt(fc, id=c("sequence"))
  fc$variable <- as.numeric(fc$variable)
  colnames(fc) <- c("sequence", "sample", "fc")
  limits <- c(min(fc$sample) - 0.5, max(fc$sample) + 0.5)
  
  if (length(labels.of.study.variables) == numberOfStudyVariables(data))
  {
    # Group labels match the number of study variables. Let us combine samples to groups.
    
    unique.labels <- unique(labels.of.study.variables)
    group.idx <- 1:length(unique.labels)
    names(group.idx) <- unique.labels
    
    fc$group <- labels.of.study.variables[fc$sample]
    fc$group.idx <- as.numeric(group.idx[fc$group])
    limits <- c(min(fc$group.idx) - 0.5, max(fc$group.idx) + 0.5)
    
    # shift group index slightly for better visibility (same sequence = same shift)
    unique.sequence <- unique(fc$sequence)
    sequence.idx <- 1:length(unique.sequence)
    names(sequence.idx) <- unique.sequence
    shift <- as.numeric(sequence.idx[fc$sequence])/length(unique.sequence)*0.4 - 0.2
    fc$group.idx <- fc$group.idx + shift
    
    pdf(file=pdf.file)
    plot(fc$group.idx, fc$fc, pch=16, xaxt="n", xlab="group", ylab=ylabel, main=protein, xlim=limits)
    axis(1, at=1:length(unique.labels), labels=unique.labels)
    dev.off()
  } else {
    # Group labels do not match the number of study variables. Let us simply plot samples and ignore the groups.
    
    pdf(file=pdf.file)
    plot(fc$sample, fc$fc, pch=16, xaxt="n", xlab="sample", ylab=ylabel, main=protein, xlim=limits)
    axis(1, at=1:numberOfStudyVariables(data))
    dev.off()
  }
}

# plot distribution
plotDistribution <- function(vector, label, pdf.file)
{
  breaks <- 80
  
  if (is.factor(vector))
  {
    vector <- as.numeric(as.character(vector))
  }
  
  pdf(file=pdf.file, height=4)
  hist(vector, xlab=label, ylab="density", freq=TRUE, main="", col="grey", yaxt='n', breaks=breaks)
  dev.off()
}

# Kendrick nominal fractional mass plot
plotKendrick <- function(mass, pdf.file) {
  nominal = floor(mass)
  fractional = mass - nominal
  pdf(file=pdf.file)
  x <- nominal
  y <- fractional
  df <- data.frame(x,y)
  x <- densCols(x,y, colramp=colorRampPalette(c("black", "white")))
  df$dens <- col2rgb(x)[1,] + 1L
  #cols <- colorRampPalette(c("#000099", "#00FEFF", "#45FE4F", "#FCFF00", "#FF9400", "#FF3100"))(256)
  cols <-  colorRampPalette(c("#2166AC", "#3F8EC0", "#80B9D8", "#BCDAEA", "#E6EFF3", "#F9EAE1", "#FAC8AF", "#ED9576", "#D25749", "#B2182B"))(256)
  df$col <- cols[df$dens]
  plot(y~x, data=df[order(df$dens),], pch=20, col=col, xlab='nominal mass [Da]', ylab='fractional mass [Da]')
  dev.off()
}

# returns a dataframe containing only the peptide quantification columns
# required input is a dataframe with columns "peptide_abundance_study_variable[*]"
getPeptideQuants <- function(data)
{
  idx <- grepl("peptide_abundance_study_variable", colnames(data))
  return(data[,idx])
}

# returns an average peptide intensity over all study variables
getAverageIntensity <- function(data)
{
  quants <- getPeptideQuants(data)
  quants[is.na(quants)] <- 0
  intensity <- apply(quants, 1, mean)
  return(intensity)
}

# makes the (modified sequence, charge) combination unique by picking the quants with maximum intensity
makeModifiedSequenceChargeUnique <- function(data)
{
  # returns index of the best quantification with this modified sequence, charge combination 
  indexMaxIntensity <- function(sequence.charge, df)
  {
    idx <- which(df$sequence.charge==sequence.charge)
    max <- max(df$intensity[idx])
    idx.m <- which(df[idx,]$intensity==max)
    return(idx[idx.m])
  }
  
  # add columns of average peptide abundance and of modified sequence and charge (which we will make unique)
  data$intensity <- getAverageIntensity(data)
  data$sequence.charge <- paste(data$"opt_global_modified_sequence", as.character(data$charge), sep="_")
  
  # make (modified sequence, charge) unique and find the quants with highest intensity
  unique.sequence.charge <- unique(data$sequence.charge)
  idx <- unlist(lapply(unique.sequence.charge, FUN=indexMaxIntensity, df=data))
  
  # clean up
  data$intensity <- NULL
  data$sequence.charge <- NULL
  
  return(data[idx,])
}

plotCorrelations <- function(data, pdf.file)
{
  # extract study variables
  study_variables.n <- numberOfStudyVariables(data)
  study_variables.data = getPeptideQuants(data)
  
  # (optional) z-score normalisation
  #study_variables.data <- scale(study_variables.data, center = TRUE, scale = TRUE)
  
  corr = cor(study_variables.data[complete.cases(study_variables.data),], method="pearson")    # possible methods: "pearson", "spearman", "kendall"
  
  # rename columns and rows
  colnames(corr) <- 1: study_variables.n
  rownames(corr) <- 1: study_variables.n
  cols <- colorRampPalette(c("#2166AC", "#3F8EC0", "#80B9D8", "#BCDAEA", "#E6EFF3", "#F9EAE1", "#FAC8AF", "#ED9576", "#D25749", "#B2182B"))(256)
  
  pdf(file=pdf.file)
  if (study_variables.n < 12)
  {
    # use combined "number/circle" plotting method for SILAC, TMT and small LFQ analyses
    corrplot(corr, cl.lim=c(min(corr),max(corr)), col = cols, is.corr=FALSE, method = "number")
    #corrplot.mixed(corr, cl.lim=c(min(corr), max(corr)), cols=cols, is.corr=FALSE, lower="number", upper="circle")
  }
  else
  {
    # use "circle" plotting method for LFQ analyses
    corrplot(corr, cl.lim=c(min(corr),max(corr)), col = cols, is.corr=FALSE, method = "circle")
  }
  dev.off()
  
  return(corr)
}

plotBoxplot <- function(data, pdf.file) {
  # extract study variables
  quants = getPeptideQuants(data)
  colnames(quants) <- as.character(1:(dim(quants)[2]))
  
  # (optional) z-score normalisation
  #quants <- scale(quants, center = TRUE, scale = TRUE)
  
  # make values strictly positive
  quants[quants <= 0] <- NA
  
  pdf(file=pdf.file, height = 6, width = 10)
  boxplot(quants, log="y", ylab="expression", xlab="samples", las=2, na.rm=TRUE)
  dev.off()
}

# calculate the principal component object
getPCA <- function(data) {
  
  # extract study variables
  quants <- getPeptideQuants(data)
  colnames(quants) <- as.character(1:(dim(quants)[2]))
  
  # remove rows with NaN values
  quants <- quants[complete.cases(quants),]
  
  # calculate principal components
  pca <- prcomp(t(quants), center = TRUE, scale = TRUE)
  
  return(pca)
}

# plot the scatter plot of the first n.pca principal components
plotPCAscatter <- function(pca, pdf.file) {
  
  # number of principal components to be plotted
  n.pca <- 3
  
  # number of distinct label
  n.labels <- length(unique(labels.of.study.variables))
  
  # number of samples i.e. dots
  n.samples <- length(pca$sdev)
  
  # define colours
  if (length(labels.of.study.variables) == n.samples) {
    colours.strong <- rainbow(n.labels, s = 1, v = 1, start = 0, end = max(1, n.labels - 1)/n.labels, alpha = 1)[as.factor(labels.of.study.variables)]
    colours.light <- rainbow(n.labels, s = 1, v = 1, start = 0, end = max(1, n.labels - 1)/n.labels, alpha = 0.2)[as.factor(labels.of.study.variables)]
  }
  else {
    colours.strong <- "darkgrey"
    colours.light <- "white"
  }
  
  # customize upper panel
  upper.panel.custom <- function(x, y){
    points(x,y, pch = 19, col = colours.light)
    text(x, y, as.character(1:n.samples))
  }
  
  # customize lower panel
  lower.panel.custom <- function(x, y){
    points(x,y, pch = 19, col = colours.strong)
    #text(x, y, labels.of.study.variables)
  }
  
  pdf(file=pdf.file)
  pairs(pca$x[,1:n.pca], upper.panel = upper.panel.custom, lower.panel = lower.panel.custom)
  if (length(labels.of.study.variables) == n.samples) {
    # legend only need if we colour the dots
    par(xpd = TRUE)
    legend(0, 1, as.factor(unique(labels.of.study.variables)), fill=colours.strong, bg="white")
  }
  dev.off()
}

# plot the standard deviation of all principal components
plotPCAcomponents <- function(pca, pdf.file) {
  
  pdf(file=pdf.file)
  barplot(pca$sdev, names.arg=as.character(1:length(pca$sdev)), xlab="principal component", ylab="standard deviation")
  dev.off()
}

# Eigenvectors point in the direction of the principal componets in the high-dimensional peptide abundance space.
# Important peptides (i.e. the ones with a large absolute eigenvector component) contribute most to this principal component.
# The function returns these peptides i.e. their row index.
getPCAeigenvector <- function(pca, n) {
 
  # number of most important peptides to return
  n.coordinates = 10
  
  eigenvector <- pca$rotation[,n]
  eigenvector <- abs(eigenvector)    # Note the PCA is centred and scaled. Consequently, the eigenvector may have negative componets.
  
  idx <- order(eigenvector, decreasing = TRUE)    # Sort in decreasing order.
  row.idx <- order(idx)[1:n.coordinates]
  
  return(row.idx)
}

# plot the coordinates of the nth eigenvector
plotPCAeigenvector <- function(pca, data, n, pdf.file) {
  
  # number of coordinates to plot
  n.coordinates = 10
  
  eigenvector <- pca$rotation[,n]
  eigenvector <- abs(eigenvector)
  
  idx <- order(eigenvector, decreasing = TRUE)
  eigenvector <- eigenvector[idx]
  eigenvector <- eigenvector[1:n.coordinates]

  idx.complete <- which(complete.cases(getPeptideQuants(data)))
  idx <- idx.complete[getPCAeigenvector(pca, n)]
  row.idx <- rownames(data[idx,])
  
  pdf(file=pdf.file)
  #plot(eigenvector, xaxt = "n", pch=19, col="darkgrey", ylab="eigenvector component", xlab="peptide (row index in PEP section)")
  plot(eigenvector, xaxt = "n", ylab="eigenvector component", xlab="peptide (row index in PEP section)", type="b")
  axis(1, at=1:n.coordinates, labels=row.idx)
  dev.off()
}

# # plot PCA scatter plot of first two principal components
# # based on ggplot2
# plotPCA <- function(data, pdf.file) {
#   # extract study variables
#   quants <- getPeptideQuants(data)
#   colnames(quants) <- as.character(1:(dim(quants)[2]))
# 
#   # remove rows with NaN values
#   quants <- quants[complete.cases(quants),]
# 
#   # study variables in rows, dimensions i.e. peptide abundances in columns
#   quants <- t(quants)
# 
#   # calculate principal components
#   quants.pca <- prcomp(quants, center = TRUE, scale = TRUE)
# 
#   # plot first two principal components
#   if (dim(quants)[1] == length(labels.of.study.variables))
#   {
#     # The labels vector matches the mzTab data.
#     df <- data.frame(quants)
#     df$labels <- labels.of.study.variables
#     autoplot(quants.pca, data = df, colour = 'labels', label = TRUE)
#     }
#   else
#   {
#     # The labels vector does not match the mzTab data.
#     autoplot(quants.pca, label = TRUE)
#   }
#   ggsave(pdf.file)
# }

# limits amino acid sequences to n characters
cutSequence <- function(s) {
  if (is.na(s)) {
    return(s)
  }
  
  n <- 25
  short <- substr(s, 1, n)
  if (nchar(s) > nchar(short)) {
    short <- paste(short, "...", sep = "")
  }
  return(short)
}

findPeptidesOfInterest <- function(data)
{
  retain.columns=c("row index", "opt_global_modified_sequence", "accession", "charge", "retention_time", "mass_to_charge")
  new.column.names=c("row index", "modified sequence", "accession", "charge", "retention time", "m/z")

  # check if sequence column is non-empty
  if (isEmpty(data$sequence))
  {
    df <- t(data.frame(c("no sequences reported", rep("", 4))))
    colnames(df) <- c("modified sequence", "accession", "charge", "retention time", "m/z" )
    rownames(df) <- c()
    return(df)
  }
  
  pattern = paste(peptides.of.interest, collapse="|")
  df <- as.data.frame(data[grepl(pattern, data$sequence),])
  
  # check if results are empty
  if (dim(df)[1] == 0)
  {
    df <- t(data.frame(c("no matching sequences found", rep("", 4))))
    colnames(df) <- c("modified sequence", "accession", "charge", "retention time", "m/z" )
    rownames(df) <- c()
    return(df)
  }
  
  # sort in decreasing abundances
  idx <- order(rowSums(getPeptideQuants(df)), decreasing = TRUE)
  df <- df[idx,]
  
  # sort in the same order as peptides.of.interest vector
  df <- df[order(match(df$sequence, peptides.of.interest)),]
  
  # reduce length of modified sequence
  df$opt_global_modified_sequence <- unlist(lapply(df$opt_global_modified_sequence, cutSequence))
  
  # add the row index in the PEP section
  df$'row index' <- rownames(df)
  
  # select and rename columns
  df <- df[,retain.columns]
  colnames(df) <- new.column.names
  
  return(df)
}

findProteinsOfInterest <- function(data) {
  retain.columns=c("row index", "opt_global_modified_sequence", "accession", "charge", "retention_time", "mass_to_charge")
  new.column.names=c("row index", "modified sequence", "accession", "charge", "retention time", "m/z")
  
  # check if protein accession column is non-empty
  if (isEmpty(data$accession))
  {
    df <- t(data.frame(c("", "no accessions reported", rep("", 3))))
    colnames(df) <- c("modified sequence", "accession", "charge", "retention time", "m/z" )
    rownames(df) <- c()
    return(df)
  }
  
  pattern = paste(proteins.of.interest, collapse="|")
  df <- as.data.frame(data[grepl(pattern, data$accession),])
  
  # check if results are empty
  if (dim(df)[1] == 0)
  {
    df <- t(data.frame(c("", "no matching accessions found", rep("", 3))))
    colnames(df) <- c("modified sequence", "accession", "charge", "retention time", "m/z" )
    rownames(df) <- c()
    return(df)
  }
  
  # sort in decreasing abundances
  idx <- order(rowSums(getPeptideQuants(df)), decreasing = TRUE)
  df <- df[idx,]
  
  # sort in the same order as proteins.of.interest vector
  df <- df[order(match(df$accession, proteins.of.interest)),]
  
  # reduce length of modified sequence
  df$opt_global_modified_sequence <- unlist(lapply(df$opt_global_modified_sequence, cutSequence))
  
  # add the row index in the PEP section
  df$'row index' <- rownames(df)
  
  # select and rename columns
  df <- df[, retain.columns]
  colnames(df) <- new.column.names
  
  return(df)
}

# plots the reported peptide abundances of all peptides of interest
plotPeptidesOfInterest <- function(data, pdf.file) {
  
  # check if sequence column is empty
  if (isEmpty(data$sequence)) return()
  
  # extract peptides of interest
  pattern = paste(peptides.of.interest, collapse="|")
  df <- as.data.frame(data[grepl(pattern, data$sequence),])
  
  # sort in decreasing abundances
  idx <- order(rowSums(getPeptideQuants(df)), decreasing = TRUE)
  df <- df[idx,]
  
  # sort in the same order as peptides.of.interest vector
  df <- df[order(match(df$sequence, peptides.of.interest)),]
  
  # abort plotting if no peptides of interest were found 
  if (dim(df)[1] == 0) return()
  
  # extract quantifications and prepare for plotting
  quants <- as.matrix(getPeptideQuants(df))
  colnames(quants) <- as.character(1:dim(quants)[2])
  quants[quants <= 0] <- NA
  quants <- log10(quants)
  if (nrow(quants) > 1) {
    # If we have a single row, there is no need to reverse the order of rows. If we try, the matrix is (automatically) converted to a vector. :(
    quants <- quants[nrow(quants):1,]
  }
  quants <- t(quants)
  
  colours <-  colorRampPalette(c("#2166AC", "#3F8EC0", "#80B9D8", "#BCDAEA", "#E6EFF3", "#F9EAE1", "#FAC8AF", "#ED9576", "#D25749", "#B2182B"))(256)
  
  pdf(file=pdf.file)
  
  my.theme <- BuRdTheme()
  my.theme$panel.background$col = 'gray20'
  my.min <- min(quants, na.rm=TRUE)
  my.max <- max(quants, na.rm=TRUE)
  my.at <- seq(my.min, my.max, length.out=length(my.theme$regions$col)-1)
  my.ckey <- list(at=my.at, col=my.theme$regions$col)
  
  p <- levelplot(quants, par.settings=my.theme, at=my.at, colorkey=my.ckey, xlab="samples", ylab="peptides (row index in PEP section)", scales = list(tck = c(0,0)))
  print(p)
  
  dev.off()
}

# plots the reported peptide abundances of all proteins of interest
plotProteinsOfInterest <- function(data, pdf.file) {
  
  # check if protein accession column is non-empty
  if (isEmpty(data$accession)) return()
  
  # extract proteins of interest
  pattern = paste(proteins.of.interest, collapse="|")
  df <- as.data.frame(data[grepl(pattern, data$accession),])
  
  # sort in decreasing abundances
  idx <- order(rowSums(getPeptideQuants(df)), decreasing = TRUE)
  df <- df[idx,]
  
  # sort in the same order as proteins.of.interest vector
  df <- df[order(match(df$accession, proteins.of.interest)),]
  
  # abort plotting if no peptides of interest were found 
  if (dim(df)[1] == 0) return()
  
  # extract quantifications and prepare for plotting
  quants <- as.matrix(getPeptideQuants(df))
  colnames(quants) <- as.character(1:dim(quants)[2])
  quants[quants <= 0] <- NA
  quants <- log10(quants)
  if (nrow(quants) > 1) {
    # If we have a single row, there is no need to reverse the order of rows. If we try, the matrix is (automatically) converted to a vector. :(
    quants <- quants[nrow(quants):1,]
  }
  quants <- t(quants)
  
  colours <-  colorRampPalette(c("#2166AC", "#3F8EC0", "#80B9D8", "#BCDAEA", "#E6EFF3", "#F9EAE1", "#FAC8AF", "#ED9576", "#D25749", "#B2182B"))(256)
  
  pdf(file=pdf.file)
  
  my.theme <- BuRdTheme()
  my.theme$panel.background$col = 'gray20'
  my.min <- min(quants, na.rm=TRUE)
  my.max <- max(quants, na.rm=TRUE)
  my.at <- seq(my.min, my.max, length.out=length(my.theme$regions$col)-1)
  my.ckey <- list(at=my.at, col=my.theme$regions$col)
  
  p <- levelplot(quants, par.settings=my.theme, at=my.at, colorkey=my.ckey, xlab="samples", ylab="peptides (row index in PEP section)", scales = list(tck = c(0,0)))
  print(p)
  
  dev.off()
  
  # # plot quantifications for each individual protein
  # for (p in 1:length(proteins.of.interest))
  # {
  #   pdf.file.temp <- paste(substr(pdf.file, 1, (nchar(pdf.file)-4)), "_", as.character(p), ".pdf", sep="")
  #   
  #   idx <- which(data$accession == proteins.of.interest[p])
  #   quants <- getPeptideQuants(data[idx,])
  #   
  #   pdf(file=pdf.file.temp)
  #   plot(1:dim(quants)[2], rep(max(quants), dim(quants)[2]), main=proteins.of.interest[p])
  #   dev.off()
  # }
}

# create a summary table of all modifications and their specificities
# required input is a dataframe with a "sequence" and "modifications" column in mzTab standard
createModsSummary <- function(data)
{
  # extract relevant data
  data <- data[,c("sequence","modifications")]
  data <- data[!is.na(data$modifications),]
  data <- data[data$modifications != c(""),]
  
  # check if any mods are reported
  if (dim(data)[1] == 0)
  {
    stats <- t(data.frame(c("no mods reported","","")))
    colnames(stats) <- c("modification","specificity","number")
    rownames(stats) <- c()
    return(stats)
  }
  
  # split comma-separted mods into multiple columns
  all.mods <- strsplit(data$modifications, split=",")
  l <- sapply(all.mods, length)
  idx <- rep(1:length(l), l)
  data <- data[idx,]
  data$modifications <- unlist(all.mods)
  
  # extract specificity
  getSiteIndex <- function(mod)
  {
    return(unlist(strsplit(mod, split="-"))[1])
  }
  data$idx <- sapply(data$modifications, getSiteIndex)
  getSiteAA <- function(idx, sequence)
  {
    if (idx == 0)
    {
      return("N-term")
    }
    else
    {
      return(substr(sequence, idx, idx))
    }
  }
  data$specificity <- mapply(getSiteAA, idx = data$idx, sequence = data$sequence)
  
  # extract mod accession
  getModAccession <- function(mod)
  {
    return(unlist(strsplit(mod, split=":"))[2])
  }
  data$accession <- sapply(data$modifications, getModAccession)
  
  # create summary statistics
  stats <- aggregate(data$accession, by=list(data$accession, data$specificity), FUN=length)
  colnames(stats) = c("mod","specificity","number")
  stats <- stats[order(stats$number, decreasing = TRUE),]
  
  # replace mod accession by mod name
  Accession2Mod <- rep("",3000)
  Accession2Mod[1] <- "Acetyl"
  Accession2Mod[4] <- "Carbamidomethyl"
  Accession2Mod[34] <- "Methyl"
  Accession2Mod[35] <- "Oxidation"
  Accession2Mod[36] <- "Dimethyl"
  Accession2Mod[39] <- "Methylthio"
  Accession2Mod[188] <- "Label:13C(6)"
  Accession2Mod[199] <- "Dimethyl:2H(4)"
  Accession2Mod[259] <- "Label:13C(6)15N(2)"
  Accession2Mod[267] <- "Label:13C(6)15N(4)"
  Accession2Mod[284] <- "Methyl:2H(2)"
  Accession2Mod[329] <- "Methyl:2H(3)13C(1)"
  Accession2Mod[330] <- "Dimethyl:2H(6)13C(2)"
  Accession2Mod[425] <- "Dioxidation"
  Accession2Mod[510] <- "Dimethyl:2H(4)13C(2)"
  Accession2Mod[737] <- "TMT6plex"
  stats$mod <- Accession2Mod[as.numeric(stats$mod)]
  
  return(stats)
}

# (in)complete quantification plot
# Not all peptides need to be quantified in all channels/samples. See for example knock-out or TAILS experiments.
# Not quantified can mean either NaN or exactly zero.
# The plot below summarises how many peptides were quantified in x samples. 1 <= x <= number of samples
plotQuantFrequency <- function(quants, pdf.file)
{
  countQuantified <- function(vector)
  {
    return(length(which(!is.na(vector) & vector > 0)))
  }
  counts.quantified <- apply(quants, 1, countQuantified)
  countOccurrenceInVector <- function(n)
  {
    return(length(which(counts.quantified == n)))
  }
  frequency <- unlist(lapply(dim(quants)[2]:1, countOccurrenceInVector))
  
  pdf(file=pdf.file)
  barplot(frequency, names.arg = as.character(dim(quants)[2]:1), xlab = "number of samples in which peptide was quantified", ylab = "peptide count")
  dev.off()
}

# plot frequency of frequencies of any vector. Take for example a vector of protein accessions.
# frequency: How often does a particular protein X occur?
# frequency of frequencies: How often does a protein occur twice or three times and so on?
plotFrequencyOfFrequencies <- function(vector, pdf.file, xlab="frequency", ylab="frequency of frequency", log="y")
{
  frequency <- as.data.frame(table(vector))
  frequency.of.frequencies <- as.data.frame(table(frequency$Freq))
  colnames(frequency.of.frequencies) <- c("freq","freq.of.freq")
  frequency.of.frequencies$freq <- as.numeric(as.character(frequency.of.frequencies$freq))
  frequency.of.frequencies$freq.of.freq <- as.numeric(as.character(frequency.of.frequencies$freq.of.freq))
  
  pdf(file=pdf.file)
  plot(frequency.of.frequencies$freq, frequency.of.frequencies$freq.of.freq, xlab=xlab, ylab=ylab, log=log, type="b")
  dev.off()
}

# (modified sequence, charge) pair multiplicity vs frequency plot
# Each peptide feature (characterised by a (possibly) modified peptide sequence and a charge state) should ideally occur only once in the analysis.
# In other words, peptides of multiplicity 1 should have a very high frequency. The plot below should show a significant spike on the left and can be used as QC of the analysis.
plotMultiplicityFrequency <- function(data, pdf.file)
{
  modified.sequence.charge <- paste(data$"opt_global_modified_sequence", as.character(data$charge), sep="_")
  plotFrequencyOfFrequencies(modified.sequence.charge, pdf.file, "multiplicity of (modified sequence, charge) pairs", "occurrences", "y")
}

# quantified peptides per protein vs frequency plot
plotPeptidesPerProtein <- function(data, pdf.file)
{
  if ("accession" %in% colnames(data))
  {
    accessions <- data$accession
    accessions <- accessions[complete.cases(accessions)]
    if (length(accessions)>0)
    {
      plotFrequencyOfFrequencies(data$accession, "plot_PeptidesPerProteinFrequency.pdf", "number of quantified peptides per protein", "occurrences", "xy")
    }
  }
}





####
## (3) main part
####

# loop parameters
LoopStart = 2.0
LoopEnd = 15
LoopStep = 0.1

# stats to be plotted
params <- c()
number.of.quants <- c()
standard.deviation <- c()

param = LoopStart
while (param <= LoopEnd)
{
  input.file = paste("BM4351_mzTab/BM4351_", format(round(param, 1), nsmall = 1), ".mzTab", sep="")
  
  print(input.file)
  peptide.data <- readMzTabPEP(input.file)
  
  params <- c(params, param)
  number.of.quants <- c(number.of.quants, dim(peptide.data)[1])
  
  quants <- getPeptideQuants(peptide.data)
  fc <- calculateFoldChange(quants[,1],quants[,2])
  standard.deviation <- c(standard.deviation, sd(fc, na.rm = TRUE))
  
  # move to next parameter
  param = param + LoopStep
}

# plot number of quants
pdf(file="plot_NumberOfQuants.pdf")
plot(params, number.of.quants, xlab="mz tolerance [ppm]", ylab="number of quants", type="b")
dev.off()

# plot standard deviation of fold changes
pdf(file="plot_StandardDeviationOfFoldChange.pdf")
plot(params, standard.deviation, xlab="mz tolerance [ppm]", ylab="standard deviation of fold change", type="b")
dev.off()
