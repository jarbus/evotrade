module Net

using Flux
using Statistics
using Functors
using FileIO

export VirtualBatchNorm, make_model

mutable struct VirtualBatchNorm
  ref::Union{Array{Float32},Nothing}
  γ::Union{Array{Float32},Nothing}
  β::Union{Array{Float32},Nothing}
  μ::Union{Array{Float32},Nothing}
  σ::Union{Array{Float32},Nothing}
end
function VirtualBatchNorm()
  VirtualBatchNorm(nothing,
    nothing,
    nothing,
    nothing,
    nothing)
end

@functor VirtualBatchNorm

Flux.trainable(bn::VirtualBatchNorm) = (β=bn.β, γ=bn.γ)

# make this dynamically handle 4d input
function (layer::VirtualBatchNorm)(x)
  if isnothing(layer.ref)
    @assert isnothing(layer.μ)
    @assert isnothing(layer.σ)
    @assert !any(isnan.(x))
    layer.ref = x
    layer.μ = mean(Float32, layer.ref, dims=ndims(layer.ref))
    layer.σ = std(layer.ref, dims=ndims(layer.ref))
    @assert !any(isnan.(layer.σ))
    @assert size(layer.μ) == (size(x)[1:end-1]..., 1)
    @assert size(layer.σ) == (size(x)[1:end-1]..., 1)
  end
  if isnothing(layer.γ)
    layer.γ = Flux.glorot_normal(size(x)[1:end-1]...)
    layer.β = Flux.glorot_normal(size(x)[1:end-1]...)
  end
  x̄ = (x .- layer.μ) ./ (layer.σ .+ 0.0001f0)
  vb = x̄ .* layer.γ .+ layer.β
  @assert ndims(vb) ∈ [4, 2]
  @assert size(vb) == size(x)
  vb
end

function test_vbn3d()
  vbn = VirtualBatchNorm()
  # test one layer
  m = Chain(vbn)
  x = randn(Float32, 7, 7, 3, 10)
  z = m(x)
  @assert size(x) == size(z)
  x = ones(Float32, 7, 7, 3, 10)
  z = m(x)
  @assert size(z) == size(x)

  @assert length(Flux.trainable(vbn)) == 2
  @assert size(Flux.params(vbn)[1]) == size(x)[1:end-1]
  @assert size(Flux.params(vbn)[2]) == size(x)[1:end-1]

  # test stacked layers 
  m = Chain(
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm(),
    Conv((3, 3), 32 => 32, pad=(1, 1), sigmoid, bias=randn(Float32, 32)),
    VirtualBatchNorm())
  x = randn(Float32, 7, 7, 32, 10)
  z = m(x)
  @assert size(x) == size(z)
  for _ in 1:20
    x = randn(Float32, 7, 7, 32, 10)
    z = m(x)
    @assert size(z) == size(x)
    @assert !any(isnan.(z))
  end
  save("/tmp/vbn.jld2", Dict("m" => m))
  m = load("/tmp/vbn.jld2")["m"]
  @assert Flux.destructure(m)[1] .|> isnan |> any |> !
  θ, re = Flux.destructure(m)
  m = re(θ)
  @assert Flux.destructure(m)[1] .|> isnan |> any |> !

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

function make_model(s::Symbol, input_size::NTuple{4,Int}, output_size::Integer)
  if s == :small
    println("Making small model")
    return make_small_model(input_size, output_size)
  elseif s == :medium
    println("Making medium model")
    return make_medium_model(input_size, output_size)
  elseif s == :large
    println("Making large model")
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

function test_lstm()
  m = make_model(:large)
  # x, y = gen_temporal_data()
  # [m(xi) for xi in x[1:end-1]]
  # z = m(x[end])
  fitness(m)
end

end