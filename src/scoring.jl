"""
Which value of each measure of the tabular and survival datasets is best: "lower", "higher", or "one" for
alpha-calibration, the ratio of observed to expected events, which is best at 1.
"""
const MEASURE_BEST = Dict("rmse" => "lower", "roc_auc" => "higher", "log_loss" => "lower",
	"harrell_c" => "higher", "uno_c" => "higher", "isbs" => "lower", "isbs_erv" => "higher", "isll" => "lower",
	"isll_erv" => "higher", "dcalib" => "lower", "alpha_calib" => "one")

"""
	measure_loss(measure, value)

`value` of `measure` as a number of which lower is better, to rank scores by: the value when lower is better, minus
the value when higher is better, and its distance from 1 for alpha-calibration.
"""
function measure_loss(measure, value)
	best = get(MEASURE_BEST, measure, nothing)
	best === nothing && error("No measure $(measure): one of $(join(sort(collect(keys(MEASURE_BEST))), ", ")).")
	best == "lower" ? Float64(value) : best == "higher" ? -Float64(value) : abs(Float64(value) - 1)
end

"""
	outer_splits(id)

The outer splits of the tabular dataset `id`, in the order of their repeats and folds: for each, its repeat, its fold,
its training rows and its test rows, numbered from 1 as the rows of its table data. The test rows are those
splits.parquet gives; the training rows are the others.
"""
function outer_splits(id)
	fields = competition(id)
	fields["format"] == "tabular" || error("$(fields["name"]) is not a tabular dataset.")
	rows = only(query("SELECT count(*) AS n FROM $(table_sql(id, "data.parquet"))").n)
	splits = query("SELECT row, repeat, fold FROM $(table_sql(id, "splits.parquet")) ORDER BY repeat, fold, row")
	found = NamedTuple{(:repeat, :fold, :train, :test), Tuple{Int, Int, Vector{Int}, Vector{Int}}}[]
	for (repeat, fold) in unique(zip(splits.repeat, splits.fold))
		test = Int.(splits.row[(splits.repeat .== repeat) .& (splits.fold .== fold)])
		push!(found, (; repeat = Int(repeat), fold = Int(fold), train = setdiff(1:rows, test), test))
	end
	found
end

"""
	tabular_scores(response_type, truth, prediction)

The measure of the Response Type `response_type` (TABULAR_MEASURES) of `prediction` against `truth`, as a Dict of the
measure and its value: for Continuous and Count, `truth` and `prediction` are numbers; for Binary, `truth` is true for
the rows of the second class and `prediction` their probability of it; for Multiclass, `truth` is the class of each
row, as its column of `prediction`, a matrix with a row per row and a column per class.
"""
function tabular_scores(response_type, truth, prediction)
	measure = get(TABULAR_MEASURES, response_type, nothing)
	measure === nothing && error("No measure scores the Response Type $(something(response_type, "(none)")) yet.")
	value = measure == "rmse" ? rmse(truth, prediction) : measure == "roc_auc" ? roc_auc(truth, prediction) : log_loss(truth, prediction)
	Dict(measure => value)
end

"""
	published_scores(ids)

The published runs of models on the whole of each dataset of `ids` (an id, or a vector of them), from the Benchmarks:
dataset_id, model_id, model_name, metric and score, a row per run and metric, ordered by dataset, model and
metric. The database is opened once, so a run on several datasets asks for them all together.
"""
function published_scores(ids)
	wanted = ids isa AbstractString ? [ids] : collect(String, ids)
	db = connect_db()
	try
		DBInterface.execute(db, "CREATE TEMP TABLE wanted AS SELECT unnest(?::VARCHAR[]) AS dataset_id", [wanted])
		Tables.columntable(DBInterface.execute(db, """SELECT b.dataset_id, b.model_id, m.model_name, b.metric, b.score
			FROM benchmarks b JOIN wanted USING (dataset_id) JOIN model_catalog m USING (model_id)
			WHERE b.run_id = b.model_id || '.' || b.dataset_id ORDER BY b.dataset_id, b.model_id, b.metric"""))
	finally
		DBInterface.close!(db)
	end
end
