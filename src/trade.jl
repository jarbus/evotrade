module Trade

export batch_reset!, batch_step!, PyTrade, render, get_metrics

using PyCall
using Pathnames
using StatsBase
using Flux

#By default, PyCall doesn't include the current directory in the Python
#search path. If you want to do that (in order to load a Python module
#from the current directory), just run pushfirst!(pyimport("sys")."path",
#"").

function PyTrade()
  pushfirst!(pyimport("sys")."path", String(dirname(@__FILE__)))
  pyimport("trade_v4")
end

step_return_type = Tuple{PyDict{String,PyArray},  # obs
  Dict{String,Float32},   # rewards
  Dict{String,Bool}}      # Dones

function ecat(x...)
  @assert all(ndims(xi) == ndims(x[1]) for xi in x)
  cat(x..., dims=ndims(x[1]))
end

function reset!(env::PyObject)
  pycall(env.reset, PyDict{String,PyArray})
end

function render(env::PyObject, filename::String)
  pycall(env.render, Nothing, filename)
end

function get_metrics(env::PyObject)
  pycall(env.mc.return_metrics, PyDict{String,Float32}, env)
end

function get_metrics(envs::Vector{PyObject})
    @assert length(envs) >= 1
    mets_vec = [get_metrics(env) for env in envs]
    mets = Dict()
    for key in keys(mets_vec[1])
        vals = [met[key] for met in mets_vec]
        push!(mets, key*"_min"=> min(vals...))
        push!(mets, key*"_mean"=> mean(vals))
        push!(mets, key*"_max"=> max(vals...))
    end
    mets
end
function step!(env::PyObject, actions::Dict{String,Int})::step_return_type
  pycall(env.step, step_return_type, actions)
end
function sample_batch(probs::Matrix{Float32})
  [sample(1:size(probs, 1), Weights(probs[:, i])) for i in 1:size(probs, 2)]
end

# TODO test that this works
# TODO figure out how/when to change agents
function reset!(env::PyObject, models::Dict{String,<:Chain})
  map(Flux.reset!, values(models))
  reset!(env)
end

function batch_dict(d::Vector{<:AbstractDict})
  Dict([key => ecat([di[key] for di in d]...) for key in keys(d[1])]...)
end

function batch_reset!(envs::Vector{PyObject}, models::Dict{String,<:Chain})
  obss = [reset!(env, models) for env in envs]
  @assert all(keys(obssi) == keys(obss[1]) for obssi in obss)
  batch_dict(obss)
end

# TODO test batch size 1 on virtual batch normalization

function batch_step!(envs::Vector{PyObject}, models::Dict{String,<:Chain}, obs::Dict{String,<:AbstractArray}; evaluation=false)
  @assert length(obs) == 1
  name, ob = first(obs)
  probs = models[name](ob) # bottleneck
  @assert !any(isnan.(probs))
  if evaluation
    # matrix of floats to matrix of cartesian indicies
    # to vector of cartesian indicies to vector of ints
    acts = argmax(probs, dims=1)[1, :] .|> z -> z[1]
  else
    acts = sample_batch(probs)
  end
  acts .-= 1 # convert to python
  @assert length(acts) == length(envs)
  obss, rews, dones = Vector{PyDict{String,PyArray,true}}(), [], []
  for (env, act) in zip(envs, acts)
    obs, rew, done = step!(env, Dict(name => act)) # biggest bottleneck
    push!(obss, PyDict(obs))
    push!(rews, rew)
    push!(dones, done)
  end
  batch_dict(obss), rews, dones, acts .+ 1
end

 

end
