
codedir=/afs/inf.ed.ac.uk/group/project/img2txt/dep_parser/dense_release
curdir=`pwd`

# model=/disk/scratch1/XingxingZhang/dep_parse/experiments/release_test/czech/model_0.001.tune.ori.t7
model=$curdir/model_0.001.tune.t7

outTrain=$curdir/label_train.h5

inTrain=/disk/scratch/s1270921/dep_parse/data_conll/czech/czech_gold_train.conll
inValid=/disk/scratch/s1270921/dep_parse/data_conll/czech/czech_gold_dev.conll
inTest=/disk/scratch/s1270921/dep_parse/data_conll/czech/czech_gold_test.conll


outValid=$curdir/valid.dep
outTest=$curdir/test.dep

log=$curdir/gen-log.txt

cd $codedir

CUDA_VISIBLE_DEVICES=3 th train_labeled.lua --mode generate \
	--modelPath $model \
	--outTrainDataPath $outTrain \
	--inTrain $inTrain \
	--inValid $inValid \
	--inTest $inTest \
	--outValid $outValid \
	--outTest $outTest \
	--language Other | tee $log

cd $curdir

