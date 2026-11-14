"""The columns of `prices.parquet` of M6: an asset, a day, and its adjusted close price."""
const M6_PRICE_COLUMNS = "symbol, CAST(strptime(date, '%Y/%m/%d') AS DATE) AS date, CAST(price AS DOUBLE) AS price"

"""
The columns of `submissions.parquet` of M6: an entry (a team), the round it submitted in and the round its submission
was evaluated in (0 for the trial run, then 1 to 12), an asset, the weight invested in it (the decision), the
probabilities that its return ranks in each fifth of the 100 assets, from the lowest (rank1) to the highest (rank5),
and whether the team was active, eligible for a prize.
"""
const M6_SUBMISSION_COLUMNS = ["entry", "submission", "evaluation", "symbol", "decision", "rank1", "rank2", "rank3", "rank4", "rank5", "active"]

"""The round of an M6 label in SQL: 0 for "Trial run", 1 for "1st Submission" and so on."""
m6_round(column) = "CASE WHEN $(column) = 'Trial run' THEN 0 ELSE CAST(regexp_extract($(column), '^([0-9]+)(st|nd|rd|th) Submission\$', 1) AS SMALLINT) END"

"""
The id and the name of a team of M6 as the leaderboard writes them, such as "cd597d34 StanekF_STU (CERGE-EI)": the
two are most often apart by a no-break space.
"""
function m6_team(text)
	space = findfirst(isspace, text)
	space === nothing && return (; id = String(text), name = missing)
	name = strip(text[nextind(text, space):end])
	(; id = String(text[1:prevind(text, space)]), name = isempty(name) ? missing : String(name))
end

"""
	read_m6_entries(db, submissions, leaderboard)

The teams of M6, from the file of submissions (every team that submitted, by its id) and the sheets Teams and Global
of `summary_leaderboard.xlsx` (their names, and the rank of those ranked over the whole year): `(; entry, name, kind,
team, rank)`, in the order of that rank, then the teams not ranked by their id. M6 Dummy, whose every submission
gives each asset the same probabilities and weight, is the benchmark.
"""
function read_m6_entries(db, submissions, leaderboard)
	ids = [row.Team for row in DBInterface.execute(db, "SELECT DISTINCT Team FROM read_csv($(sql_text(submissions)), all_varchar = true)")]
	rows = excel_rows(db, leaderboard, "Teams")
	rows[1][1:2] == ["Title", "TeamID_system"] || error("The sheet Teams of summary_leaderboard.xlsx does not start with Title and TeamID_system.")
	names = Dict(m6_team(row[1]).id => m6_team(row[1]).name for row in rows[2:end] if row[1] !== missing)
	rows = excel_rows(db, leaderboard, "Global")
	rows[1][1:2] == ["Position", "Team"] || error("The sheet Global of summary_leaderboard.xlsx does not start with Position and Team.")
	ranks = Dict(m6_team(row[2]).id => parse(Int16, row[1]) for row in rows[2:end] if row[1] !== missing)
	unknown = setdiff(union(keys(names), keys(ranks)), ids)
	isempty(unknown) || error("summary_leaderboard.xlsx names teams that submitted nothing: $(join(sort(collect(unknown)), ", ")).")
	order = sort(ids; by = id -> (get(ranks, id, typemax(Int16)), id))
	benchmark = [id for id in ids if get(names, id, missing) === "M6 Dummy"]
	length(benchmark) == 1 || error("summary_leaderboard.xlsx has $(length(benchmark)) teams named M6 Dummy, not one.")
	(; entry = Int16.(eachindex(order)), name = order, kind = [id in benchmark ? "benchmark" : "submission" for id in order],
		team = [get(names, id, missing) for id in order], rank = Union{Missing, Int16}[get(ranks, id, missing) for id in order])
end

"""
	read_m6_scores(db, path, numbers)

The published scores of M6 from `summary_leaderboard.xlsx`: `(; entry, measure, breakdown, level, value)`. The sheets
RPS, IR and OR give each team's ranked probability score, information ratio and overall rank for each month (levels 1
to 12), each quarter (1 to 4) and the whole year (Total); the sheet Trial gives the same of the trial run. An entry is
named as in `numbers` (team id => entry).
"""
function read_m6_scores(db, path, numbers)
	scores = (; entry = Int16[], measure = String[], breakdown = String[], level = String[], value = Float64[])
	function add(team, measure, breakdown, level, text)
		(text === missing || isempty(text) || text in ("NA", "#N/A")) && return
		entry = get(numbers, m6_team(team).id, nothing)
		entry === nothing && error("summary_leaderboard.xlsx scores team $(team), which submitted nothing.")
		push!(scores.entry, entry); push!(scores.measure, measure); push!(scores.breakdown, breakdown)
		push!(scores.level, level); push!(scores.value, parse(Float64, text))
	end
	for measure in ("RPS", "IR", "OR")
		rows = excel_rows(db, path, measure)
		header = rows[1]
		header[1:18] == ["Team"; ["M$(month)" for month in 1:12]; ["Q$(quarter)" for quarter in 1:4]; "Global"] ||
			error("The sheet $(measure) of summary_leaderboard.xlsx does not have the columns Team, M1 to M12, Q1 to Q4 and Global.")
		for row in rows[2:end]
			row[1] === missing && continue
			for month in 1:12
				add(row[1], measure, "month", string(month), row[1 + month])
			end
			for quarter in 1:4
				add(row[1], measure, "quarter", string(quarter), row[13 + quarter])
			end
			add(row[1], measure, "global", "Total", row[18])
		end
	end
	rows = excel_rows(db, path, "Trial")
	columns = Dict(name => index for (index, name) in enumerate(rows[1]) if name !== missing)
	for name in ("Team", "Overall Rank (OR)", "Performance of Forecasts (RPS)", "Performance of Decisions (IR)")
		haskey(columns, name) || error("The sheet Trial of summary_leaderboard.xlsx has no column $(name).")
	end
	for row in rows[2:end]
		row[columns["Team"]] === missing && continue
		for (measure, column) in (("RPS", "Performance of Forecasts (RPS)"), ("IR", "Performance of Decisions (IR)"), ("OR", "Overall Rank (OR)"))
			add(row[columns["Team"]], measure, "trial", "Trial", row[columns[column]])
		end
	end
	scores
end

"""
	convert_m6(id, source, target; progress)

M6 from its repository: `prices.parquet` (symbol, date, price) from `assets_m6.csv`, `entries.parquet` (the teams),
`submissions.parquet` from `submissions.csv`, a row for each team, round of evaluation and asset, and
`published_scores.parquet` from `summary_leaderboard.xlsx`.
"""
function convert_m6(id, source, target; progress = (done, total) -> nothing)
	prices = fetch_file(only(files_of(id, "prices")), source)
	submissions = fetch_file(only(files_of(id, "submissions")), source)
	leaderboard = fetch_file(only(files_of(id, "scores")), source)
	with_database() do db
		header = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM read_csv($(sql_text(prices)), all_varchar = true)")]
		header == ["symbol", "date", "price"] || error("assets_m6.csv has the columns $(join(header, ", ")), not symbol, date and price.")
		copy_parquet(db, "SELECT $(M6_PRICE_COLUMNS) FROM read_csv($(sql_text(prices)), all_varchar = true)", joinpath(target, "prices.parquet"); order = "symbol, date")
		progress(1, 4)
		entries = read_m6_entries(db, submissions, leaderboard)
		writer = TableWriter(db, "entries", ENTRY_COLUMNS)
		add!(writer, entries; constants = ("competition" => id, "forecasts" => "rank probabilities"))
		write_parquet(writer, joinpath(target, "entries.parquet"); order = "entry")
		progress(2, 4)
		csv = "read_csv($(sql_text(submissions)), all_varchar = true)"
		header = [row.column_name for row in DBInterface.execute(db, "DESCRIBE SELECT * FROM $(csv)")]
		expected = ["Team", "Submission", "Evaluation", "Symbol", "Decision", "Rank1", "Rank2", "Rank3", "Rank4", "Rank5", "IsActive"]
		header[1:11] == expected || error("submissions.csv has the columns $(join(header, ", ")), not those of M6.")
		select = """SELECT e.entry, $(m6_round("s.Submission")) AS submission, $(m6_round("s.Evaluation")) AS evaluation, s.Symbol AS symbol,
			CAST(s.Decision AS DOUBLE) AS decision, $(join(["CAST(s.Rank$(k) AS DOUBLE) AS rank$(k)" for k in 1:5], ", ")),
			s.IsActive = '1' AS active FROM $(csv) s JOIN entries e ON e.name = s.Team"""
		check = only(Tables.rowtable(DBInterface.execute(db, "SELECT count(*) AS rows, count(*) FILTER (WHERE submission IS NULL OR evaluation IS NULL) AS unread FROM ($(select))")))
		total = only(Tables.rowtable(DBInterface.execute(db, "SELECT count(*) AS rows FROM $(csv)"))).rows
		check.rows == total && check.unread == 0 || error("submissions.csv has rows whose team or round is not read: $(total - check.rows + check.unread) of $(total).")
		copy_parquet(db, select, joinpath(target, "submissions.parquet"); order = "entry, evaluation, symbol")
		progress(3, 4)
		scores = read_m6_scores(db, leaderboard, Dict(zip(entries.name, entries.entry)))
		writer = TableWriter(db, "published_scores", SCORE_COLUMNS)
		add!(writer, scores)
		write_parquet(writer, joinpath(target, "published_scores.parquet"); order = "entry, breakdown, measure, level")
		progress(4, 4)
	end
end
