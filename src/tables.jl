"""
	query(sql, parameters = [])

The result of `sql`, run by DuckDB in memory with `parameters` for its `?`, as a table of columns (a NamedTuple of
vectors). The Parquet files of a competition are read with `read_parquet`, such as
`read_parquet('$(joinpath(HOME, "m4", "series.parquet"))')`.
"""
function query(sql, parameters = [])
	with_database() do db
		Tables.columntable(DBInterface.execute(db, sql, parameters))
	end
end

"""The Parquet file `name` of dataset `id`, whose data must be on this computer."""
function table_file(id, name)
	path = joinpath(folder(id), name)
	isfile(path) && return path
	competition(id)
	error("$(competition(id)["name"]) has no $(name).")
end

"""The table `name` of competition `id` for SQL: `read_parquet` of its file."""
table_sql(id, name) = "read_parquet($(sql_text(table_file(id, name))))"

"""
The conditions of a WHERE clause and their parameters, from pairs of an SQL expression and a value: a value `nothing`
adds no condition, a vector adds `IN`.
"""
function conditions(pairs...)
	clauses = String[]
	parameters = Any[]
	for (expression, value) in pairs
		value === nothing && continue
		if value isa AbstractVector
			isempty(value) && (push!(clauses, "false"); continue)
			push!(clauses, "$(expression) IN ($(join(fill("?", length(value)), ", ")))")
			append!(parameters, value)
		else
			push!(clauses, "$(expression) = ?")
			push!(parameters, value)
		end
	end
	(isempty(clauses) ? "" : " WHERE " * join(clauses, " AND "), parameters)
end

"""
	series(id; frequency = nothing, domain = nothing)

The series of competition `id`: series (a number), competition, name (as the source names it), frequency, period
(the seasonal period), horizon, domain and start (as the source gives it), filtered by frequency or domain when given
(a value or a vector of values).
"""
function series(id; frequency = nothing, domain = nothing)
	where, parameters = conditions("frequency" => frequency, "domain" => domain)
	query("SELECT * FROM $(table_sql(id, "series.parquet"))$(where) ORDER BY series", parameters)
end

"""
	observations(id; series = nothing, frequency = nothing, split = nothing)

The values of the series of competition `id`: series, t (from 1), value, and split, "train" for the values the
forecasters saw and "test" for those their forecasts were scored on; filtered by series (a number or a vector of
numbers), frequency or split when given.
"""
function observations(id; series = nothing, frequency = nothing, split = nothing)
	where, parameters = conditions("o.series" => series, "s.frequency" => frequency, "o.split" => split)
	query("SELECT o.* FROM $(table_sql(id, "observations.parquet")) o JOIN $(table_sql(id, "series.parquet")) s USING (series)$(where) ORDER BY o.series, o.t", parameters)
end

"""
	entries(id; kind = nothing)

The entries of competition `id` whose forecasts are published: entry (a number), competition, name, kind
(submission, benchmark or standard), method, team, affiliation, rank and forecasts (point); filtered by kind when given.
"""
function entries(id; kind = nothing)
	where, parameters = conditions("kind" => kind)
	query("SELECT * FROM $(table_sql(id, "entries.parquet"))$(where) ORDER BY entry", parameters)
end

"""
	forecasts(id; entry, series = nothing, frequency = nothing, level = nothing, quantile = nothing)

The forecasts of an entry of competition `id`, given by its number or its name in `entries(id)` (such as "118" or
"Theta"), which must be on this computer. Point forecasts: entry, series, h (the step ahead, from 1)
and value, filtered by series or frequency when given. The quantile forecasts of M5 Uncertainty: entry, level (1 to
12), agg_level_1 and agg_level_2 (the names of the series in `weights.parquet`), quantile, h and value, filtered by
level or quantile when given.
"""
function forecasts(id; entry, series = nothing, frequency = nothing, level = nothing, quantile = nothing)
	number = entry_number(id, entry)
	file = table_sql(id, joinpath("forecasts", "$(number).parquet"))
	if only(query("SELECT forecasts FROM $(table_sql(id, "entries.parquet")) WHERE entry = ?", [number]).forecasts) == "quantiles"
		series === nothing && frequency === nothing || error("The quantile forecasts of M5 are of the series of its 12 levels: filter them by level, not by series or frequency.")
		where, parameters = conditions("level" => level, "quantile" => quantile)
		return query("SELECT * FROM $(file)$(where) ORDER BY level, agg_level_1, agg_level_2, quantile, h", parameters)
	end
	level === nothing && quantile === nothing || error("The forecasts of entry $(entry) are point forecasts: filter them by series or frequency.")
	where, parameters = conditions("f.series" => series, "s.frequency" => frequency)
	query("SELECT f.* FROM $(file) f JOIN $(table_sql(id, "series.parquet")) s USING (series)$(where) ORDER BY f.series, f.h", parameters)
end

"""
	published_scores(id; measure = nothing, breakdown = nothing, entry = nothing)

The scores the organisers of competition `id` published for its entries: entry, measure (such as sMAPE, MASE, OWA),
breakdown (such as frequency or domain), level (such as Yearly, Macro or Total) and value; filtered by measure,
breakdown or entry (its number or its name) when given.
"""
function published_scores(id; measure = nothing, breakdown = nothing, entry = nothing)
	number = entry === nothing ? nothing : entry_number(id, entry)
	where, parameters = conditions("measure" => measure, "breakdown" => breakdown, "entry" => number)
	query("SELECT * FROM $(table_sql(id, "published_scores.parquet"))$(where) ORDER BY entry, breakdown, measure, level", parameters)
end

"""
	tables(id)

The names of the tables of competition `id` on this computer, such as "series", "observations" and "entries", which
`table` reads; the forecasts of each entry are read by `forecasts`.
"""
function tables(id)
	table_file(id, "info.toml")
	sort([splitext(name)[1] for name in readdir(folder(id)) if endswith(name, ".parquet")])
end

"""
	table(id, name; filters...)

The table `name` of competition `id`, one of `tables(id)`, such as `table("m5", "calendar")` or `table("m6",
"submissions"; entry = 1, evaluation = 3)`: each filter, a column and a value (or a vector of values), keeps the rows
that have it.
"""
function table(id, name; filters...)
	name in tables(id) || error("$(competition(id)["name"]) has no table $(name): one of $(join(tables(id), ", ")).")
	columns = query("DESCRIBE SELECT * FROM $(table_sql(id, "$(name).parquet"))").column_name
	unknown = setdiff(string.(keys(filters)), columns)
	isempty(unknown) || error("The table $(name) of $(competition(id)["name"]) has no column $(join(unknown, ", ")).")
	where, parameters = conditions((string(column) => value for (column, value) in filters)...)
	query("SELECT * FROM $(table_sql(id, "$(name).parquet"))$(where)", parameters)
end
