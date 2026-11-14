"""
	read_tsf(path)

A file of the Monash Time Series Forecasting Archive (.tsf), as `(; frequency, horizon, rows)`: the frequency and the
horizon of its header (`nothing` when it has none), and each series, `(; name, start, values)`, its start `nothing`
when the file gives none. The attributes of the header say what comes before the values of a series, separated by
colons. A missing value, `?`, is an error: the competitions of the catalogue have none.
"""
function read_tsf(path)
	attributes = String[]
	frequency = horizon = nothing
	rows = @NamedTuple{name::String, start::Union{Nothing, String}, values::Vector{Float64}}[]
	in_data = false
	# The comments of the header are in Latin-1, which these lines never read
	for line in eachline(path)
		line = strip(line)
		(isempty(line) || startswith(line, '#')) && continue
		if !in_data
			words = split(line)
			keyword = lowercase(first(words))
			if keyword == "@attribute"
				push!(attributes, words[2])
			elseif keyword == "@frequency"
				frequency = String(words[2])
			elseif keyword == "@horizon"
				horizon = parse(Int, words[2])
			elseif keyword == "@data"
				in_data = true
			end
			continue
		end
		fields = split(line, ':'; limit = length(attributes) + 1)
		length(fields) == length(attributes) + 1 || error("$(basename(path)): a series has $(length(fields) - 1) attributes, not $(length(attributes)).")
		values = [value == "?" ? error("$(basename(path)): series $(fields[1]) has a missing value.") : parse(Float64, value) for value in split(fields[end], ',')]
		start = "start_timestamp" in attributes ? String(fields[findfirst(==("start_timestamp"), attributes)]) : nothing
		push!(rows, (; name = String(fields[1]), start, values))
	end
	in_data || error("$(basename(path)) has no @data line.")
	(; frequency, horizon, rows)
end

"""
	convert_monash(id, source, target; progress)

The series of competition `id` from its files of the Monash archive, each a zip of one .tsf file of one frequency:
`series.parquet` and `observations.parquet` in `target`. In each series of the archive, the values the forecasters saw
come first, then the `horizon` values their forecasts were scored on. The horizon of each file must be that of the
catalogue.
"""
function convert_monash(id, source, target; progress = (done, total) -> nothing)
	files = files_of(id, "series")
	with_database() do db
		series_writer = TableWriter(db, "series", SERIES_COLUMNS)
		observations_writer = TableWriter(db, "observations", OBSERVATION_COLUMNS)
		number = 0
		for (index, file) in enumerate(files)
			archive = fetch_file(file, source)
			tsf = read_tsf(only_file(extract(archive, joinpath(source, splitext(file["name"])[1])), ".tsf", archive))
			horizon = file["horizon"]
			tsf.horizon === nothing || tsf.horizon == horizon ||
				error("$(file["name"]) gives a horizon of $(tsf.horizon), the catalogue $(horizon).")
			numbers = Int32[]; names = String[]; starts = Union{Missing, String}[]
			train = (; series = Int32[], t = Int16[], value = Float64[])
			test = (; series = Int32[], t = Int16[], value = Float64[])
			for row in tsf.rows
				length(row.values) > horizon || error("$(file["name"]): series $(row.name) has $(length(row.values)) values, no more than its horizon.")
				number += 1
				push!(numbers, number); push!(names, row.name); push!(starts, something(row.start, missing))
				seen = length(row.values) - horizon
				for (t, value) in enumerate(row.values)
					part = t <= seen ? train : test
					push!(part.series, number); push!(part.t, t); push!(part.value, value)
				end
			end
			add!(series_writer, (; series = numbers, name = names, start = starts);
				constants = ("competition" => id, "frequency" => file["frequency"], "period" => file["period"], "horizon" => horizon))
			add!(observations_writer, train; constants = ("split" => "train",))
			add!(observations_writer, test; constants = ("split" => "test",))
			progress(index, length(files))
		end
		write_parquet(series_writer, joinpath(target, "series.parquet"); order = "series")
		write_parquet(observations_writer, joinpath(target, "observations.parquet"); order = "series, t")
	end
end
