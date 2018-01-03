import FemtoCleaner
using Base.Test

println("Dry running DataFrames")
@test FemtoCleaner.cleanrepo("https://github.com/JuliaData/DataFrames.jl"; show_diff = false)
println("Dry running Gadfly")
@test FemtoCleaner.cleanrepo("https://github.com/GiovineItalia/Gadfly.jl"; show_diff = false)
println("Dry running JuMP")
@test FemtoCleaner.cleanrepo("https://github.com/JuliaOpt/JuMP.jl"; show_diff = false)
println("Dry running Plots")
@test FemtoCleaner.cleanrepo("https://github.com/JuliaPlots/Plots.jl"; show_diff = false)

