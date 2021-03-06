-- Copyright (c) 2017-present, Facebook, Inc.
-- All rights reserved.

-- This source code is licensed under the BSD-style license found in the
-- LICENSE file in the root directory of this source tree. An additional grant
-- of patent rights can be found in the PATENTS file in the same directory.

require 'torch'
require 'nn'

local tnt = require 'torchnet'
local threads = require 'threads'
local data = require 'wav2letter.runtime.data'
local log = require 'wav2letter.runtime.log'
local serial = require 'wav2letter.runtime.serial'
local tds = require 'tds'
local netutils = require 'wav2letter.runtime.netutils'

require 'wav2letter'

torch.setdefaulttensortype('torch.FloatTensor')


local function cmdmutableoptions(cmd)
   cmd:text()
   cmd:text('Run Options:')
   cmd:option('-datadir', string.format('%s/local/datasets/speech', os.getenv('HOME')), 'speech data directory')
   cmd:option('-dictdir', string.format('%s/local/datasets/speech/dict', os.getenv('HOME')), 'dictionary directory')
   cmd:option('-rundir', string.format('%s/local/experiments/speech', os.getenv('HOME')), 'experiment root directory')
   cmd:option('-archdir', string.format('%s/local/arch/speech', os.getenv('HOME')), 'arch root directory')
   cmd:option('-runname', '', 'name of current run')
   cmd:option('-gfsai', false, 'override above paths to gfsai ones')
   cmd:option('-mpi', false, 'use mpi parallelization')
   cmd:option('-seed', 1111, 'Manually set RNG seed')
   cmd:option('-progress', false, 'display training progress per epoch')
   cmd:option('-batchsize', 0, 'batchsize') -- not that mutable...
   cmd:option('-gpu', 0, 'use gpu instead of cpu (indicate device > 0)') -- not that mutable...
   cmd:option('-nthread', 1, 'specify number of threads for data parallelization')
   cmd:option('-mtcrit', false, 'use multi-threaded criterion')
   cmd:option('-terrsr', 1, 'train err sample rate (default: each example; 0 is skip)')
   cmd:option('-tag', '', 'tag this experiment with a particular name (e.g. "hypothesis1")')
   cmd:option('-gc', 100, 'collectgarbage every specified number of samples')
   cmd:text()
   cmd:text('Learning hyper-parameter Options:')
   cmd:option('-linseg', 0, 'number of linear segmentation iter, if not using -seg')
   cmd:option('-linsegznet', false, 'use fake zero-network with linseg')
   cmd:option('-linlr', -1, 'linear segmentation learning rate (if < 0, use lr)')
   cmd:option('-linlrcrit', -1, 'linear segmentation learning rate (if < 0, use lrcrit)')
   cmd:option('-iter', 1000000,   'number of iterations')
   cmd:option('-itersz', -1, 'iteration size')
   cmd:option('-lr', 1, 'learning rate')
   cmd:option('-falseg', 0, 'number of force aligned segmentation iter')
   cmd:option('-fallr', -1, 'force aligned segmentation learning rate (if < 0, use lr)')
   cmd:option('-sqnorm', false, 'use square-root when normalizing lr/batchsize/etc...')
   cmd:option('-layerlr', false, 'use learning rate per layer (divide by number of inputs)')
   cmd:option('-lrcrit', 0, 'criterion learning rate')
   cmd:option('-momentum', -1, 'provide momentum')
   cmd:option('-weightdecay', -1, 'weight decay')
   cmd:text()
   cmd:text('Filtering and normalization options:')
   cmd:option('-absclamp', 0, 'if > 0, clamp gradient to -value..value')
   cmd:option('-scaleclamp', 0, 'if > 0, clamp gradient to -(scale*|w|+value)..(scale*|w|+value) (value provided by -absclamp)')
   cmd:option('-normclamp', 0, 'if > 0, clamp gradient to provided norm')
   cmd:option('-maxisz', math.huge, 'max input size allowed during training')
   cmd:option('-maxtsz', math.huge, 'max target size allowed during training')
   cmd:option('-mintsz', 0, 'min target size allowed during training')
   cmd:option('-noresample', false, 'do not resample training data')
   cmd:text()
   cmd:text('Data Options:')
   cmd:option('-train', '', 'space-separated list of training data')
   cmd:option('-valid', '', 'space-separated list of valid data')
   cmd:option('-test', '', 'space-separated list of test data')
   cmd:option('-maxload', -1, 'max number of training examples (random sub-selection)')
   cmd:option('-maxloadvalid', -1, 'max number of valid examples (linear sub-selection)')
   cmd:option('-maxloadtest', -1, 'max number of testing examples (linear sub-selection)')
   cmd:option('-dictsil', false, 'with target=ltr, collapse <N> (noise) and <L> (laughter) to <|>)')
   cmd:text()
   cmd:text('Data Augmentation Options:')
   cmd:option('-aug', false, 'Enable data augmentations')
   cmd:option('-augbendingp', 0, 'Enable pitch bending with given probability')
   cmd:option('-augflangerp', 0, 'enable flanger')
   cmd:option('-augechorusp', 0, 'enable chorus')
   cmd:option('-augechop', 0, 'enable echos')
   cmd:option('-augnoisep', 0, 'enable addition of white/brown noise with given probability')
   cmd:option('-augcompandp', 0, 'enable compand (may clip!)')
   cmd:option('-augspeedp', 0, 'probability with which input speech transformation is applied')
   cmd:option('-augspeed', 0, 'variance of input speed transformation')
   cmd:text()
   cmd:text('Word Related Options:')
   cmd:option('-wer', false, 'compute WER (viterbi)')
   cmd:option('-bmrwer', false, 'compute non-train decoder WER')
   cmd:option('-bmrletters', '', 'path to LM letters')
   cmd:option('-bmrwords', '', 'path to LM words')
   cmd:option('-bmrlm', '', 'path to LM model')
   cmd:option('-bmrsmearing', 'max', 'use LM smearing or not')
   cmd:option('-bmrmaxword', -1, 'limit LM word dictionary')
   cmd:option('-bmrlmweight', 1, 'language model weight')
   cmd:option('-bmrwordscore', 0, 'word insertion score')
   cmd:option('-bmrunkscore', -math.huge, 'unknown word insertion score')
   cmd:option('-bmrbeamsize', 25, 'beam size')
   cmd:option('-bmrbeamscore', 25, 'beam threshold')
   cmd:option('-bmrforceendsil', false, 'force end sil')
   cmd:option('-bmrlogadd', false, 'use logadd instead of max')
   cmd:text()
   cmd:text('Architecture Options:')
   cmd:option('-posmax', false, 'use max instead of logadd (pos)')
   cmd:option('-negmax', false, 'use max instead of logadd (neg)')
   cmd:text()
end

function cmdimmutableoptions(cmd)
   cmd:text()
   cmd:text('----- Immutable Options -----')
   cmd:text()
   cmd:text('Architecture Options:')
   cmd:option('-arch', 'default', 'network architecture')
   cmd:option('-inormmax', false, 'input norm is max instead of std')
   cmd:option('-inormloc', false, 'input norm is local instead global')
   cmd:option('-nstate', 1, 'number of states per label (autoseg only)')
   cmd:option('-msc', false, 'use multi state criterion instead of fcc')
   cmd:option('-ctc', false, 'use ctc criterion for training')
   cmd:option('-garbage', false, 'add a garbage between each target label')
   cmd:option('-lsm', false, 'add LogSoftMax layer')
   cmd:text()
   cmd:text('Data Options:')
   cmd:option('-input', 'flac', 'input feature')
   cmd:option('-target', 'ltr', 'target feature [phn, ltr, wrd]')
   cmd:option('-samplerate', 16000, 'sample rate (Hz)')
   cmd:option('-channels', 1, 'number of input channels')
   cmd:option('-dict', 'letters.lst', 'dictionary to use')
   cmd:option('-replabel', 0, 'replace up to replabel reptitions by additional classes')
   cmd:option('-dict39', false, 'with target=phn, dictionary with 39 phonemes mode (training -- always for testing)')
   cmd:option('-surround', '', 'surround target with provided label')
   cmd:option('-seg', false, 'segmentation is given or not')
   cmd:text()
   cmd:text('MFCC Options:')
   cmd:option('-mfcc', false, 'use standard htk mfcc features as input')
   cmd:option('-pow', false, 'use standard power spectrum as input')
   cmd:option('-mfcccoeffs', 13, 'number of mfcc coefficients')
   cmd:option('-mfsc', false, 'use standard mfsc features as input')
   cmd:option('-melfloor', 0.0, 'specify optional mel floor for mfcc/mfsc/pow')
   cmd:text()
   cmd:text('Normalization Options:')
   cmd:option('-inkw', 8000, 'local input norm kw')
   cmd:option('-indw', 2666, 'local input norm dw')
   cmd:option('-innt', 0.01, 'local input noise threshold')
   cmd:option('-onorm', 'none', 'output norm (none, input or target)')
   cmd:option('-wnorm', false, 'weight normalization')
   cmd:text()
   cmd:text('Input shifting Options:')
   cmd:option('-shift', 0, 'number of shifts')
   cmd:option('-dshift', 0, '# of frames to shift')
   cmd:text()
end

-- override paths?
local function overridepath(opt)
   if opt.gfsai then
      opt.datadir = '/data/local/packages/ai-group.speechdata/latest/speech'
      opt.dictdir = '/data/local/packages/ai-group.speechdata/latest/speech'
      opt.archdir = '/mnt/vol/gfsai-east/ai-group/teams/wav2letter/arch'
      opt.rundir = '/mnt/vol/gfsai-east/ai-group/users/' .. assert(os.getenv('USER'), 'unknown user') .. '/chronos'
      opt.runname = assert(os.getenv('CHRONOS_JOB_ID'), 'unknown job id')
   end
end

local opt -- current options
local path -- current experiment path
local runidx -- current #runs in this path
local reload -- path to model to reload
local cmdline = serial.savecmdline{arg=arg}
local command = arg[1]
if #arg >= 1 and command == '--train' then
   table.remove(arg, 1)
   opt = serial.parsecmdline{
      closure =
         function(cmd)
            cmdmutableoptions(cmd)
            cmdimmutableoptions(cmd)
         end,
      arg = arg
   }
   overridepath(opt)
   runidx = 1
   path = serial.newpath(opt.rundir, opt)
elseif #arg >= 2 and arg[1] == '--continue' then
   path = arg[2]
   table.remove(arg, 1)
   table.remove(arg, 1)
   runidx = serial.runidx(path, "model_last.bin")
   reload = serial.runidx(path, "model_last.bin", runidx-1)
   opt = serial.parsecmdline{
      closure = cmdmutableoptions,
      arg = arg,
      default = serial.loadmodel(reload).config.opt
   }
   if opt.gfsai then
      overridepath(opt)
      local symlink = serial.newpath(opt.rundir, opt)
      -- make a symlink to track exp id
      serial.symlink(
         path,
         symlink
      )
      print(string.format("| experiment symlink path: %s", symlink))
   end
elseif #arg >= 2 and arg[1] == '--fork' then
   reload = arg[2]
   table.remove(arg, 1)
   table.remove(arg, 1)
   opt = serial.parsecmdline{
      closure = cmdmutableoptions,
      arg = arg,
      default = serial.loadmodel(reload).config.opt
   }
   overridepath(opt)
   runidx = 1
   path = serial.newpath(opt.rundir, opt)
else
   error(string.format([[
usage:
   %s --train <options...>
or %s --continue <directory> <options...>
or %s --fork <directory/model> <options...>
]], arg[0], arg[0], arg[0]))
end

-- saved configuration
local config = {
   opt = opt,
   path = path,
   runidx = runidx,
   reload = reload,
   cmdline = cmdline,
   command = command,
   -- extra goodies:
   username = os.getenv('USER'),
   hostname = os.getenv('HOSTNAME'),
   timestamp = os.date("%Y-%m-%d %H:%M:%S"),
}

local mpi
local mpinn
local mpirank = 1
local mpisize = 1
local function reduce(val)
   return val
end
if opt.mpi then
   mpi = require 'torchmpi'
   mpinn = require 'torchmpi.nn'
   mpi.start(opt.gpu > 0, true)
   mpirank = mpi.rank()+1
   mpisize = mpi.size()
   print(string.format('| MPI #%d/%d', mpirank, mpisize))
   function reduce(val, noavg)
      if noavg then
         return mpi.allreduce_double(val)
      else
         return mpi.allreduce_double(val)/mpisize
      end
   end
end
config.mpisize = mpisize

if mpirank == 1 then
   print(string.format("| experiment path: %s", path))
   print(string.format("| experiment runidx: %d", runidx))
   serial.mkdir(path)
end

-- default lr
opt.linlr = (opt.linlr < 0) and opt.lr or opt.linlr
opt.fallr = (opt.fallr < 0) and opt.lr or opt.fallr
opt.linlrcrit = (opt.linlrcrit < 0) and opt.lrcrit or opt.linlrcrit

if opt.seed > 0 then
   torch.manualSeed(opt.seed)
else
   torch.seed()
end
if opt.gpu > 0 then
   require 'cutorch'
   require 'cunn'
   require 'cudnn'
   if not opt.mpi then
      cutorch.setDevice(opt.gpu)
   end
   if opt.seed > 0 then
      cutorch.manualSeedAll(opt.seed)
   else
      cutorch.seedAll()
   end
end

local dict = data.newdict{
   path = paths.concat(opt.dictdir, opt.dict)
}

if opt.dictsil then
   data.dictadd{dictionary=dict, token='N', idx=assert(dict['|'])}
   data.dictadd{dictionary=dict, token='L', idx=assert(dict['|'])}
end

local dict61phn
local dict39phn
if opt.target == "phn" then
   dict61phn = dict
   dict39phn = data.dictcollapsephones{dictionary=dict}
   if opt.dict39 then
      dict = dict39phn
   end
end

if opt.replabel > 0 then
   for i=1,opt.replabel do
      data.dictadd{dictionary=dict, token=string.format("%d", i)}
   end
end

-- ctc expects the blank label last
if opt.ctc or opt.garbage then
   data.dictadd{dictionary=dict, token="#"} -- blank
end

local decoder
local dopt
if opt.bmrwer then
   decoder = require 'wav2letter.runtime.decoder'
   decoder = decoder(
      opt.bmrletters,
      opt.bmrwords,
      opt.bmrlm,
      opt.bmrsmearing,
      opt.bmrmaxword
   )
   dopt = {
      lmweight = opt.bmrlmweight,
      wordscore = opt.bmrwordscore,
      unkscore = opt.bmrunkscore,
      beamsize = opt.bmrbeamsize,
      beamscore = opt.bmrbeamscore,
      forceendsil = opt.bmrforceendsil,
      logadd = opt.bmrlogadd
   }
end

-- if opt.garbage then
--    assert(opt.nstate == 1, 'cannot have garbage and nstate set together')
--    #dict = #dict + 1
-- else
--    #dict = #dict*opt.nstate
-- end

print(string.format('| number of classes (network) = %d', #dict))

-- neural network and training criterion
local network, transitions, kw, dw
if reload then
   print(string.format('| reloading model <%s>', reload))
   local model = serial.loadmodel{filename=reload, arch=true}
   network = model.arch.network
   transitions = model.arch.transitions
   kw = model.config.kw
   dw = model.config.dw
   assert(kw and dw, 'kw and dw could not be found in model archive')
else
   network, kw, dw = netutils.create{
      specs = netutils.readspecs(paths.concat(opt.archdir, opt.arch)),
      gpu = opt.gpu,
      channels = (opt.mfsc and 40 ) or ((opt.pow and 257 ) or (opt.mfcc and opt.mfcccoeffs*3 or opt.channels)), -- DEBUG: UGLY
      nclass = #dict,
      lsm = opt.lsm,
      batchsize = opt.batchsize,
      wnorm = opt.wnorm
   }
end
config.kw = kw
config.dw = dw

local zeronet = nn.ZeroNet(kw, dw, #dict)
local netcopy = network:clone() -- pristine stateless copy
local scale
if opt.onorm == 'input' then
   function scale(input, target)
      return opt.sqnorm and math.sqrt(1/input:size(1)) or 1/input:size(1)
   end
elseif opt.onorm == 'target' then
   function scale(input, target)
      return opt.sqnorm and math.sqrt(1/target:size(1)) or 1/target:size(1)
   end
elseif opt.onorm ~= 'none' then
   error('invalid onorm option')
end
print(string.format('| neural network number of parameters: %d', netutils.size(network)))

local function initCriterion(class, ...)
   if opt.batchsize > 0 and class == 'AutoSegCriterion' then
      return nn.BatchAutoSegCriterionC(opt.batchsize, ...)
   elseif opt.batchsize > 0 and opt.mtcrit then
      return nn.MultiThreadedBatchCriterion(opt.batchsize, {'transitions'}, class, ...)
   elseif opt.batchsize > 0 then
      return nn.BatchCriterion(opt.batchsize, {'transitions'}, class, ...)
   else
      return nn[class](...)
   end
end

local fllcriterion
local asgcriterion
local ctccriterion = initCriterion('ConnectionistTemporalCriterion', #dict, scale)
local msccriterion = initCriterion('MultiStateFullConnectCriterion', #dict/opt.nstate, opt.nstate, opt.posmax, scale)
local lincriterion = initCriterion('LinearSegCriterion', #dict, opt.negmax, scale, opt.linlrcrit == 0)
local falcriterion = initCriterion('CrossEntropyForceAlignCriterion', #dict, opt.posmax, scale)
local viterbi      = initCriterion('Viterbi', #dict, scale)

if opt.garbage then
   fllcriterion = initCriterion('FullConnectGarbageCriterion', #dict-1, opt.posmax, scale)
   asgcriterion = initCriterion('AutoSegCriterion', #dict-1, opt.posmax, opt.negmax, scale, 'garbage')
else
   if opt.posmax then
      fllcriterion = initCriterion('FullConnectCriterion', #dict, opt.posmax, scale)
   else
      fllcriterion = initCriterion('FullConnectCriterionC', #dict, opt.posmax, scale)
   end
   asgcriterion = initCriterion('AutoSegCriterion', #dict, opt.posmax, opt.negmax, scale, opt.msc and opt.nstate or nil)
end

lincriterion:share(asgcriterion, 'transitions') -- beware (asg...)
falcriterion:share(asgcriterion, 'transitions')
fllcriterion:share(asgcriterion, 'transitions')
msccriterion:share(asgcriterion, 'transitions')
viterbi:share(asgcriterion, 'transitions')

local evlcriterion = (opt.ctc and ctccriterion) or (opt.msc and msccriterion or viterbi)
-- clone is important (otherwise forward/backward not in a row
-- because we evaluate right after the forward and before the backward)
evlcriterion = evlcriterion:clone():share(asgcriterion, 'transitions')

-- from reload?
if transitions then
   asgcriterion.transitions:copy(transitions)
end

if opt.layerlr then
   network = netutils.layerlr(network, opt.lr)
end

local function applyOnBackwardOptims() end
if opt.weightdecay or opt.momentum > 0 then
   applyOnBackwardOptims = netutils.applyOptim(network,
                                               opt.momentum,
                                               opt.weightdecay)
end

local function applyClamp() end
local wavoptim = require 'wav2letter.optim'
if opt.scaleclamp > 0 then
   local apply = wavoptim.weightedGradientClamp(network, asgcriterion)
   function applyClamp()
      apply(opt.absclamp, opt.scaleclamp)
   end
elseif opt.absclamp > 0 then
   local apply = wavoptim.absGradientClamp(network, asgcriterion)
   function applyClamp()
      apply(opt.absclamp)
   end
elseif opt.normclamp > 0 then
   local apply = wavoptim.normGradientClamp(network, asgcriterion)
   function applyClamp()
      apply(opt.normclamp)
   end
end

assert(not(opt.batchsize > 0 and opt.shift > 0), 'Cannot allow both shifting and batching')

if opt.shift > 0 then
   network = nn.MapTable(network, {'weight', 'bias'})
   network:resize(opt.shift)
   network = nn.ShiftNet(network, opt.shift)
end

local transforms = require 'wav2letter.runtime.transforms'
local remaplabels = transforms.remap{
   uniq = true,
   replabel = opt.replabel > 0 and {n=opt.replabel, dict=dict} or nil,
   phn61to39 = ((opt.target == "phn") and not opt.dict39) and {dict39=dict39phn, dict61=dict61phn} or nil
}

local sampler, resample = data.newsampler(opt.itersz)
local worddict = tds.Hash()
if opt.wer or opt.bmrwer then
   local i = 0
   for line in io.lines(opt.bmrwords) do
      local word = line:match('^(%S+)')
      worddict[word] = i
      i = i + 1
   end
   worddict['<unk>'] = i
end
local trainiterator = data.newiterator{
   nthread = opt.nthread,
   closure =
      function()
         local data = require 'wav2letter.runtime.data'
         return data.newdataset{
            names = data.namelist(opt.train),
            opt = opt,
            dict = dict,
            kw = kw,
            dw = dw,
            sampler = sampler,
            samplersize = opt.itersz,
            mpirank = mpirank,
            mpisize = mpisize,
            aug = opt.aug,
            maxload = opt.maxload,
            words = (opt.wer or opt.bmrwer or opt.bmcrt) and 'wrd' or nil,
         }
      end
}
local trainsize = trainiterator.execSingle and trainiterator:execSingle('size') or trainiterator:exec('size')

local validiterators = {}
for _, name in ipairs(data.namelist(opt.valid)) do
   validiterators[name] = data.newiterator{
   nthread = opt.nthread,
   closure =
      function()
         local data = require 'wav2letter.runtime.data'
         return data.newdataset{
            names = {name},
            opt = opt,
            dict = dict,
            kw = kw,
            dw = dw,
            mpirank = mpirank,
            mpisize = mpisize,
            maxload = opt.maxloadvalid,
            words = (opt.wer or opt.bmrwer or opt.bmcrt) and 'wrd' or nil,
         }
      end
   }
end

local testiterators = {}
for _, name in ipairs(data.namelist(opt.test)) do
   testiterators[name] = data.newiterator{
   nthread = opt.nthread,
   closure =
      function()
         local data = require 'wav2letter.runtime.data'
         return data.newdataset{
            names = {name},
            opt = opt,
            dict = dict,
            kw = kw,
            dw = dw,
            mpirank = mpirank,
            mpisize = mpisize,
            maxload = opt.maxloadtest,
            words = (opt.wer or opt.bmrwer or opt.bmcrt) and 'wrd' or nil,
         }
      end
   }
end

----------------------------------------------------------------------
-- Performance meters

local meters = {}

meters.runtime = tnt.TimeMeter()
meters.timer = tnt.TimeMeter{unit = true}
meters.sampletimer = tnt.TimeMeter{unit = true}
meters.networktimer = tnt.TimeMeter{unit = true}
meters.criteriontimer = tnt.TimeMeter{unit = true}
meters.loss = tnt.AverageValueMeter{}
if opt.seg then -- frame error rate
   meters.trainframeerr = tnt.FrameErrorMeter{}
end
meters.trainedit = tnt.EditDistanceMeter()
meters.wordedit = tnt.EditDistanceMeter()
meters.bmrwordedit = tnt.EditDistanceMeter()

meters.validedit = {}
meters.validwordedit = {}
meters.validbmrwordedit = {}
for name, valid in pairs(validiterators) do
   meters.validedit[name] = tnt.EditDistanceMeter()
   meters.validwordedit[name] = tnt.EditDistanceMeter()
   meters.validbmrwordedit[name] = tnt.EditDistanceMeter()
end

meters.testedit = {}
meters.testwordedit = {}
meters.testbmrwordedit = {}
for name, test in pairs(testiterators) do
   meters.testedit[name] = tnt.EditDistanceMeter()
   meters.testwordedit[name] = tnt.EditDistanceMeter()
   meters.testbmrwordedit[name] = tnt.EditDistanceMeter()
end

meters.stats = tnt.SpeechStatMeter()


local logfile
local perffile
if mpirank == 1 then
   logfile = torch.DiskFile(serial.runidx(path, "log", runidx), "w")
   perffile = torch.DiskFile(serial.runidx(path, "perf", runidx), "w")
   log.print2file{file=logfile, date=true, stdout=true}
   local _, header = log.status{meters=meters, opt=opt, date=true}
   perffile:seekEnd()
   perffile:writeString('# ' .. header .. '\n')
   perffile:synchronize()
end

local function logstatus(meters, state)
   local msgl = log.status{meters=meters, state=state, verbose=true, separator=" | ", opt=opt, reduce=reduce}
   local msgp = log.status{meters=meters, state=state, opt=opt, reduce=reduce, date=true}
   if mpirank == 1 then
      print(msgl)
      logfile:seekEnd()
      logfile:writeString(msgl)
      logfile:writeString("\n")
      logfile:synchronize()

      perffile:seekEnd()
      perffile:writeString(msgp)
      perffile:writeString("\n")
      perffile:synchronize()
   end
end

-- best perf so far on valid datasets
local minerrs = {}
for name, valid in pairs(validiterators) do
   minerrs[name] = math.huge
end

local function savebestmodels()
   if mpirank ~= 1 then
      return
   end

   -- save last model
   serial.savemodel{
      filename = serial.runidx(path, "model_last.bin", runidx),
      config = config,
      arch = {
         network = netutils.copy(
            netcopy,
            (opt.shift > 0) and network.network or network
         ),
         transitions = asgcriterion.transitions
      }
   }

   -- save if better than ever for one valid
   local err = {}
   for name, validedit in pairs(meters.validedit) do
      local value = validedit:value()
      if value < minerrs[name] then
         err[name] = value
         minerrs[name] = value
         serial.savemodel{
            filename = serial.runidx(path, serial.cleanfilename("model_" .. name .. ".bin"), runidx),
            config = config,
            arch = {
               network = netutils.copy(
                  netcopy,
                  (opt.shift > 0) and network.network or network
               ),
               transitions = asgcriterion.transitions,
               perf = value
            },
         }
      end
   end

   return err
end

----------------------------------------------------------------------


local function createProgress(iterator)
   local xlua = require 'xlua'
   local N = iterator.execSingle and iterator:execSingle('size') or iterator:exec('size')
   local n = 0
   return function ()
      if mpirank == 1 then
         n = n + 1
         xlua.progress(n, N)
      end
   end
end

local function map(closure, a)
   if opt.batchsize > 0 then
      local bsz = type(a) == 'table' and #a or a:size(1)
      for k=1,bsz do
         closure(a[k])
      end
   else
      closure(a)
   end
end

local function map2(closure, a, b)
   if opt.batchsize > 0 then
      local bsz = type(a) == 'table' and #a or a:size(1)
      for k=1,bsz do
         closure(a[k], b[k])
      end
   else
      closure(a, b)
   end
end

local function evalOutput(edit, wordedit, output, target, words, remaplabels)
   local function evl(o, t)
      edit:add(remaplabels(o), remaplabels(t))
   end
   local function wordevl(o, t)
      o = remaplabels(o)
      local unkhash = tds.Hash()
      o = data.tensor2string{tensor=o, dict=dict}:gsub('|', ' ')
      o = data.words2tensor{words=o, dict=worddict, unkdict=unkhash}
      t = data.words2tensor{words=t, dict=worddict, unkdict=unkhash}
      wordedit:add(o, t)
   end
   local path = evlcriterion:viterbi(output)
   map2(evl, path, target)
   if opt.wer then
      map2(wordevl, path, words)
   end
end

local function test(network, criterion, iterator, edit, wordedit, bmrwordedit)
   local progress = opt.progress and createProgress(iterator)
   local engine = tnt.SGDEngine()
   function engine.hooks.onStart()
      edit:reset()
      wordedit:reset()
      bmrwordedit:reset()
   end
   function engine.hooks.onForward(state)
      if progress then
         progress()
      end
      if state.t % opt.gc == 0 then
         collectgarbage()
         collectgarbage()
      end
      evalOutput(edit, wordedit, state.network.output, state.sample.target, state.sample.words, remaplabels)
      -- compute decoder WER?
      if opt.bmrwer and bmrwordedit then
         local function decode(output, words)
            local wpred = decoder.removeunk(decoder(dopt, asgcriterion.transitions, output))
            bmrwordedit:add(wpred, words)
         end
         map2(decode, state.network.output, data.words2tensor{words=state.sample.words, dict=worddict, unk=assert(worddict['<unk>'])})
      end
   end
   engine:test{
      network = network,
      iterator = iterator
   }
   if progress and mpirank == 1 then
      print()
   end
end

local function train(network, criterion, iterator, params, opid)
   local progress
   local heartbeat = serial.heartbeat{
      filename = paths.concat(path, "heartbeat"),
   }
   local engine = tnt.SGDEngine()

   function engine.hooks.onStart(state)
      meters.loss:reset()
      meters.trainedit:reset()
      meters.wordedit:reset()
      meters.bmrwordedit:reset()
      if opt.mpi then
         mpinn.synchronizeParameters(state.network, true) -- DEBUG: FIXME
         if state.criterion.parameters and state.criterion:parameters() then
            mpinn.synchronizeParameters(state.criterion, true) -- DEBUG: FIXME
         end
      end
   end

   function engine.hooks.onStartEpoch(state)
      meters.runtime:reset()
      meters.runtime:resume()
      if not opt.noresample then
         resample()
      end
      if trainframeerr then
         trainframeerr:reset()
      end
      progress = opt.progress and createProgress(iterator)
      meters.stats:reset()
      meters.timer:reset()
      meters.sampletimer:resume()
      meters.sampletimer:reset()
      meters.networktimer:stop()
      meters.networktimer:reset()
      meters.criteriontimer:stop()
      meters.criteriontimer:reset()
      meters.timer:resume()
   end

   function engine.hooks.onSample(state)
      if progress then
         progress()
      end
      meters.sampletimer:stop()
      meters.networktimer:resume()
      heartbeat()
   end

   function engine.hooks.onForward(state)
      if state.t % opt.gc == 0 then
         collectgarbage()
         collectgarbage()
      end
      meters.networktimer:stop()
      meters.criteriontimer:resume()
      if state.t % opt.terrsr == 0 then
         evalOutput(meters.trainedit, meters.wordedit, state.network.output, state.sample.target, state.sample.words, remaplabels)
      end
      if trainframeerr then
         evalOutput(meters.trainframeerr, meters.wordedit, state.network.output, state.sample.target, state.sample.words, remaplabels)
      end
   end

   function engine.hooks.onBackwardCriterion(state)
      meters.criteriontimer:stop()
      meters.networktimer:resume()
   end

   function engine.hooks.onBackward(state)
      if opt.mpi then
         mpinn.synchronizeGradients(state.network)
         if state.criterion.parameters and state.criterion:parameters() then
            mpinn.synchronizeGradients(state.criterion)
         end
      end
      applyClamp()
      applyOnBackwardOptims()
      meters.networktimer:stop()
   end

   function engine.hooks.onUpdate(state)
      map(function(out) if out then meters.loss:add(out) end end, state.criterion.output)
      map2(function(i, t) if i then meters.stats:add(i, t) end end, opt.shift > 0 and state.sample.input[1] or state.sample.input, state.sample.target)
      meters.timer:incUnit()
      meters.sampletimer:incUnit()
      meters.networktimer:incUnit()
      meters.criteriontimer:incUnit()
      meters.sampletimer:resume()
   end

   function engine.hooks.onEndEpoch(state)
      meters.runtime:stop()
      meters.timer:stop()
      meters.sampletimer:stop()
      meters.networktimer:stop()
      if progress then
         print()
      end

      -- valid
      for name, validiterator in pairs(validiterators) do
         test(network, criterion, validiterator,
              meters.validedit[name],
              meters.validwordedit[name],
              meters.validbmrwordedit[name])
      end

      -- test
      for name, testiterator in pairs(testiterators) do
         test(network, criterion, testiterator,
              meters.testedit[name],
              meters.testwordedit[name],
              meters.testbmrwordedit[name])
      end

      -- print status
      logstatus(meters, state)

      -- save last and best models
      savebestmodels()

      -- reset meters for next readings
      meters.loss:reset()
      meters.trainedit:reset()
      meters.wordedit:reset()
      meters.bmrwordedit:reset()

   end

   engine:train{
      network = network,
      criterion = criterion,
      iterator = iterator,
      lr = params.lr,
      lrcriterion = params.lrcriterion,
      maxepoch = params.maxepoch
   }
end

if mpirank == 1 then
   serial.savetable{
      filename = serial.runidx(path, "config.lua", runidx),
      tbl = config
   }
end

local lrnorm = opt.batchsize > 0 and 1/(mpisize*opt.batchsize) or 1/mpisize
lrnorm = opt.sqnorm and math.sqrt(lrnorm) or lrnorm

if not opt.seg and opt.linseg > 0 then
   train(
      opt.linsegznet and zeronet or network,
      lincriterion,
      trainiterator,
      {lr=opt.linlr*lrnorm, lrcriterion=opt.linlrcrit*lrnorm, maxepoch=opt.linseg},
      1
   )
end

if opt.falseg > 0 then
   train(
      network,
      falcriterion,
      trainiterator,
      {lr=opt.fallr, maxepoch=opt.falseg},
      2
   )
end

train(
   network,
   ((opt.ctc and ctccriterion) or (opt.seg and fllcriterion or asgcriterion)),
   trainiterator,
   {lr=opt.lr*lrnorm, lrcriterion=opt.lrcrit*lrnorm, maxepoch=opt.iter},
   3
)

if opt.mpi then
   mpi.stop()
end
