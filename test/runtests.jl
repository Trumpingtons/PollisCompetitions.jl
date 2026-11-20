using Test
import DBInterface, Downloads, JSON, Tables
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
		write(joinpath(folder, "dataset.toml"), "[[datasets]]\ndataset_id = \"mine\"\ndataset_name = \"My Dataset\"\n")
		@test PC.is_dataset(folder) && !PC.is_dataset("nn3") && !PC.is_dataset(mktempdir())
		@test PC.competition(folder)["name"] == "My Dataset"
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
