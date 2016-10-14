
require 'basic'
require 'EMaskedClassNLLCriterion'
require 'shortcut'
require 'DetailedMaskedNLLCriterion'

local model_utils = require 'model_utils'

local EncDecA = torch.class('EncDecA', 'BModel')

function EncDecA:__init(opts)
  self.opts = opts
  self.name = 'EncDecA'
  opts.nivocab, opts.novocab = opts.src_vocab.nvocab, opts.dst_vocab.nvocab
  self:createNetwork(opts)
  
  if opts.optimMethod == 'AdaGrad' then
    self.optimMethod = optim.adagrad
  elseif opts.optimMethod == 'Adam' then
    self.optimMethod = optim.adam
  elseif opts.optimMethod == 'AdaDelta' then
    self.optimMethod = optim.adadelta
  elseif opts.optimMethod == 'SGD' then
    self.optimMethod = optim.sgd
  end
end

function EncDecA:transData(d, cpu_type)
  if self.opts.useGPU then 
    return d:cuda() 
  else
    if cpu_type then
      return d:type(cpu_type)
    else
      return d
    end
  end
end

function EncDecA:createLSTM(x_t, c_tm1, h_tm1, nin, nhid)
  -- compute activations of four gates all together
  local x2h = nn.Linear(nin, nhid * 4)(x_t)
  local h2h = nn.Linear(nhid, nhid * 4)(h_tm1)
  local allGatesActs = nn.CAddTable()({x2h, h2h})
  local allGatesActsSplits = nn.SplitTable(2)( nn.Reshape(4, nhid)(allGatesActs) )
  -- unpack all gate activations
  local i_t = nn.Sigmoid()( nn.SelectTable(1)( allGatesActsSplits ) )
  local f_t = nn.Sigmoid()( nn.SelectTable(2)( allGatesActsSplits ) )
  local o_t = nn.Sigmoid()( nn.SelectTable(3)( allGatesActsSplits ) )
  local n_t = nn.Tanh()( nn.SelectTable(4)( allGatesActsSplits ) )
  -- compute new cell
  local c_t = nn.CAddTable()({
      nn.CMulTable()({ i_t, n_t }),
      nn.CMulTable()({ f_t, c_tm1 })
    })
  -- compute new hidden state
  local h_t = nn.CMulTable()({ o_t, nn.Tanh()( c_t ) })
  
  return c_t, h_t
end

function EncDecA:createEncoder(opts)
  local emb = nn.LookupTable(opts.nivocab, opts.nin)
  local x_t = nn.Identity()()
  local s_tm1 = nn.Identity()()
  
  local in_t = { [0] = emb(x_t):annotate{name='enc_lookup'} }
  local s_t = {}
  local splits_tm1 = {s_tm1:split(2 * opts.nlayers)}
  
  for i = 1, opts.nlayers do
    local c_tm1_i = splits_tm1[i + i - 1]
    local h_tm1_i = splits_tm1[i + i]
    local x_t_i = in_t[i - 1]
    local c_t_i, h_t_i = nil, nil
    
    if opts.dropout > 0 then
      printf( 'lstm encoder layer %d, dropout = %f\n', i, opts.dropout) 
      x_t_i = nn.Dropout(opts.dropout)(x_t_i)
    end
    
    if i == 1 then
      c_t_i, h_t_i = self:createLSTM(x_t_i, c_tm1_i, h_tm1_i, opts.nin, opts.nhid)
    else
      c_t_i, h_t_i = self:createLSTM(x_t_i, c_tm1_i, h_tm1_i, opts.nhid, opts.nhid)
    end
    s_t[i+i-1] = c_t_i
    s_t[i+i] = h_t_i
    in_t[i] = h_t_i
  end
  
  local model = nn.gModule({x_t, s_tm1}, {nn.Identity()(s_t)})
  return self:transData(model)
end

function EncDecA:createDecoder(opts)
  local emb = nn.LookupTable(opts.nivocab, opts.nin)
  local x_t = nn.Identity()()
  local s_tm1 = nn.Identity()()
  local cxt_t = nn.Identity()()
  -- join word embedings of x_t and context vector
  local x_cxt_t = nn.JoinTable(2){emb(x_t):annotate{name='dec_lookup'}, cxt_t}
  local in_t = {[0] = x_cxt_t}
  local s_t = {}
  local splits_tm1 = {s_tm1:split(2 * opts.nlayers)}
  
  for i = 1, opts.nlayers do
    local c_tm1_i = splits_tm1[i + i - 1]
    local h_tm1_i = splits_tm1[i + i]
    local x_t_i = in_t[i - 1]
    local c_t_i, h_t_i = nil, nil
    
    if opts.dropout > 0 then
      printf( 'lstm encoder layer %d, dropout = %f\n', i, opts.dropout) 
      x_t_i = nn.Dropout(opts.dropout)(x_t_i)
    end
    
    if i == 1 then
      c_t_i, h_t_i = self:createLSTM(x_t_i, c_tm1_i, h_tm1_i, opts.nin, opts.nhid)
    else
      c_t_i, h_t_i = self:createLSTM(x_t_i, c_tm1_i, h_tm1_i, opts.nhid, opts.nhid)
    end
    s_t[i+i-1] = c_t_i
    s_t[i+i] = h_t_i
    in_t[i] = h_t_i
  end
  local h_L = s_t[2*opts.nlayers]
  if opts.dropout > 0 then
    h_L = nn.Dropout(opts.dropout)(h_L)
    printf('apply dropout before output layer, drop = %f\n', opts.dropout)
  end
  local y_a = nn.Linear(opts.nhid, opts.novocab)(h_L)
  local y_prob = nn.LogSoftMax()(y_a)
  
  local model = nn.gModule({x_t, s_tm1}, {nn.Identity()(s_t), y_prob})
  return self:transData(model)
end

-- enc_hs (hidden states of encoder); size: bs x seqlen x nhid
-- dec_h (current hidden state of decoder); size: bs x nhid
function EncDecA:getEncVecByAtt(enc_hs, dec_h, mask, mask_sub, opts)
  --[[
  local enc_hs = nn.Identity()()  -- size: bs x seqlen x nhid
  local dec_h = nn.Identity()()   -- size: bs x nhid
  --]]
  -- general transformation / or just use simple dot: resulting size: bs x nhid x 1
  local dec_h_t
  if opts.attention == 'dot' then
    dec_h_t = nn.View(opts.nhid, 1)( dec_h )
    self:print('attention type is dot!')
  elseif opts.attention == 'general' then
    dec_h_t = nn.View(opts.nhid, 1)( nn.Linear(opts.nhid, opts.nhid)(dec_h) )
    self:print('attention type is general!')
  else
    error('attention should be "dot" or "general"')
  end
  --local dec_h_t = nn.View(opts.nhid, 1)( nn.Linear(opts.nhid, opts.nhid)(dec_h) )
  -- get attention: dot_encdec size: bs x seqlen x 1
  local dot_encdec = nn.MM()( {enc_hs, dec_h_t} )
  -- applying mask here
  local dot_encdec_tmp = nn.CAddTable()({ 
      nn.CMulTable()({ nn.Sum(3)(dot_encdec), 
          mask }),
      mask_sub
    })    -- size: bs x seqlen
  
  -- be careful x_mask is not handled currently!!!
  local attention = nn.SoftMax()( dot_encdec_tmp ):annotate{name='attention'}   -- size: bs x seqlen
  -- bs x seqlen x nhid MM bs x seqlen x 1
  local mout = nn.Sum(3)( nn.MM(true, false)( {enc_hs, nn.View(-1, 1):setNumInputDims(1)(attention)} ) )
  
  return mout
end

function EncDecA:createAttentionDecoder(opts)
  local emb = nn.LookupTable(opts.nivocab, opts.nin)
  local x_t = nn.Identity()()       -- previous word
  local s_tm1 = nn.Identity()()     -- previous hidden states
  local h_hat_tm1 = nn.Identity()() -- the previous hidden state used to predict y (input feed)
  local enc_hs = nn.Identity()()    -- all hidden states of encoder
  -- add mask
  local mask = nn.Identity()()
  local mask_sub = nn.Identity()()
  
  -- join word embedings of x_t and previous hidden (input feed)
  local x_cxt_t = nn.JoinTable(2){emb(x_t):annotate{name='dec_lookup'}, h_hat_tm1}
  local in_t = {[0] = x_cxt_t}
  local s_t = {}
  local splits_tm1 = {s_tm1:split(2 * opts.nlayers)}
  
  for i = 1, opts.nlayers do
    local c_tm1_i = splits_tm1[i + i - 1]
    local h_tm1_i = splits_tm1[i + i]
    local x_t_i = in_t[i - 1]
    local c_t_i, h_t_i = nil, nil
  
    if opts.dropout > 0 then
      printf( 'lstm decoder layer %d, dropout = %f\n', i, opts.dropout)
      x_t_i = nn.Dropout(opts.dropout)(x_t_i)
    end
    
    if i == 1 then
      c_t_i, h_t_i = self:createLSTM(x_t_i, c_tm1_i, h_tm1_i, opts.nin + opts.nhid, opts.nhid)
    else
      c_t_i, h_t_i = self:createLSTM(x_t_i, c_tm1_i, h_tm1_i, opts.nhid, opts.nhid)
    end
    s_t[i+i-1] = c_t_i
    s_t[i+i] = h_t_i
    in_t[i] = h_t_i
  end
  local h_L = s_t[2*opts.nlayers]
  -- now time for attention!
  local c_t = self:getEncVecByAtt(enc_hs, h_L, mask, mask_sub, opts)
  local h_hat_t_in = nn.JoinTable(2){h_L, c_t}
  local h_hat_t = nn.Tanh()( nn.Linear( 2*opts.nhid, opts.nhid )( h_hat_t_in ) )
  
  local h_hat_t_out = h_hat_t
  if opts.dropout > 0 then
    h_hat_t_out = nn.Dropout(opts.dropout)(h_hat_t_out)
    printf('apply dropout before output layer, drop = %f\n', opts.dropout)
  end
  
  local y_a = nn.Linear(opts.nhid, opts.novocab)(h_hat_t_out)
  local y_prob = nn.LogSoftMax()(y_a)
  
  local model = nn.gModule({x_t, s_tm1, h_hat_tm1, enc_hs, mask, mask_sub}, 
    {nn.Identity()(s_t), y_prob, h_hat_t})
  
  return self:transData(model)
end

function EncDecA:initModel(opts)
  self.enc_h0 = {}
  for i = 1, 2*opts.nlayers do
    self.enc_h0[i] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  end
  print(self.enc_h0)
  
  self.enc_hs = {}   -- including all h_t and c_t
  for j = 0, opts.seqLen do
    self.enc_hs[j] = {}
    for d = 1, 2 * opts.nlayers do
      self.enc_hs[j][d] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
    end
  end
  
  self.df_enc_hs = {}
  
  self.dec_hs = {}
  for j = 0, opts.seqLen do
    self.dec_hs[j] = {}
    for d = 1, 2*opts.nlayers do
      self.dec_hs[j][d] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
    end
  end
  
  self.dec_hs2 = {}
  for j = 0, opts.seqLen do
    self.dec_hs2[j] = {}
    for d = 1, 2*opts.nlayers do
      self.dec_hs2[j][d] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
    end
  end
  
  self.df_dec_hs = {}
  self.df_dec_h = {} -- remember always to reset it to zero!
  self.df_dec_h_cp = {}
  for i = 1, 2 * opts.nlayers do
    self.df_dec_h[i] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
    self.df_dec_h_cp[i] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  end
  print(self.df_dec_h)
  
  self.df_dec_hs2 = {}
  self.df_dec_h2 = {} -- remember always to reset it to zero!
  self.df_dec_h_cp2 = {}
  for i = 1, 2 * opts.nlayers do
    self.df_dec_h2[i] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
    self.df_dec_h_cp2[i] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  end
  print(self.df_dec_h2)
  
  -- for attention model
  self.all_enc_hs = self:transData( torch.zeros( self.opts.batchSize * self.opts.seqLen, self.opts.nhid ) )
  self.df_all_enc_hs = self:transData( torch.zeros( self.opts.batchSize, self.opts.seqLen, self.opts.nhid ) )
  
  -- h_hat_t
  self.dec_hs_hat = {}
  for j = 0, opts.seqLen do
    self.dec_hs_hat[j] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  end
  
  self.df_dec_h_hat = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  
  -- h_hat_t
  self.dec_hs_hat2 = {}
  for j = 0, opts.seqLen do
    self.dec_hs_hat2[j] = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  end
  
  self.df_dec_h_hat2 = self:transData( torch.zeros(opts.batchSize, opts.nhid) )
  
  -- for max margin model
  self.nlls1 = self:transData( torch.zeros(opts.seqLen, opts.batchSize) )
  self.nlls2 = self:transData( torch.zeros(opts.seqLen, opts.batchSize) )
end

function EncDecA:createNLL2Prob()
  local nll = nn.Identity()()
  local prob = nn.Exp()( nn.MulConstant(-1)(nll) )
  local m = nn.gModule({nll}, {prob})
  
  return self:transData(m)
end

function EncDecA:createNetwork()
  self.enc_lstm_master = self:createEncoder(self.opts)
  -- self.dec_lstm_master = self:createDecoder(self.opts)
  self.dec_lstm_master = self:createAttentionDecoder(self.opts)
  -- self.dec_lstm_master2 = self:createAttentionDecoder(self.opts)
  
  self.params, self.grads = model_utils.combine_all_parameters(self.enc_lstm_master, self.dec_lstm_master)
  self.params:uniform(-self.opts.initRange, self.opts.initRange)
  self:print( string.format( '#params %d', self.params:size(1) ) )
  self:print('clone encoder and decoder ...')
  self.enc_lstms = model_utils.clone_many_times(self.enc_lstm_master, self.opts.seqLen)
  self.dec_lstms = model_utils.clone_many_times(self.dec_lstm_master, self.opts.seqLen)
  self:print('clone encoder and decoder done!')
  self:print('clone decoder2 ...')
  self.dec_lstms2 = model_utils.clone_many_times(self.dec_lstm_master, self.opts.seqLen)
  self:print('clone decoder2 done!')
  
  self.criterions = {}
  for i = 1, self.opts.seqLen do
    self.criterions[i] = self:transData(EMaskedClassNLLCriterion())
  end
  
  self.detailed_crits1 = {}
  self.detailed_crits2 = {}
  for i = 1, self.opts.seqLen do
    self.detailed_crits1[i] = self:transData( DetailedMaskedNLLCriterion() )
    self.detailed_crits2[i] = self:transData( DetailedMaskedNLLCriterion() )
  end
  
  self.margin_crit = self:transData( nn.MarginRankingCriterion(self.opts.margin) )
  self.nll2prob1 = self:createNLL2Prob()
  self.nll2prob2 = self:createNLL2Prob()
  
  self:initModel(self.opts)
end

function EncDecA:trainBatch(x, x_mask, y, sgdParam)
  x = self:transData(x)
  if not self.opts.useGPU then
    x_mask = x_mask:type( torch.getdefaulttensortype() )
  end
  x_mask = self:transData(x_mask)
  y = self:transData(y)
  
  local xlen = x_mask:sum(1):view(-1)
  
  local x_mask_t = x_mask:t()
  local x_mask_sub = (-x_mask_t + 1) * -50
  x_mask_sub = self:transData( x_mask_sub )
  
  -- if y:eq(0):sum() > 0 then print(y) end
  -- set to training mode
  self.enc_lstm_master:training()
  self.dec_lstm_master:training()
  for i = 1, #self.enc_lstms do
    self.enc_lstms[i]:training()
  end
  for i = 1, #self.dec_lstms do
    self.dec_lstms[i]:training()
  end
  
  local function feval(params_)
    if self.params ~= params_ then
      self.params:copy(params_)
    end
    self.grads:zero()
    
    -- encoder forward pass
    for i = 1, 2 * self.opts.nlayers do
      self.enc_hs[0][i]:zero()
    end
    local Tx = x:size(1)
    -- used for copying all encoder states
    self.all_enc_hs:resize( self.opts.batchSize * Tx, self.opts.nhid )
    local raw_idxs = self:transData( torch.linspace(0, Tx*(self.opts.batchSize-1), self.opts.batchSize):long() )
    for t = 1, Tx do
      self.enc_hs[t] = self.enc_lstms[t]:forward({x[{ t, {} }], self.enc_hs[t-1]})
      -- copy all encoder states
      local idxs = raw_idxs + t
      self.all_enc_hs:indexCopy(1, idxs, self.enc_hs[t][2*self.opts.nlayers])
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    local all_enc_hs = self.all_enc_hs:view(self.opts.batchSize, Tx, self.opts.nhid)
    
    -- decoder forward pass
    for i = 1, 2 * self.opts.nlayers do
      for j = 1, self.opts.batchSize do
        self.dec_hs[0][i][{ j, {} }]:copy( self.enc_hs[ xlen[j] ][i][{ j, {} }] )
      end
    end
     
    local function wrap4lt(y)
      local y_ = y:clone()
      y_[y_:eq(0)] = 1
      return y_
    end
    
    local Ty = y:size(1) - 1
    local y_preds = {}
    local loss = 0
    for t = 1, Ty do
      -- self.dec_hs[t], y_preds[t] = unpack( self.dec_lstms[t]:forward({y[{ t, {} }], self.dec_hs[t-1]}) )
      -- local wy = wrap4lt( y[{ t, {} }] )
      local wy = self.opts.useGPU and y[{ t, {} }] or wrap4lt( y[{ t, {} }] )
      self.dec_hs[t], y_preds[t], self.dec_hs_hat[t] = unpack( 
        self.dec_lstms[t]:forward( { wy, self.dec_hs[t-1], self.dec_hs_hat[t-1], all_enc_hs, x_mask_t, x_mask_sub } ) 
        )
      local loss_ = self.criterions[t]:forward({y_preds[t], y[{t+1, {}}], self.opts.batchSize})
      loss = loss + loss_
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    -- decoder backward pass
    for i = 1, 2 * self.opts.nlayers do
      self.df_dec_h[i]:zero()
    end
    self.df_dec_h_hat:zero()
    -- initialize it at initModel
    self.df_all_enc_hs:resize( self.opts.batchSize, Tx, self.opts.nhid )
    self.df_all_enc_hs:zero()
    
    for t = Ty, 1, -1 do
      local df_crit = self.criterions[t]:backward({y_preds[t], y[{t+1, {}}], self.opts.batchSize})
      
      local wy = self.opts.useGPU and y[{ t, {} }] or wrap4lt( y[{ t, {} }] )
      local _, tmp_dec_h, tmp_dec_h_hat, tmp_all_enc_hs, _, _ = unpack( self.dec_lstms[t]:backward(
        { wy, self.dec_hs[t-1], self.dec_hs_hat[t-1], all_enc_hs, x_mask_t, x_mask_sub }, 
        { self.df_dec_h, df_crit, self.df_dec_h_hat })
      )
      -- local tmp = self.dec_lstms[t]:backward({y[{ t, {}}], self.dec_hs[t-1]}, {self.df_dec_h, df_crit})[2]
      model_utils.copy_table(self.df_dec_h, tmp_dec_h)
      self.df_dec_h_hat:copy(tmp_dec_h_hat)
      self.df_all_enc_hs:add(tmp_all_enc_hs)
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    -- encoder backward pass
    model_utils.copy_table(self.df_dec_h_cp, self.df_dec_h)
    local min_xlen = xlen:min()
    for t = Tx, 1, -1 do
      if t >= min_xlen then
        for i = 1, self.opts.batchSize do
          if x_mask[{ t, i }] == 0 then
            for d = 1, 2 * self.opts.nlayers do
              self.df_dec_h[d][{ i, {} }]:zero()
            end
            -- clear back prop error in padded place
            self.df_all_enc_hs[{ i, t, {} }]:zero()
          elseif t == xlen[i] then
            for d = 1, 2 * self.opts.nlayers do
              self.df_dec_h[d][{ i, {} }]:copy( self.df_dec_h_cp[d][{ i, {} }] )
            end
          end
        end
      end
      
      -- add errors to last layer of self.df_dec_h
      self.df_dec_h[2*self.opts.nlayers]:add( self.df_all_enc_hs[{ {}, t, {} }] )
      local tmp = self.enc_lstms[t]:backward({x[{ t, {} }], self.enc_hs[t-1]}, self.df_dec_h)[2]
      model_utils.copy_table(self.df_dec_h, tmp)
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    if self.opts.gradClip < 0 then
      local clip = -self.opts.gradClip
      self.grads:clamp(-clip, clip)
    elseif self.opts.gradClip > 0 then
      local maxGradNorm = self.opts.gradClip
      local gradNorm = self.grads:norm()
      if gradNorm > maxGradNorm then
        local shrinkFactor = maxGradNorm / gradNorm
        self.grads:mul(shrinkFactor)
      end
    end
    
    return loss, self.grads
  end
  
  local _, loss_ = self.optimMethod(feval, self.params, sgdParam)
  return loss_[1]
end

-- y1 here is the real y
-- y2 here is the sequence x
-- loss = max( 0, NLL(x, y1) - NLL(x, y2) + margin )
function EncDecA:trainBatchMaxMargin(x, x_mask, y1, y2, sgdParam)
  x = self:transData(x)
  if not self.opts.useGPU then
    x_mask = x_mask:type( torch.getdefaulttensortype() )
  end
  x_mask = self:transData(x_mask)
  y1 = self:transData(y1)
  y2 = self:transData(y2)
  
  local xlen = x_mask:sum(1):view(-1)
  
  local x_mask_t = x_mask:t()
  local x_mask_sub = (-x_mask_t + 1) * -50
  x_mask_sub = self:transData( x_mask_sub )
  
  -- if y:eq(0):sum() > 0 then print(y) end
  -- set to training mode
  self.enc_lstm_master:training()
  self.dec_lstm_master:training()
  for i = 1, #self.enc_lstms do
    self.enc_lstms[i]:training()
  end
  for i = 1, #self.dec_lstms do
    self.dec_lstms[i]:training()
  end
  
  local function feval(params_)
    if self.params ~= params_ then
      self.params:copy(params_)
    end
    self.grads:zero()
    
    -- encoder forward pass
    for i = 1, 2 * self.opts.nlayers do
      self.enc_hs[0][i]:zero()
    end
    local Tx = x:size(1)
    -- used for copying all encoder states
    self.all_enc_hs:resize( self.opts.batchSize * Tx, self.opts.nhid )
    local raw_idxs = self:transData( torch.linspace(0, Tx*(self.opts.batchSize-1), self.opts.batchSize):long() )
    for t = 1, Tx do
      self.enc_hs[t] = self.enc_lstms[t]:forward({x[{ t, {} }], self.enc_hs[t-1]})
      -- copy all encoder states
      local idxs = raw_idxs + t
      self.all_enc_hs:indexCopy(1, idxs, self.enc_hs[t][2*self.opts.nlayers])
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    local all_enc_hs = self.all_enc_hs:view(self.opts.batchSize, Tx, self.opts.nhid)
    
    local function wrap4lt(y)
      local y_ = y:clone()
      y_[y_:eq(0)] = 1
      return y_
    end
    
    -- decoder1 forward pass
    for i = 1, 2 * self.opts.nlayers do
      for j = 1, self.opts.batchSize do
        self.dec_hs[0][i][{ j, {} }]:copy( self.enc_hs[ xlen[j] ][i][{ j, {} }] )
      end
    end
    
    local Ty = y1:size(1) - 1
    local y_preds = {}
    self.nlls1:resize(Ty, self.opts.batchSize)
    for t = 1, Ty do
      -- self.dec_hs[t], y_preds[t] = unpack( self.dec_lstms[t]:forward({y[{ t, {} }], self.dec_hs[t-1]}) )
      local wy = self.opts.useGPU and y1[{ t, {} }] or wrap4lt( y1[{ t, {} }] )
      self.dec_hs[t], y_preds[t], self.dec_hs_hat[t] = unpack( 
        self.dec_lstms[t]:forward( { wy, self.dec_hs[t-1], self.dec_hs_hat[t-1], all_enc_hs, x_mask_t, x_mask_sub } ) 
        )
      local nll = self.detailed_crits1[t]:forward({y_preds[t], y1[{t+1, {}}]})
      self.nlls1[{ t, {} }] = nll
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    -- decoder2 forward pass
    for i = 1, 2 * self.opts.nlayers do
      for j = 1, self.opts.batchSize do
        self.dec_hs2[0][i][{ j, {} }]:copy( self.enc_hs[ xlen[j] ][i][{ j, {} }] )
      end
    end
    
    local Ty2 = y2:size(1) - 1
    local y_preds2 = {}
    self.nlls2:resize(Ty2, self.opts.batchSize)
    for t = 1, Ty2 do
      -- self.dec_hs[t], y_preds[t] = unpack( self.dec_lstms[t]:forward({y[{ t, {} }], self.dec_hs[t-1]}) )
      local wy = self.opts.useGPU and y2[{ t, {} }] or wrap4lt( y2[{ t, {} }] )
      self.dec_hs2[t], y_preds2[t], self.dec_hs_hat2[t] = unpack(
        self.dec_lstms2[t]:forward( { wy, self.dec_hs2[t-1], self.dec_hs_hat2[t-1], all_enc_hs, x_mask_t, x_mask_sub } ) 
        )
      local nll = self.detailed_crits2[t]:forward({y_preds2[t], y2[{t+1, {}}]})
      self.nlls2[{ t, {} }] = nll
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    -- get y1 mask and y2 mask
    local y1_mask = self:transData(y1:ne(0), torch.getdefaulttensortype())
    local y2_mask = self:transData(y2:ne(0), torch.getdefaulttensortype())
    -- one column: all zero not taken into account
    local nll1 = torch.cdiv( self.nlls1:sum(1):squeeze(), y1_mask:sum(1):squeeze() )
    local nll2 = torch.cdiv( self.nlls2:sum(1):squeeze(), y2_mask:sum(1):squeeze() )
    
    --[[
    print('nll1 = ')
    print(nll1)
    print('nll2 = ')
    print(nll2)
    --]]
    
    local prob1 = self.nll2prob1:forward(nll1)
    local prob2 = self.nll2prob2:forward(nll2)
    
    --[[
    print('prob1 = ')
    print(prob1)
    print('prob2 = ')
    print(prob2)
    --]]
    
    local y_rank = self:transData( torch.ones(nll1:size(1)) )
    local margin_loss = self.margin_crit:forward({prob1, prob2}, y_rank)
    
    local loss = {}
    loss[1] = margin_loss
    loss[2] = self.nlls1:sum() / self.opts.batchSize
    loss[3] = self.opts.marginWeight * loss[1] + (1 - self.opts.marginWeight) * (nll1:sum() / self.opts.batchSize)
    
    local dx_prob1, dx_prob2 = unpack( self.margin_crit:backward({prob1, prob2}, y_rank) )
    dx_prob1:mul( self.opts.batchSize )
    dx_prob2:mul( self.opts.batchSize )
    local dx_nll1 = self.nll2prob1:backward(nll1, dx_prob1)
    local dx_nll2 = self.nll2prob2:backward(nll2, dx_prob2)
    
    --[[
    print('dx_nll1', dx_nll1)
    print('dx_nll2', dx_nll2)
    --]]
    
    -- decoder1 backward pass
    for i = 1, 2 * self.opts.nlayers do
      self.df_dec_h[i]:zero()
    end
    self.df_dec_h_hat:zero()
    -- initialize it at initModel
    self.df_all_enc_hs:resize( self.opts.batchSize, Tx, self.opts.nhid )
    self.df_all_enc_hs:zero()
    
    for t = Ty, 1, -1 do
      local df_crit = self.criterions[t]:backward({y_preds[t], y1[{t+1, {}}], self.opts.batchSize})
      local sizem = dx_nll1:size(1)
      local sizen = df_crit:size(2)
      -- assign margin weight here
      dx_nll1:mul( self.opts.marginWeight ):add( 1 - self.opts.marginWeight )
      
      df_crit:cmul( dx_nll1:view( sizem, 1 ):expand( sizem, sizen ) )
      
      local wy = self.opts.useGPU and y1[{ t, {} }] or wrap4lt( y1[{ t, {} }] )
      local _, tmp_dec_h, tmp_dec_h_hat, tmp_all_enc_hs, _, _ = unpack( self.dec_lstms[t]:backward(
        { wy, self.dec_hs[t-1], self.dec_hs_hat[t-1], all_enc_hs, x_mask_t, x_mask_sub }, 
        { self.df_dec_h, df_crit, self.df_dec_h_hat })
      )
      
      model_utils.copy_table(self.df_dec_h, tmp_dec_h)
      self.df_dec_h_hat:copy(tmp_dec_h_hat)
      self.df_all_enc_hs:add(tmp_all_enc_hs)
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    -- decoder2 backward pass
    for i = 1, 2 * self.opts.nlayers do
      self.df_dec_h2[i]:zero()
    end
    self.df_dec_h_hat2:zero()
    -- initialize it at initModel
    -- self.df_all_enc_hs:resize( self.opts.batchSize, Tx, self.opts.nhid )
    -- self.df_all_enc_hs:zero()
    
    for t = Ty2, 1, -1 do
      local df_crit = self.criterions[t]:backward({y_preds2[t], y2[{t+1, {}}], self.opts.batchSize})
      local sizem = dx_nll2:size(1)
      local sizen = df_crit:size(2)
      -- assign margin weight here
      dx_nll2:mul(  self.opts.marginWeight )
      
      df_crit:cmul( dx_nll2:view( sizem, 1 ):expand( sizem, sizen ) )
      
      local wy = self.opts.useGPU and y2[{ t, {} }] or wrap4lt( y2[{ t, {} }] )
      local _, tmp_dec_h, tmp_dec_h_hat, tmp_all_enc_hs, _, _ = unpack( self.dec_lstms2[t]:backward(
        { wy, self.dec_hs2[t-1], self.dec_hs_hat2[t-1], all_enc_hs, x_mask_t, x_mask_sub }, 
        { self.df_dec_h2, df_crit, self.df_dec_h_hat2 })
      )
      -- local tmp = self.dec_lstms[t]:backward({y[{ t, {}}], self.dec_hs[t-1]}, {self.df_dec_h, df_crit})[2]
      model_utils.copy_table(self.df_dec_h2, tmp_dec_h)
      self.df_dec_h_hat2:copy(tmp_dec_h_hat)
      self.df_all_enc_hs:add(tmp_all_enc_hs)
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    -- encoder backward pass
    model_utils.copy_table(self.df_dec_h_cp, self.df_dec_h)
    -- don't forget decoder2
    model_utils.add_table(self.df_dec_h_cp, self.df_dec_h2)
    
    local min_xlen = xlen:min()
    for t = Tx, 1, -1 do
      if t >= min_xlen then
        for i = 1, self.opts.batchSize do
          if x_mask[{ t, i }] == 0 then
            for d = 1, 2 * self.opts.nlayers do
              self.df_dec_h[d][{ i, {} }]:zero()
            end
            -- clear back prop error in padded place
            self.df_all_enc_hs[{ i, t, {} }]:zero()
          elseif t == xlen[i] then
            for d = 1, 2 * self.opts.nlayers do
              self.df_dec_h[d][{ i, {} }]:copy( self.df_dec_h_cp[d][{ i, {} }] )
            end
          end
        end
      end
      
      -- add errors to last layer of self.df_dec_h
      self.df_dec_h[2*self.opts.nlayers]:add( self.df_all_enc_hs[{ {}, t, {} }] )
      local tmp = self.enc_lstms[t]:backward({x[{ t, {} }], self.enc_hs[t-1]}, self.df_dec_h)[2]
      model_utils.copy_table(self.df_dec_h, tmp)
      
      if self.opts.useGPU then cutorch.synchronize() end
    end
    
    if self.opts.gradClip < 0 then
      local clip = -self.opts.gradClip
      self.grads:clamp(-clip, clip)
    elseif self.opts.gradClip > 0 then
      local maxGradNorm = self.opts.gradClip
      local gradNorm = self.grads:norm()
      if gradNorm > maxGradNorm then
        local shrinkFactor = maxGradNorm / gradNorm
        self.grads:mul(shrinkFactor)
      end
    end
    
    return loss, self.grads
  end
  
  local _, loss_ = self.optimMethod(feval, self.params, sgdParam)
  
  return loss_[1]
end

function EncDecA:validBatch(x, x_mask, y)
  if not self.opts.useGPU then
    x_mask = x_mask:type( torch.getdefaulttensortype() )
  end
  x = self:transData(x)
  x_mask = self:transData(x_mask)
  y = self:transData(y)
  
  local xlen = x_mask:sum(1):view(-1)
  
  local x_mask_t = x_mask:t()
  local x_mask_sub = (-x_mask_t + 1) * -50
  x_mask_sub = self:transData( x_mask_sub )
  
  -- set to evaluation mode
  self.enc_lstm_master:evaluate()
  self.dec_lstm_master:evaluate()
  for i = 1, #self.enc_lstms do
    self.enc_lstms[i]:evaluate()
  end
  for i = 1, #self.dec_lstms do
    self.dec_lstms[i]:evaluate()
  end
  
  -- encoder forward pass
  for i = 1, 2 * self.opts.nlayers do
    self.enc_hs[0][i]:zero()
  end
  local Tx = x:size(1)
  -- used for copying all encoder states
  self.all_enc_hs:resize( self.opts.batchSize * Tx, self.opts.nhid )
  local raw_idxs = self:transData( torch.linspace(0, Tx*(self.opts.batchSize-1), self.opts.batchSize):long() )
  for t = 1, Tx do
    self.enc_hs[t] = self.enc_lstms[t]:forward({x[{ t, {} }], self.enc_hs[t-1]})
    -- copy all encoder states
    local idxs = raw_idxs + t
    self.all_enc_hs:indexCopy(1, idxs, self.enc_hs[t][2*self.opts.nlayers])
    
    if self.opts.useGPU then cutorch.synchronize() end
  end
  local all_enc_hs = self.all_enc_hs:view(self.opts.batchSize, Tx, self.opts.nhid)
  
  -- decoder forward pass
  for i = 1, 2 * self.opts.nlayers do
    for j = 1, self.opts.batchSize do
      self.dec_hs[0][i][{ j, {} }]:copy( self.enc_hs[ xlen[j] ][i][{ j, {} }] )
    end
  end
  
  local function wrap4lt(y)
    local y_ = y:clone()
    y_[y_:eq(0)] = 1
    return y_
  end
  
  local Ty = y:size(1) - 1
  local y_preds = {}
  local loss = 0
  for t = 1, Ty do
    local wy = self.opts.useGPU and y[{ t, {} }] or wrap4lt( y[{ t, {} }] )
    -- self.dec_hs[t], y_preds[t] = unpack( self.dec_lstms[t]:forward({y[{ t, {} }], self.dec_hs[t-1]}) )
    self.dec_hs[t], y_preds[t], self.dec_hs_hat[t] = unpack( 
      self.dec_lstms[t]:forward( { wy, self.dec_hs[t-1], self.dec_hs_hat[t-1], all_enc_hs, x_mask_t, x_mask_sub } ) 
      )
    local loss_ = self.criterions[t]:forward({y_preds[t], y[{t+1, {}}], self.opts.batchSize})
    loss = loss + loss_
    
    if self.opts.useGPU then cutorch.synchronize() end
  end
  
  return loss, y_preds
end

-- y1 here is the real y
-- y2 here is the sequence x
-- loss = max( 0, NLL(x, y1) - NLL(x, y2) + margin )
function EncDecA:validBatchMaxMargin(x, x_mask, y1, y2)
  x = self:transData(x)
  if not self.opts.useGPU then
    x_mask = x_mask:type( torch.getdefaulttensortype() )
  end
  x_mask = self:transData(x_mask)
  y1 = self:transData(y1)
  y2 = self:transData(y2)
  
  local xlen = x_mask:sum(1):view(-1)
  
  local x_mask_t = x_mask:t()
  local x_mask_sub = (-x_mask_t + 1) * -50
  x_mask_sub = self:transData( x_mask_sub )
  
  -- if y:eq(0):sum() > 0 then print(y) end
  -- set to evaluate mode
  self.enc_lstm_master:evaluate()
  self.dec_lstm_master:evaluate()
  for i = 1, #self.enc_lstms do
    self.enc_lstms[i]:evaluate()
  end
  for i = 1, #self.dec_lstms do
    self.dec_lstms[i]:evaluate()
  end
  
  
  -- encoder forward pass
  for i = 1, 2 * self.opts.nlayers do
    self.enc_hs[0][i]:zero()
  end
  local Tx = x:size(1)
  -- used for copying all encoder states
  self.all_enc_hs:resize( self.opts.batchSize * Tx, self.opts.nhid )
  local raw_idxs = self:transData( torch.linspace(0, Tx*(self.opts.batchSize-1), self.opts.batchSize):long() )
  for t = 1, Tx do
    self.enc_hs[t] = self.enc_lstms[t]:forward({x[{ t, {} }], self.enc_hs[t-1]})
    -- copy all encoder states
    local idxs = raw_idxs + t
    self.all_enc_hs:indexCopy(1, idxs, self.enc_hs[t][2*self.opts.nlayers])
    
    if self.opts.useGPU then cutorch.synchronize() end
  end
  local all_enc_hs = self.all_enc_hs:view(self.opts.batchSize, Tx, self.opts.nhid)
  
  local function wrap4lt(y)
    local y_ = y:clone()
    y_[y_:eq(0)] = 1
    return y_
  end
  
  -- decoder1 forward pass
  for i = 1, 2 * self.opts.nlayers do
    for j = 1, self.opts.batchSize do
      self.dec_hs[0][i][{ j, {} }]:copy( self.enc_hs[ xlen[j] ][i][{ j, {} }] )
    end
  end
  
  local Ty = y1:size(1) - 1
  local y_preds = {}
  self.nlls1:resize(Ty, self.opts.batchSize)
  for t = 1, Ty do
    -- self.dec_hs[t], y_preds[t] = unpack( self.dec_lstms[t]:forward({y[{ t, {} }], self.dec_hs[t-1]}) )
    local wy = self.opts.useGPU and y1[{ t, {} }] or wrap4lt( y1[{ t, {} }] )
    self.dec_hs[t], y_preds[t], self.dec_hs_hat[t] = unpack( 
      self.dec_lstms[t]:forward( { wy, self.dec_hs[t-1], self.dec_hs_hat[t-1], all_enc_hs, x_mask_t, x_mask_sub } ) 
      )
    local nll = self.detailed_crits1[t]:forward({y_preds[t], y1[{t+1, {}}]})
    self.nlls1[{ t, {} }] = nll
    
    if self.opts.useGPU then cutorch.synchronize() end
  end
  
  -- decoder2 forward pass
  for i = 1, 2 * self.opts.nlayers do
    for j = 1, self.opts.batchSize do
      self.dec_hs2[0][i][{ j, {} }]:copy( self.enc_hs[ xlen[j] ][i][{ j, {} }] )
    end
  end
  
  local Ty2 = y2:size(1) - 1
  local y_preds2 = {}
  self.nlls2:resize(Ty2, self.opts.batchSize)
  for t = 1, Ty2 do
    -- self.dec_hs[t], y_preds[t] = unpack( self.dec_lstms[t]:forward({y[{ t, {} }], self.dec_hs[t-1]}) )
    local wy = self.opts.useGPU and y2[{ t, {} }] or wrap4lt( y2[{ t, {} }] )
    self.dec_hs2[t], y_preds2[t], self.dec_hs_hat2[t] = unpack(
      self.dec_lstms2[t]:forward( { wy, self.dec_hs2[t-1], self.dec_hs_hat2[t-1], all_enc_hs, x_mask_t, x_mask_sub } ) 
      )
    local nll = self.detailed_crits2[t]:forward({y_preds2[t], y2[{t+1, {}}]})
    self.nlls2[{ t, {} }] = nll
    
    if self.opts.useGPU then cutorch.synchronize() end
  end
  
  -- get y1 mask and y2 mask
  local y1_mask = self:transData(y1:ne(0), torch.getdefaulttensortype())
  local y2_mask = self:transData(y2:ne(0), torch.getdefaulttensortype())
  -- one column: all zero not taken into account
  -- now taken into account
  require 'mathshortcut'
  local nll1 = safe_cdiv( self.nlls1:sum(1):squeeze(), y1_mask:sum(1):squeeze() )
  local nll2 = safe_cdiv( self.nlls2:sum(1):squeeze(), y2_mask:sum(1):squeeze() )
  
  local prob1 = self.nll2prob1:forward(nll1)
  local prob2 = self.nll2prob2:forward(nll2)
  
  local y_rank = self:transData( torch.ones(nll1:size(1)) )
  local margin_loss = self.margin_crit:forward({prob1, prob2}, y_rank)
  
  local loss = {}
  loss[1] = margin_loss
  loss[2] = self.nlls1:sum() / self.opts.batchSize
  loss[3] = self.opts.marginWeight * loss[1] + (1 - self.opts.marginWeight) * (nll1:sum() / self.opts.batchSize)
  
  return loss, y_preds
end




