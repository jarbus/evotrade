module GANS
using StableRNGs
using Flux
using Statistics
using Distributed
using Infiltrator
using NearestNeighbors
export compute_novelty, compute_novelties,
bc1, create_next_pop, add_to_archive!,
reorder!, average_bc, compute_elite

function compute_novelty(ind_bc::Vector, archive_and_pop::Matrix; k::Int=25)::Float64 
    # for mazes
    @assert k < size(archive_and_pop, 2)
    @assert size(ind_bc,1) == size(archive_and_pop, 1)
    # Assumptions: Novelty against self is zero, ind_bc is in archive_and_pop
    kdtree = KDTree(archive_and_pop, leafsize=100000)
    inds, dists = knn(kdtree, ind_bc, k+1)
    # @assert length(dists) == length(archive_and_pop) - k
    return sum(dists) / k
end


function compute_novelties(ind_bc::Matrix, archive_and_pop::Matrix; k::Int=25) 
    # for mazes
    @assert k < size(archive_and_pop, 2)
    @assert size(ind_bc, 2) <= size(archive_and_pop, 2)
    @assert size(ind_bc, 1) == size(archive_and_pop, 1)
    @assert size(ind_bc, 1) == size(archive_and_pop, 1)
    # Assumptions: Novelty against self is zero, ind_bc is in archive_and_pop
    kdtree = KDTree(archive_and_pop, leafsize=100000)
    inds, dists = knn(kdtree, ind_bc, k+1)
    # @assert length(dists) == length(archive_and_pop) - k
    return [sum(d) / k for d in dists]
end



function reorder!(to_sort, vecs...)
   """sorts all vecs according to the order
   specified by to_sort"""


   order = sortperm(to_sort, rev=true)
   length(order) > 2 && @assert to_sort[order[2]] >= to_sort[order[3]]
   # reorder lists in-place
   for vec in vecs
       @assert length(vec) == length(order)
       vec[:] = vec[order]
   end
   to_sort[:] = to_sort[order]
end

function add_to_archive!(archive, BC, pop, prob)
  for i in 1:length(pop)
      if i > 1 && rand() <= prob
          push!(archive, (BC[i], pop[i]))
      end
  end
end

function create_next_pop(gen::Int, pop::Vector{Vector{UInt32}}, num_elites::Int)
    pop_size = length(pop)
    @assert pop_size > 0
    @assert num_elites != pop_size

    next_pop = [copy(pop[1])] # copy elites
    for i in 2:pop_size
        parent_idx = (rand(UInt) % num_elites) + 1 # select parent
        push!(next_pop, copy(pop[parent_idx])) # copy parent to next pop
        push!(next_pop[i], rand(UInt32)) # mutate parent into child
    end
    @assert length(next_pop) == pop_size
    next_pop 
end

function create_next_pop(gen::Int,
        pop::Vector{Vector{UInt32}},
        fitnesses::Vector{Float32},
        novelties::Vector{Float64},
        γ::Float64,
        num_elites::Int)
    pop_size = length(pop)
    @assert length(pop) == length(fitnesses) == length(novelties)
    @assert num_elites < pop_size
    @assert pop_size > 0
    num_elite_explorers = Int(round(γ * num_elites))
    num_elite_exploiters = num_elites - num_elite_explorers
    num_next_explorers = round(Int, pop_size * γ)
    num_next_exploiters  = pop_size - num_next_explorers
    exploiter_elites = pop[sortperm(fitnesses, rev=true)][1:num_elite_exploiters]
    explorer_elites  = pop[sortperm(novelties, rev=true)][1:num_elite_explorers]

    next_pop = Vector{Vector{UInt32}}() # copy elites
    num_next_exploiters > 0 && for i in 1:num_next_exploiters
        push!(next_pop, copy(rand(exploiter_elites))) # copy parent to next pop
        push!(next_pop[end], rand(UInt32)) # mutate parent into child
    end
    num_next_explorers > 0 && for j in 1:num_next_explorers
        push!(next_pop, copy(rand(explorer_elites))) # copy parent to next pop
        push!(next_pop[end], rand(UInt32)) # mutate parent into child
    end
    @assert length(next_pop) == pop_size
    next_pop, vcat(exploiter_elites, explorer_elites)
end

function bc1(x::Vector{<:Integer}, num_actions=9)::Vector{Float64}
    # count number of each element in x
    counts = zeros(Int, num_actions)
    for i in x
        counts[i] += 1
    end
    counts ./ length(x)
end

function average_bc(bcs::Vector)
  @assert Set(length.(bcs)) |> length == 1
  [mean(x) for x in zip(bcs...)]
end

function compute_elite(f, pop, F; k::Int=10, n::Int=30)
  # run n evals in parallel on top k members to compute elite
  top_F_idxs = sortperm(F, rev=true)[1:min(k, length(pop))]
  @assert F[top_F_idxs[1]] >= maximum(F)
  rollout_Fs = pmap(1:k*n) do rollout_idx
      # get member ∈ [1,10] from rollout count
      p = floor(Int, (rollout_idx-1) / n) + 1
      @assert p in 1:k
      fit = f(pop[top_F_idxs[p]], pop[top_F_idxs[p]])
      (fit[1] + fit[2])/2
  end
  @assert rollout_Fs isa Vector{<:AbstractFloat}
  accurate_Fs = [sum(rollout_Fs[i:i+n-1])/n for i in 1:n:length(rollout_Fs)]
  @assert length(accurate_Fs) == k
  elite_idx = argmax(accurate_Fs)
  elite = maximum(accurate_Fs), pop[top_F_idxs[elite_idx]]
  elite

end
end
