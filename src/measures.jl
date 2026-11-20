"""The measures by which a forecasting dataset is scored: sMAPE, MASE and OWA."""
const MEASURES = ("sMAPE", "MASE", "OWA")

"""
	prepare!(db, id)

The tables of the database `db` that every score of dataset `id` uses: `known_series` (series, frequency, domain,
period), `test_values` (series, h, value: the values the forecasts are scored on, h from 1) and `scales` (series,
scale: the mean absolute difference between a training value and the one a seasonal period before, the denominator of
MASE).
"""
function prepare!(db, id)
	observations, known = table_sql(id, "observations.parquet"), table_sql(id, "series.parquet")
	DBInterface.execute(db, "CREATE TEMP TABLE known_series AS SELECT series, frequency, domain, period FROM $(known)")
	DBInterface.execute(db, "CREATE TEMP TABLE train_values AS SELECT series, t, value FROM $(observations) WHERE split = 'train'")
	DBInterface.execute(db, """CREATE TEMP TABLE test_values AS SELECT o.series, o.t - n.last AS h, o.value FROM $(observations) o
		JOIN (SELECT series, max(t) AS last FROM train_values GROUP BY series) n USING (series) WHERE o.split = 'test'""")
	# The time a seasonal period earlier is worked out first, so that the join is on two columns and DuckDB hashes it
	DBInterface.execute(db, """CREATE TEMP TABLE scales AS SELECT l.series, avg(abs(l.value - b.value)) AS scale
		FROM (SELECT a.series, a.t - s.period AS earlier, a.value FROM train_values a JOIN known_series s USING (series)) l
		JOIN train_values b ON b.series = l.series AND b.t = l.earlier GROUP BY l.series""")
	DBInterface.execute(db, "DROP TABLE train_values")
	db
end

"""
	errors!(db, name, relation)

The table `name` of the database `db` (series, smape, mase): the sMAPE and the MASE of each series forecast in
`relation` (SQL of a table of series, h and value), the means over its horizon. A series must be forecast once at each
step of its horizon.
"""
function errors!(db, name, relation)
	DBInterface.execute(db, """CREATE TEMP TABLE $(name) AS SELECT f.series,
		avg(200 * abs(t.value - f.value) / (abs(t.value) + abs(f.value))) AS smape, avg(abs(t.value - f.value)) / any_value(c.scale) AS mase,
		count(*) AS steps, any_value(h.horizon) AS horizon
		FROM $(relation) f JOIN test_values t USING (series, h) JOIN scales c USING (series)
		JOIN (SELECT series, count(*) AS horizon FROM test_values GROUP BY series) h USING (series) GROUP BY f.series""")
	short = only_row(db, "SELECT count(*) AS series FROM $(name) WHERE steps <> horizon").series
	short == 0 || error("$(short) series are not forecast once at each step of their horizon: give one forecast for every h from 1 to the horizon.")
	db
end

"""
	summary(db, errors)

The scores of the table `errors` of `db` (series, smape, mase): measure, breakdown, level and value. sMAPE and MASE are
means over the series of each frequency, each domain (when the dataset gives domains) and all of them (Total, under
each breakdown), and OWA weighs them against those of Naive2 on the same series, in the table `reference`.
"""
function summary(db, errors)
	result = Tables.columntable(DBInterface.execute(db, """
		SELECT s.frequency, s.domain, GROUPING(s.frequency) AS all_frequencies, GROUPING(s.domain) AS all_domains,
			avg(e.smape) AS smape, avg(e.mase) AS mase, avg(r.smape) AS reference_smape, avg(r.mase) AS reference_mase
		FROM $(errors) e JOIN known_series s USING (series) JOIN reference r USING (series)
		GROUP BY GROUPING SETS ((s.frequency), (s.domain), ()) ORDER BY ALL"""))
	scores = (; measure = String[], breakdown = String[], level = String[], value = Float64[])
	function add(breakdown, level, smape, mase, owa)
		for (measure, value) in zip(MEASURES, (smape, mase, owa))
			push!(scores.measure, measure); push!(scores.breakdown, breakdown); push!(scores.level, level); push!(scores.value, value)
		end
	end
	domains = any(!ismissing, result.domain)
	for row in Tables.rows(result)
		owa = (row.smape / row.reference_smape + row.mase / row.reference_mase) / 2
		if row.all_frequencies == 0
			add("frequency", row.frequency, row.smape, row.mase, owa)
		elseif row.all_domains == 0
			domains && add("domain", row.domain, row.smape, row.mase, owa)
		else
			add("frequency", "Total", row.smape, row.mase, owa)
			domains && add("domain", "Total", row.smape, row.mase, owa)
		end
	end
	scores
end

"""
The format of dataset `id` if this package scores it, else an error: a forecasting dataset of series and observations
("monash"), scored by sMAPE, MASE and OWA.
"""
function scored(id)
	format = competition(id)["format"]
	format == "monash" || error("$(competition(id)["name"]) is not a forecasting dataset of series and observations: score scores those.")
	format
end

"""
	naive2(y, period, horizon)

The forecasts of Naive2 of the values of `y` over `horizon` steps, as `Benchmarks` computes them: the last value,
seasonally adjusted when the series passes the seasonality test, times the seasonal index of each step.
"""
function naive2(y, period, horizon)
	n = length(y)
	Benchmarks.is_seasonal(y, period) || return fill(Float64(y[n]), horizon)
	index = Benchmarks.seasonal_index(y, period)
	[y[n] / index[n] * index[n - period + 1 + mod(step - 1, period)] for step in 1:horizon]
end

"""
The table `reference` of `db`: the errors of Naive2, against which OWA weighs every forecast, computed on this computer
from the values the forecasters saw of each series of dataset `id`.
"""
function reference!(db, id)
	known = series(id)
	values = observations(id; split = "train")
	starts = [searchsortedfirst(values.series, number) for number in known.series]
	forecasts = (; series = Int32[], h = Int16[], value = Float64[])
	for (k, number) in enumerate(known.series)
		stop = k == length(starts) ? length(values.series) : starts[k + 1] - 1
		forecast = naive2(view(values.value, starts[k]:stop), known.period[k], known.horizon[k])
		append!(forecasts.series, fill(Int32(number), length(forecast)))
		append!(forecasts.h, Int16.(eachindex(forecast))); append!(forecasts.value, forecast)
	end
	writer = TableWriter(db, "naive2", ["series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"])
	add!(writer, forecasts)
	errors!(db, "reference", "naive2")
	db
end

"""
	score(id, forecasts)

The scores of `forecasts`, a table of columns series, h and value (any Tables.jl table, such as a NamedTuple of
vectors), against dataset `id`: measure, breakdown, level and value, over the series forecast. Each series must be
forecast over its whole horizon, h from 1. sMAPE, MASE and OWA (against Naive2 on the same series, computed on this
computer) by frequency, by domain when the dataset gives domains, and in total.
"""
function score(id, forecasts)
	scored(id)
	with_database() do db
		prepare!(db, id)
		reference!(db, id)
		given!(db, id, forecasts)
		errors!(db, "given_errors", "given")
		summary(db, "given_errors")
	end
end

"""
	step_errors(id, forecasts)

The errors of `forecasts`, a table of columns series, h and value, against dataset `id` at each step ahead: series, h,
smape (200 times the absolute error over the sum of the absolute actual value and the absolute forecast) and mase (the
absolute error over the scale of MASE of the series). The means of smape and mase over the horizon of a series are its
sMAPE and its MASE, as `score` computes them.
"""
function step_errors(id, forecasts)
	scored(id)
	with_database() do db
		prepare!(db, id)
		given!(db, id, forecasts)
		Tables.columntable(DBInterface.execute(db, """SELECT f.series, f.h, 200 * abs(t.value - f.value) / (abs(t.value) + abs(f.value)) AS smape,
			abs(t.value - f.value) / c.scale AS mase FROM given f JOIN test_values t USING (series, h) JOIN scales c USING (series) ORDER BY f.series, f.h"""))
	end
end

"""
The table `given` of `db` (series, h, value) from `forecasts`, a table of columns series, h and value, whose series
must be series of dataset `id`.
"""
function given!(db, id, forecasts)
	columns = Tables.columntable(forecasts)
	for name in (:series, :h, :value)
		haskey(columns, name) || error("The forecasts have no column $(name): they need series, h and value.")
	end
	batch = (; series = Int32.(columns.series), h = Int16.(columns.h), value = Float64.(columns.value))
	writer = TableWriter(db, "given", ["series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"])
	add!(writer, batch)
	unknown = only_row(db, "SELECT count(DISTINCT series) AS series FROM given WHERE series NOT IN (SELECT series FROM known_series)").series
	unknown == 0 || error("$(unknown) series of the forecasts are not series of $(competition(id)["name"]).")
	db
end
