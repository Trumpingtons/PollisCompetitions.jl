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
of series and of observations, and, for each entry whose forecasts are downloaded, the number of series it forecast
over their whole horizon. `nothing` when the competition is not downloaded.
"""
info(id) = isfile(info_file(id)) ? TOML.parsefile(info_file(id)) : nothing

"""
	download(id; progress = (done, total) -> nothing, keep_source = false)

Makes competition `id` ready on this computer, in `folder(id)`: its files fetched from their source, each checked
against the SHA-256 of the catalogue, then converted into `series.parquet` and `observations.parquet`, and, for a
competition whose entries are published, `entries.parquet` and `published_scores.parquet`. The files of the source
are removed once converted, unless `keep_source`. Nothing is done when the competition is there already from the
files of the catalogue. Answers `info(id)`.
"""
function download(id; progress = (done, total) -> nothing, keep_source = false)
	entry = competition(id)
	current = info(id)
	current !== nothing && get(current, "fingerprint", "") == fingerprint(id) && return current
	target = folder(id)
	source = joinpath(target, "source")
	for name in ("series.parquet", "observations.parquet", "entries.parquet", "published_scores.parquet", "info.toml")
		rm(joinpath(target, name); force = true)
	end
	rm(joinpath(target, "forecasts"); recursive = true, force = true)
	format = entry["format"]
	if format == "monash"
		convert_monash(id, source, target; progress)
	elseif format == "m4"
		convert_m4(id, source, target; progress)
	else
		error("The catalogue gives competition $(id) the format $(format), which PollisCompetitions does not read.")
	end
	keep_source || rm(source; recursive = true, force = true)
	counts = query("SELECT (SELECT count(*) FROM read_parquet($(sql_text(joinpath(target, "series.parquet"))))) AS series, (SELECT count(*) FROM read_parquet($(sql_text(joinpath(target, "observations.parquet"))))) AS observations")
	write_info(id, Dict{String, Any}("competition" => id, "fingerprint" => fingerprint(id), "converted" => string(now(UTC)),
		"series" => only(counts.series), "observations" => only(counts.observations), "forecasts" => Dict{String, Any}()))
end

"""
	download_forecasts(id; entries = nothing, progress = (done, total) -> nothing, keep_source = false)

The forecasts of the entries of competition `id` named in `entries` (their names in `entries(id)`, such as "118" or
"Theta"; all of them when `nothing`), fetched, checked and converted into `forecasts/<entry>.parquet`, unless they are
there already. The competition must be downloaded first. Answers `info(id)`.
"""
function download_forecasts(id; entries = nothing, progress = (done, total) -> nothing, keep_source = false)
	current = info(id)
	current === nothing && error("$(competition(id)["name"]) is not downloaded yet: download(\"$(id)\") first.")
	files = files_of(id, "forecasts")
	isempty(files) && error("$(competition(id)["name"]) has no forecasts published.")
	if entries !== nothing
		unknown = setdiff(string.(entries), [file["entry"] for file in files])
		isempty(unknown) || error("$(competition(id)["name"]) has no forecasts of $(join(unknown, ", ")).")
		files = [file for file in files if file["entry"] in string.(entries)]
	end
	target = folder(id)
	source = joinpath(target, "source")
	done = current["forecasts"]
	for (index, file) in enumerate(files)
		if !(haskey(done, file["entry"]) && isfile(joinpath(target, "forecasts", "$(file["entry"]).parquet")))
			done[file["entry"]] = convert_m4_forecasts(id, file, source, target)
			keep_source || rm(joinpath(source, file["name"]); force = true)
			write_info(id, current)
		end
		progress(index, length(files))
	end
	keep_source || (isdir(source) && isempty(readdir(source)) && rm(source))
	current
end

function write_info(id, info)
	path = info_file(id)
	mkpath(dirname(path))
	open(io -> TOML.print(io, info; sorted = true), path * ".part", "w")
	mv(path * ".part", path; force = true)
	info
end
