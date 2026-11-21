using Test
import DBInterface, Downloads, JSON, LinearAlgebra, Survival, Tables, TOML
import PollisCompetitions as PC
using PollisCompetitions.Benchmarks: BENCHMARKS, benchmarks, holt, is_seasonal

@testset "PollisCompetitions" begin
	@testset "Metadata" begin
		folder = mktempdir()
		write(joinpath(folder, "datasets.toml"), """
			[[datasets]]
			dataset_id = "guerry"
			dataset_name = "Guerry Moral Statistics"
			topic = "Socioeconomics"
			data_structure = "Cross-section"
			geometry = "Polygons"
			response_type = "Continuous"
			rows = 86
			features = 23
			delivery = "Built-in"

			  [[datasets.references]]
			  bibtex_key = "G1833a"
			  role = "Primary"
			""")
		write(joinpath(folder, "models.toml"), """
			[[models]]
			model_id = "ridge"
			model_name = "Ridge Regression"
			estimator_family = "Baseline"
			estimator_method = "Penalized linear model"
			package = "GLMNet"
			language = "Julia"
			""")
		write(joinpath(folder, "benchmarks.toml"), """
			[[runs]]
			run_id = "run_001"
			model_id = "ridge"
			dataset_id = "guerry"
			split_protocol = "5_fold_spatial"

			  [runs.scores]
			  RMSE = 4.12
			  MAE = 3.25
			""")
		db = PC.connect_db(; metadata = folder, builtin = folder)
		try
			query(sql) = Tables.columntable(DBInterface.execute(db, sql))
			@test (query("SELECT dataset_id, bibtex_key, role FROM dataset_references"),
				query("SELECT run_id, model_name, dataset_name, geometry, metric, score FROM model_comparisons ORDER BY metric")) ==
				((; dataset_id = ["guerry"], bibtex_key = ["G1833a"], role = ["Primary"]),
				(; run_id = ["run_001", "run_001"], model_name = ["Ridge Regression", "Ridge Regression"],
					dataset_name = ["Guerry Moral Statistics", "Guerry Moral Statistics"], geometry = ["Polygons", "Polygons"],
					metric = ["MAE", "RMSE"], score = [3.25, 4.12]))
		finally
			DBInterface.close!(db)
		end

		write(joinpath(folder, "datasets.toml"), "[[datasets]]\ndataset_id = \"x\"\ndataset_name = \"X\"\ntopic = \"General\"\ngeometry = \"Lines\"\n")
		@test_throws Exception PC.connect_db(; metadata = folder, builtin = folder)

		# The metadata of the package loads, and every reference is a work of PollisReferences: of the clone that
		# POLLIS_REFERENCES names, else of its main branch
		DBInterface.close!(PC.connect_db())
		file = haskey(ENV, "POLLIS_REFERENCES") ? joinpath(ENV["POLLIS_REFERENCES"], "data", "references.json") :
			Downloads.download("https://raw.githubusercontent.com/Trumpingtons/PollisReferences.jl/main/data/references.json")
		works = Set(work["key"] for work in JSON.parsefile(file)["references"])
		cited = vcat(PC.load_table("dataset_references").bibtex_key, PC.load_table("model_references").bibtex_key)
		@test filter(key -> !(key in works), cited) == String[]
	end

	@testset "Filters" begin
		@test PC.conditions("frequency" => nothing) == ("", Any[])
		@test PC.conditions("frequency" => "Yearly", "series" => [1, 2]) == (" WHERE frequency = ? AND series IN (?, ?)", Any["Yearly", 1, 2])
	end

	# A dataset of your own: one yearly series, 1, 2, 4 seen and 5, 7 to forecast, forecast 4, 6. Naive2 forecasts 4, 4
	# (a period of 1 is never seasonal). sMAPE: (200 / 9 + 200 / 13) / 2 = 2200 / 117, and Naive2's (200 / 9 + 600 / 11) / 2
	# = 3800 / 99. MASE: the mean absolute error, 1, over the mean absolute change of the values seen, (1 + 2) / 2, so
	# 2 / 3, and Naive2's 2 / (3 / 2) = 4 / 3. OWA: the mean of the two ratios to Naive2's.
	@testset "A dataset of your own" begin
		folder = mktempdir()
		PC.with_database() do db
			execute(sql) = PC.DuckDB.DBInterface.execute(db, sql)
			execute("""COPY (SELECT 1::INTEGER AS series, 'mine' AS competition, 'S1' AS name, 'yearly' AS frequency, 1::SMALLINT AS period,
				2::SMALLINT AS horizon, 'general' AS domain, '2020' AS start) TO '$(joinpath(folder, "series.parquet"))' (FORMAT parquet)""")
			execute("""COPY (SELECT 1::INTEGER AS series, t::SMALLINT AS t, v::DOUBLE AS value, s AS split
				FROM (VALUES (1, 1, 'train'), (2, 2, 'train'), (3, 4, 'train'), (4, 5, 'test'), (5, 7, 'test')) AS o(t, v, s))
				TO '$(joinpath(folder, "observations.parquet"))' (FORMAT parquet)""")
		end
		write(joinpath(folder, "dataset.toml"), "[[datasets]]\ndataset_id = \"mine\"\ndataset_name = \"My Dataset\"\nresponse_type = \"Continuous\"\n")
		@test PC.is_dataset(folder) && !PC.is_dataset("nn3") && !PC.is_dataset(mktempdir())
		@test (PC.competition(folder)["name"], PC.competition(folder)["response_type"]) == ("My Dataset", "Continuous")
		@test PC.series(folder).horizon == [2]
		scores = PC.score(folder, (; series = [1, 1], h = [1, 2], value = [4.0, 6.0]))
		total(measure) = only(scores.value[(scores.measure .== measure) .& (scores.breakdown .== "frequency") .& (scores.level .== "Total")])
		smape, mase = 2200 / 117, 2 / 3
		@test total("sMAPE") ≈ smape
		@test total("MASE") ≈ mase
		@test total("OWA") ≈ (smape / (3800 / 99) + mase / (4 / 3)) / 2
	end

	# Every built-in forecasting dataset: each series has as many values held out as its horizon, and scoring a benchmark
	# of every series gives the three measures in total
	@testset "Built-in forecasting datasets" begin
		ids = [id for id in readdir(PC.BUILTIN) if PC.competition(id)["format"] == "monash"]
		@test !isempty(ids)
		@testset "$(id)" for id in ids
			known = PC.series(id)
			held = PC.query("SELECT series, count(*) AS n FROM $(PC.table_sql(id, "observations.parquet")) WHERE split = 'test' GROUP BY series ORDER BY series")
			@test held.series == known.series && held.n == known.horizon
		end
		scores = PC.score(ids[1], PC.benchmarks(ids[1]; methods = ["Naive2"]))
		@test only(scores.value[(scores.measure .== "OWA") .& (scores.breakdown .== "frequency") .& (scores.level .== "Total")]) ≈ 1
	end

	# Every built-in tabular dataset: its response type is in the Dataset Catalog, Survival when info.toml names an event;
	# the folds and repeats of its splits are numbered from 1 to those info.toml gives; and in each repeat, no row is a
	# test row twice, and with cross-validation (more than one fold) every row of its data is a test row once, while a
	# single hold-out fold leaves some rows for training
	@testset "Built-in tabular datasets" begin
		ids = [id for id in readdir(PC.BUILTIN) if PC.competition(id)["format"] == "tabular"]
		@test !isempty(ids)
		@testset "$(id)" for id in ids
			fields = PC.info(id)
			kind = PC.competition(id)["response_type"]
			@test kind in ("Binary", "Multiclass", "Count", "Survival", "Continuous")
			@test (kind == "Survival") == haskey(fields, "event")
			rows = only(PC.query("SELECT count(*) AS n FROM $(PC.table_sql(id, "data.parquet"))").n)
			splits = PC.query("""SELECT repeat, count(*) AS n, count(DISTINCT row) AS distinct_rows, min(row) AS first_row, max(row) AS last_row,
				min(fold) AS first_fold, max(fold) AS last_fold FROM $(PC.table_sql(id, "splits.parquet")) GROUP BY repeat ORDER BY repeat""")
			@test splits.repeat == 1:fields["repeats"]
			@test all(splits.distinct_rows .== splits.n) && all(splits.first_row .>= 1) && all(splits.last_row .<= rows)
			@test fields["folds"] > 1 ? all(splits.n .== rows) : all(0 .< splits.n .< rows)
			@test all(splits.first_fold .== 1) && all(splits.last_fold .== fields["folds"])
		end
	end

	# The measures of the Low-Dimensional Survival Benchmark: Kaplan-Meier and Nelson-Aalen, which have nothing to tune and
	# nothing random, fitted by Survival.jl on the training rows of every split of the 34 survival datasets and scored by
	# the port of mlr3proba, give, as means over the splits, the scores the benchmark published for them in
	# benchmarks.toml. The training times are first tied as R's survfit ties them (time_fix), as the benchmark fitted
	# both with survfit.
	@testset "Survival measures" begin
		runs = Dict(run["run_id"] => run["scores"] for run in PC.metadata_entries(PC.METADATA, "benchmarks.toml", "runs"))
		ids = [id for id in readdir(PC.BUILTIN) if PC.competition(id)["response_type"] == "Survival"]
		@test length(ids) == 34
		@testset "$(id)" for id in ids
			fields = PC.info(id)
			data = PC.query("SELECT $(fields["target"]) AS time, $(fields["event"]) AS event FROM $(PC.table_sql(id, "data.parquet"))")
			splits = PC.query("SELECT row, repeat, fold FROM $(PC.table_sql(id, "splits.parquet"))")
			time, event = Float64.(data.time), Int.(data.event)
			for (model, curve) in (("survival_benchmark_km", (t, e) -> (f = Survival.fit(Survival.KaplanMeier, t, e); (f.events.time, f.survival))),
				("survival_benchmark_nel", (t, e) -> (f = Survival.fit(Survival.NelsonAalen, t, e); (f.events.time, exp.(-f.chaz)))))
				scores = [begin
					test = sort(splits.row[(splits.repeat .== repeat) .& (splits.fold .== fold)])
					train = setdiff(eachindex(time), test)
					times, survival = curve(PC.time_fix(time[train]), event[train])
					PC.survival_scores(time[train], event[train], time[test], event[test], times, Base.repeat(permutedims(survival), length(test)))
				end for repeat in 1:fields["repeats"] for fold in 1:fields["folds"]]
				published = runs["$(model).$(id)"]
				@test all(isapprox(sum(s[m] for s in scores) / length(scores), published[m]; rtol = 1e-9, atol = 1e-12) for m in PC.SURVIVAL_MEASURES)
			end
		end
	end

	# The measures of the tabular datasets against the values scikit-learn gives on fixed predictions, in
	# tabular_measures.toml (written by scripts/tabular_measures.py, which says how the predictions are made): every
	# built-in tabular dataset whose Response Type has a measure, on its first split. Ties in the scores of roc_auc and
	# probabilities of 0 in those of log_loss are among them.
	@testset "Tabular measures" begin
		expected = TOML.parsefile(joinpath(@__DIR__, "tabular_measures.toml"))
		ids = [id for id in readdir(PC.BUILTIN) if get(something(PC.info(id), Dict()), "format", nothing) == "tabular" &&
			haskey(PC.TABULAR_MEASURES, something(PC.competition(id)["response_type"], ""))]
		@test sort(collect(keys(expected))) == ids
		@testset "$(id)" for id in ids
			kind = PC.competition(id)["response_type"]
			target = PC.query("SELECT \"$(PC.info(id)["target"])\" AS y FROM $(PC.table_sql(id, "data.parquet"))").y
			splits = PC.query("SELECT row, repeat, fold FROM $(PC.table_sql(id, "splits.parquet"))")
			test = sort(splits.row[(splits.repeat .== 1) .& (splits.fold .== 1)])
			train = setdiff(eachindex(target), test)
			mine = if PC.TABULAR_MEASURES[kind] == "rmse"
				y = Float64.(target)
				mean = sum(y[train]) / length(train)
				Dict("mean" => PC.rmse(y[test], fill(mean, length(test))), "rows" => PC.rmse(y[test], [mean + r % 7 - 3 for r in test]))
			elseif PC.TABULAR_MEASURES[kind] == "roc_auc"
				classes = sort(unique(target))
				truth = target[test] .== classes[2]
				share = count(==(classes[2]), target[train]) / length(train)
				Dict("frequency" => PC.roc_auc(truth, fill(share, length(test))), "rows" => PC.roc_auc(truth, [(r % 10) / 10 for r in test]))
			else
				classes = sort(unique(target))
				k = length(classes)
				truth = [findfirst(==(y), classes) for y in target[test]]
				shares = [count(==(c), target[train]) / length(train) for c in classes]
				Dict("frequency" => PC.log_loss(truth, Base.repeat(permutedims(shares), length(test))),
					"rows" => PC.log_loss(truth, [Float64(r % k + 1 == c) for r in test, c in 1:k]))
			end
			@test expected[id]["response_type"] == kind
			@test all(isapprox(value, expected[id][name]; rtol = 1e-12) for (name, value) in mine) && length(mine) == length(expected[id]) - 1
		end
	end

	# What a run of Score Models on tabular datasets uses: the outer splits of every built-in tabular dataset, its
	# published runs, and the measures by Response Type
	@testset "Scoring tabular datasets" begin
		ids = [id for id in readdir(PC.BUILTIN) if get(something(PC.info(id), Dict()), "format", nothing) == "tabular"]
		@testset "$(id)" for id in ids
			fields = PC.info(id)
			rows = only(PC.query("SELECT count(*) AS n FROM $(PC.table_sql(id, "data.parquet"))").n)
			splits = PC.outer_splits(id)
			@test [(s.repeat, s.fold) for s in splits] == [(r, f) for r in 1:fields["repeats"] for f in 1:fields["folds"]]
			@test all(sort([s.train; s.test]) == 1:rows for s in splits)
		end
		runs = [run for run in PC.metadata_entries(PC.METADATA, "benchmarks.toml", "runs") if run["dataset_id"] in ids && run["run_id"] == "$(run["model_id"]).$(run["dataset_id"])"]
		published = PC.published_scores(ids)
		@test sort(collect(zip(published.dataset_id, published.model_id, published.metric, published.score))) ==
			sort([(run["dataset_id"], run["model_id"], metric, score) for run in runs for (metric, score) in run["scores"]])
		@test [PC.measure_loss(m, v) for (m, v) in (("rmse", 3), ("roc_auc", 0.75), ("alpha_calib", 0.8), ("alpha_calib", 1.25), ("isbs_erv", 0.1))] ≈ [3, -0.75, 0.2, 0.25, -0.1]
		@test PC.tabular_scores("Continuous", [1, 2, 3], [1, 2, 5]) == Dict("rmse" => sqrt(4 / 3))
		@test PC.tabular_scores("Binary", [true, false, true, false], [0.9, 0.2, 0.4, 0.4]) == Dict("roc_auc" => 0.875)
		@test only(values(PC.tabular_scores("Multiclass", [1, 3], [0.5 0.25 0.25; 0.2 0.3 0.5]))) ≈ log(2)
		@test_throws ErrorException PC.tabular_scores("Ordered", [1, 2], [1, 2])
	end

	# Cox's model, fitted by Survival.jl (Efron's ties, as R's coxph), on every outer split of the survival datasets,
	# scored by Harrell's C and Uno's C and compared with the benchmark's CPH means. The covariates are prepared as the
	# benchmark prepares them for CPH (mlr3pipelines 0.7.1 in its bl(): fixfactors, imputesample of factors,
	# collapsefactors at 5% and 5 levels, removeconstants), the factors of info.toml coded as R's model.matrix codes them
	# (a column per level after the first), and the columns coxph drops as collinear dropped. A dataset is compared when
	# all its splits can be, as the published scores are means over the splits. A split cannot be when:
	# - a test row has a level of a factor that no training row has: the benchmark imputes it at random;
	# - it is one of COX_DIFFERENT: the published score differs from ours, while R's coxph on the same training rows
	#   gives our value (checked on one of them) and the benchmark logged no error.
	@testset "Cox's model" begin
		COX_DIFFERENT = Dict("aids_id" => [9], "kidtran" => [15, 21], "liver" => [3, 5, 9], "ova" => [24, 30], "std" => [12], "tumor" => [8])
		runs = Dict(run["run_id"] => run["scores"] for run in PC.metadata_entries(PC.METADATA, "benchmarks.toml", "runs"))
		label(x::AbstractString) = String(x)
		label(x::Real) = isinteger(x) ? string(Int(x)) : string(x)
		# collapsefactors: with more than 5 levels, the levels of 5% or more of the training rows and the 5 most
		# frequent are kept, and the others merge into the last level kept
		function collapse(levels, counts)
			length(levels) <= 5 && return Dict(l => l for l in levels)
			order = sortperm(counts; rev = true, alg = MergeSort)
			keep = unique([[levels[k] for k in order if counts[k] / sum(counts) >= 0.05]; levels[order[1:5]]])
			Dict(l => (l in keep ? l : keep[end]) for l in levels)
		end
		compared = String[]
		@testset "$(id)" for id in [id for id in readdir(PC.BUILTIN) if PC.competition(id)["response_type"] == "Survival"]
			fields = PC.info(id)
			factors = get(fields, "factors", Dict{String, Any}())
			data = PC.query("SELECT * FROM $(PC.table_sql(id, "data.parquet"))")
			splits = PC.query("SELECT row, repeat, fold FROM $(PC.table_sql(id, "splits.parquet"))")
			time, event = Float64.(getproperty(data, Symbol(fields["target"]))), Int.(getproperty(data, Symbol(fields["event"])))
			features = [String(n) for n in keys(data) if !(String(n) in (fields["target"], fields["event"]))]
			scores, comparable = Dict{String, Float64}[], !haskey(COX_DIFFERENT, id)
			for repeat in 1:fields["repeats"], fold in 1:fields["folds"]
				test = sort(splits.row[(splits.repeat .== repeat) .& (splits.fold .== fold)])
				train = setdiff(eachindex(time), test)
				columns, test_columns = Vector{Float64}[], Vector{Float64}[]
				for n in features
					values = getproperty(data, Symbol(n))
					if haskey(factors, n)
						x = label.(values)
						present = [l for l in factors[n] if any(==(l), x[train])]
						all(v -> v in present, x[test]) || (comparable = false)
						merging = collapse(present, [count(==(l), x[train]) for l in present])
						for l in unique(merging[l] for l in present)[2:end]
							push!(columns, [merging[v] == l ? 1.0 : 0.0 for v in x[train]])
							push!(test_columns, [get(merging, v, "") == l ? 1.0 : 0.0 for v in x[test]])
						end
					else
						push!(columns, Float64.(values[train]))
						push!(test_columns, Float64.(values[test]))
					end
				end
				# removeconstants; then the columns coxph keeps, in order, by a pivoted QR with the intercept
				kept = [k for k in eachindex(columns) if length(unique(columns[k])) > 1]
				X, Xt = reduce(hcat, columns[kept]), reduce(hcat, test_columns[kept])
				F = LinearAlgebra.qr([ones(length(train)) X], LinearAlgebra.ColumnNorm())
				independent = sort(filter(>(1), F.p[1:LinearAlgebra.rank(F.R; rtol = 1e-12)])) .- 1
				X, Xt = X[:, independent], Xt[:, independent]
				# Survival.jl's search reaches its iteration limit on some splits as the covariates are and on others once
				# they are centred: the fit as they are, else centred, which leaves the ranking of the test rows unchanged
				y = Survival.EventTime.(time[train], event[train] .== 1)
				model = try
					Survival.coxph(X, y; tol = 1e-10)
				catch
					centre = sum(X; dims = 1) ./ size(X, 1)
					X, Xt = X .- centre, Xt .- centre
					Survival.coxph(X, y; tol = 1e-10)
				end
				crank = Xt * Survival.coef(model)
				push!(scores, Dict("harrell_c" => PC.concordance(time[test], event[test], crank, :I),
					"uno_c" => PC.concordance(time[test], event[test], crank, :G2; train_time = time[train], train_event = event[train])))
			end
			comparable || continue
			push!(compared, id)
			published = runs["survival_benchmark_cph.$(id)"]
			@test all(isapprox(sum(s[m] for s in scores) / length(scores), published[m]; rtol = 1e-9, atol = 1e-12) for m in ("harrell_c", "uno_c"))
		end
		@test length(compared) == 24
	end

	@testset "Monash archive files" begin
		folder = mktempdir()
		path = joinpath(folder, "small.tsf")
		write(path, """
			# A comment in Latin-1: \xe9
			@relation Small
			@attribute series_name string
			@attribute start_timestamp date
			@frequency quarterly
			@horizon 2
			@missing false
			@data
			T1:1990-01-01 00-00-00:1,2.5,3,4
			T2:1991-04-01 00-00-00:10,20,30
			""")
		tsf = PC.read_tsf(path)
		@test tsf.frequency == "quarterly"
		@test tsf.horizon == 2
		@test [row.name for row in tsf.rows] == ["T1", "T2"]
		@test tsf.rows[1].start == "1990-01-01 00-00-00"
		@test tsf.rows[1].values == [1.0, 2.5, 3.0, 4.0]
		write(path, "@relation Other\n@attribute series_name string\n@horizon 8\n@data\nT1:5,6\n")
		@test PC.read_tsf(path).rows[1].start === nothing
		write(path, "@relation Other\n@attribute series_name string\n@data\nT1:5,?\n")
		@test_throws ErrorException PC.read_tsf(path)
	end

	# Two series and the forecasts of the eight benchmarks published with them (Makridakis, Spiliotis and Assimakopoulos
	# 2020; Mcompetitions/M4-methods, Point Forecasts), to six decimals
	published = [
		(name = "Y1", period = 1,
			y = [5172.1, 5133.5, 5186.9, 5084.6, 5182.0, 5414.3, 5576.2, 5752.9, 5955.2, 6087.8, 6238.9, 6317.2, 6262.7, 6361.0,
				6427.4, 6654.9, 6835.4, 6925.5, 7073.5, 7144.0, 7230.6, 7349.6, 7339.2, 7250.8, 7294.6, 7393.9, 7560.9, 7651.4,
				7587.3, 7530.5, 7261.1],
			forecasts = (
				Naive = [7261.1, 7261.1, 7261.1, 7261.1, 7261.1, 7261.1],
				sNaive = [7261.1, 7261.1, 7261.1, 7261.1, 7261.1, 7261.1],
				Naive2 = [7261.1, 7261.1, 7261.1, 7261.1, 7261.1, 7261.1],
				SES = [7261.126945, 7261.126945, 7261.126945, 7261.126945, 7261.126945, 7261.126945],
				Holt = [7043.070295, 6825.018586, 6606.966877, 6388.915169, 6170.86346, 5952.811752],
				Damped = [7087.905815, 6929.106722, 6802.067444, 6700.43602, 6619.130878, 6554.086763],
				Theta = [7307.46351, 7353.795446, 7400.127381, 7446.459317, 7492.791252, 7539.123188],
				Com = [7130.701018, 7005.084084, 6890.053756, 6783.492711, 6683.707094, 6589.34182])),
		(name = "Q159", period = 4,
			y = [5805.0, 6228.0, 6225.0, 6646.0, 6467.0, 6846.0, 6115.0, 6929.0, 6032.0, 6340.0, 6071.0, 7711.0, 6067.0, 6414.0,
				6153.0, 7456.0, 6567.0, 6677.0, 6225.0, 7279.0, 6237.0, 6969.0, 6743.0],
			forecasts = (
				Naive = [6743.0, 6743.0, 6743.0, 6743.0, 6743.0, 6743.0, 6743.0, 6743.0],
				sNaive = [7279.0, 6237.0, 6969.0, 6743.0, 7279.0, 6237.0, 6969.0, 6743.0],
				Naive2 = [7848.355911, 6804.815535, 7145.697468, 6743.0, 7848.355911, 6804.815535, 7145.697468, 6743.0],
				SES = [7472.879026, 6479.263155, 6803.836796, 6420.404967, 7472.879026, 6479.263155, 6803.836796, 6420.404967],
				Holt = [7511.83568, 6533.175023, 6881.592988, 6513.731287, 7604.726769, 6613.71504, 6966.167595, 6593.539671],
				Damped = [7489.31116, 6509.488314, 6852.018783, 6481.077415, 7560.84172, 6570.267568, 6914.566247, 6538.91955],
				Theta = [7380.131533, 6410.804321, 6744.50421, 6376.264149, 7435.292638, 6458.631044, 6794.726776, 6423.65641],
				Com = [7491.341955, 6507.308831, 6845.816189, 6471.737889, 7546.149171, 6554.415254, 6894.856879, 6517.621396])),
	]

	@testset "Benchmarks" begin
		@testset "$(series.name)" for series in published
			horizon = length(series.forecasts.Naive)
			computed = benchmarks(series.y; series.period, horizon)
			@test keys(computed) == BENCHMARKS
			@testset "$(method)" for method in BENCHMARKS
				# each forecast within half a unit of the sixth decimal, to which the published ones are rounded
				@test all(abs.(getproperty(computed, method) .- getproperty(series.forecasts, method)) .<= 5e-7 + 1e-9)
			end
		end
		@test !is_seasonal(published[1].y, 1) && is_seasonal(published[2].y, 4)
		@test_throws ArgumentError holt(published[1].y[1:8], 6)
	end
end
