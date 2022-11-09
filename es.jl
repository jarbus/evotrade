module DistributedES

export fitness, VirtualBatchNorm, make_model, compute_centered_ranks,
  NoiseTable, compute_grad, refresh_noise!, get_noise

using Flux
using Functors
using StableRNGs
using Statistics
using Logging
# using ProfileView
rng = StableRNG(123)

function compute_ranks(x)
  @assert ndims(x) == 1
  ranks = zeros(Int, size(x))
  ranks[sortperm(x)] = 1:length(x)
  ranks
end
function compute_centered_ranks(x)
  ranks = (compute_ranks(x) .- 1) / length(x)
  ranks = ranks .- 0.5
  ranks
end

mutable struct NoiseTable
  rng::StableRNGs.LehmerRNG
  noise::Vector{Float32}
  nparams::Int
  pop_size::Int
  σ::Float32
end

NoiseTable(rng::StableRNGs.LehmerRNG, nparams::Int, pop_size::Int, σ::Float32) = NoiseTable(rng, σ * randn(rng, Float32, nparams + pop_size), nparams, pop_size, σ)
get_noise(nt::NoiseTable, idx::Int) = nt.noise[idx:idx+nt.nparams-1]
function refresh_noise!(nt)
  nt.noise = randn(rng, Float32, nt.nparams + nt.pop_size) * nt.σ
end

function compute_grad(nt::NoiseTable, centered_ranks::Vector{Float32})
  @assert nt.pop_size == length(centered_ranks)
  grad = zeros(Float32, nt.nparams)
  for i in 1:nt.pop_size
    grad += get_noise(nt, i) * centered_ranks[i]
  end
  grad
end

function test_nt()
  rng = StableRNG(123)
  nt = NoiseTable(rng, 2, 4, 0.1f0)
  println(get_noise(nt, 1))
  println(get_noise(nt, 2))
  refresh_noise!(nt)
  println(get_noise(nt, 1))
  println(get_noise(nt, 2))
end


mutable struct VirtualBatchNorm1
  ref::Union{Array{Float32},Nothing}
  γ::Array{Float32}
  β::Array{Float32}
  μ::Array{Float32}
  σ²::Array{Float32}
end
function VirtualBatchNorm1()
  VirtualBatchNorm1(nothing,
    randn(rng, Float32, 1),
    randn(rng, Float32, 1),
    zeros(Float32, 1),
    zeros(Float32, 1))
end

VirtualBatchNorm = VirtualBatchNorm1
@functor VirtualBatchNorm


trainable(bn::VirtualBatchNorm) = (β=bn.β, γ=bn.γ)

# make this dynamically handle 4d input
function (layer::VirtualBatchNorm)(x)
  if isnothing(layer.ref)
    batch_start = 1
    layer.ref = x
    b = copy(layer.ref)
  else
    batch_start = size(layer.ref)[end] + 1
    b = cat(layer.ref, x, dims=ndims(x))
  end
  b̄ = (b .- mean(b)) ./ (std(b) + 0.00001f0)
  if !isapprox(std(b̄), 1, atol=0.1) || !isapprox(mean(b̄), 0, atol=0.1)
    @error " " min(x...) max(x...) mean(x) batch_start
    throw("std(b̄)=$(std(b̄)) mean(b̄)=$(mean(b̄))")
  end
  vb = b̄ .* layer.γ .+ layer.β
  @assert ndims(vb) ∈ [4, 2]
  if ndims(vb) == 4
    ret = vb[:, :, :, batch_start:end]
  else
    ret = vb[:, batch_start:end]
  end
  @assert size(ret) == size(x)
  ret
end

function test_vbn3d()
  vbn = VirtualBatchNorm()
  vbn.γ = [1.0f0]
  vbn.β = [0.0f0]

  # test one layer
  m = Chain(vbn)
  x = randn(rng, 7, 7, 3, 10)
  z = m(x)
  @assert size(x) == size(z)
  x = ones(7, 7, 3, 10)
  z = m(x)
  @assert !isapprox(std(z), 1, atol=0.1)
  @assert !isapprox(mean(z), 0, atol=0.1)
  @assert size(z) == size(x)


  # test stacked layers 
  m = Chain(
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm())
  x = randn(rng, 7, 7, 32, 10)
  z = m(x)
  @assert size(x) == size(z)
  for _ in 1:20
    x = randn(rng, 7, 7, 32, 10)
    z = m(x)
    @assert !isapprox(std(z), 1, atol=0.1)
    @assert !isapprox(mean(z), 0, atol=0.1)
    @assert size(z) == size(x)
  end
end

function gen_temporal_data()
  frame_size = (7, 7, 3, 1)
  num_points = 50
  seq_len = 3
  pos = zeros(Float32, frame_size...)
  pos[:, :, :, :] .= rand()
  neg = zeros(Float32, frame_size...)
  neg[:, :, :, :] .= -rand()
  labels = []
  seq::Vector{Array{Float32,4}} = []
  first_frames = []
  for _ in 1:num_points
    if rand() > 0.5
      push!(first_frames, copy(pos))
      push!(labels, Vector{Float32}([0, 1]))
    else
      push!(first_frames, copy(neg))
      push!(labels, Vector{Float32}([1, 0]))
    end
  end
  push!(seq, cat(first_frames..., dims=4))
  for _ in 1:(seq_len-1)
    push!(seq, zeros(Float32, size(seq[1])))
  end
  seq, hcat(labels...)
end


# function fitness(j)
#   global N, mut, θ
#   model = re(θ .+ (mut * N[j, :]))
#   x, y_gold = gen_temporal_data()
#   Flux.reset!(model)
#   [model(xi) for xi in x[1:end-1]]
#   y_pred = model(x[end])

#   @assert min(y_pred...) >= 0
#   @assert max(y_pred...) <= 1
#   @assert min(y_gold...) >= 0
#   @assert max(y_gold...) <= 1
#   @assert size(y_pred) == size(y_gold)

#   fit = -Flux.Losses.binarycrossentropy(y_pred, y_gold)

#   print && println(" $(round(fit,digits=2))")
#   fit
# end

function fitness(model; print=false)::Float32
  # y_pred should be vector of probabilities
  x, y_gold = gen_temporal_data()
  Flux.reset!(model)
  [model(xi) for xi in x[1:end-1]]
  y_pred = model(x[end])

  @assert min(y_pred...) >= 0
  @assert max(y_pred...) <= 1
  @assert min(y_gold...) >= 0
  @assert max(y_gold...) <= 1
  @assert size(y_pred) == size(y_gold)

  fit = -Flux.Losses.binarycrossentropy(y_pred, y_gold)

  print && println(" $(round(fit,digits=2))")
  fit
end



function make_lstm()
  Chain(
    Conv((3, 3), 3 => 3, pad=(1, 1), sigmoid, bias=randn(Float32, 3)),
    VirtualBatchNorm(),
    Flux.flatten,
    # Dense(147 => 16, relu),
    # make sure to call reset! when batch size changes
    LSTM(147 => 16),
    relu,
    Dense(16 => 2),
    softmax
  )
end


function make_model(s::Symbol, input_size::NTuple{4,Int}, output_size::Integer)
  if s == :small
    return make_small_model(input_size, output_size)
  elseif s == :medium
    return make_medium_model(input_size, output_size)
  elseif s == :large
    return make_large_model(input_size, output_size)
  end
end

function make_small_model(input_size::NTuple{4,Int}, output_size::Integer)
  Chain(
    Conv((3, 3), input_size[3] => 32, pad=(1, 1), relu, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 16, pad=(1, 1), relu, bias=randn(Float32, 16)),
    VirtualBatchNorm(),
    Flux.flatten,
    # Dense(147 => 16, relu),
    # make sure to call reset! when batch size changes
    LSTM(784 => 256),
    relu,
    Dense(256 => output_size),
    softmax
  )
end

function make_medium_model(input_size::NTuple{4,Int}, output_size::Integer)
  Chain(
    Conv((3, 3), input_size[3] => 3, pad=(1, 1), sigmoid, bias=randn(Float32, 3)),
    VirtualBatchNorm(),
    Flux.flatten,
    # Dense(147 => 16, relu),
    # make sure to call reset! when batch size changes
    LSTM(147 => 16),
    relu,
    Dense(16 => output_size),
    softmax
  )
end

function make_large_model(input_size::NTuple{4,Int}, output_size::Integer)
  Chain(
    Conv((3, 3), input_size[3] => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Flux.flatten,
    # Dense(147 => 16, relu),
    # make sure to call reset! when batch size changes
    LSTM(1568 => 256),
    relu,
    Dense(256 => 128),
    relu,
    Dense(128 => output_size),
    softmax
  )
end

function test_lstm()
  m = make_lstm()
  # x, y = gen_temporal_data()
  # [m(xi) for xi in x[1:end-1]]
  # z = m(x[end])
  fitness(m)
end


end
