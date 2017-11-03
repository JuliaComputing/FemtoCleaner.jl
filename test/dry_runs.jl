import FemtoCleaner
using Base.Test

println("Dry running DataFrames")
@test FemtoCleaner.dry_run("https://github.com/JuliaData/DataFrames.jl"; show_diff = false)
println("Dry running Gadfly")
@test FemtoCleaner.dry_run("https://github.com/GiovineItalia/Gadfly.jl"; show_diff = false)
println("Dry running JuMP")
@test FemtoCleaner.dry_run("https://github.com/JuliaOpt/JuMP.jl"; show_diff = false)
println("Dry running Plots")
@test FemtoCleaner.dry_run("https://github.com/JuliaPlots/Plots.jl"; show_diff = false)

