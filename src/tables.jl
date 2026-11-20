"""
	query(sql, parameters = [])

The result of `sql`, run by DuckDB in memory with `parameters` for its `?`, as a table of columns (a NamedTuple of
vectors). The Parquet files of a dataset are read with `read_parquet` of their paths, which `folder(id)` gives.
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

"""The table `name` of dataset `id` for SQL: `read_parquet` of its file."""
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

The series of dataset `id`: series (a number), competition, name (as the source names it), frequency, period
(the seasonal period), horizon, domain and start (as the source gives it), filtered by frequency or domain when given
(a value or a vector of values).
"""
function series(id; frequency = nothing, domain = nothing)
	where, parameters = conditions("frequency" => frequency, "domain" => domain)
	query("SELECT * FROM $(table_sql(id, "series.parquet"))$(where) ORDER BY series", parameters)
end

"""
	observations(id; series = nothing, frequency = nothing, split = nothing)

The values of the series of dataset `id`: series, t (from 1), value, and split, "train" for the values the
forecasters saw and "test" for those their forecasts were scored on; filtered by series (a number or a vector of
numbers), frequency or split when given.
"""
function observations(id; series = nothing, frequency = nothing, split = nothing)
	where, parameters = conditions("o.series" => series, "s.frequency" => frequency, "o.split" => split)
	query("SELECT o.* FROM $(table_sql(id, "observations.parquet")) o JOIN $(table_sql(id, "series.parquet")) s USING (series)$(where) ORDER BY o.series, o.t", parameters)
end

"""
	tables(id)

The names of the tables of dataset `id` on this computer, such as "series" and "observations", or "data" and
"splits", which `table` reads.
"""
function tables(id)
	table_file(id, "info.toml")
	sort([splitext(name)[1] for name in readdir(folder(id)) if endswith(name, ".parquet")])
end

"""
	table(id, name; filters...)

The table `name` of dataset `id`, one of `tables(id)`, such as `table("heloc", "splits"; repeat = 1, fold = 2)`: each
filter, a column and a value (or a vector of values), keeps the rows that have it.
"""
function table(id, name; filters...)
	name in tables(id) || error("$(competition(id)["name"]) has no table $(name): one of $(join(tables(id), ", ")).")
	columns = query("DESCRIBE SELECT * FROM $(table_sql(id, "$(name).parquet"))").column_name
	unknown = setdiff(string.(keys(filters)), columns)
	isempty(unknown) || error("The table $(name) of $(competition(id)["name"]) has no column $(join(unknown, ", ")).")
	where, parameters = conditions((string(column) => value for (column, value) in filters)...)
	query("SELECT * FROM $(table_sql(id, "$(name).parquet"))$(where)", parameters)
end
