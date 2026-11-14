"""A text for SQL: `text` between single quotes, those inside doubled."""
sql_text(text) = "'" * replace(string(text), "'" => "''") * "'"

"""
	with_database(f)

`f(db)` with a DuckDB database in memory, closed when `f` returns.
"""
function with_database(f)
	db = DuckDB.DB()
	try
		f(db)
	finally
		DBInterface.close!(db)
	end
end

"""
	TableWriter(db, name, columns)

A table `name` of the database `db`, created with `columns` (pairs of a name and an SQL type), to which batches of
rows are added by `add!` and which `write_parquet` writes to a Parquet file.
"""
struct TableWriter
	db::DuckDB.DB
	name::String
end

function TableWriter(db, name, columns)
	DBInterface.execute(db, "CREATE TABLE $(name) ($(join(["$(column) $(type)" for (column, type) in columns], ", ")))")
	TableWriter(db, name)
end

"""
	add!(writer, batch; constants = ())

The rows of `batch`, a table of columns (a NamedTuple of vectors), added to the table of `writer`, with the columns of
`constants` (pairs of a column and its value, the same for every row) after them.

DuckDB reads `batch` by calling Julia while it holds the lock of its connection. Were the garbage collector to run a
finalizer then, one closing a statement of the same connection would wait for that lock forever: the finalizers wait
until the batch is in.
"""
function add!(writer::TableWriter, batch; constants = ())
	isempty(first(batch)) && return writer
	GC.enable_finalizers(false)
	try
		DuckDB.register_table(writer.db, batch, "batch")
		try
			extra = join([", $(sql_text(value)) AS $(column)" for (column, value) in constants])
			DBInterface.execute(writer.db, "INSERT INTO $(writer.name) BY NAME SELECT *$(extra) FROM batch")
		finally
			DuckDB.unregister_table(writer.db, "batch")
		end
	finally
		GC.enable_finalizers(true)
	end
	writer
end

"""
	write_parquet(writer, path; order = "")

The table of `writer` written to the Parquet file `path`, compressed with ZSTD, its rows in the order of `order`
(columns for ORDER BY) when given. The file is written beside `path` first, then put in its place.
"""
function write_parquet(writer::TableWriter, path; order = "")
	mkpath(dirname(path))
	partial = path * ".part"
	sorted = isempty(order) ? "" : " ORDER BY $(order)"
	DBInterface.execute(writer.db, "COPY (SELECT * FROM $(writer.name)$(sorted)) TO $(sql_text(partial)) (FORMAT parquet, COMPRESSION zstd)")
	mv(partial, path; force = true)
end
