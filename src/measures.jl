"""The measures of M4, as its organisers' code (`Benchmarks and Evaluation.R`) computes them."""
const M4_MEASURES = ("sMAPE", "MASE", "OWA")

"""The entry of M4 against which OWA weighs the others."""
const M4_REFERENCE = "Naive2"

"""
	prepare_m4!(db, id)

The tables of the database `db` that every score of competition `id` (M4) uses: `m4_series` (series, frequency,
domain), `m4_test` (series, h, value: the values the forecasts are scored on, h from 1) and `m4_scale` (series, scale:
the mean absolute difference between a training value and the one a seasonal period before, the denominator of MASE).
"""
function prepare_m4!(db, id)
	observations, known = table_sql(id, "observations.parquet"), table_sql(id, "series.parquet")
	DBInterface.execute(db, "CREATE TEMP TABLE m4_series AS SELECT series, frequency, domain, period FROM $(known)")
	DBInterface.execute(db, "CREATE TEMP TABLE m4_train AS SELECT series, t, value FROM $(observations) WHERE split = 'train'")
	DBInterface.execute(db, """CREATE TEMP TABLE m4_test AS SELECT o.series, o.t - n.last AS h, o.value FROM $(observations) o
		JOIN (SELECT series, max(t) AS last FROM m4_train GROUP BY series) n USING (series) WHERE o.split = 'test'""")
	# The time a seasonal period earlier is worked out first, so that the join is on two columns and DuckDB hashes it
	DBInterface.execute(db, """CREATE TEMP TABLE m4_scale AS SELECT l.series, avg(abs(l.value - b.value)) AS scale
		FROM (SELECT a.series, a.t - s.period AS earlier, a.value FROM m4_train a JOIN m4_series s USING (series)) l
		JOIN m4_train b ON b.series = l.series AND b.t = l.earlier GROUP BY l.series""")
	DBInterface.execute(db, "DROP TABLE m4_train")
	db
end

"""
	m4_errors!(db, name, relation)

The table `name` of the database `db` (entry, series, smape, mase): the sMAPE and the MASE of each series forecast in
`relation` (SQL of a table of entry, series, h and value), the means over its horizon. A series must be forecast once at
each step of its horizon.
"""
function m4_errors!(db, name, relation)
	DBInterface.execute(db, """CREATE TEMP TABLE $(name) AS SELECT f.entry, f.series,
		avg(200 * abs(t.value - f.value) / (abs(t.value) + abs(f.value))) AS smape, avg(abs(t.value - f.value)) / any_value(c.scale) AS mase,
		count(*) AS steps, any_value(h.horizon) AS horizon
		FROM $(relation) f JOIN m4_test t USING (series, h) JOIN m4_scale c USING (series)
		JOIN (SELECT series, count(*) AS horizon FROM m4_test GROUP BY series) h USING (series) GROUP BY f.entry, f.series""")
	short = only_row(db, "SELECT count(*) AS series FROM $(name) WHERE steps <> horizon").series
	short == 0 || error("$(short) series are not forecast once at each step of their horizon: give one forecast for every h from 1 to the horizon.")
	db
end

"""
	m4_summary(db, errors)

The scores of the entries of the table `errors` of `db` (entry, series, smape, mase), as `published_scores` gives
them: entry, measure, breakdown, level, value. sMAPE and MASE are means over the series of each frequency, each domain
and all of them (Total, under both breakdowns), and OWA weighs them against those of Naive2 on the same series, in the
table `m4_reference`.
"""
function m4_summary(db, errors)
	result = Tables.columntable(DBInterface.execute(db, """
		SELECT e.entry, s.frequency, s.domain, GROUPING(s.frequency) AS all_frequencies, GROUPING(s.domain) AS all_domains,
			avg(e.smape) AS smape, avg(e.mase) AS mase, avg(r.smape) AS reference_smape, avg(r.mase) AS reference_mase
		FROM $(errors) e JOIN m4_series s USING (series) JOIN m4_reference r USING (series)
		GROUP BY GROUPING SETS ((e.entry, s.frequency), (e.entry, s.domain), (e.entry)) ORDER BY ALL"""))
	scores = (; entry = Int16[], measure = String[], breakdown = String[], level = String[], value = Float64[])
	function add(entry, breakdown, level, smape, mase, owa)
		for (measure, value) in zip(M4_MEASURES, (smape, mase, owa))
			push!(scores.entry, entry); push!(scores.measure, measure); push!(scores.breakdown, breakdown)
			push!(scores.level, level); push!(scores.value, value)
		end
	end
	for row in Tables.rows(result)
		owa = (row.smape / row.reference_smape + row.mase / row.reference_mase) / 2
		if row.all_frequencies == 0
			add(row.entry, "frequency", row.frequency, row.smape, row.mase, owa)
		elseif row.all_domains == 0
			add(row.entry, "domain", row.domain, row.smape, row.mase, owa)
		else
			add(row.entry, "frequency", "Total", row.smape, row.mase, owa)
			add(row.entry, "domain", "Total", row.smape, row.mase, owa)
		end
	end
	scores
end

"""Whether competition `id` is scored by this package: so far, M4."""
function scored(id)
	competition(id)["format"] == "m4" || error("$(competition(id)["name"]) is not scored yet: score and scores give the measures of M4.")
	info(id) === nothing && error("$(competition(id)["name"]) is not downloaded yet: download(\"$(id)\") first.")
	id
end

"""The forecasts of Naive2 must be on this computer: OWA weighs every entry against them."""
function m4_reference!(db, id)
	reference = entry_number(id, M4_REFERENCE)
	path = joinpath(folder(id), "forecasts", "$(reference).parquet")
	isfile(path) || error("OWA weighs the forecasts against those of Naive2: download_forecasts(\"$(id)\"; entries = [\"Naive2\"]) first.")
	m4_errors!(db, "m4_reference", "read_parquet($(sql_text(path)))")
	db
end

"""
	scores(id; entries = nothing)

The scores of the entries of competition `id` whose forecasts are on this computer (those of `entries`, by number or
name, or all of them), computed from their forecasts as the organisers compute them: entry, measure, breakdown, level
and value, as `published_scores(id)` gives the organisers' own. For M4: sMAPE, MASE and OWA by frequency and by
domain, and in total. OWA needs the forecasts of Naive2.
"""
function scores(id; entries = nothing)
	scored(id)
	known = PollisCompetitions.entries(id)
	numbers = entries === nothing ? [Int(entry) for entry in known.entry] : [entry_number(id, entry; known) for entry in entries]
	files = [joinpath(folder(id), "forecasts", "$(number).parquet") for number in numbers]
	missing_files = [number for (number, file) in zip(numbers, files) if !isfile(file)]
	if entries !== nothing && !isempty(missing_files)
		error("The forecasts of entries $(join(missing_files, ", ")) are not on this computer: download_forecasts(\"$(id)\"; entries = [$(join(missing_files, ", "))]) first.")
	end
	files = filter(isfile, files)
	isempty(files) && error("No forecasts of $(competition(id)["name"]) are on this computer: download_forecasts(\"$(id)\") first.")
	with_database() do db
		prepare_m4!(db, id)
		m4_reference!(db, id)
		m4_errors!(db, "m4_errors", "read_parquet([$(join(sql_text.(files), ", "))])")
		m4_summary(db, "m4_errors")
	end
end

"""
	score(id, forecasts)

The scores of `forecasts`, a table of columns series, h and value (any Tables.jl table, such as a NamedTuple of
vectors), against competition `id`, as the organisers compute them: measure, breakdown, level and value, over the
series forecast. Each series must be forecast over its whole horizon, h from 1. For M4: sMAPE, MASE and OWA (against
Naive2 on the same series) by frequency, by domain and in total.
"""
function score(id, forecasts)
	scored(id)
	columns = Tables.columntable(forecasts)
	for name in (:series, :h, :value)
		haskey(columns, name) || error("The forecasts have no column $(name): they need series, h and value.")
	end
	batch = (; entry = fill(Int16(0), length(columns.series)), series = Int32.(columns.series), h = Int16.(columns.h), value = Float64.(columns.value))
	result = with_database() do db
		prepare_m4!(db, id)
		m4_reference!(db, id)
		writer = TableWriter(db, "given", ["entry" => "SMALLINT", "series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"])
		add!(writer, batch)
		unknown = only_row(db, "SELECT count(DISTINCT series) AS series FROM given WHERE series NOT IN (SELECT series FROM m4_series)").series
		unknown == 0 || error("$(unknown) series of the forecasts are not series of $(competition(id)["name"]).")
		m4_errors!(db, "m4_errors", "given")
		m4_summary(db, "m4_errors")
	end
	(; measure = result.measure, breakdown = result.breakdown, level = result.level, value = result.value)
end
