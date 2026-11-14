using Test
import PollisCompetitions as PC

@testset "PollisCompetitions" begin
	@testset "Catalogue" begin
		entries = PC.catalogue()
		@test [entry["id"] for entry in entries] == ["m1", "m3", "m4"]
		roles = Set(["series", "info", "train", "test", "entries", "scores", "forecasts"])
		for entry in entries, file in entry["files"]
			@test file["role"] in roles
			@test occursin(r"^[0-9a-f]{64}$", file["sha256"])
			@test startswith(file["url"], "https://")
		end
		@test count(file -> file["role"] == "forecasts", PC.competition("m4")["files"]) == PC.competition("m4")["entries"] == 61
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
		end
	end
end
