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
	# M1 and M3, from the Monash archive, have no domains: their scores are by frequency only
	domains = any(!ismissing, result.domain)
	for row in Tables.rows(result)
		owa = (row.smape / row.reference_smape + row.mase / row.reference_mase) / 2
		if row.all_frequencies == 0
			add(row.entry, "frequency", row.frequency, row.smape, row.mase, owa)
		elseif row.all_domains == 0
			domains && add(row.entry, "domain", row.domain, row.smape, row.mase, owa)
		else
			add(row.entry, "frequency", "Total", row.smape, row.mase, owa)
			domains && add(row.entry, "domain", "Total", row.smape, row.mase, owa)
		end
	end
	scores
end

"""
The levels of M5, by which its 30,490 series add up into 42,840: for each, the columns of `hierarchy` (as SQL) that
name a series of that level as `weights` names it, in agg_level_1 and agg_level_2 ('X' for none).
"""
const M5_LEVELS = (
	(1, "'Total'", "'X'"), (2, "state", "'X'"), (3, "store", "'X'"), (4, "category", "'X'"), (5, "department", "'X'"),
	(6, "state", "category"), (7, "state", "department"), (8, "store", "category"), (9, "store", "department"),
	(10, "item", "'X'"), (11, "state", "item"), (12, "item", "store"))

"""
	prepare_m5!(db, id)

The tables of the database `db` that every WRMSSE of competition `id` (M5) uses: `m5_keys` (series, level, a1, a2:
the series of each level a series adds up into), `m5_test` (level, a1, a2, h, value: the sums of the values the
forecasts are scored on, h from 1), `m5_scale` (level, a1, a2, scale: the mean squared change from one day to the next
of the training values of each series, from its first day of sales, the denominator of RMSSE) and `m5_weights`.
"""
function prepare_m5!(db, id)
	observations, hierarchy = table_sql(id, "observations.parquet"), table_sql(id, "hierarchy.parquet")
	keys = join(["SELECT series, $(level) AS level, $(first) AS a1, $(second) AS a2 FROM $(hierarchy)" for (level, first, second) in M5_LEVELS], " UNION ALL ")
	DBInterface.execute(db, "CREATE TEMP TABLE m5_keys AS $(keys)")
	DBInterface.execute(db, """CREATE TEMP TABLE m5_train AS SELECT k.level, k.a1, k.a2, o.t, sum(o.value) AS value
		FROM $(observations) o JOIN m5_keys k USING (series) WHERE o.split = 'train' GROUP BY ALL""")
	trained = only_row(db, "SELECT max(t) AS t FROM m5_train").t
	DBInterface.execute(db, """CREATE TEMP TABLE m5_test AS SELECT k.level, k.a1, k.a2, o.t - $(trained) AS h, sum(o.value) AS value
		FROM $(observations) o JOIN m5_keys k USING (series) WHERE o.split = 'test' GROUP BY ALL""")
	# A series is scaled over the days from its first sale: the changes from that day on
	DBInterface.execute(db, """CREATE TEMP TABLE m5_scale AS
		WITH sales AS (SELECT level, a1, a2, min(t) FILTER (WHERE value <> 0) AS first FROM m5_train GROUP BY ALL),
		changes AS (SELECT level, a1, a2, t, value - lag(value) OVER (PARTITION BY level, a1, a2 ORDER BY t) AS change FROM m5_train)
		SELECT level, a1, a2, avg(change * change) AS scale FROM changes JOIN sales USING (level, a1, a2) WHERE t > first GROUP BY ALL""")
	DBInterface.execute(db, "DROP TABLE m5_train")
	DBInterface.execute(db, """CREATE TEMP TABLE m5_weights AS SELECT level, agg_level_1 AS a1, agg_level_2 AS a2, weight
		FROM $(table_sql(id, "weights.parquet"))""")
	db
end

"""
	m5_summary(db, relation)

The WRMSSE of the point forecasts in `relation` (SQL of a table of entry, series, h and value, of the 30,490 series of
M5), as `published_scores` gives it: entry, measure, breakdown, level and value. The forecasts are added up into the
42,840 series of the 12 levels; the RMSSE of a series is the root of its mean squared error over the horizon over its
scale, the WRMSSE of a level the sum of the RMSSE of its series by their weights, and that of Total the mean of the 12
levels. Every series must be forecast once at each step of the horizon.
"""
function m5_summary(db, relation)
	series = only_row(db, "SELECT count(DISTINCT series) AS series FROM m5_keys").series
	horizon = only_row(db, "SELECT max(h) AS h FROM m5_test").h
	# Each entry must give one forecast of each series at each step: as many distinct (series, h) as forecasts, h from 1 to the horizon
	wrong = only_row(db, """SELECT count(*) AS entries FROM (SELECT entry, count(*) AS forecasts,
			count(DISTINCT CAST(series AS BIGINT) * 1000 + h) AS pairs, min(h) AS first, max(h) AS last FROM $(relation) GROUP BY entry)
		WHERE forecasts <> $(series * horizon) OR pairs <> forecasts OR first <> 1 OR last <> $(horizon)""").entries
	wrong == 0 || error("The forecasts must give each of the $(series) series of M5 one forecast for every h from 1 to $(horizon): the WRMSSE adds them up into the series of every level.")
	result = Tables.columntable(DBInterface.execute(db, """
		WITH added AS (SELECT f.entry, k.level, k.a1, k.a2, f.h, sum(f.value) AS value FROM $(relation) f JOIN m5_keys k USING (series) GROUP BY ALL),
		errors AS (SELECT a.entry, a.level, a.a1, a.a2, sqrt(avg((t.value - a.value) * (t.value - a.value)) / any_value(c.scale)) AS rmsse
			FROM added a JOIN m5_test t USING (level, a1, a2, h) JOIN m5_scale c USING (level, a1, a2) GROUP BY ALL)
		SELECT e.entry, e.level, sum(w.weight * e.rmsse) AS wrmsse FROM errors e JOIN m5_weights w USING (level, a1, a2)
		GROUP BY ALL ORDER BY ALL"""))
	scores = (; entry = Int16[], measure = String[], breakdown = String[], level = String[], value = Float64[])
	function add(entry, level, value)
		push!(scores.entry, entry); push!(scores.measure, "WRMSSE"); push!(scores.breakdown, "level")
		push!(scores.level, level); push!(scores.value, value)
	end
	for entry in unique(result.entry)
		rows = findall(==(entry), result.entry)
		for row in rows
			add(entry, string(result.level[row]), result.wrmsse[row])
		end
		add(entry, "Total", sum(result.wrmsse[rows]) / length(M5_LEVELS))
	end
	scores
end

"""
The format of competition `id` if this package scores it, else an error: M1 and M3 ("monash") and M4 by sMAPE, MASE
and OWA, M5 by the WRMSSE of its point forecasts.
"""
function scored(id)
	format = competition(id)["format"]
	format in ("monash", "m4", "m5") || error("$(competition(id)["name"]) is not scored yet: score and scores give the measures of M1, M3 and M4 and the WRMSSE of M5.")
	info(id) === nothing && error("$(competition(id)["name"]) is not downloaded yet: download(\"$(id)\") first.")
	format
end

"""
	naive2(y, period, horizon)

The forecasts of Naive2 of the values of `y` over `horizon` steps, as ForecastM4Benchmark.jl computes them: the last
value, seasonally adjusted when the series passes the seasonality test of M4, times the seasonal index of each step.
"""
function naive2(y, period, horizon)
	n = length(y)
	ForecastM4Benchmark.is_seasonal(y, period) || return fill(Float64(y[n]), horizon)
	index = ForecastM4Benchmark.seasonal_index(y, period)
	[y[n] / index[n] * index[n - period + 1 + mod(step - 1, period)] for step in 1:horizon]
end

"""
The table `m4_reference` of `db`: the errors of Naive2, against which OWA weighs every forecast. For M4, those of its
published forecasts, which must be on this computer; for M1 and M3, which publish none here, those of Naive2 computed
on this computer from the values the forecasters saw.
"""
function m4_reference!(db, id)
	if competition(id)["format"] == "m4"
		reference = entry_number(id, M4_REFERENCE)
		path = joinpath(folder(id), "forecasts", "$(reference).parquet")
		isfile(path) || error("OWA weighs the forecasts against those of Naive2: download_forecasts(\"$(id)\"; entries = [\"Naive2\"]) first.")
		m4_errors!(db, "m4_reference", "read_parquet($(sql_text(path)))")
		return db
	end
	known = series(id)
	values = observations(id; split = "train")
	starts = [searchsortedfirst(values.series, number) for number in known.series]
	forecasts = (; entry = Int16[], series = Int32[], h = Int16[], value = Float64[])
	for (k, number) in enumerate(known.series)
		stop = k == length(starts) ? length(values.series) : starts[k + 1] - 1
		forecast = naive2(view(values.value, starts[k]:stop), known.period[k], known.horizon[k])
		append!(forecasts.entry, fill(Int16(0), length(forecast))); append!(forecasts.series, fill(Int32(number), length(forecast)))
		append!(forecasts.h, Int16.(eachindex(forecast))); append!(forecasts.value, forecast)
	end
	writer = TableWriter(db, "naive2", ["entry" => "SMALLINT", "series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"])
	add!(writer, forecasts)
	m4_errors!(db, "m4_reference", "naive2")
	db
end

"""
	scores(id; entries = nothing)

The scores of the entries of competition `id` whose forecasts are on this computer (those of `entries`, by number or
name, or all of them), computed from their forecasts as the organisers compute them: entry, measure, breakdown, level
and value, as `published_scores(id)` gives the organisers' own. For M4: sMAPE, MASE and OWA by frequency and by
domain, and in total; OWA needs the forecasts of Naive2. For M5: the WRMSSE of the point forecasts (M5 Accuracy) by
level, 1 to 12, and in total.
"""
function scores(id; entries = nothing)
	format = scored(id)
	format == "monash" && error("$(competition(id)["name"]) has no published entries here: score(\"$(id)\", forecasts) scores forecasts of your own.")
	known = PollisCompetitions.entries(id)
	point = Set(Int(entry) for (entry, kind) in zip(known.entry, known.forecasts) if kind == "point")
	numbers = entries === nothing ? [Int(entry) for entry in known.entry if Int(entry) in point] : [entry_number(id, entry; known) for entry in entries]
	quantiles = [number for number in numbers if !(number in point)]
	isempty(quantiles) || error("Entries $(join(quantiles, ", ")) give quantile forecasts, which are not scored yet: scores gives the WRMSSE of the point forecasts of M5.")
	files = [joinpath(folder(id), "forecasts", "$(number).parquet") for number in numbers]
	missing_files = [number for (number, file) in zip(numbers, files) if !isfile(file)]
	if entries !== nothing && !isempty(missing_files)
		error("The forecasts of entries $(join(missing_files, ", ")) are not on this computer: download_forecasts(\"$(id)\"; entries = [$(join(missing_files, ", "))]) first.")
	end
	files = filter(isfile, files)
	isempty(files) && error("No forecasts of $(competition(id)["name"]) are on this computer: download_forecasts(\"$(id)\") first.")
	relation = "read_parquet([$(join(sql_text.(files), ", "))])"
	with_database() do db
		if format == "m5"
			prepare_m5!(db, id)
			return m5_summary(db, relation)
		end
		prepare_m4!(db, id)
		m4_reference!(db, id)
		m4_errors!(db, "m4_errors", relation)
		m4_summary(db, "m4_errors")
	end
end

"""
	score(id, forecasts)

The scores of `forecasts`, a table of columns series, h and value (any Tables.jl table, such as a NamedTuple of
vectors), against competition `id`, as the organisers compute them: measure, breakdown, level and value, over the
series forecast. Each series must be forecast over its whole horizon, h from 1. For M4: sMAPE, MASE and OWA (against
Naive2 on the same series) by frequency, by domain and in total; for M1 and M3 the same by frequency and in total,
against Naive2 computed on this computer. For M5: the WRMSSE by level and in total, of point
forecasts of all its 30,490 series.
"""
function score(id, forecasts)
	format = scored(id)
	columns = Tables.columntable(forecasts)
	for name in (:series, :h, :value)
		haskey(columns, name) || error("The forecasts have no column $(name): they need series, h and value.")
	end
	batch = (; entry = fill(Int16(0), length(columns.series)), series = Int32.(columns.series), h = Int16.(columns.h), value = Float64.(columns.value))
	result = with_database() do db
		format == "m5" ? prepare_m5!(db, id) : (prepare_m4!(db, id); m4_reference!(db, id))
		writer = TableWriter(db, "given", ["entry" => "SMALLINT", "series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"])
		add!(writer, batch)
		known = format == "m5" ? "m5_keys" : "m4_series"
		unknown = only_row(db, "SELECT count(DISTINCT series) AS series FROM given WHERE series NOT IN (SELECT series FROM $(known))").series
		unknown == 0 || error("$(unknown) series of the forecasts are not series of $(competition(id)["name"]).")
		format == "m5" && return m5_summary(db, "given")
		m4_errors!(db, "m4_errors", "given")
		m4_summary(db, "m4_errors")
	end
	(; measure = result.measure, breakdown = result.breakdown, level = result.level, value = result.value)
end
