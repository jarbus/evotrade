using Distributed

function get_procs(str)
    full_cpus_per_node = Vector{Int}()
    for c in str
        m = match(r"(\d+)\(x(\d+)\)",c)
        if !isnothing(m)
            for i in 1:parse(Int, m[2])
                push!(full_cpus_per_node, parse(Int, m[1]))
            end
        else
            push!(full_cpus_per_node, parse(Int, c))
        end
    end
    full_cpus_per_node
end



cpus_per_node = get_procs(split( ENV["SLURM_JOB_CPUS_PER_NODE"],","))
nodelist = ENV["SLURM_JOB_NODELIST"]
hostnames = read(`scontrol show hostnames "$nodelist"`, String) |> strip |> split .|> String
@assert length(cpus_per_node) == length(hostnames)

machine_specs = [hostspec for hostspec in zip(hostnames, cpus_per_node)]
println(machine_specs)
#TODO FIX SSH NOT FINDING HOT NAMES
addprocs(machine_specs, max_parallel=100, multiplex=true)
println("nprocs $(nprocs())")

@everywhere begin
  include("args.jl")
  include("es.jl")
  include("trade.jl")
end
@everywhere begin
  args=$args
  using .DistributedES
  using .Trade
  using Flux
  using Statistics
  using StableRNGs

  # Load args

  env_config = Dict(
    "window" => args["window"],
    "grid" => (args["gx"], args["gy"]),
    "food_types" => 2,
    "latest_agent_ids" => [0, 0],
    "matchups" => [("f0a0", "f1a0")],
    "episode_length" => args["episode-length"],
    "respawn" => true,
    "fires" => [Tuple(args["fires"][i:i+1]) for i in 1:2:length(args["fires"])],
    "foods" => [Tuple(args["foods"][i:i+2]) for i in 1:3:length(args["foods"])],
    "health_baseline" => true,
    "spawn_agents" => "center",
    "spawn_food" => "corner",
    "light_coeff" => 10,
    "food_agent_start" => 1.0,
    "food_env_spawn" => 1.0,
    "day_night_cycle" => true,
    "day_steps" => args["day-steps"],
    "vocab_size" => 0)

  function run_batch(batch_size::Int, models::Dict{String,<:Chain})
    benv = [Trade.PyTrade.Trade(env_config) for _ in 1:batch_size]
    obs_size = (benv[1].obs_size..., batch_size)
    num_actions = benv[1].num_actions
    b_obs = batch_reset!(benv, models)
    max_steps = args["episode-length"] * args["num-agents"]
    rews = Dict(key => 0.0f0 for key in keys(models))
    for _ in 1:max_steps
      b_obs, b_rew, b_dones = batch_step!(benv, models, b_obs)
      for rew_dict in b_rew
        for (name, rew) in rew_dict
          rews[name] += rew
        end
      end
    end
    Dict(name => rew / (args["episode-length"] * batch_size) for (name, rew) in rews)
  end

end

function compute_matrix_fitness(A::Matrix{Tuple{Float32,Float32}}, i::Integer)
  row_fit = sum([e[1] for e in A[i, :]])
  col_fit = sum([e[2] for e in A[:, i]])
  row_fit + col_fit / (size(A, 1)^2)
end

function main()

  println("--------------------------------------")
  @everywhere begin
    pop_size = args["pop-size"]
    mut = args["mutation-rate"]
    α = args["alpha"]
    rng = StableRNG(0)
    println("Making Env")
    env = Trade.PyTrade.Trade(env_config)
    batch_size = 5
    println("Making Model")
    base_model = make_model(:small, (env.obs_size..., batch_size), env.num_actions)
    θ, re = Flux.destructure(base_model)
    model_size = size(θ)[1]
    println("Done")
  end

  print("Generation 0: ")

  for i in 1:60

    @everywhere N = randn(rng, Float32, pop_size, model_size)
    futures = []

    for p1 in 1:pop_size
      for p2 in 1:pop_size

        fut = remotecall(procs()[(p2%nprocs())+1]) do
          θ_n1 = θ .+ (mut * N[p1, :])
          θ_n2 = θ .+ (mut * N[p2, :])

          rew_dict = run_batch(batch_size, Dict("f0a0" => re(θ_n1),
            "f1a0" => re(θ_n2)))
          rew_dict["f0a0"], rew_dict["f1a0"]
        end
        push!(futures, fut)
      end
    end

    fits = [fetch(future) for future in futures]
    fits = reshape(fits, (pop_size, pop_size))
    fits = [compute_matrix_fitness(fits, i) for i in 1:pop_size]
    A = (fits .- mean(fits)) ./ (std(fits) + 0.0001f0)
    @everywhere θ = θ .+ ((α / (pop_size * mut)) * (N' * $A))

    if i % 1 == 0
      print("Generation $i: ")
      println(round(mean(fits), digits=2))
    end
  end
end

main()