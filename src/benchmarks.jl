"""The eight statistical benchmarks of M4, by the names of their entries: those of ForecastM4Benchmark.jl."""
const M4_BENCHMARKS = Tuple(string.(ForecastM4Benchmark.BENCHMARKS))

"""
	benchmarks(id; methods = M4_BENCHMARKS, series = nothing)

The forecasts of the benchmarks of competition `id` (M4) given in `methods`, computed on this computer from the values
the forecasters saw, for every series or those of `series` (a number or a vector of numbers): method, series, h and
value, the columns of `forecasts`, so that `score(id, ...)` scores each method. The series are forecast in parallel
over Julia's threads, by ForecastM4Benchmark.jl, which computes them as the organisers of M4 did.
"""
function benchmarks(id::AbstractString; methods = M4_BENCHMARKS, series = nothing)
	competition(id)["format"] == "m4" || error("$(competition(id)["name"]) has no benchmarks here yet: benchmarks gives those of M4.")
	info(id) === nothing && error("$(competition(id)["name"]) is not downloaded yet: download(\"$(id)\") first.")
	unknown = setdiff(methods, M4_BENCHMARKS)
	isempty(unknown) || error("$(join(unknown, ", ")) are not benchmarks of M4: they are $(join(M4_BENCHMARKS, ", ")).")
	where, parameters = conditions("series" => series)
	known = query("SELECT series, period, horizon FROM $(table_sql(id, "series.parquet"))$(where) ORDER BY series", parameters)
	values = observations(id; series = series === nothing ? nothing : known.series, split = "train")
	starts = [searchsortedfirst(values.series, number) for number in known.series]
	results = Vector{Any}(undef, length(known.series))
	Threads.@threads for k in eachindex(known.series)
		stop = k == length(starts) ? length(values.series) : starts[k + 1] - 1
		results[k] = ForecastM4Benchmark.benchmarks(view(values.value, starts[k]:stop); period = known.period[k], horizon = known.horizon[k])
	end
	columns = (; method = String[], series = Int32[], h = Int16[], value = Float64[])
	for method in methods, (k, number) in enumerate(known.series)
		forecast = getproperty(results[k], Symbol(method))
		append!(columns.method, fill(method, length(forecast)))
		append!(columns.series, fill(Int32(number), length(forecast)))
		append!(columns.h, Int16.(eachindex(forecast)))
		append!(columns.value, forecast)
	end
	columns
end
