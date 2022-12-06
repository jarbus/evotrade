@testset "test_maze" begin
    env = maze_from_file("mazes/test_maze.txt")
    @assert length(env.locations) == 4
    reset!(env)
    solution = [4, 4, 3, 3, 3, 3, 2, 2]
    rews = [-sqrt(2), -1, 10, -1, -1, -1, -1, 10]
    for i in 1:8
        act = solution[i]
        r, done = step!(env, act)
        @test r == rews[i]
    end
end
@testset "test_maze_obs" begin
    env = maze_from_file("mazes/test_maze.txt")
    reset!(env)
    obs = get_obs(env)
    @test sum(obs.==1) == 4
    @test ndims(obs) == 4
    r, done = step!(env, 4)
    @test env.locations[4] != env.locations[3]
    obs = get_obs(env)
    @test obs[env.locations[4]..., 4] == obs[env.locations[3]..., 3] == 1
    @test obs[env.locations[3]..., 4] != obs[env.locations[3]..., 3]
    @test sum(obs.==1) == 4
end