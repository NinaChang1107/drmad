--[[
Multiple meta-iterations for DrMAD on CIFAR10
]]

require 'torch'
require 'sys'
require 'image'

local root = '../'

local grad = require 'autograd'
local utils = require(root .. 'models/utils.lua')
local optim = require 'optim'
local dl = require 'dataload'
local xlua = require 'xlua'
local c = require 'trepl.colorize'


opt = lapp[[
   -s,--save            (default "logs")    subdirectory to save logs
   -b,--batchSize         (default 128)      batch size
   -r,--learningRate      (default 1)      learning rate
   --learningRateDecay      (default 1e-7)    learning rate decay
   --weightDecay          (default 0.0005)    weightDecay
   -m,--momentum          (default 0.9)       momentum
   --epoch_step         (default 25)      epoch step
   --model            (default vgg)       model name
   --max_epoch          (default 300)       maximum number of iterations
   --backend            (default cunn)        backend
   --mode             (default L2)        L2/L1/learningrate
   --type             (default cuda)      cuda/float/cl
   --numMeta            (default 3)         #episode
   --hLR              (default 0.0001)     learningrate of hyperparameter
   --initHyper          (default 0.001)      initial value for hyperparameter
]]

print(c.blue "==> " .. "parameter:")
print(opt)

grad.optimize(true)


local function sgd_m(opfunc, x, config, state)
   -- (0) get/update state
   local config = config or {}
   local state = state or config
   local lr = config.learningRate or 1e-3
   local lrd = config.learningRateDecay or 0
   local wd = config.weightDecay or 0
   local mom = config.momentum or 0
   local damp = config.dampening or mom
   local nesterov = config.nesterov or false
   local lrs = config.learningRates
   local wds = config.weightDecays
   local forward_only = config.forward_only or nil
   state.evalCounter = state.evalCounter or 0
   local nevals = state.evalCounter
   assert(not nesterov or (mom > 0 and damp == 0), "Nesterov momentum requires a momentum and zero dampening")


   --print(config)
   -- (1) evaluate f(x) and df/dx
   local fx,dfdx = opfunc(x)

   --print(dfdx)

   -- (2) weight decay with single or individual parameters
   if wd ~= 0 then
      for i = 1, #dfdx do
         dfdx[i]:add(wd, x[i])
      end
   elseif wds then
      if not state.decayParameters then
         state.decayParameters = torch.Tensor():typeAs(x):resizeAs(dfdx)
      end
      state.decayParameters:copy(wds):cmul(x)
      dfdx:add(state.decayParameters)
   end

   -- (3) apply momentum
   if mom ~= 0 then
      if not state.dfdx then
         state.dfdx = {}
         for i = 1, #dfdx do
            state.dfdx[i] = torch.Tensor():typeAs(dfdx[i]):resizeAs(dfdx[i]):copy(dfdx[i])
         end
      else
         for i = 1, #dfdx do
            state.dfdx[i]:mul(mom):add(1-damp, dfdx[i])
         end
      end
      if nesterov then
         dfdx:add(mom, state.dfdx)
      else
         dfdx = state.dfdx
      end
   end

   -- (4) learning rate decay (annealing)
   local clr = lr / (1 + nevals*lrd)

   -- (5) parameter update with single or individual learning rates
   if lrs then
      if not state.deltaParameters then
         state.deltaParameters = {}
         for i = 1, #dfdx do
            state.deltaParameters[i] = torch.Tensor():typeAs(x[i]):resizeAs(dfdx[i])
         end
      end
      for i = 1, #dfdx do
         state.deltaParameters[i]:copy(lrs[i]):cmul(dfdx[i])
         x[i]:add(-clr[i], state.deltaParameters[i])
      end
   else
      for i = 1, #dfdx do
         x[i]:add(-clr, dfdx[i])
      end
   end

   -- (6) update evaluation counter
   state.evalCounter = state.evalCounter + 1

   -- return x*, f(x) before optimization
--   if not forward_only then
--      return x, {fx}
--   end


   return x, {fx}
end

-- Load in MNIST

print(c.blue '==>' ..' loading data')
local trainset, validset, testset = dl.loadCIFAR10()
local classes = testset.classes
local confusionMatrix = optim.ConfusionMatrix(classes)
print(c.blue '    completed!')


local predict, model, modelf, dfTrain, params, all_params, initParams, finalParams, params_l2, params_velocity
local params_proj, dHyperProj


local function cast(t)
   if opt.type == 'cuda' then
      require 'cunn'
      return t:cuda()
   elseif opt.type == 'float' then
      return t:float()
   elseif opt.type == 'cl' then
      require 'clnn'
      return t:cl()
   else
      error('Unknown type '..opt.type)
   end
end


-- create params that has a same size as elementary parameters
local function full_create(params)
   local full_params = {}
   for i = 1, #params do
      full_params[i] = params[i]:clone():fill(0)
   end
   return full_params
end

-- create params that has a same size as elementary weight parameters
-- i.e. ignore bias parameters
local function L2_norm_create(params, initHyper)
   local hyper_L2 = {}
   for i = 1, #params do
      -- dimension = 1 is bias, do not need L2_reg
      if (params[i]:nDimension() > 1) then
        hyper_L2[i] = params[i]:clone():fill(initHyper)
      end
   end
   return hyper_L2
end

local function L2_norm(params, params_l2)
--   local penalty = torch.sum(params[1]) * params_l2[1]
   local penalty = 0
   for i = 1, #params do
       --dimension = 1 is bias, do not need L2_reg
       if (params[i]:nDimension() > 1) then
         --print(i)
         penalty = penalty + torch.sum(torch.cmul(params[i], params_l2[i]))
       end
   end
    return penalty
end


local function init(iter)
   ----
   --- build VGG net.
   ----

   if iter == 1 then
      -- load model
      print(c.blue '==>' ..' configuring model')
      model = cast(dofile(root .. 'models/'..opt.model..'.lua'))
      -- cast a model using functionalize
      modelf, params = grad.functionalize(model)

      params_l2 = L2_norm_create(params, opt.initHyper)
      params_velocity = full_create(params)
      params_proj = full_create(params)

      local Lossf = grad.nn.CrossEntropyCriterion()

      -- define training function
      local function fTrain(params, x, y)
         --print(params.elementary)
         --print(params.l2)
         local prediction = modelf(params.elementary, x)
         --local penalty = L2_norm(params.elementary, params.l2)
         return Lossf(prediction, y), prediction
      end

      dfTrain = grad(fTrain)

      -- a simple unit test
      local X = cast(torch.Tensor(4, 3, 32, 32):fill(0.5))
      local Y = cast(torch.Tensor(1, 4):fill(0))

      all_params = {
         elementary = params,
         l2 = params_l2,
         velocity = params_velocity
      }

      local dparams, l, p = dfTrain(all_params, X, Y)

      if (l) then
        print(c.green '    Auto Diff works!')
      end

      print(c.blue '    completed!')
   end

   print(c.blue '==>' ..' initializing model')
   --print(params[1])
   utils.MSRinit(model)
   --print(params[1])

   print(c.blue '    completed!')

   -- copy initial weights for later computation
   initParams = utils.deepcopy(params)
end


local function gradProj(params, input, target, Proj, dV)
--   local grads, loss, prediction = dfTrain(params, input, target)
--   proj_1 = proj_1 + torch.cmul(grads.W[1] , DV_1)
--   proj_2 = proj_2 + torch.cmul(grads.W[2] , DV_2)
--   proj_3 = proj_3 + torch.cmul(grads.W[3] , DV_3)
--   local loss = torch.sum(proj_1) + torch.sum(proj_2) + torch.sum(proj_3)
--   return loss

end


local optimState = {
   learningRate = opt.learningRate,
   weightDecay = opt.weightDecay,
   momentum = opt.momentum,
   learningRateDecay = opt.learningRateDecay,
}

local function train_meta(iter)

    -----------------------------------
    -- [[Meta training]]
    -----------------------------------

    -- Train a neural network to get final parameters

    local iter_num = torch.floor(trainset:size() / opt.batchSize)

--    print(iter_num)
--
--    sys.sleep(100)

    local grads, loss, prediction


    for epoch = 1, opt.max_epoch do
      print(c.blue '==>' ..' Meta episode #' .. iter .. ', Training epoch #' .. epoch)
      for i = 1, iter_num do
         local inputs, targets = trainset:index(torch.LongTensor():range((i - 1) * opt.batchSize + 1, i * opt
         .batchSize))

         local X, Y = cast(inputs), cast(targets)
--
--         local grads, loss, prediction = dfTrain(all_params, X, Y)


         local feval = function(x)
            if x~=params then params:copy(x) end
            grads, loss, prediction = dfTrain(all_params, X, Y)
            confusionMatrix:batchAdd(prediction, Y)
            return loss, grads.elementary
         end

         -- use optim's implementation
         sgd_m(feval, params, optimState)


         -- update parameter
--         for j = 1, #grads.elementary do
--            -- add weight dacay, i.e. l2 norm
--            grads.elementary[j]:add(opt.weightDecay, params[j])
--            params_velocity[j] = params_velocity[j]:mul(opt.learningRateDecay) - grads.elementary[j]:mul(1 - opt.learningRateDecay)
--            params[j] = params[j] + opt.learningRate * params_velocity[j]
--         end
----

         -- Log performance:
--         confusionMatrix:batchAdd(prediction, Y)
         if i % 100 == 0 then
            print("Epoch "..epoch)
            print(confusionMatrix)
            if i % 1000 == 0 then
               confusionMatrix:zero()
            end
         end
         print(c.red 'loss: ', loss)
         --break
      end
   end

   -- copy final parameters after convergence
   finalParams = utils.deepcopy(params)
   finalParams = nn.utils.recursiveCopy(finalParams, params)

   -----------------------
   -- [[Reverse mode hyper-parameter training:
   -- to get gradient w.r.t. hyper-parameters]]
   -----------------------


    --- obtain on validation





--    for i = 1, iter_num do
--       local inputs, targets = trainset:index(torch.LongTensor():range((i - 1) * opt.batchSize + 1, i * opt.batchSize))
--
--       local X, Y = cast(inputs), cast(targets)
--
--
--       local feval = function(x)
--          if x~=params then params:copy(x) end
--          grads.elementary:zero()
--          grads, loss, prediction = dfTrain(all_params, X, Y)
--          confusionMatrix:batchAdd(prediction, Y)
--          return loss, grads.elementary
--       end
--       -- update parameter
--
--       sgd_m(feval, params, optimState)
--
--
----       for i = 1, #grads do
----          params_velocity[i] = params_velocity[i]:mul(opt.learningRateDecay) - grads[i]:mul(1 - opt.learningRateDecay)
----          params[i] = params[i] + opt.learningRate * params_velocity[i]
----       end
----
----       -- Log performance:
----       confusionMatrix:batchAdd(prediction, Y)
--       if i % 50 == 0 then
--          print("Epoch "..epoch)
--          print(confusionMatrix)
--          if i % 1000 == 0 then
--             confusionMatrix:zero()
--          end
--       end
----       print(c.red 'loss: ', loss)
--       --break
--    end
--
--    dHyperProj = grad(gradProj)



end

-----------------------------
-- entry point
-----------------------------

local time = sys.clock()


for i = 1, opt.numMeta do
    init(i)
    --    print("wtf", model)
    train_meta(i)
end

time = sys.clock() - time
print(time)