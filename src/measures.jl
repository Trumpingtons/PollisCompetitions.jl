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
and OWA, M5 by the WRMSSE of its point forecasts, M6 by the RPS of its forecasts and the IR of its decisions.
"""
function scored(id)
	format = competition(id)["format"]
	format in ("monash", "m4", "m5", "m6") || error("$(competition(id)["name"]) is not scored yet: score and scores give the measures of M1, M3 and M4, the WRMSSE of M5 and the RPS and IR of M6.")
	info(id) === nothing && error("$(competition(id)["name"]) is not downloaded yet: download(\"$(id)\") first.")
	format
end

"""
	naive2(y, period, horizon)

The forecasts of Naive2 of the values of `y` over `horizon` steps, as `M4Benchmarks` computes them: the last
value, seasonally adjusted when the series passes the seasonality test of M4, times the seasonal index of each step.
"""
function naive2(y, period, horizon)
	n = length(y)
	M4Benchmarks.is_seasonal(y, period) || return fill(Float64(y[n]), horizon)
	index = M4Benchmarks.seasonal_index(y, period)
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
	format == "m6" && return m6_scores(id, entries)
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
	format == "m6" && return m6_score(id, forecasts)
	result = with_database() do db
		format == "m5" ? prepare_m5!(db, id) : (prepare_m4!(db, id); m4_reference!(db, id))
		given!(db, id, format, forecasts)
		format == "m5" && return m5_summary(db, "given")
		m4_errors!(db, "m4_errors", "given")
		m4_summary(db, "m4_errors")
	end
	(; measure = result.measure, breakdown = result.breakdown, level = result.level, value = result.value)
end

"""
	step_errors(id, forecasts)

The errors of `forecasts`, a table of columns series, h and value, against competition `id` (M1, M3 or M4) at each
step ahead: series, h, smape (200 times the absolute error over the sum of the absolute actual value and the absolute
forecast) and mase (the absolute error over the scale of MASE of the series). The means of smape and mase over the
horizon of a series are its sMAPE and its MASE, as `score` computes them.
"""
function step_errors(id, forecasts)
	format = scored(id)
	format in ("m5", "m6") && error("$(competition(id)["name"]) is not scored by errors at each step: step_errors gives the errors of M1, M3 and M4.")
	with_database() do db
		prepare_m4!(db, id)
		given!(db, id, format, forecasts)
		Tables.columntable(DBInterface.execute(db, """SELECT f.series, f.h, 200 * abs(t.value - f.value) / (abs(t.value) + abs(f.value)) AS smape,
			abs(t.value - f.value) / c.scale AS mase FROM given f JOIN m4_test t USING (series, h) JOIN m4_scale c USING (series) ORDER BY f.series, f.h"""))
	end
end

"""
The table `given` of `db` (entry 0, series, h, value) from `forecasts`, a table of columns series, h and value, whose
series must be series of competition `id`, of format `format`.
"""
function given!(db, id, format, forecasts)
	columns = Tables.columntable(forecasts)
	for name in (:series, :h, :value)
		haskey(columns, name) || error("The forecasts have no column $(name): they need series, h and value.")
	end
	batch = (; entry = fill(Int16(0), length(columns.series)), series = Int32.(columns.series), h = Int16.(columns.h), value = Float64.(columns.value))
	writer = TableWriter(db, "given", ["entry" => "SMALLINT", "series" => "INTEGER", "h" => "SMALLINT", "value" => "DOUBLE"])
	add!(writer, batch)
	known = format == "m5" ? "m5_keys" : "m4_series"
	unknown = only_row(db, "SELECT count(DISTINCT series) AS series FROM given WHERE series NOT IN (SELECT series FROM $(known))").series
	unknown == 0 || error("$(unknown) series of the forecasts are not series of $(competition(id)["name"]).")
	db
end

# ------------------------------------------------------------------------------------------------------------------
# M6: the RPS of the forecasts and the IR of the decisions, as the organisers' evaluation code computes them
# (`Baseline for evaluating the hypotheses.R` and `RPS and IR calculation.R` of Mcompetitions/M6-methods)
# ------------------------------------------------------------------------------------------------------------------

"""The last day of each of the 12 rounds of M6 that were scored; the returns of a round are over the 28 days to it."""
const M6_ROUND_ENDS = Date.(["2022-04-01", "2022-04-29", "2022-05-27", "2022-06-24", "2022-07-22", "2022-08-19",
	"2022-09-16", "2022-10-14", "2022-11-11", "2022-12-09", "2023-01-06", "2023-02-03"])

"""
	m6_prices(id)

The prices of the assets of M6 in each of its 12 rounds, as the organisers' evaluation code takes them: a vector of
`(; days, symbols, prices)`, for round k the days from 28 days before its last day to that day on which an asset has
a price, every asset of M6 in `symbols` (the same in every round), and `prices`, a matrix of the assets by the days.
An asset with no price on a day has its price of the day before; one with no price in the round, as DRE once it was
taken over, has its last price of all on every day, so that its return is 0.
"""
function m6_prices(id)
	known = query("SELECT symbol, date, price FROM $(table_sql(id, "prices.parquet"))")
	rows_of = Dict{String, Vector{Int}}()
	for (k, symbol) in enumerate(known.symbol)
		push!(get!(rows_of, symbol, Int[]), k)
	end
	symbols = sort(collect(keys(rows_of)))
	for symbol in symbols
		sort!(rows_of[symbol]; by = k -> known.date[k])
	end
	map(M6_ROUND_ENDS) do last_day
		first_day = last_day - Day(28)
		days = sort(unique(day for day in known.date if first_day <= day <= last_day))
		prices = fill(NaN, length(symbols), length(days))
		for (row, symbol) in enumerate(symbols)
			inside = [k for k in rows_of[symbol] if first_day <= known.date[k] <= last_day]
			if isempty(inside)
				prices[row, :] .= known.price[last(rows_of[symbol])]
				continue
			end
			given = Dict(known.date[k] => known.price[k] for k in inside)
			for (column, day) in enumerate(days)
				prices[row, column] = get(given, day, column > 1 ? prices[row, column - 1] : NaN)
			end
		end
		(; days, symbols, prices)
	end
end

"""
	m6_rps(round, probabilities)

The ranked probability score of `probabilities` (a matrix of the assets of `round`, as `m6_prices` gives it, by the
five ranks, from the lowest returns to the highest) over that round. The assets are ranked by their return from the
first day of the round to the last, ties at the lowest place, and the places 1 to 20 are rank 1, 21 to 40 rank 2 and
so on; assets that tie share the ranks of the places they span. The RPS of an asset is the mean of the squared
differences of the cumulative probabilities from the cumulative ranks, and that of the round their mean over the assets.
"""
function m6_rps(round, probabilities)
	returns = (round.prices[:, end] .- round.prices[:, 1]) ./ round.prices[:, 1]
	n = length(returns)
	total = 0.0
	for i in 1:n
		place = count(<(returns[i]), returns) + 1
		tied = count(==(returns[i]), returns)
		target = zeros(5)
		for p in place:(place + tied - 1)
			target[min(5, cld(p, 20))] += 1 / tied
		end
		total += sum(abs2, cumsum(target) .- cumsum(probabilities[i, :])) / 5
	end
	total / n
end

"""
	m6_daily_returns(round, weights)

The log returns of the portfolio of `weights` (one for each asset of `round`, as `m6_prices` gives it, negative for a
short position) on each day of the round after the first: the log of 1 plus the sum of each asset's weight times its
return from the day before.
"""
m6_daily_returns(round, weights) = [log(1 + sum(weights .* (round.prices[:, t] .- round.prices[:, t - 1]) ./ round.prices[:, t - 1])) for t in 2:size(round.prices, 2)]

"""The information ratio of daily log returns: their sum over their standard deviation (with n - 1)."""
function information_ratio(returns)
	mean = sum(returns) / length(returns)
	sum(returns) / sqrt(sum(abs2, returns .- mean) / (length(returns) - 1))
end

"""
	m6_summary(rounds, submitted)

The RPS and the IR of one set of submissions to M6, `submitted` (round => `(; probabilities, weights)`, in the order
of the assets of `rounds`), as `published_scores` gives them: measure, breakdown, level and value, for each round
submitted (breakdown month, levels 1 to 12), each quarter (quarter, 1 to 4) and the year (global, Total). The RPS of a
quarter or of the year is the mean of the RPS of its rounds, and the IR is that of all the daily returns of its rounds.
"""
function m6_summary(rounds, submitted)
	scores = (; measure = String[], breakdown = String[], level = String[], value = Float64[])
	function add(measure, breakdown, level, value)
		push!(scores.measure, measure); push!(scores.breakdown, breakdown); push!(scores.level, level); push!(scores.value, value)
	end
	rps, daily = Dict{Int, Float64}(), Dict{Int, Vector{Float64}}()
	for (k, round) in enumerate(rounds)
		haskey(submitted, k) || continue
		rps[k] = m6_rps(round, submitted[k].probabilities)
		daily[k] = m6_daily_returns(round, submitted[k].weights)
		add("RPS", "month", string(k), rps[k])
		add("IR", "month", string(k), information_ratio(daily[k]))
	end
	for (breakdown, level, months) in vcat([("quarter", string(q), (3q - 2):(3q)) for q in 1:4], [("global", "Total", 1:12)])
		chosen = [k for k in months if haskey(rps, k)]
		isempty(chosen) && continue
		add("RPS", breakdown, level, sum(rps[k] for k in chosen) / length(chosen))
		add("IR", breakdown, level, information_ratio(reduce(vcat, [daily[k] for k in chosen])))
	end
	scores
end

"""
The submissions of `columns` (evaluation, the round from 1 to 12; symbol; decision; rank1 to rank5) as `m6_summary`
takes them, each round's rows put in the order of the assets of `rounds`; every round given must have each asset once.
"""
function m6_submitted(rounds, columns)
	symbols = first(rounds).symbols
	submitted = Dict{Int, NamedTuple}()
	for k in sort(unique(Int.(columns.evaluation)))
		1 <= k <= length(rounds) || error("Round $(k) is not a round of M6: the rounds scored are 1 to $(length(rounds)).")
		rows = findall(==(k), columns.evaluation)
		at = Dict(String(columns.symbol[r]) => r for r in rows)
		length(at) == length(rows) == length(symbols) && all(s -> haskey(at, s), symbols) ||
			error("Round $(k) must give each of the $(length(symbols)) assets of M6 once.")
		order = [at[s] for s in symbols]
		probabilities = Float64.(hcat(columns.rank1[order], columns.rank2[order], columns.rank3[order], columns.rank4[order], columns.rank5[order]))
		submitted[k] = (; probabilities, weights = Float64.(columns.decision[order]))
	end
	submitted
end

"""
The scores of M6 of submissions of the user's own, `forecasts`, a table of columns evaluation (the round, 1 to 12),
symbol, decision and rank1 to rank5: measure, breakdown, level and value, as `m6_summary` gives them.
"""
function m6_score(id, forecasts)
	columns = Tables.columntable(forecasts)
	for name in (:evaluation, :symbol, :decision, :rank1, :rank2, :rank3, :rank4, :rank5)
		haskey(columns, name) || error("The submissions have no column $(name): they need evaluation, symbol, decision and rank1 to rank5.")
	end
	rounds = m6_prices(id)
	m6_summary(rounds, m6_submitted(rounds, columns))
end

"""
The scores of M6 of its teams (those of `entries`, by number or name, or all of them), from their submissions: entry,
measure, breakdown, level and value, as `published_scores` gives the organisers' own. The trial run is not scored.
"""
function m6_scores(id, entries)
	known = PollisCompetitions.entries(id)
	numbers = entries === nothing ? Int.(known.entry) : [entry_number(id, entry; known) for entry in entries]
	where, parameters = conditions("entry" => numbers)
	submissions = query("SELECT entry, evaluation, symbol, decision, rank1, rank2, rank3, rank4, rank5 FROM $(table_sql(id, "submissions.parquet"))$(where) AND evaluation BETWEEN 1 AND 12", parameters)
	rounds = m6_prices(id)
	result = (; entry = Int16[], measure = String[], breakdown = String[], level = String[], value = Float64[])
	for number in numbers
		rows = findall(==(number), submissions.entry)
		isempty(rows) && continue
		team = m6_summary(rounds, m6_submitted(rounds, map(column -> column[rows], submissions)))
		append!(result.entry, fill(Int16(number), length(team.value)))
		append!(result.measure, team.measure); append!(result.breakdown, team.breakdown)
		append!(result.level, team.level); append!(result.value, team.value)
	end
	result
end
