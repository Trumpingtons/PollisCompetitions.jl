using Test
import PollisCompetitions as PC

@testset "PollisCompetitions" begin
	@testset "Catalogue" begin
		entries = PC.catalogue()
		@test [entry["id"] for entry in entries] == ["m1", "m3", "m4", "m5", "m6"]
		roles = Set(["series", "info", "train", "test", "calendar", "prices", "weights", "submissions", "entries", "scores", "forecasts"])
		for entry in entries, file in entry["files"]
			@test file["role"] in roles
			@test occursin(r"^[0-9a-f]{64}$", file["sha256"])
			@test startswith(file["url"], "https://")
		end
		@test count(file -> file["role"] == "forecasts", PC.competition("m4")["files"]) == PC.competition("m4")["entries"] == 61
		# M5: 24 benchmarks and the top 50 of Accuracy, 6 benchmarks and the top 50 of Uncertainty
		m5 = PC.files_of("m5", "forecasts")
		@test length(m5) == PC.competition("m5")["entries"] == 130
		@test [count(file -> file["forecasts"] == forecasts && file["kind"] == kind, m5) for forecasts in ("point", "quantiles") for kind in ("submission", "benchmark")] == [50, 24, 50, 6]
		@test sort([file["rank"] for file in m5 if file["kind"] == "submission" && file["forecasts"] == "point"]) == 1:50
		@test allunique(file["name"] for file in m5)
		@test_throws ErrorException PC.competition("m7")
	end

	@testset "Reading the files of the sources" begin
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

		@test PC.csv_fields("\"Y2\",\"1598\",\"1366\",") == ["Y2", "1598", "1366", ""]
		@test PC.has_value("7.5") && !PC.has_value("") && !PC.has_value("NA")
		@test PC.entry_name("005") == "5"
		@test PC.entry_name("Naive2") == "Naive2"

		write(path, "\"item_id\",\"dept_id\",\"cat_id\",\"store_id\",\"state_id\",\"d_1\",\"d_2\"\n\"FOODS_1_001\",\"FOODS_1\",\"FOODS\",\"CA_1\",\"CA\",3,0\n")
		@test PC.read_m5_series(path) == (; item = ["FOODS_1_001"], department = ["FOODS_1"], category = ["FOODS"], store = ["CA_1"], state = ["CA"])
		@test PC.m6_team("cd597d34 StanekF_STU (CERGE-EI)") == (; id = "cd597d34", name = "StanekF_STU (CERGE-EI)")
		@test PC.m6_team("0b1bfb9c\u00a0Team X") == (; id = "0b1bfb9c", name = "Team X")
		@test isequal(PC.m6_team("0b1bfb9c"), (; id = "0b1bfb9c", name = missing))
	end

	@testset "Filters" begin
		@test PC.conditions("frequency" => nothing) == ("", Any[])
		@test PC.conditions("frequency" => "Yearly", "series" => [1, 2]) == (" WHERE frequency = ? AND series IN (?, ?)", Any["Yearly", 1, 2])
	end

	# The competitions on this computer, downloaded with download(id), against the numbers their papers and files give
	downloaded(id) = PC.info(id) !== nothing
	@testset "M1 and M3" begin
		for (id, counts) in (("m1", Dict("Yearly" => 181, "Quarterly" => 203, "Monthly" => 617)),
				("m3", Dict("Yearly" => 645, "Quarterly" => 756, "Monthly" => 1428, "Other" => 174)))
			downloaded(id) || continue
			series = PC.series(id)
			@test Dict(frequency => count(==(frequency), series.frequency) for frequency in unique(series.frequency)) == counts
			test = PC.observations(id; series = 1, split = "test")
			@test length(test.t) == series.horizon[1]
		end
	end

	@testset "M4" begin
		if downloaded("m4")
			@test length(PC.series("m4").series) == 100000
			@test length(PC.series("m4"; frequency = "Hourly").series) == 414
			entries = PC.entries("m4")
			@test length(entries.entry) == 61
			@test entries.name[1] == "118" && entries.rank[1] == 1
			smyl = PC.published_scores("m4"; entry = 1, measure = "sMAPE", breakdown = "frequency")
			@test smyl.value[findfirst(==("Yearly"), smyl.level)] ≈ 13.176 atol = 0.0005
			@test PC.entry_number("m4", "118") == 1 && PC.entry_number("m4", 1) == 1
		end
	end

	@testset "M5" begin
		if downloaded("m5")
			# 3,049 items in 10 stores of 3 states, over 1,969 days, the last 28 to forecast
			hierarchy = PC.table("m5", "hierarchy")
			@test length(hierarchy.series) == 30490
			@test length.(unique.((hierarchy.item, hierarchy.department, hierarchy.category, hierarchy.store, hierarchy.state))) == (3049, 7, 3, 10, 3)
			@test PC.info("m5")["tables"]["observations"] == 30490 * 1969
			@test length(PC.observations("m5"; series = 1, split = "test").t) == 28
			@test length(PC.table("m5", "calendar").t) == 1969
			# The weights of the series of each of the 12 levels add up to 1
			weights = PC.table("m5", "weights")
			@test all(level -> isapprox(sum(weights.weight[weights.level .== level]), 1; atol = 1e-4), 1:12)
			@test length(weights.level) == 42840
			entries = PC.entries("m5")
			@test count(==("point"), entries.forecasts) == 74 && count(==("quantiles"), entries.forecasts) == 56
			@test_throws ErrorException PC.entry_number("m5", "Random_prediction")
		end
	end

	@testset "M6" begin
		if downloaded("m6")
			prices = PC.table("m6", "prices")
			@test length(unique(prices.symbol)) == 100
			entries = PC.entries("m6")
			benchmark = only(entries.entry[entries.kind .== "benchmark"])
			# Probabilities of 0.2 for each fifth score 0.16, whichever fifth the return falls in
			rps = PC.published_scores("m6"; entry = benchmark, measure = "RPS", breakdown = "month")
			@test all(value -> isapprox(value, 0.16; atol = 0.005), rps.value)
			submissions = PC.table("m6", "submissions"; entry = benchmark)
			@test all(==(0.2), submissions.rank1) && all(==(0.01), submissions.decision)
		end
	end
end
