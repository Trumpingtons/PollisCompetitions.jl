"""The fields of a line of a CSV file of the M4 repository, their quotes taken off."""
csv_fields(line) = [strip(field, '"') for field in split(strip(line), ',')]

"""Whether a field of a CSV file of the M4 repository holds a value: not empty, not NA."""
has_value(field) = !isempty(field) && field != "NA"

"""
	read_m4_info(path)

`M4-info.csv`, the facts of each series of M4, in its order: `(; names, domains, periods, horizons, frequencies,
starts)`. Its start is kept as the file gives it, such as "01-01-79 12:00".
"""
function read_m4_info(path)
	lines = eachline(path)
	header = csv_fields(first(lines))
	header == ["M4id", "category", "Frequency", "Horizon", "SP", "StartingDate"] ||
		error("M4-info.csv has the columns $(join(header, ", ")), not those of M4.")
	info = (; names = String[], domains = String[], periods = Int16[], horizons = Int16[], frequencies = String[], starts = String[])
	for line in lines
		isempty(strip(line)) && continue
		name, domain, period, horizon, frequency, start = csv_fields(line)
		push!(info.names, name); push!(info.domains, domain); push!(info.periods, parse(Int16, period))
		push!(info.horizons, parse(Int16, horizon)); push!(info.frequencies, frequency); push!(info.starts, start)
	end
	info
end

"""
	read_m4_values!(part, path, numbers, frequency)

The values of each series of a training or test file of M4 (`Yearly-train.csv` and the others: a series a line, its
name, then its values) added to `part` (series, t, value), `t` counting on from `first_t(number)`. Every series must
be one of `numbers`, of `frequency`. Answers the number of values of each series read.
"""
function read_m4_values!(part, path, numbers, frequency; first_t = number -> 1)
	counts = Dict{Int32, Int}()
	lines = eachline(path)
	first(lines)
	for line in lines
		isempty(strip(line)) && continue
		fields = csv_fields(line)
		entry = get(numbers, fields[1], nothing)
		entry === nothing && error("$(basename(path)): series $(fields[1]) is not in M4-info.csv.")
		entry.frequency == frequency || error("$(basename(path)): series $(fields[1]) is $(entry.frequency) in M4-info.csv.")
		t = first_t(entry.number)
		count = 0
		for field in fields[2:end]
			has_value(field) || continue
			push!(part.series, entry.number); push!(part.t, t); push!(part.value, parse(Float64, field))
			t += 1; count += 1
		end
		counts[entry.number] = count
	end
	counts
end

"""
	excel_rows(db, path, sheet)

The rows of `sheet` of the Excel file `path`, each a vector of texts (`missing` for an empty cell), read by the excel
extension of DuckDB. Rows with no text at all are left out.
"""
function excel_rows(db, path, sheet)
	try
		DBInterface.execute(db, "LOAD excel")
	catch
		DBInterface.execute(db, "INSTALL excel")
		DBInterface.execute(db, "LOAD excel")
	end
	query = "SELECT * FROM read_xlsx($(sql_text(path)), sheet = $(sql_text(sheet)), header = false, all_varchar = true, range = 'A1:BZ500', stop_at_empty = false)"
	rows = [[value === missing ? missing : strip(string(value)) for value in values(NamedTuple(row))] for row in DBInterface.execute(db, query)]
	filter(row -> any(value -> value !== missing && !isempty(value), row), rows)
end

"""The name of an entry of M4 as its files of forecasts name it: "005" is entry 5."""
entry_name(name) = all(isdigit, name) ? string(parse(Int, name)) : name

"""
	read_m4_entries(db, path)

The entries of M4 from `Submission Info.xlsx`, in its order (that of their rank by OWA): `(; entry, name, kind, method,
team, affiliation, rank)`. Its "Author(s)" names a benchmark "Theta - Benchmark" and a standard for comparison "ARIMA
- Standard for comparison"; the team of either is missing.
"""
function read_m4_entries(db, path)
	rows = excel_rows(db, path, first(sheet_names(path)))
	header = rows[1][1:5]
	header == ["ID", "Type", "Author(s)", "Affiliation", "Rank (OWA)"] ||
		error("Submission Info.xlsx has the columns $(join(skipmissing(header), ", ")), not those of M4.")
	entries = (; entry = Int16[], name = String[], kind = String[], method = String[], team = Union{Missing, String}[],
		affiliation = Union{Missing, String}[], rank = Int16[])
	for row in rows[2:end]
		row[1] === missing && continue
		authors = row[3]
		kind = endswith(authors, " - Benchmark") ? "benchmark" : endswith(authors, " - Standard for comparison") ? "standard" : "submission"
		push!(entries.entry, length(entries.entry) + 1); push!(entries.name, entry_name(row[1])); push!(entries.kind, kind)
		push!(entries.method, row[2]); push!(entries.team, kind == "submission" ? authors : missing)
		push!(entries.affiliation, row[4] === missing || isempty(row[4]) ? missing : row[4]); push!(entries.rank, parse(Int16, row[5]))
	end
	entries
end

"""The names of the sheets of the Excel file `path`, in their order, read from its workbook."""
function sheet_names(path)
	mktempdir() do folder
		workbook = joinpath(folder, "xl", "workbook.xml")
		run(`$(bsdtar()) -xf $(path) -C $(folder) xl/workbook.xml`)
		[match.captures[1] for match in eachmatch(r"<sheet [^>]*name=\"([^\"]+)\"", read(workbook, String))]
	end
end

"""
	read_m4_scores(db, path, numbers)

The published scores of the point forecasts of M4, from the sheets "Point Forecasts-Frequency" and "Point
Forecasts-Domain" of `Evaluation and Ranks.xlsx`: `(; entry, measure, breakdown, level, value)`, a row for each
entry, measure (sMAPE, MASE, OWA) and level (a frequency, a domain, or Total). The first row of a sheet names each
measure over its columns, the second the levels; an entry is named as in `numbers` (name => entry).
"""
function read_m4_scores(db, path, numbers)
	scores = (; entry = Int16[], measure = String[], breakdown = String[], level = String[], value = Float64[])
	for (sheet, breakdown) in (("Point Forecasts-Frequency", "frequency"), ("Point Forecasts-Domain", "domain"))
		rows = excel_rows(db, path, sheet)
		rows[1][1] == "Method" && rows[2][1] == "User ID" || error("$(sheet) of Evaluation and Ranks.xlsx does not start with Method and User ID.")
		measures = String[]
		current = ""
		for (column, value) in enumerate(rows[1])
			column == 1 && continue
			value === missing || isempty(value) || (current = value)
			push!(measures, current)
		end
		levels = rows[2][2:end]
		for row in rows[3:end]
			# The notes under the table, on what the measures are, follow a row with no entry
			(row[1] === missing || occursin(':', row[1])) && break
			name = entry_name(row[1])
			entry = get(numbers, name, nothing)
			entry === nothing && error("$(sheet) of Evaluation and Ranks.xlsx scores $(name), which Submission Info.xlsx does not list.")
			for (index, value) in enumerate(row[2:end])
				(levels[index] === missing || value === missing || isempty(value) || value == "#N/A") && continue
				push!(scores.entry, entry); push!(scores.measure, measures[index]); push!(scores.breakdown, breakdown)
				push!(scores.level, levels[index]); push!(scores.value, parse(Float64, value))
			end
		end
	end
	scores
end

"""
	convert_m4(id, source, target; progress)

M4 from its repository: `series.parquet` and `observations.parquet` from `M4-info.csv` and the training and test files
of each frequency, `entries.parquet` from `Submission Info.xlsx`, and `published_scores.parquet` from `Evaluation and
Ranks.xlsx`. The test file of a series must hold its horizon of values.
"""
function convert_m4(id, source, target; progress = (done, total) -> nothing)
	trains = files_of(id, "train")
	total = 2 * length(trains) + 2
	info = read_m4_info(fetch_file(only(files_of(id, "info")), source))
	numbers = Dict(name => (; number = Int32(index), frequency = info.frequencies[index]) for (index, name) in enumerate(info.names))
	with_database() do db
		series_writer = TableWriter(db, "series", SERIES_COLUMNS)
		add!(series_writer, (; series = Int32.(eachindex(info.names)), name = info.names, frequency = info.frequencies,
			period = info.periods, horizon = info.horizons, domain = info.domains, start = info.starts); constants = ("competition" => id,))
		write_parquet(series_writer, joinpath(target, "series.parquet"); order = "series")
		observations_writer = TableWriter(db, "observations", OBSERVATION_COLUMNS)
		done = 0
		for train_file in trains
			frequency = train_file["frequency"]
			test_file = only(file for file in files_of(id, "test") if file["frequency"] == frequency)
			train = (; series = Int32[], t = Int16[], value = Float64[])
			seen = read_m4_values!(train, fetch_file(train_file, source), numbers, frequency)
			add!(observations_writer, train; constants = ("split" => "train",))
			progress(done += 1, total)
			test = (; series = Int32[], t = Int16[], value = Float64[])
			counted = read_m4_values!(test, fetch_file(test_file, source), numbers, frequency; first_t = number -> seen[number] + 1)
			for (number, count) in counted
				count == info.horizons[number] || error("$(test_file["name"]): series $(info.names[number]) has $(count) values to forecast, not its horizon $(info.horizons[number]).")
			end
			length(counted) == length(seen) || error("$(test_file["name"]) and $(train_file["name"]) hold different series.")
			add!(observations_writer, test; constants = ("split" => "test",))
			progress(done += 1, total)
		end
		write_parquet(observations_writer, joinpath(target, "observations.parquet"); order = "series, t")
		entries = read_m4_entries(db, fetch_file(only(files_of(id, "entries")), source))
		entries_writer = TableWriter(db, "entries", ENTRY_COLUMNS)
		add!(entries_writer, entries; constants = ("competition" => id, "forecasts" => "point"))
		write_parquet(entries_writer, joinpath(target, "entries.parquet"); order = "entry")
		progress(done += 1, total)
		scores = read_m4_scores(db, fetch_file(only(files_of(id, "scores")), source), Dict(zip(entries.name, entries.entry)))
		scores_writer = TableWriter(db, "published_scores", SCORE_COLUMNS)
		add!(scores_writer, scores)
		write_parquet(scores_writer, joinpath(target, "published_scores.parquet"); order = "entry, breakdown, measure, level")
		progress(done += 1, total)
	end
end

"""
	convert_m4_forecasts(id, file, source, target)

The point forecasts of the entry of `file`, a RAR archive of the M4 repository holding one CSV file (a series a line:
its name, then its forecasts F1, F2 and so on), written to `forecasts/<entry>.parquet` in `target`: `(; entry, series,
h, value)`. A forecast beyond the horizon of its series is an error. Answers the number of series given every
forecast of their horizon.
"""
function convert_m4_forecasts(id, file, source, target)
	archive = fetch_file(file, source)
	csv = only_file(extract(archive, joinpath(source, splitext(file["name"])[1])), ".csv", archive)
	known = series(id)
	numbers = Dict(zip(known.name, zip(known.series, known.horizon)))
	entry = only(row.entry for row in Tables.rows(entries(id)) if row.name == file["entry"])
	forecasts = (; series = Int32[], h = Int16[], value = Float64[])
	complete = 0
	lines = eachline(csv)
	first(lines)
	for line in lines
		isempty(strip(line)) && continue
		fields = csv_fields(line)
		found = get(numbers, fields[1], nothing)
		found === nothing && error("$(file["name"]): series $(fields[1]) is not in M4.")
		number, horizon = found
		given = 0
		for (h, field) in enumerate(fields[2:end])
			has_value(field) || continue
			h <= horizon || error("$(file["name"]): series $(fields[1]) has a forecast at h = $(h), beyond its horizon $(horizon).")
			push!(forecasts.series, number); push!(forecasts.h, h); push!(forecasts.value, parse(Float64, field))
			given += 1
		end
		complete += given == horizon
	end
	with_database() do db
		writer = TableWriter(db, "forecasts", FORECAST_COLUMNS)
		add!(writer, forecasts; constants = ("entry" => entry,))
		write_parquet(writer, joinpath(target, "forecasts", "$(file["entry"]).parquet"); order = "series, h")
	end
	rm(joinpath(source, splitext(file["name"])[1]); recursive = true, force = true)
	complete
end
