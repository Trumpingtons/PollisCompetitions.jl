"""The names of the eight statistical benchmarks of `Benchmarks`."""
const BENCHMARK_METHODS = Tuple(string.(Benchmarks.BENCHMARKS))

"""
	benchmarks(id; methods = BENCHMARK_METHODS, series = nothing)

The forecasts of the benchmarks given in `methods` on forecasting dataset `id`, computed on this computer from the
values the forecasters saw, for every series or those of `series` (a number or a vector of numbers): method, series, h
and value, so that `score(id, ...)` scores each method. The series are forecast in parallel over Julia's threads, by
`Benchmarks`.
"""
function benchmarks(id::AbstractString; methods = BENCHMARK_METHODS, series = nothing)
	scored(id)
	unknown = setdiff(methods, BENCHMARK_METHODS)
	isempty(unknown) || error("$(join(unknown, ", ")) are not benchmarks: they are $(join(BENCHMARK_METHODS, ", ")).")
	where, parameters = conditions("series" => series)
	known = query("SELECT series, period, horizon FROM $(table_sql(id, "series.parquet"))$(where) ORDER BY series", parameters)
	values = observations(id; series = series === nothing ? nothing : known.series, split = "train")
	starts = [searchsortedfirst(values.series, number) for number in known.series]
	results = Vector{Any}(undef, length(known.series))
	Threads.@threads for k in eachindex(known.series)
		stop = k == length(starts) ? length(values.series) : starts[k + 1] - 1
		results[k] = Benchmarks.benchmarks(view(values.value, starts[k]:stop); period = known.period[k], horizon = known.horizon[k], methods = Symbol.(methods))
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
