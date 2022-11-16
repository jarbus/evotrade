module GANS
using StableRNGs
using Flux
export reconstruct, compute_novelty

function reconstruct(x::Vector{<:UInt32}, len, ϵ=0.1)
  @assert length(x) > 0
  @assert len > 0
  theta = Flux.glorot_normal(StableRNG(x[1]), len)
  for seed in x
    theta .+= ϵ .* Flux.glorot_normal(StableRNG(seed), len)
  end

  @assert theta .|> isnan |> any |> !
  theta
end

function test_reconstruct()
  z = reconstruct([3, 4, 5], 4)
  println(z)
end

function compute_novelty(ind_bc::Vector{<:Float64}, archive::Set{Tuple{Vector{Float32},Vector{UInt32}}})
    sum((ind_bc .- bc) .^ 2 for (bc, _) in archive) / length(archive)
end


end
