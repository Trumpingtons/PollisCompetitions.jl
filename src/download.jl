"""The columns of `series.parquet`: a series, its competition, its name in the source, its frequency, seasonal period and horizon, its domain and its start, as the source gives them."""
const SERIES_COLUMNS = ["series" => "INTEGER", "competition" => "VARCHAR", "name" => "VARCHAR", "frequency" => "VARCHAR",
	"period" => "SMALLINT", "horizon" => "SMALLINT", "domain" => "VARCHAR", "start" => "VARCHAR"]

"""The columns of `observations.parquet`: a series, the time from 1, the value, and whether the forecasters saw it (train) or their forecasts were scored on it (test)."""
const OBSERVATION_COLUMNS = ["series" => "INTEGER", "t" => "SMALLINT", "value" => "DOUBLE", "split" => "VARCHAR"]

"""The columns of `entries.parquet`: an entry, its competition, its name in the source, its kind (submission, benchmark, standard), its method, team and affiliation, its published rank, and the forecasts published (point)."""
const ENTRY_COLUMNS = ["entry" => "SMALLINT", "competition" => "VARCHAR", "name" => "VARCHAR", "kind" => "VARCHAR",
	"method" => "VARCHAR", "team" => "VARCHAR", "affiliation" => "VARCHAR", "rank" => "SMALLINT", "forecasts" => "VARCHAR"]

"""The columns of the files `forecasts/<entry>.parquet`: an entry, a series, the step ahead from 1, the forecast."""
const FORECAST_COLUMNS = ["entry" => "SMALLINT", "series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"]

"""The columns of `published_scores.parquet`: an entry, a measure, what the scores are broken down by (frequency, domain), the level (Yearly, Macro, Total and so on) and the score the organisers published."""
const SCORE_COLUMNS = ["entry" => "SMALLINT", "measure" => "VARCHAR", "breakdown" => "VARCHAR", "level" => "VARCHAR", "value" => "DOUBLE"]

"""The folder of competition `id` on this computer."""
folder(id) = joinpath(HOME, competition(id)["id"])

"""The file in which `download` records what is on this computer of competition `id`."""
info_file(id) = joinpath(HOME, id, "info.toml")

"""
The fingerprint of the files of the catalogue of competition `id` that `download` converts: when the catalogue
changes them, the competition is downloaded again.
"""
fingerprint(id) = bytes2hex(sha256(join(sort([file["sha256"] for file in competition(id)["files"] if file["role"] != "forecasts"]), ",")))

"""
	info(id)

What is on this computer of competition `id`: when it was converted, from which files (their fingerprint), the number
of rows of each of its tables, and, for each entry whose forecasts are downloaded (by its number), the number of
series it forecast over their whole horizon. `nothing` when the competition is not downloaded.
"""
info(id) = isfile(info_file(id)) ? TOML.parsefile(info_file(id)) : nothing

"""
	download(id; progress = (done, total) -> nothing, keep_source = false)

Makes competition `id` ready on this computer, in `folder(id)`: its files fetched from their source, each checked
against the SHA-256 of the catalogue, then converted into its tables, Parquet files: `series.parquet` and
`observations.parquet`, and, for a competition whose entries are published, `entries.parquet` and
`published_scores.parquet`; M5 adds `hierarchy`, `calendar`, `prices` and `weights`, and M6, whose forecasts are of
the ranks of the returns of assets, has `prices`, `entries`, `submissions` and `published_scores`. The files of the source
are removed once converted, unless `keep_source`. Nothing is done when the competition is there already from the
files of the catalogue. Answers `info(id)`.
"""
function download(id; progress = (done, total) -> nothing, keep_source = false)
	entry = competition(id)
	current = info(id)
	current !== nothing && get(current, "fingerprint", "") == fingerprint(id) && return current
	target = folder(id)
	source = joinpath(target, "source")
	if isdir(target)
		for name in readdir(target)
			(endswith(name, ".parquet") || name == "info.toml") && rm(joinpath(target, name))
		end
	end
	rm(joinpath(target, "forecasts"); recursive = true, force = true)
	format = entry["format"]
	converters = Dict("monash" => convert_monash, "m4" => convert_m4, "m5" => convert_m5, "m6" => convert_m6)
	haskey(converters, format) || error("The catalogue gives competition $(id) the format $(format), which PollisCompetitions does not read.")
	converters[format](id, source, target; progress)
	keep_source || rm(source; recursive = true, force = true)
	rows = Dict{String, Any}(splitext(name)[1] => only(query("SELECT count(*) AS rows FROM $(table_sql(id, name))").rows)
		for name in readdir(target) if endswith(name, ".parquet"))
	write_info(id, Dict{String, Any}("competition" => id, "fingerprint" => fingerprint(id), "converted" => string(now(UTC)),
		"tables" => rows, "forecasts" => Dict{String, Any}()))
end

"""
	download_forecasts(id; entries = nothing, progress = (done, total) -> nothing, keep_source = false)

The forecasts of the entries of competition `id` given in `entries` (their numbers, or their names, such as "118" or
"Theta", in `entries(id)`; all of them when `nothing`), fetched, checked and converted into
`forecasts/<entry>.parquet`, named by the entry's number, unless they are there already. The competition must be
downloaded first. Answers `info(id)`.
"""
function download_forecasts(id; entries = nothing, progress = (done, total) -> nothing, keep_source = false)
	current = info(id)
	current === nothing && error("$(competition(id)["name"]) is not downloaded yet: download(\"$(id)\") first.")
	files = files_of(id, "forecasts")
	isempty(files) && error("$(competition(id)["name"]) has no forecasts published.")
	known = PollisCompetitions.entries(id)
	numbers = [entry_of(known, file["entry"], get(file, "forecasts", "point")) for file in files]
	if entries !== nothing
		chosen = Set(entry_number(id, entry; known) for entry in entries)
		keep = [number in chosen for number in numbers]
		files, numbers = files[keep], numbers[keep]
	end
	target = folder(id)
	source = joinpath(target, "source")
	done = current["forecasts"]
	for (index, (file, number)) in enumerate(zip(files, numbers))
		if !(haskey(done, string(number)) && isfile(joinpath(target, "forecasts", "$(number).parquet")))
			done[string(number)] = competition(id)["format"] == "m5" ? convert_m5_forecasts(id, file, number, source, target) :
				convert_m4_forecasts(id, file, number, source, target)
			keep_source || rm(joinpath(source, file["name"]); force = true)
			write_info(id, current)
		end
		progress(index, length(files))
	end
	keep_source || (isdir(source) && isempty(readdir(source)) && rm(source))
	current
end

"""The number of the entry of `known` (the entries of a competition) named `name` whose forecasts are `forecasts`."""
function entry_of(known, name, forecasts)
	found = [entry for (entry, other, kind) in zip(known.entry, known.name, known.forecasts) if other == name && kind == forecasts]
	length(found) == 1 || error("The entries of the competition have $(length(found)) entries $(name) of forecasts $(forecasts), not one.")
	only(found)
end

"""
	entry_number(id, entry; known = entries(id))

The number of an entry of competition `id`, given by its number or its name. A name that two entries share (in M5,
an entry of Accuracy and one of Uncertainty) is an error that names both numbers.
"""
function entry_number(id, entry; known = entries(id))
	if entry isa Integer
		entry in known.entry || error("$(competition(id)["name"]) has no entry $(entry).")
		return Int(entry)
	end
	found = [number for (number, name) in zip(known.entry, known.name) if name == string(entry)]
	isempty(found) && error("$(competition(id)["name"]) has no entry named $(entry).")
	length(found) == 1 || error("$(competition(id)["name"]) has $(length(found)) entries named $(entry): give its number, one of $(join(found, ", ")).")
	Int(only(found))
end

function write_info(id, info)
	path = info_file(id)
	mkpath(dirname(path))
	open(io -> TOML.print(io, info; sorted = true), path * ".part", "w")
	mv(path * ".part", path; force = true)
	info
end
