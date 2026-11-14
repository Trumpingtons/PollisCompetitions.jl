"""The first day of M5, d_1 of its sales files."""
const M5_START = "2011-01-29"

"""The columns that name a series in the sales files of M5, before its daily sales d_1, d_2 and so on."""
const M5_ID_COLUMNS = ["item_id", "dept_id", "cat_id", "store_id", "state_id"]

"""
The columns of `hierarchy.parquet` of M5: a series, and the item, department, category, store and state it sells,
the levels by which M5 adds its series up.
"""
const M5_HIERARCHY_COLUMNS = ["series" => "INTEGER", "item" => "VARCHAR", "department" => "VARCHAR", "category" => "VARCHAR",
	"store" => "VARCHAR", "state" => "VARCHAR"]

"""
The columns of the files `forecasts/<entry>.parquet` of an entry of M5 Uncertainty: an entry, the series it forecast
by its level (1 to 12) and the two names that `weights.parquet` gives it (such as CA and FOODS_1), a quantile, the
step ahead from 1, and the forecast.
"""
const QUANTILE_FORECAST_COLUMNS = ["entry", "level", "agg_level_1", "agg_level_2", "quantile", "h", "value"]

"""
	read_m5_series(path)

The series of a sales file of M5, one a line in its order: `(; item, department, category, store, state)`.
"""
function read_m5_series(path)
	lines = eachline(path)
	header = strip.(split(first(lines), ','; limit = 6)[1:5], '"')
	header == M5_ID_COLUMNS || error("$(basename(path)) does not start with the columns $(join(M5_ID_COLUMNS, ", ")).")
	series = (; item = String[], department = String[], category = String[], store = String[], state = String[])
	for line in lines
		isempty(strip(line)) && continue
		fields = strip.(split(line, ','; limit = 6)[1:5], '"')
		push!(series.item, fields[1]); push!(series.department, fields[2]); push!(series.category, fields[3])
		push!(series.store, fields[4]); push!(series.state, fields[5])
	end
	series
end

"""The days of a sales file of M5: the numbers of its columns d_1, d_2 and so on, in their order."""
function m5_days(db, csv)
	names = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM $(csv)")]
	names[1:5] == M5_ID_COLUMNS || error("A sales file of M5 does not start with the columns $(join(M5_ID_COLUMNS, ", ")).")
	all(name -> occursin(r"^d_[0-9]+$", name), names[6:end]) || error("A sales file of M5 has columns other than d_1, d_2 and so on.")
	[parse(Int, name[3:end]) for name in names[6:end]]
end

"""The values of one SQL query, as a NamedTuple of its one row."""
only_row(db, sql) = only(Tables.rowtable(DBInterface.execute(db, sql)))

"""
The benchmarks of M5 Accuracy that `Scores and Ranks.xlsx` names otherwise than their files of forecasts: the files
of the organisers' errors give their scores under the names of the files, the same scores.
"""
const M5_SHEET_NAMES = Dict("CRO" => "Croston", "optCRO" => "optCroston", "MLP" => "MLP_l", "RF" => "RF_l", "gMLP" => "MLP_g", "gRF" => "RF_g")

"""
	read_m5_scores(db, path, numbers)

The published scores of M5 from `Scores and Ranks.xlsx`: `(; entry, measure, breakdown, level, value)`. The sheets of
Accuracy give the WRMSSE of the point forecasts by level (1 to 12, and Total, their average); those of Uncertainty
the WSPL of the quantile forecasts by level and by quantile, and the coverage rate of each quantile. A sheet holds one
table or more, one under the other: each starts with a row naming the measure over its columns (after Team or
Benchmark), then a row of the levels (L1 to L12 and Avg) or of the quantiles; the ranks beside them are left out. An
entry is named as in `numbers`, (name, forecasts) => entry, its forecasts "point" in the sheets of Accuracy and
"quantiles" in those of Uncertainty.
"""
function read_m5_scores(db, path, numbers)
	scores = (; entry = Int16[], measure = String[], breakdown = String[], level = String[], value = Float64[])
	sheets = (("Accuracy-Benchmarks (AL)", "point"), ("Accuracy-Top50 (AL)", "point"), ("Uncertainty-Benchmarks", "quantiles"),
		("Uncertainty-Top50 (AL)", "quantiles"), ("Uncertainty-Top50 (CL)", "quantiles"), ("Uncertainty-Top50 (CR)", "quantiles"))
	for (sheet, forecasts) in sheets
		rows = excel_rows(db, path, sheet)
		rows[1][1] in ("Team", "Benchmark") || error("The sheet $(sheet) of Scores and Ranks.xlsx does not start with Team or Benchmark.")
		measures, levels, breakdown = String[], Union{Missing, String}[], ""
		index = 1
		while index <= length(rows)
			row = rows[index]
			if row[1] in ("Team", "Benchmark")
				measures = String[]
				current = ""
				for value in row[2:end]
					value === missing || isempty(value) || (current = value)
					push!(measures, current)
				end
				labels = rows[index + 1][2:end]
				breakdown = any(label -> label !== missing && startswith(label, "L"), labels) ? "level" : "quantile"
				levels = map(labels) do label
					label === missing && return missing
					label == "Avg" && return "Total"
					startswith(label, "L") && return String(label[2:end])
					# A quantile, which Excel writes as it keeps it, such as 5.0000000000000001E-3
					string(round(parse(Float64, label); digits = 3))
				end
				index += 2
				continue
			end
			index += 1
			row[1] === missing && continue
			name = get(M5_SHEET_NAMES, row[1], row[1])
			entry = get(numbers, (name, forecasts), nothing)
			entry === nothing && error("The sheet $(sheet) of Scores and Ranks.xlsx scores $(row[1]), which is not an entry of M5.")
			for (column, value) in enumerate(row[2:end])
				(measures[column] == "Rank" || levels[column] === missing || value === missing || isempty(value)) && continue
				push!(scores.entry, entry); push!(scores.measure, measures[column]); push!(scores.breakdown, breakdown)
				push!(scores.level, levels[column]); push!(scores.value, parse(Float64, value))
			end
		end
	end
	scores
end

"""
	convert_m5(id, source, target; progress)

M5 from the files of its organisers, in its evaluation phase (that of the private leaderboard): `series.parquet`
(the 30,490 series of an item in a store, named as their forecasts name them, their domain the category) and
`hierarchy.parquet` from the sales files; `observations.parquet` from `sales_train_evaluation.csv` (train, days 1 to
1941) and `sales_test_evaluation.csv` (test, days 1942 to 1969); `calendar.parquet` (t, the day, then the columns of
`calendar.csv`), `prices.parquet` (series, wm_yr_wk, price) from `sell_prices.csv`, `weights.parquet` (level,
agg_level_1, agg_level_2, dollar_sales, weight) from `weights_evaluation.csv`; `entries.parquet` from the catalogue,
and `published_scores.parquet` from `Scores and Ranks.xlsx`.
"""
function convert_m5(id, source, target; progress = (done, total) -> nothing)
	path(role) = fetch_file(only(files_of(id, role)), source)
	train, test = path("train"), path("test")
	calendar, prices, weights, scores = path("calendar"), path("prices"), path("weights"), path("scores")
	total = 7
	with_database() do db
		# The sort of 60 million values may need more than the memory DuckDB allows itself
		DBInterface.execute(db, "SET temp_directory = $(sql_text(joinpath(source, "duckdb")))")
		known = read_m5_series(train)
		read_m5_series(test) == known || error("sales_test_evaluation.csv does not hold the series of sales_train_evaluation.csv in their order.")
		names = [item * "_" * store for (item, store) in zip(known.item, known.store)]
		allunique(names) || error("sales_train_evaluation.csv holds an item in a store twice.")
		number = Int32.(eachindex(names))
		writer = TableWriter(db, "series", SERIES_COLUMNS)
		add!(writer, (; series = number, name = names, domain = known.category);
			constants = ("competition" => id, "frequency" => "Daily", "period" => 7, "horizon" => 28, "start" => M5_START))
		write_parquet(writer, joinpath(target, "series.parquet"); order = "series")
		writer = TableWriter(db, "hierarchy", M5_HIERARCHY_COLUMNS)
		add!(writer, (; series = number, known...))
		write_parquet(writer, joinpath(target, "hierarchy.parquet"); order = "series")
		progress(1, total)

		writer = TableWriter(db, "observations", OBSERVATION_COLUMNS)
		days = 0
		for (file, split) in ((train, "train"), (test, "test"))
			csv = "read_csv($(sql_text(file)), header = true)"
			range = m5_days(db, csv)
			range == days .+ (1:length(range)) || error("$(basename(file)) does not hold the days $(days + 1) to $(days + length(range)) in their order.")
			days += length(range)
			DBInterface.execute(db, """INSERT INTO observations SELECT h.series, CAST(substr(u.day, 3) AS SMALLINT) AS t, CAST(u.value AS DOUBLE) AS value,
				'$(split)' AS split FROM (UNPIVOT (SELECT * EXCLUDE (dept_id, cat_id, state_id) FROM $(csv)) ON COLUMNS('^d_') INTO NAME day VALUE value) u
				JOIN hierarchy h ON h.item = u.item_id AND h.store = u.store_id""")
			progress(1 + (split == "train" ? 1 : 2), total)
		end
		counts = only_row(db, "SELECT count(*) AS rows, count(*) FILTER (WHERE split = 'test') AS test FROM observations")
		counts.rows == days * length(names) && counts.test == 28 * length(names) ||
			error("The sales files of M5 give $(counts.rows) values, not $(days) days of $(length(names)) series, or the test file not 28 days of each.")
		write_parquet(writer, joinpath(target, "observations.parquet"); order = "series, t")
		DBInterface.execute(db, "DROP TABLE observations")

		csv = "read_csv($(sql_text(calendar)), header = true, nullstr = 'NA')"
		header = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM $(csv)")]
		header[1:2] == ["date", "wm_yr_wk"] || error("calendar.csv does not start with the columns date and wm_yr_wk.")
		dates = only_row(db, "SELECT count(*) AS days, count(DISTINCT date) AS distinct_days, min(date) AS first, max(date) - min(date) + 1 AS span FROM $(csv)")
		dates.days == dates.distinct_days == dates.span == days && string(dates.first) == M5_START ||
			error("calendar.csv does not give the $(days) days of M5 from $(M5_START), one a row.")
		copy_parquet(db, "SELECT CAST(date - DATE '$(M5_START)' + 1 AS SMALLINT) AS t, * FROM $(csv)", joinpath(target, "calendar.parquet"); order = "t")
		progress(4, total)

		csv = "read_csv($(sql_text(prices)), header = true)"
		header = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM $(csv)")]
		header == ["store_id", "item_id", "wm_yr_wk", "sell_price"] || error("sell_prices.csv has the columns $(join(header, ", ")), not those of M5.")
		select = "SELECT h.series, p.wm_yr_wk, CAST(p.sell_price AS DOUBLE) AS price FROM $(csv) p JOIN hierarchy h ON h.item = p.item_id AND h.store = p.store_id"
		only_row(db, "SELECT count(*) AS rows FROM ($(select))").rows == only_row(db, "SELECT count(*) AS rows FROM $(csv)").rows ||
			error("sell_prices.csv gives prices of items in stores that are not series of M5.")
		copy_parquet(db, select, joinpath(target, "prices.parquet"); order = "series, wm_yr_wk")
		progress(5, total)

		csv = "read_csv($(sql_text(weights)), header = true, all_varchar = true)"
		header = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM $(csv)")]
		header == ["Level_id", "Agg_Level_1", "Agg_Level_2", "Dollar_Sales", "weight"] || error("weights_evaluation.csv has the columns $(join(header, ", ")), not those of M5.")
		select = """SELECT CAST(regexp_extract(Level_id, '^Level([0-9]+)\$', 1) AS SMALLINT) AS level, Agg_Level_1 AS agg_level_1, Agg_Level_2 AS agg_level_2,
			CAST(Dollar_Sales AS DOUBLE) AS dollar_sales, CAST(weight AS DOUBLE) AS weight FROM $(csv)"""
		levels = only_row(db, "SELECT count(*) AS rows, count(DISTINCT level) AS levels, count(*) FILTER (WHERE level = 12) AS bottom FROM ($(select))")
		levels.rows == 42840 && levels.levels == 12 && levels.bottom == length(names) ||
			error("weights_evaluation.csv does not give the 42,840 series of the 12 levels of M5.")
		copy_parquet(db, select, joinpath(target, "weights.parquet"); order = "level, agg_level_1, agg_level_2")
		progress(6, total)

		files = files_of(id, "forecasts")
		entries = (; entry = Int16.(eachindex(files)), name = [file["entry"] for file in files], kind = [file["kind"] for file in files],
			team = [file["kind"] == "submission" ? file["entry"] : missing for file in files],
			rank = Union{Missing, Int16}[get(file, "rank", missing) for file in files], forecasts = [file["forecasts"] for file in files])
		writer = TableWriter(db, "entries", ENTRY_COLUMNS)
		add!(writer, entries; constants = ("competition" => id,))
		write_parquet(writer, joinpath(target, "entries.parquet"); order = "entry")
		published = read_m5_scores(db, scores, Dict(zip(zip(entries.name, entries.forecasts), entries.entry)))
		writer = TableWriter(db, "published_scores", SCORE_COLUMNS)
		add!(writer, published)
		write_parquet(writer, joinpath(target, "published_scores.parquet"); order = "entry, breakdown, measure, level")
		progress(7, total)
	end
	rm(joinpath(source, "duckdb"); recursive = true, force = true)
end

"""
	convert_m5_forecasts(id, file, entry, source, target)

The forecasts of an entry of M5, `file` of the catalogue (a CSV file: a row for each series id, then its forecasts F1
to F28), written to `forecasts/<entry>.parquet` in `target`. Only the rows of the evaluation phase are kept, their id
ending in `_evaluation`. A point forecast of M5 Accuracy is of a series of `series.parquet`: `(; entry, series, h,
value)`. A forecast of M5 Uncertainty is of a quantile of any of the 42,840 series of `weights.parquet`, its id
the two names of the series, the quantile and the phase, such as `CA_FOODS_1_0.995_evaluation`: `(; entry, level,
agg_level_1, agg_level_2, quantile, h, value)`. Answers the number of series given every forecast of their horizon.
"""
function convert_m5_forecasts(id, file, entry, source, target)
	path = fetch_file(file, source)
	result = joinpath(target, "forecasts", "$(entry).parquet")
	complete = with_database() do db
		csv = "read_csv($(sql_text(path)), header = true, all_varchar = true)"
		header = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM $(csv)")]
		header == ["id"; ["F$(h)" for h in 1:28]] || error("$(file["name"]) does not have the columns id and F1 to F28.")
		long = "UNPIVOT (SELECT * FROM $(csv) WHERE id LIKE '%\\_evaluation' ESCAPE '\\') ON COLUMNS('^F') INTO NAME step VALUE text"
		step = "CAST(substr(u.step, 2) AS SMALLINT) AS h, CAST(u.text AS DOUBLE) AS value"
		if file["forecasts"] == "point"
			known = "read_parquet($(sql_text(joinpath(target, "series.parquet"))))"
			select = "SELECT $(entry)::SMALLINT AS entry, s.series, $(step) FROM ($(long)) u JOIN $(known) s ON s.name || '_evaluation' = u.id"
			kept = "(SELECT * FROM $(csv) WHERE id LIKE '%\\_evaluation' ESCAPE '\\')"
			read = only_row(db, "SELECT count(*) AS rows, count(DISTINCT id) AS ids FROM $(kept)")
			joined = only_row(db, "SELECT count(DISTINCT series) AS series FROM ($(select))").series
			read.rows == read.ids == joined || error("$(file["name"]) gives forecasts of $(read.rows - joined) series that are not series of M5, or of a series twice.")
			copy_parquet(db, select, result; order = "series, h")
			only_row(db, "SELECT count(*) AS complete FROM (SELECT series FROM read_parquet($(sql_text(result))) WHERE value IS NOT NULL GROUP BY series HAVING count(*) = 28)").complete
		elseif file["forecasts"] == "quantiles"
			known = "read_parquet($(sql_text(joinpath(target, "weights.parquet"))))"
			parts = "regexp_extract(u.id, '^(.*)_([0-9.]+)_evaluation\$', ['key', 'quantile'])"
			select = """SELECT $(entry)::SMALLINT AS entry, w.level, w.agg_level_1, w.agg_level_2, CAST(p.parts.quantile AS DOUBLE) AS quantile, p.h, p.value
				FROM (SELECT $(parts) AS parts, $(step) FROM ($(long)) u) p JOIN $(known) w ON w.agg_level_1 || '_' || w.agg_level_2 = p.parts.key"""
			read = only_row(db, "SELECT count(*) AS rows, count(DISTINCT id) AS ids FROM $(csv) WHERE id LIKE '%\\_evaluation' ESCAPE '\\'")
			joined = only_row(db, "SELECT count(*) AS rows FROM ($(select))").rows
			read.rows == read.ids && joined == 28 * read.rows || error("$(file["name"]) gives forecasts of series that are not series of M5, or of a quantile of a series twice.")
			copy_parquet(db, select, result; order = "level, agg_level_1, agg_level_2, quantile, h")
			only_row(db, """SELECT count(*) AS complete FROM (SELECT level, agg_level_1, agg_level_2 FROM read_parquet($(sql_text(result)))
				WHERE value IS NOT NULL GROUP BY ALL HAVING count(*) = 28 * 9)""").complete
		else
			error("$(file["name"]) gives forecasts $(file["forecasts"]), which PollisCompetitions does not read.")
		end
	end
	complete
end
